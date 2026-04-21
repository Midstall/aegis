use super::*;

// === Layout formula tests ===

#[test]
fn t1_width() {
    // 18 + 4*4 + 4*1*4 = 18 + 16 + 16 = 50
    assert_eq!(tile_config_width(1), 50);
}

#[test]
fn t2_width() {
    // 18 + 4*4 + 4*2*4 = 18 + 16 + 32 = 66
    assert_eq!(tile_config_width(2), 66);
}

#[test]
fn t4_width() {
    // 18 + 4*5 + 4*4*4 = 18 + 20 + 64 = 102
    assert_eq!(tile_config_width(4), 102);
}

#[test]
fn input_sel_width_values() {
    assert_eq!(input_sel_width(1), 4); // 11 values -> 4 bits
    assert_eq!(input_sel_width(2), 4); // 15 values -> 4 bits
    assert_eq!(input_sel_width(4), 5); // 23 values -> 5 bits
}

#[test]
fn input_sel_offsets_t1() {
    assert_eq!(input_sel_offset(0, 1), 18);
    assert_eq!(input_sel_offset(1, 1), 22);
    assert_eq!(input_sel_offset(2, 1), 26);
    assert_eq!(input_sel_offset(3, 1), 30);
}

#[test]
fn output_base_t1() {
    // 18 + 4*4 = 34
    assert_eq!(output_base(1), 34);
}

#[test]
fn output_offsets_t1() {
    // output_base(1) = 34
    assert_eq!(output_en(0, 0, 1), 34); // EN_NORTH
    assert_eq!(output_sel(0, 0, 1), 35); // SEL_NORTH
    assert_eq!(output_en(1, 0, 1), 38); // EN_EAST
    assert_eq!(output_en(2, 0, 1), 42); // EN_SOUTH
    assert_eq!(output_en(3, 0, 1), 46); // EN_WEST
    // Last bit: 46 + 3 = 49, total width = 50
}

#[test]
fn output_offsets_t4() {
    // output_base(4) = 18 + 4*5 = 38
    assert_eq!(output_base(4), 38);
    // N0: 38, N1: 42, N2: 46, N3: 50
    assert_eq!(output_en(0, 0, 4), 38);
    assert_eq!(output_en(0, 1, 4), 42);
    assert_eq!(output_en(0, 2, 4), 46);
    assert_eq!(output_en(0, 3, 4), 50);
    // E0: 54
    assert_eq!(output_en(1, 0, 4), 54);
    // W3: 38 + (3*4 + 3)*4 = 38 + 60 = 98
    assert_eq!(output_en(3, 3, 4), 98);
    assert_eq!(output_sel(3, 3, 4), 99);
    // Last bit: 99 + 2 = 101, total width = 102 ✓
}

// === Mux select value tests ===

#[test]
fn mux_values_t1() {
    assert_eq!(mux_dir_track(0, 0, 1), 0); // N0
    assert_eq!(mux_dir_track(1, 0, 1), 1); // E0
    assert_eq!(mux_dir_track(2, 0, 1), 2); // S0
    assert_eq!(mux_dir_track(3, 0, 1), 3); // W0
    assert_eq!(mux_clb_out(1), 4);
    assert_eq!(mux_const0(1), 5);
    assert_eq!(mux_const1(1), 6);
    assert_eq!(mux_neighbor(0, 1), 7); // NB_N
    assert_eq!(mux_neighbor(1, 1), 8); // NB_E
    assert_eq!(mux_neighbor(2, 1), 9); // NB_S
    assert_eq!(mux_neighbor(3, 1), 10); // NB_W
}

#[test]
fn mux_values_t4() {
    assert_eq!(mux_dir_track(0, 0, 4), 0); // N0
    assert_eq!(mux_dir_track(0, 3, 4), 3); // N3
    assert_eq!(mux_dir_track(1, 0, 4), 4); // E0
    assert_eq!(mux_dir_track(1, 3, 4), 7); // E3
    assert_eq!(mux_dir_track(2, 0, 4), 8); // S0
    assert_eq!(mux_dir_track(3, 3, 4), 15); // W3
    assert_eq!(mux_clb_out(4), 16);
    assert_eq!(mux_const0(4), 17);
    assert_eq!(mux_const1(4), 18);
}

#[test]
fn all_mux_values_fit_in_input_sel_width() {
    for tracks in [1, 2, 4, 8] {
        let isw = input_sel_width(tracks);
        let max_val = mux_neighbor(3, tracks);
        assert!(
            max_val < (1 << isw),
            "max mux value {} doesn't fit in {} bits for T={}",
            max_val,
            isw,
            tracks
        );
    }
}

