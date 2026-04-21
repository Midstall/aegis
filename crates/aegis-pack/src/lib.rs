use aegis_ip::*;
use serde::Deserialize;
use serde_json::Value;
use std::collections::HashMap;

/// A placed cell from nextpnr's JSON output.
#[derive(Debug, Deserialize)]
pub struct PnrCell {
    #[serde(rename = "type")]
    pub cell_type: String,
    #[serde(default)]
    pub attributes: HashMap<String, String>,
    #[serde(default)]
    pub parameters: HashMap<String, String>,
    #[serde(default)]
    pub port_directions: HashMap<String, String>,
}

/// A net from nextpnr's JSON output.
#[derive(Debug, Deserialize)]
pub struct PnrNet {
    #[serde(default)]
    pub attributes: HashMap<String, Value>,
    #[serde(default)]
    pub bits: Vec<Value>,
}

/// Top-level nextpnr JSON output.
#[derive(Debug, Deserialize)]
pub struct PnrOutput {
    pub modules: HashMap<String, PnrModule>,
}

/// A module in the nextpnr output.
#[derive(Debug, Deserialize)]
pub struct PnrModule {
    #[serde(default)]
    pub cells: HashMap<String, PnrCell>,
    #[serde(default)]
    pub netnames: HashMap<String, PnrNet>,
}

use aegis_ip::tile_bits;

/// Pack a nextpnr-placed design into a bitstream.
///
/// Returns the raw bitstream bytes matching the config chain order:
/// clock tiles → IO tiles → SerDes tiles → fabric tiles (row-major).
pub fn pack(desc: &AegisFpgaDeviceDescriptor, pnr: &PnrOutput) -> Vec<u8> {
    let total_bits = desc.config.total_bits as usize;
    let mut bits = vec![0u8; (total_bits + 7) / 8];

    let module = pnr
        .modules
        .values()
        .next()
        .expect("No modules in PnR output");

    // Build tile lookup: (x, y) → config offset within the fabric section
    let tile_offsets: HashMap<(i64, i64), (usize, usize)> = desc
        .tiles
        .iter()
        .map(|t| {
            (
                (t.x, t.y),
                (t.config_offset as usize, t.config_width as usize),
            )
        })
        .collect();

    // Compute the bit offset where the fabric_tiles section starts
    let mut fabric_base = 0usize;
    for section in &desc.config.chain_order {
        if matches!(section.section, ChainSectionSection::FabricTiles) {
            break;
        }
        fabric_base += section.total_bits as usize;
    }

    // Pack cell configurations
    for (_name, cell) in &module.cells {
        let loc = cell_location(cell);
        match cell.cell_type.as_str() {
            "AEGIS_LUT4" | "$lut" => {
                if let Some((x, y)) = loc {
                    pack_lut4(&mut bits, cell, x, y, &tile_offsets, fabric_base);
                }
            }
            "AEGIS_DFF" | "$_DFF_P_" => {
                if let Some((x, y)) = loc {
                    pack_dff(&mut bits, x, y, &tile_offsets, fabric_base);
                }
            }
            "AEGIS_CARRY" => {
                if let Some((x, y)) = loc {
                    pack_carry(&mut bits, x, y, &tile_offsets, fabric_base);
                }
            }
            "AEGIS_BRAM" => {
                if let Some((x, y)) = loc {
                    pack_bram(&mut bits, x, y, &tile_offsets, fabric_base);
                }
            }
            _ => {}
        }
    }

    // Pack routing from pip names
    let tracks = u64::from(desc.fabric.tracks) as usize;
    pack_routing(&mut bits, pnr, &tile_offsets, fabric_base, tracks);

    bits
}

/// Extract BEL location (x, y) from cell attributes.
///
/// Looks for `"place"` or `"nextpnr_bel"` attributes with format `"X{x}/Y{y}/..."`.
fn cell_location(cell: &PnrCell) -> Option<(i64, i64)> {
    let bel = cell
        .attributes
        .get("place")
        .or_else(|| cell.attributes.get("NEXTPNR_BEL"))
        .or_else(|| cell.attributes.get("nextpnr_bel"))?;
    // Convert viaduct grid coords to descriptor tile coords (-1 for IO ring)
    let (x, y) = parse_xy(bel)?;
    Some((x - 1, y - 1))
}

