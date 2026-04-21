import 'dart:math';
import 'clb_config.dart';

/// Compute the input select width for a given number of tracks.
/// Values: N0..N(T-1), E0..E(T-1), S0..S(T-1), W0..W(T-1),
///         CLB_OUT, const0, const1, NB_N, NB_E, NB_S, NB_W
int inputSelWidth(int tracks) => (4 * tracks + 7 - 1).bitLength;

/// Compute the total tile config width for a given number of tracks.
///
/// Layout:
///   [17:0]            CLB config (16 LUT + 1 FF enable + 1 carry mode)
///   [18..18+4*ISW-1]  input mux sel0..sel3 (4 x ISW bits)
///   [18+4*ISW..]      per-track output config:
///                      for each direction (N,E,S,W) and track (0..T-1):
///                        1 enable bit + 3 select bits = 4 bits
///
/// For T=1: 18 + 4*4 + 4*1*4 = 50
/// For T=4: 18 + 4*5 + 4*4*4 = 102
int tileConfigWidth(int tracks) =>
    18 + 4 * inputSelWidth(tracks) + 4 * tracks * 4;

/// Input mux select value for a directional source.
int inputSelDir(int direction, int track, int tracks) =>
    direction * tracks + track;

/// Input mux select value for CLB output.
int inputSelClbOut(int tracks) => 4 * tracks;

/// Input mux select value for constant 0.
int inputSelConst0(int tracks) => 4 * tracks + 1;

/// Input mux select value for constant 1.
int inputSelConst1(int tracks) => 4 * tracks + 2;

/// Input mux select value for neighbor CLB output (0=N, 1=E, 2=S, 3=W).
int inputSelNeighbor(int direction, int tracks) => 4 * tracks + 3 + direction;

/// Per-track output configuration.
class TrackOutputConfig {
  final bool enable;
  final int select; // 0=N, 1=E, 2=S, 3=W, 4=CLB_OUT

  const TrackOutputConfig({this.enable = false, this.select = 0});
}

/// Configuration for a routing tile with per-track output muxes.
class TileConfig {
  final ClbConfig clb;
  final List<int> inputSel; // 4 input mux select values
  final List<List<TrackOutputConfig>> outputs; // outputs[dir][track]
  final int tracks;

  const TileConfig({
    this.clb = const ClbConfig(),
    this.inputSel = const [0, 0, 0, 0],
    this.outputs = const [[], [], [], []],
    this.tracks = 1,
  });

  /// Create a default config for the given track count.
  factory TileConfig.defaultFor(int tracks) => TileConfig(
    tracks: tracks,
    outputs: List.generate(
      4,
      (_) => List.generate(tracks, (_) => const TrackOutputConfig()),
    ),
  );

  int get width => tileConfigWidth(tracks);

  BigInt encode() {
    final isw = inputSelWidth(tracks);
    var bits = clb.encode();

    // Input mux selects
    for (var i = 0; i < 4; i++) {
      bits |= BigInt.from(inputSel[i]) << (18 + i * isw);
    }

    // Per-track output config
    final outBase = 18 + 4 * isw;
    for (var d = 0; d < 4; d++) {
      for (var t = 0; t < tracks; t++) {
        final cfg = (d < outputs.length && t < outputs[d].length)
            ? outputs[d][t]
            : const TrackOutputConfig();
        final bitOff = outBase + (d * tracks + t) * 4;
        if (cfg.enable) {
          bits |= BigInt.one << bitOff;
        }
        bits |= BigInt.from(cfg.select & 0x7) << (bitOff + 1);
      }
    }

    return bits;
  }

  static TileConfig decode(BigInt bits, {int tracks = 1}) {
    int field(int offset, int w) =>
        ((bits >> offset) & BigInt.from((1 << w) - 1)).toInt();

    final isw = inputSelWidth(tracks);

    final inputSel = List.generate(4, (i) => field(18 + i * isw, isw));

    final outBase = 18 + 4 * isw;
    final outputs = List.generate(4, (d) {
      return List.generate(tracks, (t) {
        final bitOff = outBase + (d * tracks + t) * 4;
        return TrackOutputConfig(
          enable: field(bitOff, 1) == 1,
          select: field(bitOff + 1, 3),
        );
      });
    });

    return TileConfig(
      clb: ClbConfig.decode(bits),
      inputSel: inputSel,
      outputs: outputs,
      tracks: tracks,
    );
  }

  @override
  String toString() {
    final dirs = ['N', 'E', 'S', 'W'];
    final outStrs = <String>[];
    for (var d = 0; d < 4; d++) {
      for (var t = 0; t < (d < outputs.length ? outputs[d].length : 0); t++) {
        final cfg = outputs[d][t];
        if (cfg.enable) {
          outStrs.add('${dirs[d]}$t=${cfg.select}');
        }
      }
    }
    return 'TileConfig(clb: $clb, '
        'inputs: $inputSel, '
        'outputs: [${outStrs.join(', ')}])';
  }
}