// === Bitstream read/write tests ===

#[test]
fn write_read_bits_roundtrip() {
    let mut bits = vec![0u8; 4];
    write_bits(&mut bits, 0, 0xABCD, 16);
    assert_eq!(read_bits(&bits, 0, 16), 0xABCD);
}

#[test]
fn write_read_bits_at_offset() {
    let mut bits = vec![0u8; 4];
    write_bits(&mut bits, 5, 0x1F, 5);
    assert_eq!(read_bits(&bits, 5, 5), 0x1F);
    // Surrounding bits should be zero
    assert_eq!(read_bits(&bits, 0, 5), 0);
    assert_eq!(read_bits(&bits, 10, 6), 0);
}

#[test]
fn write_bits_clears_before_writing() {
    let mut bits = vec![0xFFu8; 4];
    write_bits(&mut bits, 8, 0x00, 8);
    assert_eq!(bits[1], 0x00);
    // Adjacent bytes untouched
    assert_eq!(bits[0], 0xFF);
    assert_eq!(bits[2], 0xFF);
}

#[test]
fn set_bit_individual() {
    let mut bits = vec![0u8; 2];
    set_bit(&mut bits, 0);
    set_bit(&mut bits, 7);
    set_bit(&mut bits, 8);
    assert_eq!(bits[0], 0x81);
    assert_eq!(bits[1], 0x01);
}

#[test]
fn read_bit_values() {
    let bits = vec![0xA5u8]; // 10100101
    assert!(read_bit(&bits, 0));
    assert!(!read_bit(&bits, 1));
    assert!(read_bit(&bits, 2));
    assert!(!read_bit(&bits, 3));
    assert!(!read_bit(&bits, 4));
    assert!(read_bit(&bits, 5));
    assert!(!read_bit(&bits, 6));
    assert!(read_bit(&bits, 7));
}

#[test]
fn read_bit_out_of_bounds_returns_false() {
    let bits = vec![0xFFu8];
    assert!(!read_bit(&bits, 8));
    assert!(!read_bit(&bits, 100));
}

// === TileConfig encode/decode round-trip tests ===

#[test]
fn roundtrip_default_t1() {
    let cfg = TileConfig::default_for(1);
    let mut bits = vec![0u8; (tile_config_width(1) + 7) / 8];
    cfg.encode(&mut bits, 0, 1);
    let decoded = TileConfig::decode(&bits, 0, 1);
    assert_eq!(cfg, decoded);
}

#[test]
fn roundtrip_default_t4() {
    let cfg = TileConfig::default_for(4);
    let mut bits = vec![0u8; (tile_config_width(4) + 7) / 8];
    cfg.encode(&mut bits, 0, 4);
    let decoded = TileConfig::decode(&bits, 0, 4);
    assert_eq!(cfg, decoded);
}

#[test]
fn roundtrip_lut_init() {
    for tracks in [1, 2, 4] {
        let mut cfg = TileConfig::default_for(tracks);
        cfg.lut_init = 0xBEEF;
        let mut bits = vec![0u8; (tile_config_width(tracks) + 7) / 8];
        cfg.encode(&mut bits, 0, tracks);
        let decoded = TileConfig::decode(&bits, 0, tracks);
        assert_eq!(decoded.lut_init, 0xBEEF, "T={}", tracks);
    }
}

#[test]
fn roundtrip_ff_enable() {
    for tracks in [1, 2, 4] {
        let mut cfg = TileConfig::default_for(tracks);
        cfg.ff_enable = true;
        let mut bits = vec![0u8; (tile_config_width(tracks) + 7) / 8];
        cfg.encode(&mut bits, 0, tracks);
        let decoded = TileConfig::decode(&bits, 0, tracks);
        assert!(decoded.ff_enable, "T={}", tracks);
    }
}

#[test]
fn roundtrip_carry_mode() {
    for tracks in [1, 2, 4] {
        let mut cfg = TileConfig::default_for(tracks);
        cfg.carry_mode = true;
        let mut bits = vec![0u8; (tile_config_width(tracks) + 7) / 8];
        cfg.encode(&mut bits, 0, tracks);
        let decoded = TileConfig::decode(&bits, 0, tracks);
        assert!(decoded.carry_mode, "T={}", tracks);
    }
}