/// Parse "X{x}/Y{y}/..." into (x, y).
fn parse_xy(s: &str) -> Option<(i64, i64)> {
    let parts: Vec<&str> = s.split('/').collect();
    if parts.len() < 2 {
        return None;
    }
    let x = parts[0].strip_prefix('X')?.parse().ok()?;
    let y = parts[1].strip_prefix('Y')?.parse().ok()?;
    Some((x, y))
}

use aegis_ip::tile_bits::{set_bit, write_bits};

fn pack_lut4(
    bits: &mut [u8],
    cell: &PnrCell,
    x: i64,
    y: i64,
    tile_offsets: &HashMap<(i64, i64), (usize, usize)>,
    fabric_base: usize,
) {
    let Some(&(tile_offset, _)) = tile_offsets.get(&(x, y)) else {
        return;
    };

    let init = cell
        .parameters
        .get("LUT")
        .or_else(|| cell.parameters.get("INIT"))
        .and_then(|v| parse_param(v, 16))
        .unwrap_or(0);

    write_bits(
        bits,
        fabric_base + tile_offset + tile_bits::LUT_INIT,
        init,
        tile_bits::LUT_INIT_WIDTH,
    );
}

fn pack_dff(
    bits: &mut [u8],
    x: i64,
    y: i64,
    tile_offsets: &HashMap<(i64, i64), (usize, usize)>,
    fabric_base: usize,
) {
    let Some(&(tile_offset, _)) = tile_offsets.get(&(x, y)) else {
        return;
    };
    set_bit(bits, fabric_base + tile_offset + tile_bits::FF_ENABLE);
}

fn pack_carry(
    bits: &mut [u8],
    x: i64,
    y: i64,
    tile_offsets: &HashMap<(i64, i64), (usize, usize)>,
    fabric_base: usize,
) {
    let Some(&(tile_offset, _)) = tile_offsets.get(&(x, y)) else {
        return;
    };
    set_bit(bits, fabric_base + tile_offset + tile_bits::CARRY_MODE);
}

fn pack_bram(
    bits: &mut [u8],
    x: i64,
    y: i64,
    tile_offsets: &HashMap<(i64, i64), (usize, usize)>,
    fabric_base: usize,
) {
    let Some(&(tile_offset, _)) = tile_offsets.get(&(x, y)) else {
        return;
    };
    set_bit(bits, fabric_base + tile_offset); // port A enable
    set_bit(bits, fabric_base + tile_offset + 1); // port B enable
}

/// Pack routing configuration by parsing pip names from routed nets.
///
/// The ROUTING attribute contains semicolon-separated entries:
///   wire_name;pip_name;strength
/// where pip_name is "dst_wire/src_wire".
///
/// Pip names use directional wire names:
///   CLB_I{n} = CLB input n
///   CLB_O    = CLB output (LUT out)
///   CLB_Q    = FF output
///   N{t}     = north track t
///   E{t}     = east track t
///   S{t}     = south track t
///   W{t}     = west track t
///   CLK      = clock wire
fn pack_routing(
    bits: &mut [u8],
    pnr: &PnrOutput,
    tile_offsets: &HashMap<(i64, i64), (usize, usize)>,
    fabric_base: usize,
    tracks: usize,
) {
    let module = match pnr.modules.values().next() {
        Some(m) => m,
        None => return,
    };

    for (_name, net) in &module.netnames {
        let route = match net.attributes.get("ROUTING") {
            Some(Value::String(s)) => s.clone(),
            _ => continue,
        };

        // Parse semicolon-separated entries: wire;pip;strength
        let parts: Vec<&str> = route.split(';').collect();
        let mut i = 0;
        while i + 2 < parts.len() {
            let _wire = parts[i];
            let pip = parts[i + 1];
            let _strength = parts[i + 2];
            i += 3;

            pack_routing_pip(bits, pip, tile_offsets, fabric_base, tracks);
        }
    }
}

