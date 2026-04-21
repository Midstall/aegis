use aegis_ip::tile_bits;
use aegis_ip::tile_bits::TileConfig;
use aegis_ip::*;

/// Per-tile simulation state with per-track outputs.
#[derive(Clone)]
pub(crate) struct TileState {
    pub(crate) ff_q: bool,
    pub(crate) lut_out: bool,
    pub(crate) carry_out: bool,
    pub(crate) out: Vec<Vec<bool>>, // out[dir][track]
}

impl TileState {
    fn new(tracks: usize) -> Self {
        Self {
            ff_q: false,
            lut_out: false,
            carry_out: false,
            out: vec![vec![false; tracks]; 4],
        }
    }
}

/// Fast cycle-accurate simulator for an Aegis FPGA.
///
/// Simulates the full grid including IO ring tiles.
/// Grid coordinates use the viaduct convention:
///   - IO ring at x=0, x=gw-1, y=0, y=gh-1
///   - Fabric tiles at (1..gw-1, 1..gh-1)
pub struct Simulator {
    gw: usize,
    gh: usize,
    tracks: usize,
    configs: Vec<Vec<TileConfig>>,
    state: Vec<Vec<TileState>>,
    next_state: Vec<Vec<TileState>>,
    io_in: Vec<bool>,
    io_out: Vec<bool>,
    io_pad_pos: Vec<(usize, usize)>,
    active_tiles: Vec<(usize, usize)>,
    cycle: u64,
}

impl Simulator {
    /// Create a simulator from a device descriptor and bitstream.
    pub fn new(desc: &AegisFpgaDeviceDescriptor, bitstream: &[u8]) -> Self {
        let fabric_w = u64::from(desc.fabric.width) as usize;
        let fabric_h = u64::from(desc.fabric.height) as usize;
        let tracks = u64::from(desc.fabric.tracks) as usize;
        let gw = fabric_w + 2;
        let gh = fabric_h + 2;
        let total_pads = 2 * fabric_w + 2 * fabric_h;
        let min_width = tile_bits::tile_config_width(tracks);

        let mut fabric_base = 0usize;
        for section in &desc.config.chain_order {
            if matches!(section.section, ChainSectionSection::FabricTiles) {
                break;
            }
            fabric_base += section.total_bits as usize;
        }

        let mut tile_offsets = std::collections::HashMap::new();
        for tile in &desc.tiles {
            tile_offsets.insert(
                (tile.x as usize, tile.y as usize),
                (tile.config_offset as usize, tile.config_width as usize),
            );
        }

        let configs: Vec<Vec<TileConfig>> = (0..gw)
            .map(|gx| {
                (0..gh)
                    .map(|gy| {
                        if gx >= 1 && gx < gw - 1 && gy >= 1 && gy < gh - 1 {
                            let dx = gx - 1;
                            let dy = gy - 1;
                            if let Some(&(offset, config_width)) = tile_offsets.get(&(dx, dy)) {
                                if config_width >= min_width {
                                    TileConfig::decode(bitstream, fabric_base + offset, tracks)
                                } else {
                                    TileConfig::default_for(tracks)
                                }
                            } else {
                                TileConfig::default_for(tracks)
                            }
                        } else {
                            TileConfig::default_for(tracks)
                        }
                    })
                    .collect()
            })
            .collect();

        let mut io_pad_pos = Vec::with_capacity(total_pads);
        for x in 1..gw - 1 {
            io_pad_pos.push((x, 0));
        }
        for y in 1..gh - 1 {
            io_pad_pos.push((gw - 1, y));
        }
        for x in 1..gw - 1 {
            io_pad_pos.push((x, gh - 1));
        }
        for y in 1..gh - 1 {
            io_pad_pos.push((0, y));
        }

        let mut active_tiles = Vec::new();
        for x in 0..gw {
            for y in 0..gh {
                if x == 0 || x == gw - 1 || y == 0 || y == gh - 1 {
                    active_tiles.push((x, y));
                } else if configs[x][y].has_any_config() {
                    active_tiles.push((x, y));
                }
            }
        }

        let state = (0..gw)
            .map(|_| (0..gh).map(|_| TileState::new(tracks)).collect::<Vec<_>>())
            .collect::<Vec<_>>();
        let next_state = state.clone();

        Simulator {
            gw,
            gh,
            tracks,
            configs,
            state,
            next_state,
            io_in: vec![false; total_pads],
            io_out: vec![false; total_pads],
            io_pad_pos,
            active_tiles,
            cycle: 0,
        }
    }

