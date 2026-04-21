import '../yosys/tcl_emitter.dart';

/// Emits an OpenROAD TCL script for top-level macro-based place-and-route.
///
/// Tile modules are pre-hardened as macros (with LEF abstracts).
/// This script places them in a grid and routes the inter-tile wiring
/// on upper metal layers.
class OpenroadTclEmitter {
  final String moduleName;
  final int width;
  final int height;
  final int serdesCount;
  final int clockTileCount;
  final int bramColumnInterval;
  final int dspColumnInterval;
  final bool hasConfigClk;
  final bool hasJtag;

  int get totalPads => 2 * width + 2 * height;

  /// Spacing between tile macros (um). Must be large enough for
  /// clock buffer and standard cell placement in routing channels.
  final double macroHaloUm;

  /// Margin around the macro grid edge (um). Room for IO pins
  /// and glue logic placement.
  final double gridMarginUm;

  const OpenroadTclEmitter({
    required this.moduleName,
    required this.width,
    required this.height,
    required this.serdesCount,
    required this.clockTileCount,
    this.bramColumnInterval = 0,
    this.dspColumnInterval = 0,
    this.hasConfigClk = false,
    this.hasJtag = false,
    this.macroHaloUm = 100,
    this.gridMarginUm = 200,
  });

  String generate() {
    final buf = StringBuffer();

    _writeHeader(buf);
    _writeReadInputs(buf);
    _writeFloorplan(buf);
    _writePinPlacement(buf);
    _writePowerGrid(buf);
    _writePlacement(buf);
    _writeCts(buf);
    _writeRouting(buf);
    _writeReports(buf);
    _writeOutputs(buf);

    return buf.toString();
  }

  void _writeHeader(StringBuffer buf) {
    buf.writeln('# Auto-generated OpenROAD TCL script for $moduleName');
    buf.writeln(
      '# Fabric: ${width}x$height, $serdesCount SerDes, '
      '$clockTileCount clock tiles',
    );
    buf.writeln('#');
    buf.writeln('# Macro-based hierarchical flow:');
    buf.writeln('# - Tile types are pre-hardened macros (LEF abstracts)');
    buf.writeln('# - Top level places macros and routes inter-tile wiring');
    buf.writeln('#');
    buf.writeln('# Shell variables substituted at build time.');
    buf.writeln();
    // Helper: discover routing layers from loaded tech LEF
    buf.writeln('# Discover routing layers from the PDK tech LEF');
    buf.writeln('proc get_routing_layers {} {');
    buf.writeln('    set layers {}');
    buf.writeln('    set tech [[ord::get_db] getTech]');
    buf.writeln('    foreach layer [\$tech getLayers] {');
    buf.writeln('        if {[\$layer getType] eq "ROUTING"} {');
    buf.writeln('            lappend layers [\$layer getName]');
    buf.writeln('        }');
    buf.writeln('    }');
    buf.writeln('    return \$layers');
    buf.writeln('}');
    buf.writeln();
  }

  void _writeReadInputs(StringBuffer buf) {
    buf.writeln(_section('Read inputs'));

    buf.writeln('read_liberty \$LIB_FILE');
    buf.writeln('read_lef \$TECH_LEF');
    buf.writeln();

    // Read standard cell LEFs
    buf.writeln('# Read standard cell LEFs');
    buf.writeln('foreach lef [glob -directory \$CELL_LEF_DIR *.lef] {');
    buf.writeln('    if {![string match "*tech*" \$lef]} {');
    buf.writeln('        read_lef \$lef');
    buf.writeln('    }');
    buf.writeln('}');
    buf.writeln();

    // Read tile macro LEFs and liberty timing models
    buf.writeln('# Read tile macro LEF abstracts and timing models');
    for (final mod in YosysTclEmitter.tileModules) {
      buf.writeln('if {[file exists \${DEVICE_NAME}_${mod}.lef]} {');
      buf.writeln('    read_lef \${DEVICE_NAME}_${mod}.lef');
      buf.writeln('}');
      buf.writeln('if {[file exists \${DEVICE_NAME}_${mod}.lib]} {');
      buf.writeln('    read_liberty \${DEVICE_NAME}_${mod}.lib');
      buf.writeln('}');
    }
    buf.writeln();

    buf.writeln('read_verilog \$SYNTH_V');
    buf.writeln('link_design $moduleName');
    buf.writeln('read_sdc \$SDC_FILE');
    buf.writeln();
  }

