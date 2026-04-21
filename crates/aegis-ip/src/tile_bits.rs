//! Shared tile config bit layout for Aegis FPGA.
//!
//! This crate is the single source of truth for the tile configuration
//! bitstream layout. Both the packer (aegis-pack) and simulator (aegis-sim)
//! depend on this crate to ensure their bit layouts are identical.
//!
//! Layout for T tracks:
//!   [17:0]              CLB config (16 LUT init + 1 FF enable + 1 carry mode)
//!   [18..18+4*ISW-1]    input mux sel0..sel3 (ISW = input_sel_width(T))
//!   [18+4*ISW..]        per-track output: 4 dirs × T tracks × (1 en + 3 sel)
//!
//! For T=1: 50 bits
//! For T=4: 102 bits

// --- Fixed offsets (track-independent) ---

pub const LUT_INIT: usize = 0;
pub const LUT_INIT_WIDTH: usize = 16;
pub const FF_ENABLE: usize = 16;
pub const CARRY_MODE: usize = 17;
pub const INPUT_SEL_BASE: usize = 18;

// --- Output mux select values ---

pub const OUT_MUX_NORTH: u64 = 0;
pub const OUT_MUX_EAST: u64 = 1;
pub const OUT_MUX_SOUTH: u64 = 2;
pub const OUT_MUX_WEST: u64 = 3;
pub const OUT_MUX_CLB: u64 = 4;

pub const OUTPUT_SEL_WIDTH: usize = 3;

// --- Parametric layout functions ---

/// Width of input select field for T tracks.
/// Encodes: N0..N(T-1), E0..E(T-1), S0..S(T-1), W0..W(T-1),
///          CLB_OUT, const0, const1, NB_N, NB_E, NB_S, NB_W
pub fn input_sel_width(tracks: usize) -> usize {
    let n = 4 * tracks + 7;
    (usize::BITS - (n - 1).leading_zeros()) as usize
}

/// Bit offset of input sel[idx] for T tracks.
pub fn input_sel_offset(idx: usize, tracks: usize) -> usize {
    INPUT_SEL_BASE + idx * input_sel_width(tracks)
}

/// Base offset of the per-track output section.
pub fn output_base(tracks: usize) -> usize {
    INPUT_SEL_BASE + 4 * input_sel_width(tracks)
}

/// Enable bit offset for output (dir, track).
pub fn output_en(dir: usize, track: usize, tracks: usize) -> usize {
    output_base(tracks) + (dir * tracks + track) * 4
}

/// Select field offset for output (dir, track). 3 bits wide.
pub fn output_sel(dir: usize, track: usize, tracks: usize) -> usize {
    output_base(tracks) + (dir * tracks + track) * 4 + 1
}

/// Total tile config width for T tracks.
pub fn tile_config_width(tracks: usize) -> usize {
    18 + 4 * input_sel_width(tracks) + 4 * tracks * 4
}

/// Input mux select value for direction + track.
pub fn mux_dir_track(dir: usize, track: usize, tracks: usize) -> u64 {
    (dir * tracks + track) as u64
}

/// Input mux select value for CLB output.
pub fn mux_clb_out(tracks: usize) -> u64 {
    (4 * tracks) as u64
}

/// Input mux select value for constant 0.
pub fn mux_const0(tracks: usize) -> u64 {
    (4 * tracks + 1) as u64
}

/// Input mux select value for constant 1.
pub fn mux_const1(tracks: usize) -> u64 {
    (4 * tracks + 2) as u64
}

/// Input mux select value for neighbor CLB output (direction 0=N, 1=E, 2=S, 3=W).
pub fn mux_neighbor(dir: usize, tracks: usize) -> u64 {
    (4 * tracks + 3 + dir) as u64
}

// --- Bitstream read/write helpers ---

/// Set a single bit in a bitstream buffer.
pub fn set_bit(bits: &mut [u8], offset: usize) {
    bits[offset / 8] |= 1 << (offset % 8);
}

/// Clear bits at a given offset and width.
pub fn clear_bits(bits: &mut [u8], offset: usize, width: usize) {
    for i in 0..width {
        bits[(offset + i) / 8] &= !(1 << ((offset + i) % 8));
    }
}

/// Write a value into the bitstream at a given bit offset and width.
pub fn write_bits(bits: &mut [u8], offset: usize, value: u64, width: usize) {
    clear_bits(bits, offset, width);
    for i in 0..width {
        if value & (1 << i) != 0 {
            set_bit(bits, offset + i);
        }
    }
}

