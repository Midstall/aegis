import 'package:rohd/rohd.dart';
import 'fabric.dart';
import 'io_tile.dart';
import 'serdes_tile.dart';
import 'tile.dart';

class IOFabric extends Module {
  Logic get clk => input('clk');
  Logic get reset => input('reset');

  Logic get cfgIn => input('cfgIn');
  Logic get cfgLoad => input('cfgLoad');
  Logic get cfgOut => output('cfgOut');

  Logic get padIn => input('padIn');
  Logic get padOut => output('padOut');
  Logic get padOutputEnable => output('padOutputEnable');

  Logic? get serialIn => serdesCount > 0 ? input('serialIn') : null;
  Logic? get serialOut => serdesCount > 0 ? output('serialOut') : null;
  Logic? get txReady => serdesCount > 0 ? output('txReady') : null;
  Logic? get rxValid => serdesCount > 0 ? output('rxValid') : null;

  final int width;
  final int height;
  final int tracks;
  final int serdesCount;
  final int bramColumnInterval;
  final int bramDataWidth;
  final int bramAddrWidth;
  final int dspColumnInterval;

  /// Total number of I/O pads: one per edge tile position.
  int get totalPads => 2 * width + 2 * height;

  IOFabric(
    Logic clk,
    Logic reset, {
    required this.width,
    required this.height,
    required this.tracks,
    this.serdesCount = 4,
    this.bramColumnInterval = 0,
    this.bramDataWidth = 8,
    this.bramAddrWidth = 7,
    this.dspColumnInterval = 0,
    required Logic cfgIn,
    required Logic cfgLoad,
    required Logic padIn,
    required Logic serialIn,
  }) : super(name: 'io_fabric') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);

    cfgIn = addInput('cfgIn', cfgIn);
    cfgLoad = addInput('cfgLoad', cfgLoad);
    addOutput('cfgOut');

    final pads = totalPads;
    padIn = addInput('padIn', padIn, width: pads);
    addOutput('padOut', width: pads);
    addOutput('padOutputEnable', width: pads);

    if (serdesCount > 0) {
      serialIn = addInput('serialIn', serialIn, width: serdesCount);
      addOutput('serialOut', width: serdesCount);
      addOutput('txReady', width: serdesCount);
      addOutput('rxValid', width: serdesCount);
    }

    // ---- IO tiles ----
    // Order: north (L-to-R), east (T-to-B), south (L-to-R), west (T-to-B)

    final ioTiles =
        <(IOTile, Logic padIn, Logic fabricIn, Logic cfgIn, Logic cfgLoad)>[];

    for (int i = 0; i < pads; i++) {
      final tilePadIn = Logic(name: 'ioPadIn_$i');
      final tileFabricIn = Logic(width: tracks, name: 'ioFabricIn_$i');
      final tileCfgIn = Logic(name: 'ioCfgIn_$i');
      final tileCfgLoad = Logic(name: 'ioCfgLoad_$i');

      final tile = IOTile(
        clk,
        reset,
        tileCfgIn,
        tileCfgLoad,
        padIn: tilePadIn,
        fabricIn: tileFabricIn,
        tracks: tracks,
      );

      ioTiles.add((tile, tilePadIn, tileFabricIn, tileCfgIn, tileCfgLoad));
    }

    for (int i = 0; i < pads; i++) {
      ioTiles[i].$2 <= padIn[i];
    }
    for (int i = 0; i < pads; i++) {
      ioTiles[i].$5 <= cfgLoad;
    }

    // ---- SerDes tiles ----
    // One per serdesCount, each with its own serial pin pair.
    // They connect to the fabric edges (distributed evenly: one per edge
    // when serdesCount == 4, otherwise round-robin).

    final serdesTiles =
        <
          (
            SerDesTile,
            Logic serialIn,
            Logic fabricIn,
            Logic cfgIn,
            Logic cfgLoad,
          )
        >[];

    for (int i = 0; i < serdesCount; i++) {
      final tileSerialIn = Logic(name: 'serdesSerialIn_$i');
      final tileFabricIn = Logic(width: tracks, name: 'serdesFabricIn_$i');
      final tileCfgIn = Logic(name: 'serdesCfgIn_$i');
      final tileCfgLoad = Logic(name: 'serdesCfgLoad_$i');

      final tile = SerDesTile(
        clk,
        reset,
        tileCfgIn,
        tileCfgLoad,
        serialIn: tileSerialIn,
        fabricIn: tileFabricIn,
        tracks: tracks,
      );

      serdesTiles.add((
        tile,
        tileSerialIn,
        tileFabricIn,
        tileCfgIn,
        tileCfgLoad,
      ));
    }

    if (serdesCount > 0) {
      for (int i = 0; i < serdesCount; i++) {
        serdesTiles[i].$2 <= serialIn![i];
      }
      for (int i = 0; i < serdesCount; i++) {
        serdesTiles[i].$5 <= cfgLoad;
      }

      // Collect serial outputs
      serialOut! <=
          serdesTiles
              .map((t) => t.$1.serialOut)
              .toList()
              .reversed
              .toList()
              .swizzle();
      txReady! <=
          serdesTiles
              .map((t) => t.$1.txReady)
              .toList()
              .reversed
              .toList()
              .swizzle();
      rxValid! <=
          serdesTiles
              .map((t) => t.$1.rxValid)
              .toList()
              .reversed
              .toList()
              .swizzle();
    }

    // ---- Config chain: IO tiles -> SerDes tiles -> fabric ----
    ioTiles[0].$4 <= cfgIn;
    for (int i = 1; i < ioTiles.length; i++) {
      ioTiles[i].$4 <= ioTiles[i - 1].$1.cfgOut;
    }

    Logic fabricCfgIn;
    if (serdesTiles.isNotEmpty) {
      serdesTiles[0].$4 <= ioTiles.last.$1.cfgOut;
      for (int i = 1; i < serdesTiles.length; i++) {
        serdesTiles[i].$4 <= serdesTiles[i - 1].$1.cfgOut;
      }
      fabricCfgIn = serdesTiles.last.$1.cfgOut;
    } else {
      fabricCfgIn = ioTiles.last.$1.cfgOut;
    }

    // Collect pad outputs
    padOut <=
        ioTiles.map((t) => t.$1.padOut).toList().reversed.toList().swizzle();
    padOutputEnable <=
        ioTiles
            .map((t) => t.$1.padOutputEnable)
            .toList()
            .reversed
            .toList()
            .swizzle();

    // ---- Fabric edge wiring ----
    // Pad index mapping:
    //   [0, width)              = north edge, left to right
    //   [width, width+height)   = east edge, top to bottom
    //   [width+height, 2w+h)    = south edge, left to right
    //   [2w+h, 2w+2h)           = west edge, top to bottom
    //
    // SerDes tiles are distributed one per edge (when serdesCount >= 4),
    // otherwise round-robin. Their fabricOut is OR'd into the edge signal
    // alongside the IO tiles.

    final fabricInput = TileInterface(width: tracks);
    final fabricOutput = TileInterface(width: tracks);

    // Assign serdes tiles to edges: 0=north, 1=east, 2=south, 3=west
    final edgeSerdes = List.generate(
      4,
      (edge) => <(SerDesTile, Logic, Logic, Logic, Logic)>[],
    );
    for (int i = 0; i < serdesCount; i++) {
      edgeSerdes[i % 4].add(serdesTiles[i]);
    }

    void wireEdge(
      Logic fabricInputDir,
      Logic fabricOutputDir,
      List<(IOTile, Logic, Logic, Logic, Logic)> edgeIO,
      List<(SerDesTile, Logic, Logic, Logic, Logic)> edgeSD,
    ) {
      // Aggregate IO tile and SerDes tile fabricOut into fabric input
      fabricInputDir <=
          List.generate(tracks, (t) {
            Logic agg = Const(0);
            for (final tile in edgeIO) {
              agg = agg | tile.$1.fabricOut[t];
            }
            for (final tile in edgeSD) {
              agg = agg | tile.$1.fabricOut[t];
            }
            return agg;
          }).reversed.toList().swizzle();

      // Feed fabric output back to IO and SerDes tiles
      for (final tile in edgeIO) {
        tile.$3 <= fabricOutputDir;
      }
      for (final tile in edgeSD) {
        tile.$3 <= fabricOutputDir;
      }
    }

    wireEdge(
      fabricInput.north,
      fabricOutput.north,
      ioTiles.sublist(0, width),
      edgeSerdes[0],
    );
    wireEdge(
      fabricInput.east,
      fabricOutput.east,
      ioTiles.sublist(width, width + height),
      edgeSerdes[1],
    );
    wireEdge(
      fabricInput.south,
      fabricOutput.south,
      ioTiles.sublist(width + height, 2 * width + height),
      edgeSerdes[2],
    );
    wireEdge(
      fabricInput.west,
      fabricOutput.west,
      ioTiles.sublist(2 * width + height, 2 * width + 2 * height),
      edgeSerdes[3],
    );

    // Instantiate the LUT fabric
    final fabric = LutFabric(
      clk,
      reset,
      width: width,
      height: height,
      tracks: tracks,
      bramColumnInterval: bramColumnInterval,
      bramDataWidth: bramDataWidth,
      bramAddrWidth: bramAddrWidth,
      dspColumnInterval: dspColumnInterval,
      cfgIn: fabricCfgIn,
      cfgLoad: cfgLoad,
      input: fabricInput,
      output: fabricOutput,
    );

    cfgOut <= fabric.cfgOut;
  }

  /// Total config bits for IO tiles + SerDes tiles (excludes fabric).
  static int peripheralConfigBits(
    int width,
    int height, {
    int serdesCount = 4,
  }) =>
      (2 * width + 2 * height) * IOTile.CONFIG_WIDTH +
      serdesCount * SerDesTile.CONFIG_WIDTH;
}