  void _writeFloorplan(StringBuffer buf) {
    buf.writeln(_section('Floorplan'));

    // Compute die area from macro sizes if available
    buf.writeln('# Determine die area: use explicit setting, or compute from');
    buf.writeln('# tile macro dimensions × grid size');
    buf.writeln('if {[info exists DIE_AREA]} {');
    buf.writeln('    initialize_floorplan \\');
    buf.writeln('        -die_area \$DIE_AREA \\');
    buf.writeln(
      '        -core_area "[expr {[lindex \$DIE_AREA 0] + 1}] [expr {[lindex \$DIE_AREA 1] + 1}] [expr {[lindex \$DIE_AREA 2] - 1}] [expr {[lindex \$DIE_AREA 3] - 1}]" \\',
    );
    buf.writeln('        -site \$SITE_NAME');
    buf.writeln('} else {');
    buf.writeln('    # Find largest macro to size the die');
    buf.writeln('    set tw 0');
    buf.writeln('    set th 0');
    buf.writeln('    foreach inst [[ord::get_db_block] getInsts] {');
    buf.writeln('        if {[[\$inst getMaster] isBlock]} {');
    buf.writeln(
      '            set mw [ord::dbu_to_microns [[\$inst getMaster] getWidth]]',
    );
    buf.writeln(
      '            set mh [ord::dbu_to_microns [[\$inst getMaster] getHeight]]',
    );
    buf.writeln('            if {\$mw > \$tw} { set tw \$mw }');
    buf.writeln('            if {\$mh > \$th} { set th \$mh }');
    buf.writeln('        }');
    buf.writeln('    }');
    buf.writeln('    if {\$tw > 0} {');
    buf.writeln('        # Count total macro instances to size the die');
    buf.writeln('        set macro_n 0');
    buf.writeln('        foreach inst [[ord::get_db_block] getInsts] {');
    buf.writeln(
      '            if {[[\$inst getMaster] isBlock]} { incr macro_n }',
    );
    buf.writeln('        }');
    buf.writeln('        # Compute grid dimensions from macro count');
    buf.writeln(
      '        set grid_cols [expr {int(sqrt(\$macro_n * \$tw / \$th)) + 1}]',
    );
    buf.writeln(
      '        set grid_rows [expr {(\$macro_n + \$grid_cols - 1) / \$grid_cols}]',
    );
    buf.writeln(
      '        puts "Die grid: \$grid_cols cols x \$grid_rows rows for \$macro_n macros"',
    );
    buf.writeln('        set mfg 0.005');
    buf.writeln(
      '        if {![info exists MACRO_HALO]} { set MACRO_HALO $macroHaloUm }',
    );
    buf.writeln(
      '        if {![info exists GRID_MARGIN]} { set GRID_MARGIN $gridMarginUm }',
    );
    buf.writeln(
      '        set die_w [expr {int(((\$tw + \$MACRO_HALO) * \$grid_cols + 2 * \$GRID_MARGIN) / \$mfg) * \$mfg}]',
    );
    buf.writeln(
      '        set die_h [expr {int(((\$th + \$MACRO_HALO) * \$grid_rows + 2 * \$GRID_MARGIN) / \$mfg) * \$mfg}]',
    );
    buf.writeln(
      '        puts "Computed die area: \${die_w}um x \${die_h}um '
      '(tile: \${tw}um x \${th}um)"',
    );
    buf.writeln('        set margin \$GRID_MARGIN');
    buf.writeln('        initialize_floorplan \\');
    buf.writeln('            -die_area "0 0 \$die_w \$die_h" \\');
    buf.writeln(
      '            -core_area "\$margin \$margin '
      '[expr {\$die_w - \$margin}] [expr {\$die_h - \$margin}]" \\',
    );
    buf.writeln('            -site \$SITE_NAME');
    buf.writeln('    } else {');
    buf.writeln('        # Fallback: utilization-based');
    buf.writeln('        initialize_floorplan \\');
    buf.writeln('            -utilization \$UTILIZATION \\');
    buf.writeln('            -core_space 2 \\');
    buf.writeln('            -site \$SITE_NAME');
    buf.writeln('    }');
    buf.writeln('}');
    buf.writeln();

    buf.writeln('foreach layer [get_routing_layers] {');
    buf.writeln(
      '    if {![catch {set tech_layer '
      '[[[ord::get_db] getTech] findLayer \$layer]}]} {',
    );
    buf.writeln('        if {\$tech_layer ne "NULL"} {');
    buf.writeln(
      '            set pitch_x '
      '[ord::dbu_to_microns [\$tech_layer getPitchX]]',
    );
    buf.writeln(
      '            set pitch_y '
      '[ord::dbu_to_microns [\$tech_layer getPitchY]]',
    );
    buf.writeln('            if {\$pitch_x > 0 && \$pitch_y > 0} {');
    buf.writeln('                make_tracks \$layer \\');
    buf.writeln('                    -x_offset 0 -x_pitch \$pitch_x \\');
    buf.writeln('                    -y_offset 0 -y_pitch \$pitch_y');
    buf.writeln('            }');
    buf.writeln('        }');
    buf.writeln('    }');
    buf.writeln('}');
    buf.writeln();
  }