    pub fn set_io(&mut self, pad: usize, value: bool) {
        if pad < self.io_in.len() {
            self.io_in[pad] = value;
        }
    }

    pub fn get_io(&self, pad: usize) -> bool {
        if pad < self.io_out.len() {
            self.io_out[pad]
        } else {
            false
        }
    }

    pub fn cycle(&self) -> u64 {
        self.cycle
    }

    fn is_io(&self, x: usize, y: usize) -> bool {
        x == 0 || x == self.gw - 1 || y == 0 || y == self.gh - 1
    }

    /// Simulate one clock cycle.
    pub fn step(&mut self) {
        let tracks = self.tracks;

        for &(x, y) in &self.active_tiles {
            let cfg = &self.configs[x][y];

            if self.is_io(x, y) {
                // IO ring tiles: per-track pass-through from opposite direction
                for dir in 0..4usize {
                    let opposite = [2, 3, 0, 1][dir];
                    for t in 0..tracks {
                        self.next_state[x][y].out[dir][t] = self.neighbor_output(x, y, opposite, t);
                    }
                }
                continue;
            }

            // Logic tile: evaluate CLB
            let inputs: [bool; 4] = std::array::from_fn(|i| self.select_input(x, y, cfg.sel[i]));

            let lut_addr = (inputs[0] as usize)
                | ((inputs[1] as usize) << 1)
                | ((inputs[2] as usize) << 2)
                | ((inputs[3] as usize) << 3);
            let lut_out = (cfg.lut_init >> lut_addr) & 1 == 1;

            let carry_in = if y < self.gh - 1 {
                self.state[x][y + 1].carry_out
            } else {
                false
            };
            let carry_out = if cfg.carry_mode {
                if lut_out { carry_in } else { inputs[0] }
            } else {
                false
            };

            // CLB output matches Dart: mux(carryMode, sum, mux(useFF, ffQ, lutOut))
            let clb_out = if cfg.carry_mode {
                lut_out ^ carry_in
            } else if cfg.ff_enable {
                self.state[x][y].ff_q
            } else {
                lut_out
            };

            self.next_state[x][y].lut_out = clb_out;
            self.next_state[x][y].carry_out = carry_out;
            // FF always captures LUT output (Dart: Sequential(clk, [ffQ < lutOut]))
            self.next_state[x][y].ff_q = lut_out;

            // Per-track output routing
            for dir in 0..4usize {
                for t in 0..tracks {
                    self.next_state[x][y].out[dir][t] = if cfg.en_out[dir][t] {
                        self.select_route(x, y, cfg.sel_out[dir][t], t, clb_out)
                    } else {
                        false
                    };
                }
            }
        }

        // Inject IO pad inputs into next_state AFTER tile evaluation
        for (pad_idx, &(px, py)) in self.io_pad_pos.iter().enumerate() {
            if pad_idx < self.io_in.len() {
                let val = self.io_in[pad_idx];
                let dir = if px == 0 {
                    1 // east toward fabric
                } else if px == self.gw - 1 {
                    3 // west toward fabric
                } else if py == 0 {
                    2 // south toward fabric
                } else {
                    0 // north toward fabric
                };
                // Drive all tracks in the direction toward fabric
                for t in 0..tracks {
                    self.next_state[px][py].out[dir][t] = val;
                }
            }
        }

        std::mem::swap(&mut self.state, &mut self.next_state);

        // Read IO pad outputs from IO ring tiles (track 0)
        for (pad_idx, &(px, py)) in self.io_pad_pos.iter().enumerate() {
            if pad_idx < self.io_out.len() {
                let dir = if px == 0 {
                    3 // west edge: read west output
                } else if px == self.gw - 1 {
                    1 // east edge: read east output
                } else if py == 0 {
                    0 // north edge: read north output
                } else {
                    2 // south edge: read south output
                };
                self.io_out[pad_idx] = self.state[px][py].out[dir][0];
            }
        }

        self.cycle += 1;
    }

