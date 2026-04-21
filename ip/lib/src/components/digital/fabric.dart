import 'package:rohd/rohd.dart';
import '../../config/tile_config.dart';
import 'bram_tile.dart';
import 'dsp_basic_tile.dart';
import 'tile.dart';

class LutFabric extends Module {
  Logic get clk => input('clk');
  Logic get reset => input('reset');

  Logic get cfgIn => input('cfgIn');
  Logic get cfgLoad => input('cfgLoad');
  Logic get cfgOut => output('cfgOut');

  final int width;
  final int height;
  final int tracks;
  final int bramColumnInterval;
  final int bramDataWidth;
  final int bramAddrWidth;
  final int dspColumnInterval;

  /// Returns the set of column indices that contain BRAM tiles.
  Set<int> get bramColumns =>
      bramColumnSet(width: width, bramColumnInterval: bramColumnInterval);

  /// Returns the set of column indices that contain DSP tiles.
  Set<int> get dspColumns => dspColumnSet(
    width: width,
    dspColumnInterval: dspColumnInterval,
    bramColumnInterval: bramColumnInterval,
  );

  /// Total config bits for this fabric.
  int get totalConfigBits => configBitsFor(
    width: width,
    height: height,
    tracks: tracks,
    bramColumnInterval: bramColumnInterval,
    dspColumnInterval: dspColumnInterval,
  );

  /// Compute total config bits without instantiating the fabric.
  static int configBitsFor({
    required int width,
    required int height,
    int tracks = 1,
    int bramColumnInterval = 0,
    int dspColumnInterval = 0,
  }) {
    final bram = bramColumnSet(
      width: width,
      bramColumnInterval: bramColumnInterval,
    );
    final dsp = dspColumnSet(
      width: width,
      dspColumnInterval: dspColumnInterval,
      bramColumnInterval: bramColumnInterval,
    );
    final lutTileWidth = tileConfigWidth(tracks);
    int bits = 0;
    for (int x = 0; x < width; x++) {
      if (bram.contains(x)) {
        bits += height * BramTile.CONFIG_WIDTH;
      } else if (dsp.contains(x)) {
        bits += height * DspBasicTile.CONFIG_WIDTH;
      } else {
        bits += height * lutTileWidth;
      }
    }
    return bits;
  }

  /// Compute which columns are BRAM without instantiating the fabric.
  static Set<int> bramColumnSet({
    required int width,
    int bramColumnInterval = 0,
  }) {
    if (bramColumnInterval <= 0) return {};
    final cols = <int>{};
    for (int x = bramColumnInterval; x < width; x += bramColumnInterval + 1) {
      cols.add(x);
    }
    return cols;
  }

  /// Compute which columns are DSP without instantiating the fabric.
  ///
  /// DSP columns are placed at their own interval, skipping any columns
  /// already occupied by BRAM.
  static Set<int> dspColumnSet({
    required int width,
    int dspColumnInterval = 0,
    int bramColumnInterval = 0,
  }) {
    if (dspColumnInterval <= 0) return {};
    final bram = bramColumnSet(
      width: width,
      bramColumnInterval: bramColumnInterval,
    );
    final cols = <int>{};
    for (int x = dspColumnInterval; x < width; x += dspColumnInterval + 1) {
      if (!bram.contains(x)) {
        cols.add(x);
      }
    }
    return cols;
  }

