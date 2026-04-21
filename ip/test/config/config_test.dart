import 'package:aegis_ip/aegis_ip.dart';
import 'package:test/test.dart';

void main() {
  group('Lut4Config', () {
    test('default is zero', () {
      const cfg = Lut4Config();
      expect(cfg.truthTable, 0);
      expect(cfg.encode(), BigInt.zero);
    });

    test('encode/decode round-trip', () {
      const cfg = Lut4Config(truthTable: 0xCAFE);
      final decoded = Lut4Config.decode(cfg.encode());
      expect(decoded.truthTable, 0xCAFE);
    });

    test('presets encode correctly', () {
      expect(Lut4Config.and2.truthTable, 0x8888);
      expect(Lut4Config.or2.truthTable, 0xEEEE);
      expect(Lut4Config.xor2.truthTable, 0x6666);
      expect(Lut4Config.inv.truthTable, 0x5555);
      expect(Lut4Config.zero.truthTable, 0x0000);
      expect(Lut4Config.one.truthTable, 0xFFFF);
      expect(Lut4Config.carryPropagate.truthTable, 0x6666);
    });

    test('decode masks to 16 bits', () {
      final decoded = Lut4Config.decode(BigInt.from(0x1CAFE));
      expect(decoded.truthTable, 0xCAFE);
    });

    test('toString', () {
      expect(Lut4Config.and2.toString(), contains('8888'));
    });
  });

  group('ClbConfig', () {
    test('default', () {
      const cfg = ClbConfig();
      expect(cfg.ffEnable, false);
      expect(cfg.carryMode, false);
      expect(cfg.lut.truthTable, 0);
    });

    test('encode/decode round-trip', () {
      const cfg = ClbConfig(
        lut: Lut4Config(truthTable: 0xABCD),
        ffEnable: true,
        carryMode: true,
      );
      final bits = cfg.encode();
      final decoded = ClbConfig.decode(bits);
      expect(decoded.lut.truthTable, 0xABCD);
      expect(decoded.ffEnable, true);
      expect(decoded.carryMode, true);
    });

    test('ff bit at position 16', () {
      const cfg = ClbConfig(ffEnable: true);
      expect(cfg.encode() >> 16 & BigInt.one, BigInt.one);
    });

    test('carry bit at position 17', () {
      const cfg = ClbConfig(carryMode: true);
      expect(cfg.encode() >> 17 & BigInt.one, BigInt.one);
    });

    test('fullAdder preset', () {
      expect(ClbConfig.fullAdder.carryMode, true);
      expect(ClbConfig.fullAdder.lut.truthTable, 0x6666);
    });

    test('toString', () {
      expect(ClbConfig.fullAdder.toString(), contains('carry: true'));
    });
  });

  group('TileConfig', () {
    test('default for 1 track', () {
      final cfg = TileConfig.defaultFor(1);
      expect(cfg.inputSel, [0, 0, 0, 0]);
      expect(cfg.outputs[0][0].enable, false);
    });

    test('encode/decode round-trip with T=1', () {
      final cfg = TileConfig(
        clb: const ClbConfig(
          lut: Lut4Config(truthTable: 0x1234),
          ffEnable: true,
          carryMode: false,
        ),
        tracks: 1,
        inputSel: [0, 1, 2, 3], // N0, E0, S0, W0
        outputs: [
          [const TrackOutputConfig(enable: true, select: 4)], // N0: CLB
          [const TrackOutputConfig(enable: false, select: 0)], // E0: off
          [
            const TrackOutputConfig(enable: true, select: 6),
          ], // S0: const1 (invalid but tests encoding)
          [const TrackOutputConfig(enable: true, select: 0)], // W0: north
        ],
      );
      final bits = cfg.encode();
      final decoded = TileConfig.decode(bits, tracks: 1);
      expect(decoded.clb.lut.truthTable, 0x1234);
      expect(decoded.clb.ffEnable, true);
      expect(decoded.clb.carryMode, false);
      expect(decoded.inputSel, [0, 1, 2, 3]);
      expect(decoded.outputs[0][0].enable, true);
      expect(decoded.outputs[0][0].select, 4);
      expect(decoded.outputs[1][0].enable, false);
      expect(decoded.outputs[2][0].enable, true);
      expect(decoded.outputs[3][0].enable, true);
      expect(decoded.outputs[3][0].select, 0);
    });

    test('T=1 fits in 50 bits', () {
      expect(tileConfigWidth(1), 50);
      final cfg = TileConfig(
        clb: const ClbConfig(
          lut: Lut4Config(truthTable: 0xFFFF),
          ffEnable: true,
          carryMode: true,
        ),
        tracks: 1,
        inputSel: [10, 10, 10, 10], // max value for T=1 (NB_W)
        outputs: [
          [const TrackOutputConfig(enable: true, select: 7)],
          [const TrackOutputConfig(enable: true, select: 7)],
          [const TrackOutputConfig(enable: true, select: 7)],
          [const TrackOutputConfig(enable: true, select: 7)],
        ],
      );
      final bits = cfg.encode();
      expect(bits < (BigInt.one << 50), true);
    });

    test('T=4 width is 102', () {
      expect(tileConfigWidth(4), 102);
    });

    test('toString', () {
      expect(TileConfig.defaultFor(1).toString(), contains('TileConfig'));
    });
  });

  group('IOTileConfig', () {
    test('default is hi-Z', () {
      const cfg = IOTileConfig();
      expect(cfg.direction, IODirection.highZ);
      expect(cfg.encode(), BigInt.zero);
    });

    test('encode/decode round-trip', () {
      const cfg = IOTileConfig(
        direction: IODirection.bidir,
        inputRegEnable: true,
        outputRegEnable: true,
        trackSelect: 5,
        pullUp: true,
      );
      final decoded = IOTileConfig.decode(cfg.encode());
      expect(decoded.direction, IODirection.bidir);
      expect(decoded.inputRegEnable, true);
      expect(decoded.outputRegEnable, true);
      expect(decoded.trackSelect, 5);
      expect(decoded.pullUp, true);
    });

    test('presets', () {
      expect(IOTileConfig.simpleInput.direction, IODirection.input);
      expect(IOTileConfig.simpleInput.inputRegEnable, false);
      expect(IOTileConfig.simpleOutput.direction, IODirection.output);
      expect(IOTileConfig.registeredInput.inputRegEnable, true);
      expect(IOTileConfig.registeredOutput.outputRegEnable, true);
    });

    test('fits in 8 bits', () {
      const cfg = IOTileConfig(
        direction: IODirection.bidir,
        inputRegEnable: true,
        outputRegEnable: true,
        trackSelect: 7,
        pullUp: true,
      );
      expect(cfg.encode() < (BigInt.one << IOTileConfig.width), true);
    });

    test('toString', () {
      expect(IOTileConfig.simpleInput.toString(), contains('IOTileConfig'));
    });
  });

  group('SerDesTileConfig', () {
    test('default', () {
      const cfg = SerDesTileConfig();
      expect(cfg.txEnable, false);
      expect(cfg.rxEnable, false);
      expect(cfg.wordLength, 8);
      expect(cfg.clockDivider, 1);
    });

    test('encode/decode round-trip', () {
      const cfg = SerDesTileConfig(
        txEnable: true,
        rxEnable: true,
        txDataTrack: 3,
        rxDataTrack: 5,
        wordLength: 32,
        msbFirst: true,
        txIdleHigh: false,
        ddrMode: true,
        clockPolarity: true,
        clockDivider: 128,
        loopback: true,
        txStrobeTrack: 2,
      );
      final decoded = SerDesTileConfig.decode(cfg.encode());
      expect(decoded.txEnable, true);
      expect(decoded.rxEnable, true);
      expect(decoded.txDataTrack, 3);
      expect(decoded.rxDataTrack, 5);
      expect(decoded.wordLength, 32);
      expect(decoded.msbFirst, true);
      expect(decoded.txIdleHigh, false);
      expect(decoded.ddrMode, true);
      expect(decoded.clockPolarity, true);
      expect(decoded.clockDivider, 128);
      expect(decoded.loopback, true);
      expect(decoded.txStrobeTrack, 2);
    });

    test('presets', () {
      expect(SerDesTileConfig.uart8n1.txEnable, true);
      expect(SerDesTileConfig.uart8n1.txIdleHigh, true);
      expect(SerDesTileConfig.uart8n1.msbFirst, false);
      expect(SerDesTileConfig.spiMaster.msbFirst, true);
      expect(SerDesTileConfig.spiMaster.txIdleHigh, false);
      expect(SerDesTileConfig.ddrLoopback.ddrMode, true);
      expect(SerDesTileConfig.ddrLoopback.loopback, true);
    });

    test('fits in 32 bits', () {
      const cfg = SerDesTileConfig(
        txEnable: true,
        rxEnable: true,
        txDataTrack: 7,
        rxDataTrack: 7,
        wordLength: 256,
        msbFirst: true,
        txIdleHigh: true,
        ddrMode: true,
        clockPolarity: true,
        clockDivider: 256,
        loopback: true,
        txStrobeTrack: 3,
      );
      expect(cfg.encode() < (BigInt.one << SerDesTileConfig.width), true);
    });

    test('toString', () {
      expect(SerDesTileConfig.uart8n1.toString(), contains('LSB-first'));
      expect(SerDesTileConfig.spiMaster.toString(), contains('MSB-first'));
      expect(SerDesTileConfig.ddrLoopback.toString(), contains('DDR'));
    });
  });

  group('BramTileConfig', () {
    test('default disabled', () {
      const cfg = BramTileConfig();
      expect(cfg.portAEnable, false);
      expect(cfg.portBEnable, false);
      expect(cfg.encode(), BigInt.zero);
    });

    test('encode/decode round-trip', () {
      const cfg = BramTileConfig(portAEnable: true, portBEnable: true);
      final decoded = BramTileConfig.decode(cfg.encode());
      expect(decoded.portAEnable, true);
      expect(decoded.portBEnable, true);
    });

    test('presets', () {
      expect(BramTileConfig.dualPort.portAEnable, true);
      expect(BramTileConfig.dualPort.portBEnable, true);
      expect(BramTileConfig.singlePortA.portAEnable, true);
      expect(BramTileConfig.singlePortA.portBEnable, false);
      expect(BramTileConfig.singlePortB.portAEnable, false);
      expect(BramTileConfig.singlePortB.portBEnable, true);
    });

    test('toString', () {
      expect(BramTileConfig.dualPort.toString(), contains('A: true'));
    });
  });
}
