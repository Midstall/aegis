import 'dart:convert';
import 'dart:io';

import 'package:aegis_ip/aegis_ip.dart';
import 'package:args/args.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart';

ArgParser buildParser() {
  return ArgParser()
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Print this usage information.',
    )
    ..addFlag(
      'config-clk',
      abbr: 'c',
      help: 'Adds a clock domain for tile configuration',
    )
    ..addFlag(
      'jtag',
      abbr: 'j',
      help: 'Adds a JTAG TAP controller for configuration and debug',
    )
    ..addOption(
      'output',
      abbr: 'o',
      help: 'Output directory (default: ./build)',
      defaultsTo: 'build',
    )
    ..addOption(
      'name',
      abbr: 'n',
      help: 'Device name (default: aegis_fpga)',
      defaultsTo: 'aegis_fpga',
    )
    ..addOption(
      'width',
      abbr: 'x',
      help: 'Number of tiles to have in the X axis',
    )
    ..addOption(
      'height',
      abbr: 'y',
      help: 'Number of tiles to have in the Y axis',
    )
    ..addOption(
      'tracks',
      abbr: 't',
      help: 'Width of the connections in the tiles',
    )
    ..addOption(
      'serdes',
      abbr: 's',
      help: 'Number of hard SerDes tiles (default: 4)',
    )
    ..addOption(
      'bram-interval',
      help: 'Place a BRAM column every N LUT columns (0 = no BRAM)',
    )
    ..addOption(
      'dsp-interval',
      help: 'Place a DSP column every N LUT columns (0 = no DSP)',
    )
    ..addOption(
      'clock-tiles',
      help: 'Number of clock management tiles (default: 1)',
    )
    ..addOption('config-data-width', help: 'Width of the config data bus')
    ..addOption('config-address-width', help: 'Width of the config address bus')
    ..addOption(
      'pdk',
      help: 'PDK for xschem analog block symbols',
      defaultsTo: 'generic',
      allowedHelp: PdkProvider.registryHelp,
    )
    ..addOption(
      'symbol-path',
      help: 'Base path for xschem symbol resolution (default: output dir)',
    );
}

void printUsage(ArgParser argParser) {
  print('Usage: aegis_genip <flags> [arguments]');
  print(argParser.usage);
}