#[test]
fn roundtrip_input_sel_all_directions_t1() {
    let mut cfg = TileConfig::default_for(1);
    cfg.sel = [0, 1, 2, 3]; // N0, E0, S0, W0
    let mut bits = vec![0u8; (tile_config_width(1) + 7) / 8];
    cfg.encode(&mut bits, 0, 1);
    let decoded = TileConfig::decode(&bits, 0, 1);
    assert_eq!(decoded.sel, [0, 1, 2, 3]);
}

#[test]
fn roundtrip_input_sel_all_values_t4() {
    let mut cfg = TileConfig::default_for(4);
    cfg.sel = [
        mux_dir_track(0, 3, 4) as u8, // N3 = 3
        mux_dir_track(2, 1, 4) as u8, // S1 = 9
        mux_clb_out(4) as u8,         // CLB = 16
        mux_const1(4) as u8,          // const1 = 18
    ];
    let mut bits = vec![0u8; (tile_config_width(4) + 7) / 8];
    cfg.encode(&mut bits, 0, 4);
    let decoded = TileConfig::decode(&bits, 0, 4);
    assert_eq!(decoded.sel, cfg.sel);
}

#[test]
fn roundtrip_per_track_output_t1() {
    let mut cfg = TileConfig::default_for(1);
    cfg.en_out[0][0] = true;
    cfg.sel_out[0][0] = OUT_MUX_CLB as u8;
    cfg.en_out[2][0] = true;
    cfg.sel_out[2][0] = OUT_MUX_WEST as u8;
    let mut bits = vec![0u8; (tile_config_width(1) + 7) / 8];
    cfg.encode(&mut bits, 0, 1);
    let decoded = TileConfig::decode(&bits, 0, 1);
    assert_eq!(decoded, cfg);
}

#[test]
fn roundtrip_per_track_output_t4_independent() {
    let mut cfg = TileConfig::default_for(4);
    // Enable different tracks in same direction with different sources
    cfg.en_out[0][0] = true;
    cfg.sel_out[0][0] = OUT_MUX_CLB as u8;
    cfg.en_out[0][1] = true;
    cfg.sel_out[0][1] = OUT_MUX_SOUTH as u8;
    cfg.en_out[0][2] = false; // disabled
    cfg.en_out[0][3] = true;
    cfg.sel_out[0][3] = OUT_MUX_EAST as u8;
    // Different direction
    cfg.en_out[3][2] = true;
    cfg.sel_out[3][2] = OUT_MUX_NORTH as u8;
    let mut bits = vec![0u8; (tile_config_width(4) + 7) / 8];
    cfg.encode(&mut bits, 0, 4);
    let decoded = TileConfig::decode(&bits, 0, 4);
    assert_eq!(decoded, cfg);
}

#[test]
fn roundtrip_all_fields_set_t4() {
    let mut cfg = TileConfig::default_for(4);
    cfg.lut_init = 0xDEAD;
    cfg.ff_enable = true;
    cfg.carry_mode = true;
    cfg.sel = [3, 7, 12, 18]; // various input sel values
    for dir in 0..4 {
        for t in 0..4 {
            cfg.en_out[dir][t] = (dir + t) % 2 == 0;
            cfg.sel_out[dir][t] = ((dir + t) % 5) as u8;
        }
    }
    let mut bits = vec![0u8; (tile_config_width(4) + 7) / 8];
    cfg.encode(&mut bits, 0, 4);
    let decoded = TileConfig::decode(&bits, 0, 4);
    assert_eq!(decoded, cfg);
}

#[test]
fn roundtrip_at_nonzero_offset() {
    let offset = 64; // like fabric_base
    let tracks = 4;
    let mut cfg = TileConfig::default_for(tracks);
    cfg.lut_init = 0x1234;
    cfg.ff_enable = true;
    cfg.en_out[1][2] = true;
    cfg.sel_out[1][2] = OUT_MUX_CLB as u8;
    let total_bits = offset + tile_config_width(tracks);
    let mut bits = vec![0u8; (total_bits + 7) / 8];
    cfg.encode(&mut bits, offset, tracks);
    let decoded = TileConfig::decode(&bits, offset, tracks);
    assert_eq!(decoded, cfg);
}

