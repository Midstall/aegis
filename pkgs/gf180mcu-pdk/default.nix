{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
}:

let
  # wafer.space's assembled GF180MCU PDK (gf180mcuD variant)
  # Includes standard cells, DRC/LVS rule decks, I/O cells, and tech files
  pdk-src = fetchFromGitHub {
    owner = "wafer-space";
    repo = "gf180mcu";
    rev = "1.8.0";
    hash = "sha256-+LYKskX0Ym2c9SmZOyiTZblAu1OL0CmM8pBGBVhI7MM=";
  };

  # wafer.space's gf180mcuD project template ships the two physical-only
  # macros every shuttle tape-out must instantiate: the chip ID block
  # (gf180mcu_ws_ip__id) and the wafer.space logo (gf180mcu_ws_ip__logo).
  # We pull them straight from upstream rather than vendoring so we
  # track the same revision wafer.space's precheck expects.
  projectTemplate-src = fetchFromGitHub {
    owner = "wafer-space";
    repo = "gf180mcu-project-template";
    rev = "8bd0f6ff28947bf222c5288343f8f3ee1fc04632";
    hash = "sha256-rU7oKdpOLYQylpZTxCZ8HgfP2/dwMlaOw9Gh0U8XpeM=";
  };

  cellLib = "gf180mcu_fd_sc_mcu7t5v0";
  ioLib = "gf180mcu_fd_io";
  pdkRoot = "${pdk-src}/gf180mcuD";
  scRoot = "${pdkRoot}/libs.ref/${cellLib}";
  ioRoot = "${pdkRoot}/libs.ref/${ioLib}";
