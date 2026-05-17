import 'package:aegis_ip/aegis_ip.dart';
import 'package:test/test.dart';

void main() {
  group('KeepHierarchy.inject', () {
    test('tags every default-list module that appears', () {
      const sv = '''
module Lut4 (
  input wire a
);
endmodule

module Clb (
  input wire a
);
endmodule

module SomeOtherModule (
  input wire a
);
endmodule
''';
      final out = KeepHierarchy.inject(sv);
      expect(out, contains('(* keep_hierarchy *) module Lut4 ('));
      expect(out, contains('(* keep_hierarchy *) module Clb ('));
      expect(out, contains('module SomeOtherModule ('));
      expect(
        out,
        isNot(contains('(* keep_hierarchy *) module SomeOtherModule')),
      );
    });

    test('tags every module in the default list', () {
      final sv = KeepHierarchy.modules
          .map((m) => 'module $m (\n  input wire a\n);\nendmodule\n')
          .join('\n');
      final out = KeepHierarchy.inject(sv);
      for (final mod in KeepHierarchy.modules) {
        expect(
          out,
          contains('(* keep_hierarchy *) module $mod ('),
          reason: '$mod should be tagged',
        );
      }
    });

    test('is idempotent', () {
      const sv = 'module Tile (\n  input wire a\n);\nendmodule\n';
      final once = KeepHierarchy.inject(sv);
      final twice = KeepHierarchy.inject(once);
      expect(twice, equals(once));
      // The `(* keep_hierarchy *)` prefix should appear exactly once.
      expect('(* keep_hierarchy *)'.allMatches(twice).length, equals(1));
    });

    test('leaves missing modules silently', () {
      const sv = 'module Lut4 (\n  input wire a\n);\nendmodule\n';
      // SerDesTile is in the default list but not in [sv].
      final out = KeepHierarchy.inject(sv);
      expect(out, contains('(* keep_hierarchy *) module Lut4 ('));
      expect(out, isNot(contains('SerDesTile')));
    });

    test('respects a custom names list', () {
      const sv = '''
module Lut4 (
);
endmodule

module Clb (
);
endmodule
''';
      final out = KeepHierarchy.inject(sv, names: ['Lut4']);
      expect(out, contains('(* keep_hierarchy *) module Lut4 ('));
      expect(out, contains('module Clb ('));
      expect(out, isNot(contains('(* keep_hierarchy *) module Clb')));
    });

    test('does not tag modules whose name is a prefix of a listed name', () {
      const sv = 'module Lut (\n);\nendmodule\n';
      final out = KeepHierarchy.inject(sv);
      // 'Lut' is not in the default list; only 'Lut4' is.
      expect(out, isNot(contains('(* keep_hierarchy *) module Lut ')));
      expect(out, contains('module Lut ('));
    });

    test(
      'does not touch lines that look like module declarations inside strings or comments',
      () {
        // Comment / string lines never start at column 0 with `module ` in
        // ROHD-emitted SV; we still check that an inline occurrence is
        // safe.
        const sv = '''
// module Lut4 fake comment
  module Lut4 (
);
endmodule
module Clb (
);
endmodule
''';
        final out = KeepHierarchy.inject(sv);
        // The genuine top-level Clb declaration is tagged.
        expect(out, contains('(* keep_hierarchy *) module Clb ('));
        // The indented `module Lut4` is not at column 0, so untouched.
        expect(out, contains('  module Lut4 ('));
        expect(out, isNot(contains('(* keep_hierarchy *)   module Lut4')));
        // The comment line is untouched.
        expect(out, contains('// module Lut4 fake comment'));
      },
    );

    test('preserves non-module content verbatim', () {
      const sv = '''
// header comment
`default_nettype none

module Tile (
  input wire clk
);
  wire foo;
  assign foo = 1'b0;
endmodule

`default_nettype wire
''';
      final out = KeepHierarchy.inject(sv);
      expect(out, contains('// header comment'));
      expect(out, contains('`default_nettype none'));
      expect(out, contains('  wire foo;'));
      expect(out, contains("  assign foo = 1'b0;"));
      expect(out, contains('endmodule'));
      expect(out, contains('`default_nettype wire'));
    });

    test('handles empty input', () {
      expect(KeepHierarchy.inject(''), equals(''));
    });

    test('handles input with no module declarations', () {
      const sv = '// just a comment\n`default_nettype none\n';
      expect(KeepHierarchy.inject(sv), equals(sv));
    });
  });

  group('KeepHierarchy.modules', () {
    test('covers all macro modules from YosysTclEmitter', () {
      // KeepHierarchy is a superset of YosysTclEmitter.macroModules so
      // anything pre-synthesized as a hard macro is also flat-synth-safe.
      for (final mod in YosysTclEmitter.macroModules) {
        expect(
          KeepHierarchy.modules,
          contains(mod),
          reason: '$mod is a macro module but is not in KeepHierarchy.modules',
        );
      }
    });

    test('includes the structural modules above the tile macros', () {
      // These wrap the tile macros and would otherwise let yosys
      // dead-code-eliminate the fabric.
      expect(KeepHierarchy.modules, contains('AegisFPGA'));
      expect(KeepHierarchy.modules, contains('IOFabric'));
      expect(KeepHierarchy.modules, contains('LutFabric'));
    });

    test('includes the per-LUT structural modules', () {
      // Lut4 holds the actual config register bits; if yosys flattens
      // through Clb -> Lut4 it constant-folds them to 0.
      expect(KeepHierarchy.modules, contains('Clb'));
      expect(KeepHierarchy.modules, contains('Lut4'));
    });
  });
}