/// Parse and pack a single routing pip.
///
/// Pip format: "X{dx}/Y{dy}/dst_wire/X{sx}/Y{sy}/src_wire"
///
/// For multi-span pips (where source and destination are more than 1 tile
/// apart), this also fills in pass-through routing on intermediate tiles.
fn pack_routing_pip(
    bits: &mut [u8],
    pip: &str,
    tile_offsets: &HashMap<(i64, i64), (usize, usize)>,
    fabric_base: usize,
    tracks: usize,
) {
    let parts: Vec<&str> = pip.split('/').collect();
    if parts.len() < 4 {
        return;
    }

    let dst_gx: i64 = match parts[0]
        .strip_prefix('X')
        .and_then(|s| s.parse::<i64>().ok())
    {
        Some(v) => v,
        None => return,
    };
    let dst_gy: i64 = match parts[1]
        .strip_prefix('Y')
        .and_then(|s| s.parse::<i64>().ok())
    {
        Some(v) => v,
        None => return,
    };
    let dst_x = dst_gx - 1;
    let dst_y = dst_gy - 1;
    let dst_wire = parts[2];

    let (src_gx, src_gy, src_wire) = if parts.len() >= 6 {
        let sx: i64 = match parts[3]
            .strip_prefix('X')
            .and_then(|s| s.parse::<i64>().ok())
        {
            Some(v) => v,
            None => return,
        };
        let sy: i64 = match parts[4]
            .strip_prefix('Y')
            .and_then(|s| s.parse::<i64>().ok())
        {
            Some(v) => v,
            None => return,
        };
        (sx, sy, parts[5])
    } else {
        (dst_gx, dst_gy, parts[3])
    };

    // Fill intermediate tiles for multi-span pips
    let dx = dst_gx - src_gx;
    let dy = dst_gy - src_gy;
    if dx.abs() > 1 || dy.abs() > 1 {
        let steps = dx.abs().max(dy.abs());
        let step_x = if dx != 0 { dx.signum() } else { 0 };
        let step_y = if dy != 0 { dy.signum() } else { 0 };

        // Determine flow direction and extract track from source wire
        let (from_dir, to_dir, track) = if dy < 0 {
            (
                tile_bits::OUT_MUX_SOUTH,
                0usize, // north
                parse_track(src_wire).unwrap_or(0),
            )
        } else if dy > 0 {
            (
                tile_bits::OUT_MUX_NORTH,
                2usize, // south
                parse_track(src_wire).unwrap_or(0),
            )
        } else if dx > 0 {
            (
                tile_bits::OUT_MUX_WEST,
                1usize, // east
                parse_track(src_wire).unwrap_or(0),
            )
        } else {
            (
                tile_bits::OUT_MUX_EAST,
                3usize, // west
                parse_track(src_wire).unwrap_or(0),
            )
        };

        let min_width = tile_bits::tile_config_width(tracks);
        for step in 1..steps {
            let ix = (src_gx + step_x * step) - 1;
            let iy = (src_gy + step_y * step) - 1;
            if let Some(&(tile_offset, config_width)) = tile_offsets.get(&(ix, iy)) {
                if config_width >= min_width {
                    let base = fabric_base + tile_offset;
                    set_bit(bits, base + tile_bits::output_en(to_dir, track, tracks));
                    write_bits(
                        bits,
                        base + tile_bits::output_sel(to_dir, track, tracks),
                        from_dir,
                        tile_bits::OUTPUT_SEL_WIDTH,
                    );
                }
            }
        }
    }

    // Neighbor direct connections: adjacent CLB output -> this tile's CLB input
    if src_gx != dst_gx || src_gy != dst_gy {
        if let Some(rest) = dst_wire.strip_prefix("CLB_I") {
            if let Ok(idx) = rest.parse::<usize>() {
                if idx < 4 && (src_wire == "CLB_O" || src_wire == "CLB_Q") {
                    let nb_dir = if dy == 1 {
                        0
                    }
                    // src is north
                    else if dx == -1 {
                        1
                    }
                    // src is east
                    else if dy == -1 {
                        2
                    }
                    // src is south
                    else {
                        3
                    }; // src is west
                    if let Some(&(tile_offset, config_width)) = tile_offsets.get(&(dst_x, dst_y)) {
                        let min_width = tile_bits::tile_config_width(tracks);
                        if config_width >= min_width {
                            let base = fabric_base + tile_offset;
                            let isw = tile_bits::input_sel_width(tracks);
                            let sel_val = tile_bits::mux_neighbor(nb_dir, tracks);
                            let sel_offset = base + tile_bits::input_sel_offset(idx, tracks);
                            write_bits(bits, sel_offset, sel_val, isw);
                        }
                    }
                }
            }
        }
        return;
    }

    let Some(&(tile_offset, config_width)) = tile_offsets.get(&(dst_x, dst_y)) else {
        return;
    };
    let min_width = tile_bits::tile_config_width(tracks);
    if config_width < min_width {
        return;
    }

    let base = fabric_base + tile_offset;
    let isw = tile_bits::input_sel_width(tracks);

    // CLB input mux: dst is CLB_I{n}, src is a track or CLB wire
    if let Some(rest) = dst_wire.strip_prefix("CLB_I") {
        if let Ok(idx) = rest.parse::<usize>() {
            if idx < 4 {
                if let Some(sel_val) = wire_to_input_sel(src_wire, tracks) {
                    let sel_offset = base + tile_bits::input_sel_offset(idx, tracks);
                    write_bits(bits, sel_offset, sel_val, isw);
                }
            }
        }
        return;
    }

    // Per-track output mux: dst is OUT_N{t}/OUT_E{t}/OUT_S{t}/OUT_W{t}
    if let Some((dir, track)) = parse_output_mux_wire(dst_wire) {
        let sel_val = if src_wire == "CLB_O" || src_wire == "CLB_Q" {
            tile_bits::OUT_MUX_CLB
        } else if let Some((src_dir, _)) = parse_track_wire(src_wire) {
            src_dir as u64
        } else {
            return;
        };
        set_bit(bits, base + tile_bits::output_en(dir, track, tracks));
        write_bits(
            bits,
            base + tile_bits::output_sel(dir, track, tracks),
            sel_val,
            tile_bits::OUTPUT_SEL_WIDTH,
        );
        return;
    }
}

