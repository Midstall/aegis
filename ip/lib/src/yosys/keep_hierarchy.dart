class KeepHierarchy {
  static const modules = <String>[
    'AegisFPGA',
    'IOFabric',
    'LutFabric',
    'ClockTile',
    'FabricConfigLoader',
    'JtagTap',
    'IOTile',
    'SerDesTile',
    'Tile',
    'BramTile',
    'DspBasicTile',
    'Clb',
    'Lut4',
  ];

  static String inject(String sv, {Iterable<String>? names}) {
    final tagged = (names ?? modules).toSet();
    final lines = sv.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (!line.startsWith('module ')) continue;
      final rest = line.substring('module '.length);
      final endIdx = rest.indexOf(RegExp(r'[\s(]'));
      if (endIdx <= 0) continue;
      final name = rest.substring(0, endIdx);
      if (!tagged.contains(name)) continue;
      lines[i] = '(* keep_hierarchy *) $line';
    }
    return lines.join('\n');
  }
}