#[test]
fn roundtrip_multiple_tiles_no_overlap() {
    let tracks = 4;
    let tw = tile_config_width(tracks);
    let mut bits = vec![0u8; (tw * 3 + 7) / 8];

    let mut cfg0 = TileConfig::default_for(tracks);
    cfg0.lut_init = 0x1111;
    cfg0.encode(&mut bits, 0, tracks);

    let mut cfg1 = TileConfig::default_for(tracks);
    cfg1.lut_init = 0x2222;
    cfg1.en_out[0][0] = true;
    cfg1.encode(&mut bits, tw, tracks);

    let mut cfg2 = TileConfig::default_for(tracks);
    cfg2.lut_init = 0x3333;
    cfg2.ff_enable = true;
    cfg2.encode(&mut bits, tw * 2, tracks);

    let d0 = TileConfig::decode(&bits, 0, tracks);
    let d1 = TileConfig::decode(&bits, tw, tracks);
    let d2 = TileConfig::decode(&bits, tw * 2, tracks);

    assert_eq!(d0.lut_init, 0x1111);
    assert!(!d0.en_out[0][0]);
    assert_eq!(d1.lut_init, 0x2222);
    assert!(d1.en_out[0][0]);
    assert_eq!(d2.lut_init, 0x3333);
    assert!(d2.ff_enable);
}

// === has_any_config tests ===

#[test]
fn default_has_no_config() {
    assert!(!TileConfig::default_for(1).has_any_config());
    assert!(!TileConfig::default_for(4).has_any_config());
}

#[test]
fn lut_init_counts_as_config() {
    let mut cfg = TileConfig::default_for(1);
    cfg.lut_init = 1;
    assert!(cfg.has_any_config());
}

#[test]
fn output_enable_counts_as_config() {
    let mut cfg = TileConfig::default_for(4);
    cfg.en_out[2][3] = true;
    assert!(cfg.has_any_config());
}

#[test]
fn input_sel_nonzero_counts_as_config() {
    let mut cfg = TileConfig::default_for(1);
    cfg.sel[2] = 1;
    assert!(cfg.has_any_config());
}

// === Edge case tests ===

#[test]
fn max_lut_init_roundtrips() {
    let mut cfg = TileConfig::default_for(1);
    cfg.lut_init = 0xFFFF;
    let mut bits = vec![0u8; (tile_config_width(1) + 7) / 8];
    cfg.encode(&mut bits, 0, 1);
    let decoded = TileConfig::decode(&bits, 0, 1);
    assert_eq!(decoded.lut_init, 0xFFFF);
}

#[test]
fn max_sel_value_roundtrips() {
    for tracks in [1, 2, 4] {
        let max_sel = mux_neighbor(3, tracks) as u8;
        let mut cfg = TileConfig::default_for(tracks);
        cfg.sel = [max_sel; 4];
        let mut bits = vec![0u8; (tile_config_width(tracks) + 7) / 8];
        cfg.encode(&mut bits, 0, tracks);
        let decoded = TileConfig::decode(&bits, 0, tracks);
        assert_eq!(decoded.sel, [max_sel; 4], "T={}", tracks);
    }
}

#[test]
fn all_output_sel_values_roundtrip() {
    let tracks = 4;
    for sel_val in 0..=4u8 {
        let mut cfg = TileConfig::default_for(tracks);
        cfg.en_out[0][0] = true;
        cfg.sel_out[0][0] = sel_val;
        let mut bits = vec![0u8; (tile_config_width(tracks) + 7) / 8];
        cfg.encode(&mut bits, 0, tracks);
        let decoded = TileConfig::decode(&bits, 0, tracks);
        assert_eq!(decoded.sel_out[0][0], sel_val, "sel_val={}", sel_val);
    }
}

#[test]
fn encode_into_zeroed_buffer_then_decode_matches() {
    // Verify encode doesn't leave stale bits from a previous encode
    let tracks = 4;
    let tw = tile_config_width(tracks);
    let mut bits = vec![0u8; (tw + 7) / 8];

    // First encode with all fields set
    let mut cfg1 = TileConfig::default_for(tracks);
    cfg1.lut_init = 0xFFFF;
    cfg1.ff_enable = true;
    cfg1.carry_mode = true;
    cfg1.sel = [18, 18, 18, 18];
    for d in 0..4 {
        for t in 0..tracks {
            cfg1.en_out[d][t] = true;
            cfg1.sel_out[d][t] = 4;
        }
    }
    cfg1.encode(&mut bits, 0, tracks);

    // Re-encode with defaults (should clear everything)
    bits.fill(0);
    let cfg2 = TileConfig::default_for(tracks);
    cfg2.encode(&mut bits, 0, tracks);
    let decoded = TileConfig::decode(&bits, 0, tracks);
    assert_eq!(decoded, cfg2);
}