/// Read a value from the bitstream at a given bit offset and width.
pub fn read_bits(bits: &[u8], offset: usize, width: usize) -> u64 {
    let mut val = 0u64;
    for i in 0..width {
        let byte_idx = (offset + i) / 8;
        let bit_idx = (offset + i) % 8;
        if byte_idx < bits.len() && bits[byte_idx] & (1 << bit_idx) != 0 {
            val |= 1 << i;
        }
    }
    val
}

/// Read a single bit from the bitstream.
pub fn read_bit(bits: &[u8], offset: usize) -> bool {
    let byte_idx = offset / 8;
    let bit_idx = offset % 8;
    byte_idx < bits.len() && bits[byte_idx] & (1 << bit_idx) != 0
}

// --- Decoded tile configuration ---

/// Decoded tile configuration with per-track output muxes.
#[derive(Clone, Debug, PartialEq)]
pub struct TileConfig {
    pub lut_init: u16,
    pub ff_enable: bool,
    pub carry_mode: bool,
    pub sel: [u8; 4],
    pub en_out: Vec<Vec<bool>>,
    pub sel_out: Vec<Vec<u8>>,
}

impl TileConfig {
    pub fn default_for(tracks: usize) -> Self {
        Self {
            lut_init: 0,
            ff_enable: false,
            carry_mode: false,
            sel: [0; 4],
            en_out: vec![vec![false; tracks]; 4],
            sel_out: vec![vec![0; tracks]; 4],
        }
    }

    pub fn has_any_config(&self) -> bool {
        self.lut_init != 0
            || self.ff_enable
            || self.carry_mode
            || self.en_out.iter().any(|d| d.iter().any(|&e| e))
            || self.sel.iter().any(|&s| s != 0)
    }

    /// Encode this tile config into a bitstream buffer at the given offset.
    pub fn encode(&self, bits: &mut [u8], bit_offset: usize, tracks: usize) {
        write_bits(
            bits,
            bit_offset + LUT_INIT,
            self.lut_init as u64,
            LUT_INIT_WIDTH,
        );
        if self.ff_enable {
            set_bit(bits, bit_offset + FF_ENABLE);
        }
        if self.carry_mode {
            set_bit(bits, bit_offset + CARRY_MODE);
        }
        let isw = input_sel_width(tracks);
        for i in 0..4 {
            write_bits(
                bits,
                bit_offset + input_sel_offset(i, tracks),
                self.sel[i] as u64,
                isw,
            );
        }
        for dir in 0..4 {
            for t in 0..tracks {
                if dir < self.en_out.len() && t < self.en_out[dir].len() && self.en_out[dir][t] {
                    set_bit(bits, bit_offset + output_en(dir, t, tracks));
                }
                if dir < self.sel_out.len() && t < self.sel_out[dir].len() {
                    write_bits(
                        bits,
                        bit_offset + output_sel(dir, t, tracks),
                        self.sel_out[dir][t] as u64,
                        OUTPUT_SEL_WIDTH,
                    );
                }
            }
        }
    }

    /// Decode a tile config from bitstream bits at the given offset.
    pub fn decode(bitstream: &[u8], bit_offset: usize, tracks: usize) -> Self {
        let isw = input_sel_width(tracks);

        let sel = std::array::from_fn(|i| {
            read_bits(bitstream, bit_offset + input_sel_offset(i, tracks), isw) as u8
        });

        let en_out = (0..4)
            .map(|d| {
                (0..tracks)
                    .map(|t| read_bit(bitstream, bit_offset + output_en(d, t, tracks)))
                    .collect()
            })
            .collect();

        let sel_out = (0..4)
            .map(|d| {
                (0..tracks)
                    .map(|t| {
                        read_bits(
                            bitstream,
                            bit_offset + output_sel(d, t, tracks),
                            OUTPUT_SEL_WIDTH,
                        ) as u8
                    })
                    .collect()
            })
            .collect();

        TileConfig {
            lut_init: read_bits(bitstream, bit_offset + LUT_INIT, LUT_INIT_WIDTH) as u16,
            ff_enable: read_bit(bitstream, bit_offset + FF_ENABLE),
            carry_mode: read_bit(bitstream, bit_offset + CARRY_MODE),
            sel,
            en_out,
            sel_out,
        }
    }
}

#[cfg(test)]
#[path = "tile_bits_tests.rs"]
mod tests;