  /// Descriptor for the tile grid, with per-tile config offsets.
  static Map<String, dynamic> tileGridDescriptor({
    required int width,
    required int height,
    int tracks = 1,
    int bramColumnInterval = 0,
    int dspColumnInterval = 0,
  }) {
    final bramCols = bramColumnSet(
      width: width,
      bramColumnInterval: bramColumnInterval,
    );
    final dspCols = dspColumnSet(
      width: width,
      dspColumnInterval: dspColumnInterval,
      bramColumnInterval: bramColumnInterval,
    );
    final lutTileWidth = tileConfigWidth(tracks);
    final tiles = <Map<String, dynamic>>[];
    int offset = 0;
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final String type;
        final int w;
        if (bramCols.contains(x)) {
          type = 'bram';
          w = BramTile.CONFIG_WIDTH;
        } else if (dspCols.contains(x)) {
          type = 'dsp';
          w = DspBasicTile.CONFIG_WIDTH;
        } else {
          type = 'lut';
          w = lutTileWidth;
        }
        tiles.add({
          'x': x,
          'y': y,
          'type': type,
          'config_width': w,
          'config_offset': offset,
        });
        offset += w;
      }
    }
    return {'width': width, 'height': height, 'tiles': tiles};
  }

  LutFabric(
    Logic clk,
    Logic reset, {
    required this.width,
    required this.height,
    required this.tracks,
    this.bramColumnInterval = 0,
    this.bramDataWidth = 8,
    this.bramAddrWidth = 7,
    this.dspColumnInterval = 0,
    required Logic cfgIn,
    required Logic cfgLoad,
    required TileInterface input,
    required TileInterface output,
  }) : super(name: 'lut_fabric') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);

    cfgIn = addInput('cfgIn', cfgIn);
    cfgLoad = addInput('cfgLoad', cfgLoad);
    addOutput('cfgOut');

    assert(width > 0);
    assert(height > 0);
    assert(tracks > 0);

    input = input.clone()
      ..connectIO(
        this,
        input,
        inputTags: {TilePortGroup.routing},
        outputTags: {},
        uniquify: (orig) => 'input_$orig',
      );

    output = output.clone()
      ..connectIO(
        this,
        output,
        inputTags: {},
        outputTags: {TilePortGroup.routing},
        uniquify: (orig) => 'output_$orig',
      );

    final bram = bramColumns;
    final dsp = dspColumns;

    // Create tile grid. Each entry: (Module, TileInterface in, TileInterface out, cfgIn, cfgLoad, carryIn)
    final tiles = List.generate(
      width,
      (x) => List.generate(height, (y) {
        final tileIn = TileInterface(width: tracks);
        final tileOut = TileInterface(width: tracks);
        final tileCfgIn = Logic();
        final tileCfgLoad = Logic();
        final tileCarryIn = Logic(name: 'carryIn_${x}_$y');

        final tileNbClb = TileInterface();

        final Module tile;
        if (bram.contains(x)) {
          tile = BramTile(
            clk,
            reset,
            tileCfgIn,
            tileCfgLoad,
            tileIn,
            tileOut,
            carryIn: tileCarryIn,
            dataWidth: bramDataWidth,
            addrWidth: bramAddrWidth,
          );
        } else if (dsp.contains(x)) {
          tile = DspBasicTile(
            clk,
            reset,
            tileCfgIn,
            tileCfgLoad,
            tileIn,
            tileOut,
            carryIn: tileCarryIn,
          );
        } else {
          tile = Tile(
            clk,
            reset,
            tileCfgIn,
            tileCfgLoad,
            tileIn,
            tileOut,
            carryIn: tileCarryIn,
            neighborClbOut: tileNbClb,
            tracks: tracks,
          );
        }

        return (
          tile,
          tileIn,
          tileOut,
          tileCfgIn,
          tileCfgLoad,
          tileCarryIn,
          tileNbClb,
        );
      }),
    );

    // Config chain: row-major order
    final flat =
        <
          (
            Module,
            TileInterface,
            TileInterface,
            Logic,
            Logic,
            Logic,
            TileInterface,
          )
        >[];

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        flat.add(tiles[x][y]);
      }
    }

    flat[0].$4 <= cfgIn;

    for (int i = 1; i < flat.length; i++) {
      flat[i].$4 <= flat[i - 1].$1.output('cfgOut');
    }

    cfgOut <= flat.last.$1.output('cfgOut');

    for (final t in flat) {
      t.$5 <= cfgLoad;
    }

    // Carry chains: south-to-north within each column
    for (int x = 0; x < width; x++) {
      tiles[x][height - 1].$6 <= Const(0);

      for (int y = height - 2; y >= 0; y--) {
        tiles[x][y].$6 <= tiles[x][y + 1].$1.output('carryOut');
      }
    }

    // Neighbor CLB output wiring
    for (int x = 0; x < width; x++) {
      for (int y = 0; y < height; y++) {
        final nbClb = tiles[x][y].$7;
        Logic clbOutOf(int nx, int ny) =>
            tiles[nx][ny].$1.tryOutput('clbOut') ?? Const(0);

        nbClb.north <= ((y > 0) ? clbOutOf(x, y - 1) : Const(0));
        nbClb.east <= ((x < width - 1) ? clbOutOf(x + 1, y) : Const(0));
        nbClb.south <= ((y < height - 1) ? clbOutOf(x, y + 1) : Const(0));
        nbClb.west <= ((x > 0) ? clbOutOf(x - 1, y) : Const(0));
      }
    }

    // Routing connections
    for (int x = 0; x < width; x++) {
      for (int y = 0; y < height; y++) {
        final block = tiles[x][y];
        final tileIn = block.$2;
        final tileOut = block.$3;

        if (x == 0) {
          tileIn.west <= input.west;
        }

        if (y == 0) {
          tileIn.north <= input.north;
        }

        if (x == width - 1) {
          tileIn.east <= input.east;
        }

        if (y == height - 1) {
          tileIn.south <= input.south;
        }

        if (x < width - 1) {
          final eastBlock = tiles[x + 1][y];
          eastBlock.$2.west <= tileOut.east;
          tileIn.east <= eastBlock.$3.west;
        }

        if (y < height - 1) {
          final southBlock = tiles[x][y + 1];
          southBlock.$2.north <= tileOut.south;
          tileIn.south <= southBlock.$3.north;
        }
      }
    }

    // Edge output aggregation
    output.east <=
        List.generate(tracks, (t) {
          Logic eastAgg = Const(0);
          for (int y = 0; y < height; y++) {
            eastAgg = eastAgg | tiles[width - 1][y].$3.east[t];
          }
          return eastAgg;
        }).reversed.toList().swizzle();

    output.south <=
        List.generate(tracks, (t) {
          Logic southAgg = Const(0);
          for (int x = 0; x < width; x++) {
            southAgg = southAgg | tiles[x][height - 1].$3.south[t];
          }
          return southAgg;
        }).reversed.toList().swizzle();

    output.north <=
        List.generate(tracks, (t) {
          Logic northAgg = Const(0);
          for (int x = 0; x < width; x++) {
            northAgg = northAgg | tiles[x][0].$3.north[t];
          }
          return northAgg;
        }).reversed.toList().swizzle();

    output.west <=
        List.generate(tracks, (t) {
          Logic westAgg = Const(0);
          for (int y = 0; y < height; y++) {
            westAgg = westAgg | tiles[0][y].$3.west[t];
          }
          return westAgg;
        }).reversed.toList().swizzle();
  }
}