/// Parse a track wire name like "N0", "E3" into (direction, track).
fn parse_track_wire(wire: &str) -> Option<(usize, usize)> {
    let (prefix, rest) = wire.split_at(1);
    if !rest.chars().all(|c| c.is_ascii_digit()) || rest.is_empty() {
        return None;
    }
    let track: usize = rest.parse().ok()?;
    let dir = match prefix {
        "N" => 0,
        "E" => 1,
        "S" => 2,
        "W" => 3,
        _ => return None,
    };
    Some((dir, track))
}

/// Extract the track number from a wire name (e.g., "S1" -> 1, "N0" -> 0, "OUT_N0" -> 0).
fn parse_track(wire: &str) -> Option<usize> {
    parse_track_wire(wire)
        .or_else(|| parse_output_mux_wire(wire))
        .map(|(_, t)| t)
}

/// Parse a per-track output mux wire like "OUT_N0", "OUT_E3".
fn parse_output_mux_wire(wire: &str) -> Option<(usize, usize)> {
    let rest = wire.strip_prefix("OUT_")?;
    let (dir_ch, track_str) = rest.split_at(1);
    if track_str.is_empty() || !track_str.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let track: usize = track_str.parse().ok()?;
    let dir = match dir_ch {
        "N" => 0,
        "E" => 1,
        "S" => 2,
        "W" => 3,
        _ => return None,
    };
    Some((dir, track))
}

/// Map a source wire name to an input mux select value for T tracks.
/// Encoding: dir*T + track for directional, 4*T for CLB_OUT.
fn wire_to_input_sel(wire: &str, tracks: usize) -> Option<u64> {
    if let Some((dir, track)) = parse_track_wire(wire) {
        Some(tile_bits::mux_dir_track(dir, track, tracks))
    } else if wire == "CLB_O" || wire == "CLB_Q" {
        Some(tile_bits::mux_clb_out(tracks))
    } else {
        None
    }
}

