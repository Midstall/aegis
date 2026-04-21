use super::*;

fn make_sim(cfg: TileConfig) -> Simulator {
    let tracks = cfg.en_out[0].len().max(1);
    // Single fabric tile at grid position (1,1), with IO ring around it
    let mut configs = vec![vec![TileConfig::default_for(tracks); 3]; 3];
    configs[1][1] = cfg;

    let state = (0..3)
        .map(|_| (0..3).map(|_| TileState::new(tracks)).collect::<Vec<_>>())
        .collect::<Vec<_>>();

    let active_tiles: Vec<(usize, usize)> =
        (0..3).flat_map(|x| (0..3).map(move |y| (x, y))).collect();

    Simulator {
        gw: 3,
        gh: 3,
        tracks,
        configs,
        state: state.clone(),
        next_state: state,
        io_in: vec![false; 4],
        io_out: vec![false; 4],
        io_pad_pos: vec![(1, 0), (2, 1), (1, 2), (0, 1)], // N, E, S, W
        active_tiles,
        cycle: 0,
    }
}

fn make_cfg(tracks: usize) -> TileConfig {
    TileConfig::default_for(tracks)
}

#[test]
fn lut_and_gate() {
    let t = 1;
    let clb_out = 4 * t as u8;
    let const0 = clb_out + 1;
    let const1 = clb_out + 2;

    let mut cfg = make_cfg(t);
    cfg.sel[0] = const1;
    cfg.sel[1] = const1;
    cfg.sel[2] = const0;
    cfg.sel[3] = const0;
    cfg.lut_init = 0x0008; // AND gate: bit 3

    let mut sim = make_sim(cfg);
    sim.step();
    assert!(sim.state[1][1].lut_out);
}

#[test]
fn lut_or_gate() {
    let t = 1;
    let const0 = (4 * t + 1) as u8;
    let const1 = (4 * t + 2) as u8;

    let mut cfg = make_cfg(t);
    cfg.sel[0] = const1;
    cfg.sel[1] = const0;
    cfg.sel[2] = const0;
    cfg.sel[3] = const0;
    cfg.lut_init = 0x000E; // OR: bits 1,2,3

    let mut sim = make_sim(cfg);
    sim.step();
    assert!(sim.state[1][1].lut_out);
}

#[test]
fn lut_all_zero_inputs() {
    let t = 1;
    let const0 = (4 * t + 1) as u8;

    let mut cfg = make_cfg(t);
    cfg.sel[0] = const0;
    cfg.sel[1] = const0;
    cfg.sel[2] = const0;
    cfg.sel[3] = const0;
    cfg.lut_init = 0x0001; // bit 0 only

    let mut sim = make_sim(cfg);
    sim.step();
    assert!(sim.state[1][1].lut_out);
}

#[test]
fn ff_captures_lut_output() {
    let mut cfg = make_cfg(1);
    cfg.lut_init = 0xFFFF;
    cfg.ff_enable = true;

    let mut sim = make_sim(cfg);
    assert!(!sim.state[1][1].ff_q);
    sim.step();
    assert!(sim.state[1][1].ff_q);
}

#[test]
fn ff_always_latches_regardless_of_enable() {
    // FF always captures LUT output (Dart: Sequential(clk, [ffQ < lutOut])).
    // ff_enable only controls the output mux, not the FF clock.
    let mut cfg = make_cfg(1);
    cfg.lut_init = 0xFFFF;
    cfg.ff_enable = false;

    let mut sim = make_sim(cfg);
    sim.step();
    // FF captures lut_out=1 even though ff_enable is false
    assert!(sim.state[1][1].ff_q);
    // Output uses raw lut_out (not ff_q) when ff_enable=false
    assert!(sim.state[1][1].lut_out);
}

#[test]
fn ff_enable_selects_ff_output() {
    // When ff_enable=true, CLB output is ff_q (one cycle delayed)
    let mut cfg = make_cfg(1);
    cfg.lut_init = 0xFFFF; // constant 1
    cfg.ff_enable = true;

    let mut sim = make_sim(cfg);
    // Cycle 1: lut_out=1, clb_out=ff_q_prev=0 (initial), ff_q_next=1
    sim.step();
    assert!(sim.state[1][1].ff_q); // FF captured lut_out=1
    assert!(!sim.state[1][1].lut_out); // clb_out = ff_q_prev = 0

    // Cycle 2: lut_out=1, clb_out=ff_q_prev=1, ff_q_next=1
    sim.step();
    assert!(sim.state[1][1].lut_out); // clb_out = ff_q_prev = 1
}

#[test]
fn decode_empty_bitstream() {
    let bitstream = vec![0u8; 16];
    let cfg = TileConfig::decode(&bitstream, 0, 1);
    assert_eq!(cfg.lut_init, 0);
    assert!(!cfg.ff_enable);
    assert!(!cfg.carry_mode);
}

#[test]
fn decode_lut_init() {
    let mut bitstream = vec![0u8; 16];
    bitstream[0] = 0xAA;
    bitstream[1] = 0xAA;
    let cfg = TileConfig::decode(&bitstream, 0, 1);
    assert_eq!(cfg.lut_init, 0xAAAA);
}

#[test]
fn decode_ff_enable() {
    let mut bitstream = vec![0u8; 16];
    bitstream[2] = 0x01; // bit 16
    let cfg = TileConfig::decode(&bitstream, 0, 1);
    assert!(cfg.ff_enable);
}

#[test]
fn run_multiple_cycles() {
    let cfg = make_cfg(1);
    let mut sim = make_sim(cfg);
    sim.run(100);
    assert_eq!(sim.cycle(), 100);
}

#[test]
fn io_pad_output_from_fabric() {
    // Configure fabric tile to output constant 1 to the west on track 0
    let mut cfg = make_cfg(1);
    cfg.lut_init = 0xFFFF; // constant 1
    cfg.en_out[3][0] = true; // enable west output track 0
    cfg.sel_out[3][0] = 4; // west output = CLB_OUT

    let mut sim = make_sim(cfg);
    sim.step();
    sim.step(); // need 2 cycles: 1 for LUT eval, 1 for IO propagation

    // West pad is index 3 in our 4-pad mapping
    assert!(sim.get_io(3), "West IO pad should be 1");
}

#[test]
fn io_pad_input_to_fabric() {
    // Set north IO pad high, configure fabric tile to read from north track 0
    let mut cfg = make_cfg(1);
    cfg.sel[0] = 0; // N0 = direction 0 * tracks 1 + track 0 = 0
    cfg.lut_init = 0xAAAA; // buffer: output = in0

    let mut sim = make_sim(cfg);
    sim.set_io(0, true); // north pad = 1
    sim.step();
    sim.step();

    assert!(sim.state[1][1].lut_out, "LUT should see north pad input");
}

#[test]
fn per_track_independent_outputs() {
    // With 2 tracks, output track 0 north with CLB and track 1 north with south pass-through
    let mut cfg = make_cfg(2);
    cfg.lut_init = 0xFFFF; // constant 1
    cfg.en_out[0][0] = true; // north track 0 enabled
    cfg.sel_out[0][0] = 4; // CLB_OUT
    cfg.en_out[0][1] = true; // north track 1 enabled
    cfg.sel_out[0][1] = 2; // south pass-through (south track 1)

    let mut sim = make_sim(cfg);
    sim.step();

    // Track 0 should have CLB output (1)
    assert!(sim.state[1][1].out[0][0], "North track 0 should be CLB=1");
    // Track 1 should have south pass-through (0, no signal from south)
    assert!(!sim.state[1][1].out[0][1], "North track 1 should be 0");
}
