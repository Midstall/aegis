import 'package:rohd/rohd.dart';
import '../../config/tile_config.dart';
import 'clb.dart';

enum TilePortGroup { routing }

class TileInterface extends Interface<TilePortGroup> {
  final int width;

  Logic get north => port('north');
  Logic get east => port('east');
  Logic get south => port('south');
  Logic get west => port('west');

  TileInterface({this.width = 1}) {
    setPorts(
      [
        Logic.port('north', width),
        Logic.port('east', width),
        Logic.port('south', width),
        Logic.port('west', width),
      ],
      [TilePortGroup.routing],
    );
  }

  @override
  TileInterface clone() => TileInterface(width: this.width);
}

class Tile extends Module {
  Logic get clk => input('clk');
  Logic get reset => input('reset');

  Logic get cfgIn => input('cfgIn');
  Logic get cfgOut => output('cfgOut');
  Logic get cfgLoad => input('cfgLoad');

  Logic get carryIn => input('carryIn');
  Logic get carryOut => output('carryOut');

  Logic get clbOut => output('clbOut');

  final int tracks;

  int get configWidth => tileConfigWidth(tracks);

  Tile(
    Logic clk,
    Logic reset,
    Logic cfgIn,
    Logic cfgLoad,
    TileInterface input,
    TileInterface output, {
    required Logic carryIn,
    required TileInterface neighborClbOut,
    this.tracks = 1,
  }) : super(name: 'tile') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);

    cfgIn = addInput('cfgIn', cfgIn, width: 1);
    cfgLoad = addInput('cfgLoad', cfgLoad, width: 1);
    addOutput('cfgOut', width: 1);

    carryIn = addInput('carryIn', carryIn);
    addOutput('carryOut');
    addOutput('clbOut');

    neighborClbOut = neighborClbOut.clone()
      ..connectIO(
        this,
        neighborClbOut,
        inputTags: {TilePortGroup.routing},
        outputTags: {},
        uniquify: (orig) => 'nb_$orig',
      );

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

    final cw = configWidth;
    final shiftReg = Logic(width: cw, name: 'shiftReg');
    final configReg = Logic(width: cw, name: 'configReg');

    Sequential(
      clk,
      [
        shiftReg < [cfgIn, shiftReg.slice(cw - 1, 1)].swizzle(),
        If.s(cfgLoad, configReg < shiftReg),
      ],
      reset: reset,
      resetValues: {
        shiftReg: Const(0, width: cw),
        configReg: Const(0, width: cw),
      },
    );

    final cfgOutBit = Logic(name: 'cfgOutBit');
    cfgOutBit <= shiftReg[0];
    cfgOut <= cfgOutBit;

    // Config layout (parametric, see tile_config.dart):
    //   [17:0]            CLB config
    //   [18..18+4*ISW-1]  input mux sel0..sel3
    //   [18+4*ISW..]      per-track output: (enable + 3-bit select) per track per direction

    final isw = inputSelWidth(tracks);

    final clbConfig = configReg.slice(17, 0);

    final sel = List.generate(4, (i) {
      final lo = 18 + i * isw;
      return configReg.slice(lo + isw - 1, lo);
    });

    final outBase = 18 + 4 * isw;

    // Neighbor CLB output ports (N, E, S, W)
    final nbPorts = [
      neighborClbOut.north,
      neighborClbOut.east,
      neighborClbOut.south,
      neighborClbOut.west,
    ];

    // Input mux: select from direction*T+track for directional,
    // 4*T+{0,1,2} for internal, 4*T+{3,4,5,6} for neighbor CLB outputs
    Logic selectInput(Logic selBits) {
      final result = Logic();

      // Build mux chain from highest value down
      Logic chain = Const(0, width: 1);

      // Neighbor CLB outputs: W, S, E, N (highest values down)
      for (var d = 3; d >= 0; d--) {
        chain = mux(
          selBits.eq(Const(inputSelNeighbor(d, tracks), width: isw)),
          nbPorts[d],
          chain,
        );
      }

      // const1
      chain = mux(
        selBits.eq(Const(inputSelConst1(tracks), width: isw)),
        Const(1, width: 1),
        chain,
      );
      // const0
      chain = mux(
        selBits.eq(Const(inputSelConst0(tracks), width: isw)),
        Const(0, width: 1),
        chain,
      );
      // clbOut
      chain = mux(
        selBits.eq(Const(inputSelClbOut(tracks), width: isw)),
        clbOut,
        chain,
      );

      // Directional sources: W(T-1) down to N0
      final dirPorts = [input.north, input.east, input.south, input.west];
      for (var d = 3; d >= 0; d--) {
        for (var t = tracks - 1; t >= 0; t--) {
          chain = mux(
            selBits.eq(Const(inputSelDir(d, t, tracks), width: isw)),
            dirPorts[d][t],
            chain,
          );
        }
      }

      result <= chain;
      return result;
    }

    final in0 = selectInput(sel[0]);
    final in1 = selectInput(sel[1]);
    final in2 = selectInput(sel[2]);
    final in3 = selectInput(sel[3]);

    final clb = Clb(
      clk,
      clbConfig,
      in0: in0,
      in1: in1,
      in2: in2,
      in3: in3,
      carryIn: carryIn,
    );

    clbOut <= clb.out;
    this.carryOut <= clb.carryOut;

    // Per-track output routing
    final dirPorts = [input.north, input.east, input.south, input.west];
    final dirOutputs = [<Logic>[], <Logic>[], <Logic>[], <Logic>[]];

    for (var d = 0; d < 4; d++) {
      for (var t = 0; t < tracks; t++) {
        final bitOff = outBase + (d * tracks + t) * 4;
        final en = configReg[bitOff];
        final selOut = configReg.slice(bitOff + 3, bitOff + 1);

        // Output mux: select source direction (same track index)
        Logic routeVal = Const(0, width: 1);
        routeVal = mux(selOut.eq(Const(4, width: 3)), clbOut, routeVal);
        for (var s = 3; s >= 0; s--) {
          routeVal = mux(
            selOut.eq(Const(s, width: 3)),
            dirPorts[s][t],
            routeVal,
          );
        }

        dirOutputs[d].add(mux(en, routeVal, Const(0, width: 1)));
      }
    }

    output.north <= dirOutputs[0].reversed.toList().swizzle();
    output.east <= dirOutputs[1].reversed.toList().swizzle();
    output.south <= dirOutputs[2].reversed.toList().swizzle();
    output.west <= dirOutputs[3].reversed.toList().swizzle();
  }
}