/// Parse a nextpnr parameter value.
fn parse_param(value: &str, width: usize) -> Option<u64> {
    if let Some(rest) = value.strip_prefix(&format!("{width}'b")) {
        u64::from_str_radix(rest, 2).ok()
    } else if let Some(rest) = value.strip_prefix(&format!("{width}'h")) {
        u64::from_str_radix(rest, 16).ok()
    } else if !value.is_empty() && value.chars().all(|c| c == '0' || c == '1') {
        // Plain binary string (nextpnr $lut LUT parameter format)
        u64::from_str_radix(value, 2).ok()
    } else {
        value.parse().ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_binary_param() {
        assert_eq!(parse_param("16'b1010101010101010", 16), Some(0xAAAA));
    }

    #[test]
    fn parse_hex_param() {
        assert_eq!(parse_param("16'hDEAD", 16), Some(0xDEAD));
    }

    #[test]
    fn parse_integer_param() {
        assert_eq!(parse_param("42", 16), Some(42));
    }

    #[test]
    fn write_bits_at_offset_zero() {
        let mut bits = vec![0u8; 4];
        write_bits(&mut bits, 0, 0xABCD, 16);
        assert_eq!(bits[0], 0xCD);
        assert_eq!(bits[1], 0xAB);
    }

    #[test]
    fn write_bits_at_offset() {
        let mut bits = vec![0u8; 4];
        write_bits(&mut bits, 8, 0xFF, 8);
        assert_eq!(bits[0], 0x00);
        assert_eq!(bits[1], 0xFF);
    }

    #[test]
    fn set_individual_bit() {
        let mut bits = vec![0u8; 2];
        set_bit(&mut bits, 0);
        set_bit(&mut bits, 7);
        set_bit(&mut bits, 8);
        assert_eq!(bits[0], 0x81);
        assert_eq!(bits[1], 0x01);
    }

    /// Build a minimal descriptor for testing.
    fn test_descriptor() -> AegisFpgaDeviceDescriptor {
        serde_json::from_str(
            r#"{
            "device": "test",
            "fabric": {
                "width": 2, "height": 2, "tracks": 1,
                "tile_config_width": 50,
                "bram": { "column_interval": 0, "columns": [],
                          "data_width": null, "addr_width": null,
                          "depth": null, "tile_config_width": 8 },
                "dsp": { "column_interval": 0, "columns": [],
                         "a_width": null, "b_width": null,
                         "result_width": null, "tile_config_width": 16 },
                "carry_chain": { "direction": "south_to_north", "per_column": true }
            },
            "io": { "total_pads": 8, "tile_config_width": 8, "pads": [] },
            "serdes": { "count": 0, "tile_config_width": 32, "edge_assignment": [] },
            "clock": { "tile_count": 0, "tile_config_width": 49,
                       "outputs_per_tile": 4, "total_outputs": 0 },
            "config": {
                "total_bits": 264,
                "chain_order": [
                    { "section": "io_tiles", "count": 8,
                      "bits_per_tile": 8, "total_bits": 64 },
                    { "section": "fabric_tiles", "count": 4,
                      "total_bits": 200 }
                ]
            },
            "tiles": [
                { "x": 0, "y": 0, "type": "lut", "config_width": 50, "config_offset": 0 },
                { "x": 1, "y": 0, "type": "lut", "config_width": 50, "config_offset": 50 },
                { "x": 0, "y": 1, "type": "lut", "config_width": 50, "config_offset": 100 },
                { "x": 1, "y": 1, "type": "lut", "config_width": 50, "config_offset": 150 }
            ]
        }"#,
        )
        .unwrap()
    }

    /// Create PnR output with a LUT at descriptor coords (x, y).
    /// Adds +1 to simulate viaduct IO ring offset.
    fn test_pnr_with_lut(x: i64, y: i64, init: &str) -> PnrOutput {
        let gx = x + 1;
        let gy = y + 1;
        let mut cells = HashMap::new();
        let mut attrs = HashMap::new();
        attrs.insert("place".to_string(), format!("X{gx}/Y{gy}/LUT4"));
        let mut params = HashMap::new();
        params.insert("INIT".to_string(), init.to_string());
        cells.insert(
            "lut0".to_string(),
            PnrCell {
                cell_type: "AEGIS_LUT4".to_string(),
                attributes: attrs,
                parameters: params,
                port_directions: HashMap::new(),
            },
        );
        let mut modules = HashMap::new();
        modules.insert(
            "top".to_string(),
            PnrModule {
                cells,
                netnames: HashMap::new(),
            },
        );
        PnrOutput { modules }
    }

    /// Create a PnR output with routing pips.
    /// Each pip is "dst_wire;pip_name;1" in ROUTING format.
    fn test_pnr_with_routing(pips: &[&str]) -> PnrOutput {
        let mut netnames = HashMap::new();
        // Build ROUTING attribute: wire;pip;strength triplets
        let mut route_parts = Vec::new();
        for pip in pips {
            // pip format: "X{x}/Y{y}/dst/X{x}/Y{y}/src"
            // Extract the dst wire (first 3 parts) as the wire entry
            let wire_parts: Vec<&str> = pip.split('/').collect();
            let wire = if wire_parts.len() >= 3 {
                format!("{}/{}/{}", wire_parts[0], wire_parts[1], wire_parts[2])
            } else {
                pip.to_string()
            };
            route_parts.push(format!("{};{};1", wire, pip));
        }
        let route_str = route_parts.join(";");
        let mut attrs = HashMap::new();
        attrs.insert("ROUTING".to_string(), Value::String(route_str));
        netnames.insert(
            "net0".to_string(),
            PnrNet {
                attributes: attrs,
                bits: vec![],
            },
        );
        let mut modules = HashMap::new();
        modules.insert(
            "top".to_string(),
            PnrModule {
                cells: HashMap::new(),
                netnames,
            },
        );
        PnrOutput { modules }
    }

    fn read_bits(bits: &[u8], offset: usize, width: usize) -> u64 {
        let mut val = 0u64;
        for i in 0..width {
            if bits[(offset + i) / 8] & (1 << ((offset + i) % 8)) != 0 {
                val |= 1 << i;
            }
        }
        val
    }

    #[test]
    fn pack_lut4_at_origin() {
        let desc = test_descriptor();
        let pnr = test_pnr_with_lut(0, 0, "16'hAAAA");
        let bits = pack(&desc, &pnr);

        let init = read_bits(&bits, 64, 16); // fabric_base=64, tile_offset=0
        assert_eq!(init, 0xAAAA);
    }

    #[test]
    fn pack_lut4_at_offset_tile() {
        let desc = test_descriptor();
        let pnr = test_pnr_with_lut(1, 0, "16'h1234");
        let bits = pack(&desc, &pnr);

        let init = read_bits(&bits, 64 + 50, 16); // tile (1,0) offset=50
        assert_eq!(init, 0x1234);
    }

    #[test]
    fn pack_dff_sets_ff_enable() {
        let desc = test_descriptor();
        let mut cells = HashMap::new();
        let mut attrs = HashMap::new();
        attrs.insert("place".to_string(), "X1/Y1/DFF".to_string());
        cells.insert(
            "dff0".to_string(),
            PnrCell {
                cell_type: "AEGIS_DFF".to_string(),
                attributes: attrs,
                parameters: HashMap::new(),
                port_directions: HashMap::new(),
            },
        );
        let mut modules = HashMap::new();
        modules.insert(
            "top".to_string(),
            PnrModule {
                cells,
                netnames: HashMap::new(),
            },
        );
        let bits = pack(&desc, &PnrOutput { modules });

        assert_ne!(read_bits(&bits, 64 + tile_bits::FF_ENABLE, 1), 0);
    }

    #[test]
    fn pack_carry_sets_carry_mode() {
        let desc = test_descriptor();
        let mut cells = HashMap::new();
        let mut attrs = HashMap::new();
        attrs.insert("place".to_string(), "X2/Y2/CARRY".to_string());
        cells.insert(
            "carry0".to_string(),
            PnrCell {
                cell_type: "AEGIS_CARRY".to_string(),
                attributes: attrs,
                parameters: HashMap::new(),
                port_directions: HashMap::new(),
            },
        );
        let mut modules = HashMap::new();
        modules.insert(
            "top".to_string(),
            PnrModule {
                cells,
                netnames: HashMap::new(),
            },
        );
        let bits = pack(&desc, &PnrOutput { modules });

        // tile (1,1) offset=150
        assert_ne!(read_bits(&bits, 64 + 150 + tile_bits::CARRY_MODE, 1), 0);
    }

    #[test]
    fn pack_routing_input_mux_north() {
        let desc = test_descriptor();
        let tracks = 1;
        let pnr = test_pnr_with_routing(&["X1/Y1/CLB_I0/X1/Y1/N0"]);
        let bits = pack(&desc, &pnr);

        let isw = tile_bits::input_sel_width(tracks);
        let sel = read_bits(&bits, 64 + tile_bits::input_sel_offset(0, tracks), isw);
        assert_eq!(sel, tile_bits::mux_dir_track(0, 0, tracks)); // N0
    }

    #[test]
    fn pack_routing_input_mux_east() {
        let desc = test_descriptor();
        let tracks = 1;
        let pnr = test_pnr_with_routing(&["X2/Y1/CLB_I2/X2/Y1/E0"]);
        let bits = pack(&desc, &pnr);

        let isw = tile_bits::input_sel_width(tracks);
        let sel = read_bits(&bits, 64 + 50 + tile_bits::input_sel_offset(2, tracks), isw);
        assert_eq!(sel, tile_bits::mux_dir_track(1, 0, tracks)); // E0
    }

    #[test]
    fn pack_routing_input_mux_feedback() {
        let desc = test_descriptor();
        let tracks = 1;
        let pnr = test_pnr_with_routing(&["X1/Y1/CLB_I1/X1/Y1/CLB_O"]);
        let bits = pack(&desc, &pnr);

        let isw = tile_bits::input_sel_width(tracks);
        let sel = read_bits(&bits, 64 + tile_bits::input_sel_offset(1, tracks), isw);
        assert_eq!(sel, tile_bits::mux_clb_out(tracks));
    }

    #[test]
    fn pack_routing_output_north() {
        let desc = test_descriptor();
        let tracks = 1;
        let pnr = test_pnr_with_routing(&["X1/Y1/OUT_N0/X1/Y1/CLB_O"]);
        let bits = pack(&desc, &pnr);

        assert_ne!(
            read_bits(&bits, 64 + tile_bits::output_en(0, 0, tracks), 1),
            0
        );
        let sel = read_bits(
            &bits,
            64 + tile_bits::output_sel(0, 0, tracks),
            tile_bits::OUTPUT_SEL_WIDTH,
        );
        assert_eq!(sel, tile_bits::OUT_MUX_CLB);
    }

    #[test]
    fn pack_routing_output_west() {
        let desc = test_descriptor();
        let tracks = 1;
        let pnr = test_pnr_with_routing(&["X2/Y2/OUT_W0/X2/Y2/CLB_Q"]);
        let bits = pack(&desc, &pnr);

        // tile (1,1) offset=150
        assert_ne!(
            read_bits(&bits, 64 + 150 + tile_bits::output_en(3, 0, tracks), 1),
            0
        );
        let sel = read_bits(
            &bits,
            64 + 150 + tile_bits::output_sel(3, 0, tracks),
            tile_bits::OUTPUT_SEL_WIDTH,
        );
        assert_eq!(sel, tile_bits::OUT_MUX_CLB);
    }

    #[test]
    fn pack_multiple_pips_same_tile() {
        let desc = test_descriptor();
        let tracks = 1;
        let pnr = test_pnr_with_routing(&[
            "X1/Y1/CLB_I0/X1/Y1/N0",
            "X1/Y1/CLB_I1/X1/Y1/E0",
            "X1/Y1/OUT_S0/X1/Y1/CLB_O",
        ]);
        let bits = pack(&desc, &pnr);

        let isw = tile_bits::input_sel_width(tracks);
        let sel0 = read_bits(&bits, 64 + tile_bits::input_sel_offset(0, tracks), isw);
        let sel1 = read_bits(&bits, 64 + tile_bits::input_sel_offset(1, tracks), isw);
        assert_eq!(sel0, tile_bits::mux_dir_track(0, 0, tracks)); // N0
        assert_eq!(sel1, tile_bits::mux_dir_track(1, 0, tracks)); // E0
        assert_ne!(
            read_bits(&bits, 64 + tile_bits::output_en(2, 0, tracks), 1),
            0
        );
    }

    #[test]
    fn pack_bitstream_length_matches_descriptor() {
        let desc = test_descriptor();
        let pnr = test_pnr_with_lut(0, 0, "0");
        let bits = pack(&desc, &pnr);
        assert_eq!(bits.len(), (desc.config.total_bits as usize + 7) / 8);
    }

    #[test]
    fn empty_design_produces_zero_bitstream() {
        let desc = test_descriptor();
        let pnr: PnrOutput =
            serde_json::from_str(r#"{"modules":{"top":{"cells":{},"netnames":{}}}}"#).unwrap();
        let bits = pack(&desc, &pnr);
        assert!(bits.iter().all(|&b| b == 0));
    }

    #[test]
    fn io_tile_pips_dont_set_fabric_bits() {
        let desc = test_descriptor();
        // Pip at tile (99,99) which doesn't exist in the fabric
        let pnr = test_pnr_with_routing(&["X99/Y99/N0/X99/Y99/CLB_O"]);
        let bits = pack(&desc, &pnr);
        assert!(bits.iter().all(|&b| b == 0));
    }
}