  void _writePinPlacement(StringBuffer buf) {
    buf.writeln(_section('Pin placement'));

    final westPins = <String>['clk', 'reset', 'configDone'];
    if (hasConfigClk) westPins.add('configClk');
    westPins.addAll([
      'configRead_en',
      'configRead_addr\\[*\\]',
      'configRead_data\\[*\\]',
    ]);
    if (hasJtag) {
      westPins.addAll(['tck', 'tms', 'tdi', 'tdo', 'trst']);
    }

    final eastPins = <String>[];
    if (serdesCount > 0) {
      eastPins.addAll([
        'serialIn\\[*\\]',
        'serialOut\\[*\\]',
        'txReady\\[*\\]',
        'rxValid\\[*\\]',
      ]);
    }
    if (clockTileCount > 0) {
      eastPins.addAll(['clkOut\\[*\\]', 'clkLocked\\[*\\]']);
    }

    _writeLayerDetection(buf);
    buf.writeln('place_pins -hor_layers \$hor_layer -ver_layers \$ver_layer');
    buf.writeln();
  }

  void _writePowerGrid(StringBuffer buf) {
    buf.writeln(_section('Power grid'));

    buf.writeln('add_global_connection -net VDD -pin_pattern VDD -power');
    buf.writeln('add_global_connection -net VSS -pin_pattern VSS -ground');
    buf.writeln('global_connect');
    buf.writeln();
  }

