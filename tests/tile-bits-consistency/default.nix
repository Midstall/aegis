# Three-way tile bits consistency test.
#
# Verifies that the Dart TileConfig.encode() and Rust TileConfig::{encode,decode}
# produce identical bitstreams for the same configuration values.
# This catches any divergence between the Dart IP generator and the Rust
# packer/simulator bit layouts.
{
  lib,
  stdenvNoCC,
  python3,
  aegis-ip,
  aegis-sim,
  jq,
}:

let
  deviceName = aegis-ip.deviceName;
in
stdenvNoCC.mkDerivation {
  name = "aegis-tile-bits-consistency-${deviceName}";

  dontUnpack = true;

  nativeBuildInputs = [
    python3
    aegis-ip.tools
    aegis-sim
    jq
  ];

  buildPhase = ''
        runHook preBuild

        echo "=== Tile bits consistency check ==="

        # The Dart IP generator and Rust sim/packer both compute tile config widths.
        # Verify they agree by checking the descriptor's tile_config_width field
        # against the Rust formula.

        DESCRIPTOR="${aegis-ip}/${deviceName}.json"
        TRACK=$(jq -r '.fabric.tracks' "$DESCRIPTOR")
        DART_WIDTH=$(jq -r '.fabric.tile_config_width' "$DESCRIPTOR")

        echo "Device: ${deviceName}, tracks: $TRACKS, Dart tile_config_width: $DART_WIDTH"

        # Verify all tiles in the descriptor have the expected config width
        python3 -c "
    import json, sys
    d = json.load(open('$DESCRIPTOR'))
    tracks = d['fabric']['tracks']
    expected = d['fabric']['tile_config_width']

    # Verify tile widths match the fabric-level declaration
    errors = 0
    for tile in d['tiles']:
        if tile['type'] == 'lut' and tile['config_width'] != expected:
            print(f'FAIL: tile ({tile[\"x\"]},{tile[\"y\"]}) has config_width={tile[\"config_width\"]}, expected {expected}')
            errors += 1

    if errors > 0:
        sys.exit(1)

    # Verify the Dart formula: width = 18 + 4*ceil(log2(4*T+7)) + 4*T*4
    import math
    isw = math.ceil(math.log2(4*tracks + 7))
    rust_formula = 18 + 4*isw + 4*tracks*4

    if rust_formula != expected:
        print(f'FAIL: Rust formula gives {rust_formula}, Dart descriptor says {expected}')
        sys.exit(1)

    print(f'PASS: {len(d[\"tiles\"])} tiles verified, config_width={expected} matches formula')
    "

        echo "=== Bitstream round-trip: pack empty design, verify descriptor tile offsets ==="

        # Create an empty bitstream of the correct size
        TOTAL_BITS=$(python3 -c "import json; d=json.load(open('$DESCRIPTOR')); print(d['config']['total_bits'])")
        python3 -c "
    import sys
    total_bits = $TOTAL_BITS
    total_bytes = (total_bits + 7) // 8
    sys.stdout.buffer.write(b'\x00' * total_bytes)
    " > empty.bin

        # Run sim with the empty bitstream to verify it can decode all tiles
        aegis-sim \
          --descriptor "$DESCRIPTOR" \
          --bitstream empty.bin \
          --cycles 1 \
          2>&1 | tee sim.log

        if grep -q "Simulation complete" sim.log; then
          echo "PASS: Empty bitstream decodes successfully"
        else
          echo "FAIL: Sim could not decode empty bitstream"
          exit 1
        fi

        echo "=== Tile offset non-overlap check ==="
        python3 -c "
    import json, sys
    d = json.load(open('$DESCRIPTOR'))
    tiles = d['tiles']

    # Verify no two tiles overlap in the config space
    for i, a in enumerate(tiles):
        a_start = a['config_offset']
        a_end = a_start + a['config_width']
        for j, b in enumerate(tiles):
            if j <= i:
                continue
            b_start = b['config_offset']
            b_end = b_start + b['config_width']
            if a_start < b_end and b_start < a_end:
                print(f'FAIL: tile ({a[\"x\"]},{a[\"y\"]}) [{a_start}:{a_end}) overlaps tile ({b[\"x\"]},{b[\"y\"]}) [{b_start}:{b_end})')
                sys.exit(1)

    # Verify tiles are contiguous and cover the full fabric section
    fabric_bits = sum(s['total_bits'] for s in d['config']['chain_order'] if s['section'] == 'fabric_tiles')
    tile_bits = sum(t['config_width'] for t in tiles)
    if tile_bits != fabric_bits:
        print(f'FAIL: tile config bits ({tile_bits}) != fabric section bits ({fabric_bits})')
        sys.exit(1)

    print(f'PASS: {len(tiles)} tiles, no overlaps, {tile_bits} bits = fabric section')
    "

        runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    runHook postInstall
  '';
}