    pub fn run(&mut self, cycles: u64) {
        for _ in 0..cycles {
            self.step();
        }
    }

    /// Get the output of a neighboring tile on a specific track.
    fn neighbor_output(&self, x: usize, y: usize, from_dir: usize, track: usize) -> bool {
        let (nx, ny, opp_dir) = match from_dir {
            0 if y > 0 => (x, y - 1, 2),           // from north
            1 if x < self.gw - 1 => (x + 1, y, 3), // from east
            2 if y < self.gh - 1 => (x, y + 1, 0), // from south
            3 if x > 0 => (x - 1, y, 1),           // from west
            _ => return false,
        };
        self.state[nx][ny].out[opp_dir]
            .get(track)
            .copied()
            .unwrap_or(false)
    }

    /// Input mux: decode select value to get input signal.
    /// Encoding: dir*T + track for directional, 4*T for CLB_OUT,
    /// 4*T+1 for const0, 4*T+2 for const1, 4*T+3..4*T+6 for neighbor N/E/S/W.
    fn select_input(&self, x: usize, y: usize, sel: u8) -> bool {
        let sel = sel as usize;
        let t = self.tracks;
        let clb_out_val = 4 * t;
        let const0_val = 4 * t + 1;
        let const1_val = 4 * t + 2;
        let nb_base = 4 * t + 3;

        if sel < clb_out_val {
            let dir = sel / t;
            let track = sel % t;
            self.neighbor_output(x, y, dir, track)
        } else if sel == clb_out_val {
            self.state[x][y].lut_out
        } else if sel == const0_val {
            false
        } else if sel == const1_val {
            true
        } else if sel >= nb_base && sel < nb_base + 4 {
            // Neighbor CLB output: N=0, E=1, S=2, W=3
            let nb_dir = sel - nb_base;
            let (nx, ny) = match nb_dir {
                0 => (x, y.wrapping_sub(1)), // north
                1 => (x + 1, y),             // east
                2 => (x, y + 1),             // south
                _ => (x.wrapping_sub(1), y), // west
            };
            if nx < self.gw && ny < self.gh {
                self.state[nx][ny].lut_out
            } else {
                false
            }
        } else {
            false
        }
    }

    /// Output mux: select source for a specific track.
    /// sel: 0=N, 1=E, 2=S, 3=W, 4=CLB_OUT. Track index is the output track.
    fn select_route(&self, x: usize, y: usize, sel: u8, track: usize, clb_out: bool) -> bool {
        match sel {
            0 => self.neighbor_output(x, y, 0, track),
            1 => self.neighbor_output(x, y, 1, track),
            2 => self.neighbor_output(x, y, 2, track),
            3 => self.neighbor_output(x, y, 3, track),
            4 => clb_out,
            _ => false,
        }
    }
}

/// VCD waveform writer.
pub struct VcdWriter {
    buf: String,
    signals: Vec<(String, char)>,
    next_id: char,
}

impl VcdWriter {
    pub fn new(timescale: &str) -> Self {
        let mut buf = String::new();
        buf.push_str(&format!("$timescale {timescale} $end\n"));
        buf.push_str("$scope module top $end\n");
        Self {
            buf,
            signals: Vec::new(),
            next_id: '!',
        }
    }

    pub fn add_signal(&mut self, name: &str) -> char {
        let id = self.next_id;
        self.next_id = (self.next_id as u8 + 1) as char;
        self.buf
            .push_str(&format!("$var wire 1 {id} {name} $end\n"));
        self.signals.push((name.to_string(), id));
        id
    }

    pub fn finish_header(&mut self) {
        self.buf.push_str("$upscope $end\n");
        self.buf.push_str("$enddefinitions $end\n");
    }

    pub fn timestamp(&mut self, t: u64) {
        self.buf.push_str(&format!("#{t}\n"));
    }

    pub fn set_value(&mut self, id: char, value: bool) {
        self.buf
            .push_str(&format!("{}{id}\n", if value { '1' } else { '0' }));
    }

    pub fn finish(self) -> String {
        self.buf
    }
}

#[cfg(test)]
mod tests;