  void _writePlacement(StringBuffer buf) {
    buf.writeln(_section('Placement'));

    // Count and report unplaced macros
    buf.writeln('# Detect macros');
    buf.writeln('set macro_count 0');
    buf.writeln('foreach inst [[ord::get_db_block] getInsts] {');
    buf.writeln('    if {[[\$inst getMaster] isBlock]} {');
    buf.writeln('        incr macro_count');
    buf.writeln('    }');
    buf.writeln('}');
    buf.writeln('puts "Detected \$macro_count macro instances"');
    buf.writeln();

    buf.writeln('if {\$macro_count > 0} {');
    buf.writeln(
      '    if {![info exists MACRO_HALO]} { set MACRO_HALO $macroHaloUm }',
    );
    buf.writeln(
      '    if {![info exists GRID_MARGIN]} { set GRID_MARGIN $gridMarginUm }',
    );
    buf.writeln('    set halo \$MACRO_HALO');
    buf.writeln('    set margin \$GRID_MARGIN');
    buf.writeln();

    // Group macros by master name
    buf.writeln('    # Group macros by type');
    buf.writeln('    array set macro_groups {}');
    buf.writeln('    foreach inst [[ord::get_db_block] getInsts] {');
    buf.writeln('        if {[[\$inst getMaster] isBlock]} {');
    buf.writeln('            set mname [[\$inst getMaster] getName]');
    buf.writeln('            lappend macro_groups(\$mname) \$inst');
    buf.writeln('        }');
    buf.writeln('    }');
    buf.writeln();
    buf.writeln('    foreach type [array names macro_groups] {');
    buf.writeln('        set n [llength \$macro_groups(\$type)]');
    buf.writeln('        set m [[lindex \$macro_groups(\$type) 0] getMaster]');
    buf.writeln('        set w [ord::dbu_to_microns [\$m getWidth]]');
    buf.writeln('        set h [ord::dbu_to_microns [\$m getHeight]]');
    buf.writeln('        puts "  \$type: \$n instances (\${w}um x \${h}um)"');
    buf.writeln('    }');
    buf.writeln();

    // Get die dimensions
    buf.writeln('    set die_rect [[ord::get_db_block] getDieArea]');
    buf.writeln('    set die_w [ord::dbu_to_microns [\$die_rect xMax]]');
    buf.writeln('    set die_h [ord::dbu_to_microns [\$die_rect yMax]]');
    buf.writeln();

    // Place fabric tiles (Tile, BramTile, DspBasicTile) in main grid
    // Each type uses its own height, packed into columns
    buf.writeln('    # Place fabric tiles in a grid');
    buf.writeln('    # Get Tile dimensions for the main grid pitch');
    buf.writeln('    set tile_w 0');
    buf.writeln('    set tile_h 0');
    buf.writeln('    if {[info exists macro_groups(Tile)]} {');
    buf.writeln(
      '        set tile_w [ord::dbu_to_microns [[[lindex \$macro_groups(Tile) 0] getMaster] getWidth]]',
    );
    buf.writeln(
      '        set tile_h [ord::dbu_to_microns [[[lindex \$macro_groups(Tile) 0] getMaster] getHeight]]',
    );
    buf.writeln('    }');
    buf.writeln('    set tile_px [expr {\$tile_w + \$halo}]');
    buf.writeln('    set tile_py [expr {\$tile_h + \$halo}]');
    buf.writeln();

    // Compute fabric grid columns from die width
    // Reserve right edge for non-fabric macros (Clock, SerDes, etc.)
    buf.writeln('    set edge_reserve 250');
    buf.writeln(
      '    set fabric_w [expr {\$die_w - 2 * \$margin - \$edge_reserve}]',
    );
    buf.writeln('    set fabric_cols [expr {int(\$fabric_w / \$tile_px)}]');
    buf.writeln('    if {\$fabric_cols < 1} { set fabric_cols 1 }');
    buf.writeln();

    // Place Tile, BramTile, DspBasicTile in fabric grid
    buf.writeln('    set cur_x \$margin');
    buf.writeln('    set cur_y \$margin');
    buf.writeln('    set col 0');
    buf.writeln('    set placed 0');
    buf.writeln();

    // Place fabric tiles column by column, matching the FPGA fabric layout.
    // BRAM columns at bramColumnInterval, DSP at dspColumnInterval,
    // remaining columns are LUT tiles. Each column type uses its own width.
    buf.writeln(
      '    # Build column-major placement matching FPGA fabric layout',
    );
    buf.writeln('    # Queues for each tile type');
    buf.writeln(
      '    set tile_q [expr {[info exists macro_groups(Tile)] ? \$macro_groups(Tile) : {}}]',
    );
    buf.writeln(
      '    set bram_q [expr {[info exists macro_groups(BramTile)] ? \$macro_groups(BramTile) : {}}]',
    );
    buf.writeln(
      '    set dsp_q [expr {[info exists macro_groups(DspBasicTile)] ? \$macro_groups(DspBasicTile) : {}}]',
    );
    buf.writeln();
    buf.writeln('    # Compute column types and x positions');
    buf.writeln('    set cur_x \$margin');
    buf.writeln('    set fabric_height ${height}');
    buf.writeln('    set col_x_list {}');
    buf.writeln('    set col_type_list {}');
    buf.writeln('    for {set c 0} {\$c < ${width}} {incr c} {');

    // Determine column type using same logic as Dart fabric
    buf.writeln('        set ctype "Tile"');
    if (bramColumnInterval > 0) {
      buf.writeln(
        '        if {$bramColumnInterval > 0 && '
        '(\$c - $bramColumnInterval) >= 0 && '
        '((\$c - $bramColumnInterval) % ($bramColumnInterval + 1)) == 0} {',
      );
      buf.writeln('            set ctype "BramTile"');
      buf.writeln('        }');
    }
    if (dspColumnInterval > 0) {
      buf.writeln(
        '        if {\$ctype eq "Tile" && $dspColumnInterval > 0 && '
        '(\$c - $dspColumnInterval) >= 0 && '
        '((\$c - $dspColumnInterval) % ($dspColumnInterval + 1)) == 0} {',
      );
      buf.writeln('            set ctype "DspBasicTile"');
      buf.writeln('        }');
    }

    buf.writeln('        lappend col_type_list \$ctype');
    buf.writeln('        lappend col_x_list \$cur_x');
    buf.writeln();
    buf.writeln('        # Advance x by this column type\'s width');
    buf.writeln('        switch \$ctype {');
    buf.writeln('            Tile { set cw \$tile_w }');
    buf.writeln('            BramTile {');
    buf.writeln('                if {[llength \$bram_q] > 0} {');
    buf.writeln(
      '                    set cw [ord::dbu_to_microns [[[lindex \$bram_q 0] getMaster] getWidth]]',
    );
    buf.writeln('                } else { set cw \$tile_w }');
    buf.writeln('            }');
    buf.writeln('            DspBasicTile {');
    buf.writeln('                if {[llength \$dsp_q] > 0} {');
    buf.writeln(
      '                    set cw [ord::dbu_to_microns [[[lindex \$dsp_q 0] getMaster] getWidth]]',
    );
    buf.writeln('                } else { set cw \$tile_w }');
    buf.writeln('            }');
    buf.writeln('        }');
    buf.writeln('        set cur_x [expr {\$cur_x + \$cw + \$halo}]');
    buf.writeln('    }');
    buf.writeln();

    // Now place tiles column by column, row by row
    buf.writeln('    # Place tiles in fabric grid');
    buf.writeln('    set placed 0');
    buf.writeln('    for {set c 0} {\$c < ${width}} {incr c} {');
    buf.writeln('        set ctype [lindex \$col_type_list \$c]');
    buf.writeln('        set cx [lindex \$col_x_list \$c]');
    buf.writeln('        for {set r 0} {\$r < \$fabric_height} {incr r} {');
    buf.writeln('            set cy [expr {\$margin + \$r * \$tile_py}]');
    buf.writeln('            switch \$ctype {');
    buf.writeln('                Tile {');
    buf.writeln('                    if {[llength \$tile_q] > 0} {');
    buf.writeln('                        set inst [lindex \$tile_q 0]');
    buf.writeln('                        set tile_q [lrange \$tile_q 1 end]');
    buf.writeln(
      '                        \$inst setLocation [ord::microns_to_dbu \$cx] [ord::microns_to_dbu \$cy]',
    );
    buf.writeln('                        \$inst setPlacementStatus FIRM');
    buf.writeln('                        incr placed');
    buf.writeln('                    }');
    buf.writeln('                }');
    buf.writeln('                BramTile {');
    buf.writeln('                    if {[llength \$bram_q] > 0} {');
    buf.writeln('                        set inst [lindex \$bram_q 0]');
    buf.writeln('                        set bram_q [lrange \$bram_q 1 end]');
    buf.writeln(
      '                        \$inst setLocation [ord::microns_to_dbu \$cx] [ord::microns_to_dbu \$cy]',
    );
    buf.writeln('                        \$inst setPlacementStatus FIRM');
    buf.writeln('                        incr placed');
    buf.writeln('                    }');
    buf.writeln('                }');
    buf.writeln('                DspBasicTile {');
    buf.writeln('                    if {[llength \$dsp_q] > 0} {');
    buf.writeln('                        set inst [lindex \$dsp_q 0]');
    buf.writeln('                        set dsp_q [lrange \$dsp_q 1 end]');
    buf.writeln(
      '                        \$inst setLocation [ord::microns_to_dbu \$cx] [ord::microns_to_dbu \$cy]',
    );
    buf.writeln('                        \$inst setPlacementStatus FIRM');
    buf.writeln('                        incr placed');
    buf.writeln('                    }');
    buf.writeln('                }');
    buf.writeln('            }');
    buf.writeln('        }');
    buf.writeln('    }');
    buf.writeln(
      '    set fabric_top [expr {\$margin + \$fabric_height * \$tile_py}]',
    );
    buf.writeln(
      '    puts "Placed \$placed fabric tiles in ${width} cols x \$fabric_height rows"',
    );
    buf.writeln();

    // Place IO tiles along the edges of the fabric grid
    buf.writeln('    # Place IO tiles along fabric perimeter');
    buf.writeln('    if {[info exists macro_groups(IOTile)]} {');
    buf.writeln(
      '        set io_h [ord::dbu_to_microns [[[lindex \$macro_groups(IOTile) 0] getMaster] getHeight]]',
    );
    buf.writeln(
      '        set io_w [ord::dbu_to_microns [[[lindex \$macro_groups(IOTile) 0] getMaster] getWidth]]',
    );
    buf.writeln('        set io_px [expr {\$io_w + \$halo}]');
    buf.writeln('        set io_idx 0');
    buf.writeln('        set io_count [llength \$macro_groups(IOTile)]');
    buf.writeln('        # Place along bottom edge');
    buf.writeln('        set io_y [expr {\$margin - \$io_h - \$halo}]');
    buf.writeln('        if {\$io_y < 0} { set io_y 0 }');
    buf.writeln(
      '        for {set i 0} {\$i < \$fabric_cols && \$io_idx < \$io_count} {incr i} {',
    );
    buf.writeln('            set io_x [expr {\$margin + \$i * \$tile_px}]');
    buf.writeln(
      '            [lindex \$macro_groups(IOTile) \$io_idx] setLocation [ord::microns_to_dbu \$io_x] [ord::microns_to_dbu \$io_y]',
    );
    buf.writeln(
      '            [lindex \$macro_groups(IOTile) \$io_idx] setPlacementStatus FIRM',
    );
    buf.writeln('            incr io_idx');
    buf.writeln('        }');
    buf.writeln('        # Place along top edge');
    buf.writeln('        set io_y \$fabric_top');
    buf.writeln(
      '        for {set i 0} {\$i < \$fabric_cols && \$io_idx < \$io_count} {incr i} {',
    );
    buf.writeln('            set io_x [expr {\$margin + \$i * \$tile_px}]');
    buf.writeln(
      '            [lindex \$macro_groups(IOTile) \$io_idx] setLocation [ord::microns_to_dbu \$io_x] [ord::microns_to_dbu \$io_y]',
    );
    buf.writeln(
      '            [lindex \$macro_groups(IOTile) \$io_idx] setPlacementStatus FIRM',
    );
    buf.writeln('            incr io_idx');
    buf.writeln('        }');
    buf.writeln('        # Place remaining IO tiles along right edge');
    buf.writeln(
      '        set io_x [expr {\$margin + \$fabric_cols * \$tile_px}]',
    );
    buf.writeln('        set io_row 0');
    buf.writeln('        while {\$io_idx < \$io_count} {');
    buf.writeln(
      '            set io_y [expr {\$margin + \$io_row * (\$io_h + \$halo)}]',
    );
    buf.writeln(
      '            [lindex \$macro_groups(IOTile) \$io_idx] setLocation [ord::microns_to_dbu \$io_x] [ord::microns_to_dbu \$io_y]',
    );
    buf.writeln(
      '            [lindex \$macro_groups(IOTile) \$io_idx] setPlacementStatus FIRM',
    );
    buf.writeln('            incr io_idx');
    buf.writeln('            incr io_row');
    buf.writeln('        }');
    buf.writeln('        puts "Placed \$io_count IO tiles around perimeter"');
    buf.writeln('    }');
    buf.writeln();

    // Place edge macros (Clock, SerDes, FabricConfigLoader) along right edge
    // Place SerDes above the fabric grid
    buf.writeln('    # Place SerDes tiles above the fabric grid');
    buf.writeln('    if {[info exists macro_groups(SerDesTile)]} {');
    buf.writeln('        set serdes_x \$margin');
    buf.writeln('        set serdes_y [expr {\$fabric_top + \$halo}]');
    buf.writeln('        foreach inst \$macro_groups(SerDesTile) {');
    buf.writeln(
      '            set mw [ord::dbu_to_microns [[\$inst getMaster] getWidth]]',
    );
    buf.writeln(
      '            set mh [ord::dbu_to_microns [[\$inst getMaster] getHeight]]',
    );
    buf.writeln(
      '            \$inst setLocation [ord::microns_to_dbu \$serdes_x] [ord::microns_to_dbu \$serdes_y]',
    );
    buf.writeln('            \$inst setPlacementStatus FIRM');
    buf.writeln(
      '            puts "Placed SerDesTile at \${serdes_x}um x \${serdes_y}um"',
    );
    buf.writeln('            set serdes_x [expr {\$serdes_x + \$mw + \$halo}]');
    buf.writeln('        }');
    buf.writeln('    }');
    buf.writeln();

    // Place Clock and ConfigLoader on the right edge
    buf.writeln('    # Place Clock and ConfigLoader on right edge');
    buf.writeln('    set edge_x [expr {\$die_w - \$margin}]');
    buf.writeln('    set edge_y \$margin');
    buf.writeln('    foreach type {ClockTile FabricConfigLoader JtagTap} {');
    buf.writeln('        if {[info exists macro_groups(\$type)]} {');
    buf.writeln('            foreach inst \$macro_groups(\$type) {');
    buf.writeln(
      '                set mw [ord::dbu_to_microns [[\$inst getMaster] getWidth]]',
    );
    buf.writeln(
      '                set mh [ord::dbu_to_microns [[\$inst getMaster] getHeight]]',
    );
    buf.writeln('                set x [expr {\$edge_x - \$mw}]');
    buf.writeln(
      '                \$inst setLocation [ord::microns_to_dbu \$x] [ord::microns_to_dbu \$edge_y]',
    );
    buf.writeln('                \$inst setPlacementStatus FIRM');
    buf.writeln('                set edge_y [expr {\$edge_y + \$mh + \$halo}]');
    buf.writeln(
      '                puts "Placed \$type at \${x}um x [expr {\$edge_y - \$mh - \$halo}]um"',
    );
    buf.writeln('            }');
    buf.writeln('        }');
    buf.writeln('    }');
    buf.writeln();

    buf.writeln('    # Cut standard cell rows around placed macros');
    buf.writeln('    cut_rows');
    buf.writeln('}');
    buf.writeln();

    // Then place remaining standard cells (glue logic)
    buf.writeln('# Place remaining standard cells');
    buf.writeln(
      'if {![info exists PLACEMENT_DENSITY]} { set PLACEMENT_DENSITY 0.1 }',
    );
    buf.writeln('global_placement -density \$PLACEMENT_DENSITY');
    buf.writeln('detailed_placement');
    buf.writeln();
  }