Future<void> main(List<String> arguments) async {
  final ArgParser argParser = buildParser();
  try {
    final ArgResults results = argParser.parse(arguments);

    if (results.flag('help')) {
      printUsage(argParser);
      return;
    }

    final width = int.parse(results.option('width') ?? '1');
    final height = int.parse(results.option('height') ?? '1');
    final tracks = int.parse(results.option('tracks') ?? '1');
    final serdesCount = int.parse(results.option('serdes') ?? '4');
    final bramInterval = int.parse(results.option('bram-interval') ?? '0');
    final dspInterval = int.parse(results.option('dsp-interval') ?? '0');
    final clockTiles = int.parse(results.option('clock-tiles') ?? '1');
    final outputDir = results.option('output')!;

    final fpga = AegisFPGA(
      Logic(),
      Logic(),
      name: results.option('name')!,
      width: width,
      height: height,
      tracks: tracks,
      serdesCount: serdesCount,
      bramColumnInterval: bramInterval,
      dspColumnInterval: dspInterval,
      clockTileCount: clockTiles,
      padIn: Logic(width: 2 * width + 2 * height),
      serialIn: Logic(width: serdesCount),
      configClk: results.flag('config-clk') ? Logic() : null,
      enableJtag: results.flag('jtag'),
      configReadPort: DataPortInterface(
        int.parse(results.option('config-data-width') ?? '8'),
        int.parse(results.option('config-address-width') ?? '8'),
      ),
    );

    await fpga.build();

    final dir = Directory(outputDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    // Tag fabric/tile modules with `(* keep_hierarchy *)` so flat
    // synthesis flows (LibreLane, OpenLane) cannot constant-fold
    // through the LUT config registers and dead-code-eliminate the
    // entire fabric.
    final svContent = KeepHierarchy.inject(fpga.generateSynth());
    File('$outputDir/${fpga.name}.sv').writeAsStringSync(svContent);

    const encoder = JsonEncoder.withIndent('  ');
    File(
      '$outputDir/${fpga.name}.json',
    ).writeAsStringSync(encoder.convert(fpga.toJsonDescriptor()));

    final symbolPath = results.option('symbol-path') ?? outputDir;
    final pdk = PdkProvider.resolve(
      results.option('pdk')!,
      symbolBasePath: symbolPath,
    );

    final tclEmitter = XschemTclEmitter(
      deviceName: fpga.name,
      clockTileCount: clockTiles,
      serdesCount: serdesCount,
      totalPads: 2 * width + 2 * height,
      width: width,
      height: height,
      pdk: pdk,
    );
    File(
      '$outputDir/${fpga.name}-xschem.tcl',
    ).writeAsStringSync(tclEmitter.generate());

    final schEmitter = XschemSchEmitter(
      deviceName: fpga.name,
      clockTileCount: clockTiles,
      serdesCount: serdesCount,
      totalPads: 2 * width + 2 * height,
      width: width,
      height: height,
      pdk: pdk,
    );
    File(
      '$outputDir/${fpga.name}-xschem.sch',
    ).writeAsStringSync(schEmitter.generate());

    final yosysEmitter = YosysTclEmitter(
      moduleName: 'AegisFPGA',
      width: width,
      height: height,
      serdesCount: serdesCount,
      clockTileCount: clockTiles,
    );
    // Top-level assembly script (reads pre-synthesized tile macros)
    File(
      '$outputDir/${fpga.name}-yosys.tcl',
    ).writeAsStringSync(yosysEmitter.generate());
    // Determine which macro modules actually exist in the generated SV
    final presentModules = YosysTclEmitter.macroModules
        .where((mod) => svContent.contains('module $mod ('))
        .toList();

    // Per-tile synthesis scripts (only for modules that exist)
    for (final mod in presentModules) {
      File(
        '$outputDir/${fpga.name}-yosys-$mod.tcl',
      ).writeAsStringSync(yosysEmitter.generateTileSynth(mod));
    }
    final stubs = StringBuffer();
    stubs.writeln(
      '// Auto-generated tile blackbox stubs for hierarchical synthesis',
    );
    stubs.writeln(
      '// These are empty modules with matching ports so the top-level',
    );
    stubs.writeln(
      '// synthesis can elaborate without processing tile internals.',
    );
    stubs.writeln();
    for (final mod in presentModules) {
      final modStart = svContent.indexOf('module $mod (');
      if (modStart == -1) continue;

      // Extract from "module X (" to the closing ");"
      final portEnd = svContent.indexOf(');', modStart);
      if (portEnd == -1) continue;

      final decl = svContent.substring(modStart, portEnd + 2);
      stubs.writeln('(* blackbox *)');
      stubs.writeln(decl);
      stubs.writeln('endmodule');
      stubs.writeln();
    }
    File(
      '$outputDir/${fpga.name}_tile_stubs.v',
    ).writeAsStringSync(stubs.toString());

    final techmapEmitter = YosysTechmapEmitter(
      deviceName: fpga.name,
      width: width,
      height: height,
      tracks: tracks,
      bramDataWidth: 8,
      bramAddrWidth: 7,
      bramColumnInterval: bramInterval,
      hasJtag: results.flag('jtag'),
    );
    File(
      '$outputDir/${fpga.name}_cells.v',
    ).writeAsStringSync(techmapEmitter.generateCells());
    File(
      '$outputDir/${fpga.name}_techmap.v',
    ).writeAsStringSync(techmapEmitter.generateTechmap());
    File(
      '$outputDir/${fpga.name}-synth-aegis.tcl',
    ).writeAsStringSync(techmapEmitter.generateSynthScript());

    final bramRules = techmapEmitter.generateBramRules();
    if (bramRules != null) {
      File('$outputDir/${fpga.name}_bram.rules').writeAsStringSync(bramRules);
    }

    final openroadEmitter = OpenroadTclEmitter(
      moduleName: 'AegisFPGA',
      width: width,
      height: height,
      serdesCount: serdesCount,
      clockTileCount: clockTiles,
      bramColumnInterval: bramInterval,
      dspColumnInterval: dspInterval,
      hasConfigClk: results.flag('config-clk'),
      hasJtag: results.flag('jtag'),
    );
    File(
      '$outputDir/${fpga.name}-openroad.tcl',
    ).writeAsStringSync(openroadEmitter.generate());

    // Per-tile OpenROAD PnR scripts (tile macro hardening)
    final tileOpenroadEmitter = OpenroadTileTclEmitter(
      deviceName: fpga.name,
      tracks: tracks,
    );
    for (final mod in presentModules) {
      File(
        '$outputDir/${fpga.name}-openroad-$mod.tcl',
      ).writeAsStringSync(tileOpenroadEmitter.generateTilePnr(mod));
    }

    print('Generated:');
    print('  $outputDir/${fpga.name}.sv');
    print('  $outputDir/${fpga.name}.json');
    print('  $outputDir/${fpga.name}-xschem.tcl');
    print('  $outputDir/${fpga.name}-xschem.sch');
    print('  $outputDir/${fpga.name}-yosys.tcl');
    for (final mod in presentModules) {
      print('  $outputDir/${fpga.name}-yosys-$mod.tcl');
    }
    print('  $outputDir/${fpga.name}_cells.v');
    print('  $outputDir/${fpga.name}_techmap.v');
    print('  $outputDir/${fpga.name}-synth-aegis.tcl');
    print('  $outputDir/${fpga.name}-openroad.tcl');
    for (final mod in presentModules) {
      print('  $outputDir/${fpga.name}-openroad-$mod.tcl');
    }
  } on FormatException catch (e) {
    print(e.message);
    print('');
    printUsage(argParser);
  }
}