in
stdenvNoCC.mkDerivation {
  pname = "gf180mcu-pdk";
  version = "1.8.0";

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    local sc=$out/share/pdk/gf180mcu/libs.ref/${cellLib}
    mkdir -p $sc/{lib,lef,gds,verilog,spice}

    # Pre-merged liberty timing files
    cp ${scRoot}/lib/*.lib $sc/lib/

    # Tech LEF files (copy .tlef as both .tlef and .lef for compatibility)
    for f in ${scRoot}/techlef/*.tlef; do
      cp "$f" $sc/lef/
      cp "$f" "$sc/lef/$(basename "$f" .tlef).lef"
    done

    # Cell LEF, GDS, Verilog, SPICE
    for f in ${scRoot}/lef/*.lef; do
      if [[ "$(basename "$f")" != *"tech"* ]]; then
        cp -n "$f" $sc/lef/
      fi
    done
    cp ${scRoot}/gds/*.gds $sc/gds/
    cp ${scRoot}/verilog/*.v $sc/verilog/
    cp ${scRoot}/spice/*.spice $sc/spice/

    # I/O pad library: bidirectional pads, input pads, power pads,
    # padring fillers, and the corner cell. Used to build the chip's
    # padring during top-level integration.
    local io=$out/share/pdk/gf180mcu/libs.ref/${ioLib}
    mkdir -p $io/{lib,lef,gds,verilog,spice}
    cp ${ioRoot}/lib/*.lib $io/lib/ 2>/dev/null || true
    cp ${ioRoot}/lef/*.lef $io/lef/ 2>/dev/null || true
    cp ${ioRoot}/gds/*.gds $io/gds/ 2>/dev/null || true
    cp ${ioRoot}/verilog/*.v $io/verilog/ 2>/dev/null || true
    cp ${ioRoot}/spice/*.spice $io/spice/ 2>/dev/null || true

    # Physical verification rule decks (DRC/LVS) from wafer-space fork
    # Maintain path structure: pv/klayout/drc/, pv/klayout/lvs/
    mkdir -p $out/share/pdk/gf180mcu/pv/klayout
    cp -r ${pdkRoot}/libs.tech/klayout/tech/* $out/share/pdk/gf180mcu/pv/klayout/

    runHook postInstall
  '';

  passthru = {
    inherit cellLib ioLib;
    siteName = "GF018hv5v_mcu_sc7";
    pdkName = "gf180mcu";
    pdkPath = "share/pdk/gf180mcu";
    techLef = "${cellLib}__nom.tlef";
    # I/O pad-ring cells used to build the chip perimeter:
    #   - cornerCell:      355x355 corner block (rotate/mirror at the 4 die corners)
    #   - signalPad:       general-purpose bidirectional 3.3V signal pad (75x350)
    #   - inputPad:        Schmitt-trigger input pad
    #   - powerPad:        VDD pad
    #   - groundPad:       VSS pad
    #   - fillCells:       pad-ring fillers, largest first
    padCells = {
      cornerCell = "gf180mcu_fd_io__cor";
      signalPad = "gf180mcu_fd_io__bi_t";
      inputPad = "gf180mcu_fd_io__in_s";
      powerPad = "gf180mcu_fd_io__dvdd";
      groundPad = "gf180mcu_fd_io__dvss";
      fillCells = [
        "gf180mcu_fd_io__fill10"
        "gf180mcu_fd_io__fill5"
        "gf180mcu_fd_io__fill1"
        "gf180mcu_fd_io__fillnc"
      ];
      padHeight = 350; # um, perpendicular to die edge
      padWidth = 75; # um, along die edge for signal pads
      cornerSize = 355; # um
    };
    # Per-layer routing capacity adjustments (0.0 = full, 1.0 = blocked).
    # Penalize the lower routing layers so the global router spreads
    # signal nets onto Metal4/Metal5 instead of saturating Metal2/Metal3.
    tileLayerAdjustments = {
      Metal2 = 0.5;
      Metal3 = 0.3;
    };
    topLayerAdjustments = {
      Metal2 = 0.6;
      Metal3 = 0.4;
    };
    # Power delivery network configuration
    pdn = {
      # Standard cell rail
      railLayer = "Metal1";
      railWidth = 0.6;
      # Vertical Metal4 power straps. Pitch 50 yields a Tile column
      # advance of 150um (115.36um Tile + halo, snapped up to next
      # multiple of pitch). 23 columns at 150um + BRAM/DSP narrower
      # advances + the last Tile's footprint fits within the 3180um
      # core (1x1 slot user area 3880um minus 350um padring inset
      # each side). Pitch 56 would site-align macros but pushes the
      # column advance to 168um and the array overflows the core.
      verticalLayer = "Metal4";
      verticalWidth = 1.6;
      verticalPitch = 50;
      verticalOffset = 10;
      verticalSpacing = 0.28;
      # Horizontal Metal5 power straps. Pitch <= half the shortest tile
      # height (102um) so every macro is crossed by at least one VDD
      # and one VSS strap pair, per the hierarchical-macro PDN spec.
      horizontalLayer = "Metal5";
      horizontalWidth = 1.6;
      horizontalPitch = 50;
      horizontalOffset = 10;
      horizontalSpacing = 0.46;
      halo = 5;
    };
    commentLayer = {
      layer = 236;
      datatype = 0;
    };
    # LibreLane Chip-flow knobs that depend on the PDK technology.
    # The custom OpenROAD flow uses the higher metals (M4/M5) per the
    # `pdn` block above, but LibreLane's stock Chip flow targets the
    # lower metals (M2/M3) for the core PDN, so these settings live
    # alongside rather than replacing the custom-flow pdn block.
    librelane = {
      pdkRoot = pdk-src;
      pdkName = "gf180mcuD";
      # Physical-only macros wafer.space requires every shuttle
      # tape-out to instantiate (chip ID block + vendor logo). Each
      # subdirectory ships its own gds/, lef/, lib/, and vh/ stub.
      fabRequiredIp = "${projectTemplate-src}/ip";
      # Pad cells instantiated by the chip_top template. The split
      # between fd_io (foundry I/O lib) and ws_io (wafer.space's
      # customized power pads) follows wafer.space's project
      # template, which uses the foundry signal pads but the
      # wafer.space-customized power pads.
      padCells = {
        # 24mA bidirectional pad with full control set (CS/SL/IE/PU/PD).
        bidirCell = "gf180mcu_fd_io__bi_24t";
        # CMOS input receiver, used for general signal pads.
        inputCmosCell = "gf180mcu_fd_io__in_c";
        # Schmitt-trigger input receiver, used for the clock pad.
        inputSchmittCell = "gf180mcu_fd_io__in_s";
        # 5 V analog passthrough pad.
        analogCell = "gf180mcu_fd_io__asig_5p0";
        # wafer.space power / ground pads (different from the fd_io
        # equivalents - these route DVDD/DVSS through the seal ring).
        powerPadCell = "gf180mcu_ws_io__dvdd";
        groundPadCell = "gf180mcu_ws_io__dvss";
      };
      # Cells whose floating pins must not error LVS / synth. Add
      # only cells safe to leave disconnected (bidir control pins, no
      # signal-pin pad cells, etc.). Input pad cells (in_c, in_s) are
      # NOT here: if added, LibreLane drops their global power-net
      # bindings and add_global_connections fails on DVDD/VSS,
      # breaking the chip-level PDN connect step.
      ignoreDisconnectedModules = [
        "gf180mcu_fd_io__bi_24t"
      ];
      # Foundry cells that need flattening for DRC parity with the
      # wafer.space precheck.
      magicGdsFlatglob = [
        "*_CDNS_*"
        "*$$*"
        "M1_N*"
        "M1_P*"
        "M2_M1*"
        "M3_M2*"
        "nmos_5p0*"
        "nmos_1p2*"
        "pmos_5p0*"
        "pmos_1p2*"
        "via1_*"
        "ypass_gate*"
        "G_ring_*"
        "dcap_103*"
        "din_*"
        "mux821_*"
        "rdummy_*"
        "pmoscap_*"
        "xdec_*"
        "ypredec*"
        "xpredec*"
        "prexdec_*"
        "xdec8_*"
        "xdec16_*"
        "xdec32_*"
        "sa_*"
      ];
      # gf180mcu's Metal2 cannot meet the minimum density without
      # letting the filler walk over active metal. The wafer.space
      # precheck moves dummy metal into active metal afterward.
      klayoutFillerOptions = {
        Metal2_ignore_active = true;
      };
      magicExtUnique = "notopports";
      # Magic DRC is informational; KLayout DRC is the gating check.
      errorOnMagicDrc = false;
      # Core PDN (LibreLane stock Chip flow targets M2/M3).
      pdn = {
        coreVerticalLayer = "Metal2";
        coreHorizontalLayer = "Metal3";
        vWidth = 5;
        hWidth = 5;
        vSpacing = 1;
        hSpacing = 1;
        vPitch = 75;
        hPitch = 75;
        coreRing = {
          enable = true;
          vWidth = 25;
          hWidth = 25;
          connectToPads = true;
          enablePins = false;
        };
        macroHorizontalHalo = 10;
        macroVerticalHalo = 10;
        horizontalHalo = 5;
        verticalHalo = 5;
      };
      # Hold-violation slack margins (template defaults that work for gf180mcu).
      resizer = {
        plHoldSlackMargin = 0.35;
        grtHoldSlackMargin = 0.3;
      };
      # Antenna repair iteration budget.
      antennaRepair = {
        iters = 10;
        margin = 10;
      };
      # LibreLane Chip-flow slot definitions. Each entry describes the
      # die / core box and the padring placement order for that slot.
      # Pad instance names match the chip_top template's generate
      # blocks (dvdd_pads[i].pad, bidir[i].pad, inputs[i].pad,
      # analog[i].pad) plus the standalone clk_pad / rst_n_pad cells.
      # The escape in `\[N\]` is what LibreLane's regex matcher needs.
      # Sourced from wafer.space's gf180mcu-project-template.
      slots."1x1" = {
        dieArea = [
          0
          0
          3932
          5122
        ];
        coreArea = [
          442
          442
          3490
          4680
        ];
        verilogDefines = [ "SLOT_1X1" ];
        pads = {
          south = [
            "clk_pad"
            "rst_n_pad"
            "bidir\\[0\\].pad"
            "bidir\\[1\\].pad"
            "bidir\\[2\\].pad"
            "bidir\\[3\\].pad"
            "bidir\\[4\\].pad"
            "bidir\\[5\\].pad"
            "dvss_pads\\[0\\].pad"
            "bidir\\[6\\].pad"
            "bidir\\[7\\].pad"
            "bidir\\[8\\].pad"
            "bidir\\[9\\].pad"
            "bidir\\[10\\].pad"
            "bidir\\[11\\].pad"
            "bidir\\[12\\].pad"
            "bidir\\[13\\].pad"
          ];
          east = [
            "dvdd_pads\\[0\\].pad"
            "dvss_pads\\[1\\].pad"
            "bidir\\[14\\].pad"
            "bidir\\[15\\].pad"
            "bidir\\[16\\].pad"
            "bidir\\[17\\].pad"
            "bidir\\[18\\].pad"
            "bidir\\[19\\].pad"
            "dvdd_pads\\[1\\].pad"
            "dvss_pads\\[2\\].pad"
            "bidir\\[20\\].pad"
            "bidir\\[21\\].pad"
            "bidir\\[22\\].pad"
            "bidir\\[23\\].pad"
            "bidir\\[24\\].pad"
            "bidir\\[25\\].pad"
            "dvss_pads\\[3\\].pad"
            "dvdd_pads\\[2\\].pad"
            "dvss_pads\\[4\\].pad"
            "dvdd_pads\\[3\\].pad"
          ];
          north = [
            "analog\\[1\\].pad"
            "analog\\[0\\].pad"
            "bidir\\[39\\].pad"
            "bidir\\[38\\].pad"
            "bidir\\[37\\].pad"
            "bidir\\[36\\].pad"
            "bidir\\[35\\].pad"
            "bidir\\[34\\].pad"
            "dvss_pads\\[5\\].pad"
            "bidir\\[33\\].pad"
            "bidir\\[32\\].pad"
            "bidir\\[31\\].pad"
            "bidir\\[30\\].pad"
            "bidir\\[29\\].pad"
            "bidir\\[28\\].pad"
            "bidir\\[27\\].pad"
            "bidir\\[26\\].pad"
          ];
          west = [
            "dvdd_pads\\[7\\].pad"
            "dvss_pads\\[9\\].pad"
            "dvdd_pads\\[6\\].pad"
            "dvss_pads\\[8\\].pad"
            "inputs\\[11\\].pad"
            "inputs\\[10\\].pad"
            "inputs\\[9\\].pad"
            "inputs\\[8\\].pad"
            "inputs\\[7\\].pad"
            "inputs\\[6\\].pad"
            "dvdd_pads\\[5\\].pad"
            "dvss_pads\\[7\\].pad"
            "inputs\\[5\\].pad"
            "inputs\\[4\\].pad"
            "inputs\\[3\\].pad"
            "inputs\\[2\\].pad"
            "dvdd_pads\\[4\\].pad"
            "dvss_pads\\[6\\].pad"
            "inputs\\[1\\].pad"
            "inputs\\[0\\].pad"
          ];
        };
      };
    };
    # Fab submission requirements (wafer.space gf180mcuD)
    fab = {
      # Available die slot sizes (um) including seal ring
      slots = {
        "1x1" = {
          w = 3932;
          h = 5122;
        };
        "0p5x1" = {
          w = 1936;
          h = 5122;
        };
        "1x0p5" = {
          w = 3932;
          h = 2531;
        };
        "0p5x0p5" = {
          w = 1936;
          h = 2531;
        };
      };
      # Seal ring around the die
      sealRing = {
        layer = 167;
        datatype = 5;
        width = 26; # um
      };
      # Required ID cell for fab tracking
      idCell = "gf180mcu_ws_ip__id";
      # Layers that must NOT have shapes (5LM only)
      forbiddenLayers = [
        {
          layer = 82;
          datatype = 0;
          name = "Via5";
        }
        {
          layer = 53;
          datatype = 0;
          name = "MetalTop";
        }
      ];
      # Required DBU for GDS output
      dbu = 0.001;
      # DRC variant for fab precheck
      drcVariant = "D";
    };
    # DRC rule tables relevant to our design (skip analog/specialty decks)
    drcTables = [
      "metal1"
      "metal2"
      "metal3"
      "metal4"
      "metal5"
      "metaltop"
      "via1"
      "via2"
      "via3"
      "via4"
      "contact"
      "geom"
      "antenna"
    ];
    # LEF layer name -> GDS layer/datatype mapping for KLayout DEF->GDS
    lefGdsLayers = {
      Poly2 = {
        layer = 30;
        datatype = 0;
      };
      CON = {
        layer = 33;
        datatype = 0;
      };
      Metal1 = {
        layer = 34;
        datatype = 0;
      };
      Via1 = {
        layer = 35;
        datatype = 0;
      };
      Metal2 = {
        layer = 36;
        datatype = 0;
      };
      Via2 = {
        layer = 38;
        datatype = 0;
      };
      Metal3 = {
        layer = 42;
        datatype = 0;
      };
      Via3 = {
        layer = 40;
        datatype = 0;
      };
      Metal4 = {
        layer = 46;
        datatype = 0;
      };
      Via4 = {
        layer = 41;
        datatype = 0;
      };
      Metal5 = {
        layer = 81;
        datatype = 0;
      };
    };
  };

  meta = {
    description = "GlobalFoundries GF180MCU 180nm PDK (wafer.space gf180mcuD variant)";
    homepage = "https://github.com/wafer-space/gf180mcu";
    license = lib.licenses.asl20;
    platforms = lib.platforms.all;
  };
}