  void _writeCts(StringBuffer buf) {
    buf.writeln(_section('Clock tree synthesis'));

    buf.writeln('estimate_parasitics -placement');
    buf.writeln();
    buf.writeln('set cts_bufs {}');
    buf.writeln('foreach sz {2 4 8 16} {');
    buf.writeln('    set cell_name \${CELL_LIB}__clkbuf_\$sz');
    buf.writeln('    lappend cts_bufs \$cell_name');
    buf.writeln('}');
    buf.writeln('clock_tree_synthesis -buf_list \$cts_bufs');
    buf.writeln();
    buf.writeln('detailed_placement');
    buf.writeln();
  }

  void _writeRouting(StringBuffer buf) {
    buf.writeln(_section('Routing'));

    // Use Metal2+ for top-level routing. Metal1 is used internally
    // by standard cells and causes PDK-inherent M1.2a violations.
    buf.writeln('set all_route_layers [get_routing_layers]');
    buf.writeln('set bot_route ""');
    buf.writeln('set top_route ""');
    buf.writeln('foreach layer \$all_route_layers {');
    buf.writeln(
      '    if {![catch {set tl '
      '[[[ord::get_db] getTech] findLayer \$layer]}]} {',
    );
    buf.writeln('        if {\$tl ne "NULL"} {');
    buf.writeln('            if {\$bot_route eq ""} {');
    buf.writeln(
      '                # Skip Metal1: use second routing layer as bottom',
    );
    buf.writeln('            } elseif {\$bot_route eq "SKIP"} {');
    buf.writeln('                set bot_route \$layer');
    buf.writeln('            }');
    buf.writeln('            if {\$bot_route eq ""} { set bot_route "SKIP" }');
    buf.writeln('            set top_route \$layer');
    buf.writeln('        }');
    buf.writeln('    }');
    buf.writeln('}');
    buf.writeln(
      'if {\$bot_route eq "" || \$bot_route eq "SKIP"} { set bot_route Metal2 }',
    );
    buf.writeln('if {\$top_route eq ""} { set top_route Metal2 }');
    buf.writeln('puts "Routing layers: \$bot_route-\$top_route"');
    buf.writeln('set_routing_layers -signal \$bot_route-\$top_route');
    buf.writeln('# Apply per-layer routing capacity adjustments');
    buf.writeln('if {[array exists LAYER_ADJ]} {');
    buf.writeln('    foreach layer [array names LAYER_ADJ] {');
    buf.writeln(
      '        set_global_routing_layer_adjustment \$layer \$LAYER_ADJ(\$layer)',
    );
    buf.writeln('    }');
    buf.writeln('}');
    buf.writeln('global_route -allow_congestion');
    buf.writeln();
    buf.writeln('# Save global-routed DEF (guaranteed output)');
    buf.writeln('write_def \${DEVICE_NAME}_grouted.def');
    buf.writeln();
    buf.writeln(
      '# Detailed route may fail on offgrid pin shapes from place_pins.',
    );
    buf.writeln('# If it fails, we still have the global-routed DEF.');
    buf.writeln(
      'if {![info exists DROUTE_END_ITER]} { set DROUTE_END_ITER 32 }',
    );
    buf.writeln(
      'detailed_route -droute_end_iter \$DROUTE_END_ITER '
      '-or_seed 42 -or_k 3 '
      '-output_drc \${DEVICE_NAME}_drc.rpt',
    );
    buf.writeln();

    buf.writeln();
  }

  void _writeDensityFill(StringBuffer buf) {
    buf.writeln(_section('Density fill'));

    buf.writeln(r'density_fill -rules $FILL_CONFIG');
    buf.writeln();
  }

  void _writeReports(StringBuffer buf) {
    buf.writeln(_section('Reports'));

    buf.writeln('report_checks -path_delay min_max > timing.rpt');
    buf.writeln('report_design_area > area.rpt');
    buf.writeln('report_power > power.rpt');
    buf.writeln();
  }

  void _writeOutputs(StringBuffer buf) {
    buf.writeln(_section('Write outputs'));

    buf.writeln('write_def \${DEVICE_NAME}_final.def');
    buf.writeln('write_verilog \${DEVICE_NAME}_final.v');
    buf.writeln();
  }

  void _writeLayerDetection(StringBuffer buf) {
    // Detect pin layers, skipping Metal1 which is reserved for
    // internal macro/standard cell routing.
    buf.writeln('set hor_layer ""');
    buf.writeln('set ver_layer ""');
    buf.writeln('set skip_first_hor 1');
    buf.writeln('foreach layer [get_routing_layers] {');
    buf.writeln(
      '    if {![catch {set tl '
      '[[[ord::get_db] getTech] findLayer \$layer]}]} {',
    );
    buf.writeln('        if {\$tl ne "NULL"} {');
    buf.writeln('            set dir [\$tl getDirection]');
    buf.writeln('            if {\$dir eq "HORIZONTAL" && \$skip_first_hor} {');
    buf.writeln('                # Skip Metal1 (first horizontal layer)');
    buf.writeln('                set skip_first_hor 0');
    buf.writeln(
      '            } elseif {\$dir eq "HORIZONTAL" && \$hor_layer eq ""} {',
    );
    buf.writeln('                set hor_layer \$layer');
    buf.writeln('            }');
    buf.writeln('            if {\$dir eq "VERTICAL" && \$ver_layer eq ""} {');
    buf.writeln('                set ver_layer \$layer');
    buf.writeln('            }');
    buf.writeln('        }');
    buf.writeln('    }');
    buf.writeln('}');
    buf.writeln('if {\$hor_layer eq ""} { set hor_layer Metal3 }');
    buf.writeln('if {\$ver_layer eq ""} { set ver_layer Metal2 }');
    buf.writeln('puts "Pin layers: hor=\$hor_layer ver=\$ver_layer"');
  }

  String _section(String title) =>
      '# ================================================================\n'
      '# $title\n'
      '# ================================================================\n';
}
