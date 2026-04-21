{
  lib,
  stdenv,
  mkShell,
  yosys,
  openroad,
  xschem,
  klayout,
  magic-vlsi,
  ngspice,
  surfer,
  aegis-ip,
}:

lib.extendMkDerivation {
  constructDrv = stdenv.mkDerivation;

  excludeDrvArgNames = [
    "pdk"
    "cellLib"
    "clockPeriodNs"
    "fabSlot"
    "dieWidthUm"
    "dieHeightUm"
    "coreUtilization"
    "macroHaloUm"
    "gridMarginUm"
    "tileUtilization"
    "tileDieSizes"
    "tilePlacementDensities"
    "topPlacementDensity"
    "topDetailedRouteIter"
    "tileLayerAdjustments"
    "topLayerAdjustments"
  ];

  extendDrvArgs =
    finalAttrs:
    {
      name ? "aegis-tapeout-${aegis-ip.deviceName}",
      pdk,
      cellLib ? pdk.cellLib,
      clockPeriodNs ? 20,
      fabSlot ? null,
      dieWidthUm ? null,
      dieHeightUm ? null,
      coreUtilization ? 0.5,
      macroHaloUm ? 20,
      gridMarginUm ? 20,
      tileUtilization ? 0.85,
      tileDieSizes ? { },
      tilePlacementDensities ? { },
      topPlacementDensity ? 0.1,
      topDetailedRouteIter ? 8,
      tileLayerAdjustments ? pdk.tileLayerAdjustments or { },
      topLayerAdjustments ? pdk.topLayerAdjustments or { },
      ...
    }@args:

    assert lib.assertMsg (
      clockPeriodNs > 0
    ) "aegis-tapeout: clockPeriodNs must be > 0, got ${toString clockPeriodNs}";
    assert lib.assertMsg (
      coreUtilization > 0.0 && coreUtilization <= 1.0
    ) "aegis-tapeout: coreUtilization must be in (0, 1], got ${toString coreUtilization}";

    let
      inherit (aegis-ip) deviceName;
      pdkPath = "${pdk}/${pdk.pdkPath}";
      libsRef = "${pdkPath}/libs.ref/${cellLib}";

      # Resolve die dimensions from fab slot or explicit values
      fab = pdk.fab or { };
      slotDims =
        if fabSlot != null && fab ? slots && fab.slots ? ${fabSlot} then fab.slots.${fabSlot} else null;
      sealRingWidth = if fab ? sealRing then fab.sealRing.width or 0 else 0;
      effectiveDieWidthUm =
        if dieWidthUm != null then
          dieWidthUm
        else if slotDims != null then
          slotDims.w
        else
          null;
      effectiveDieHeightUm =
        if dieHeightUm != null then
          dieHeightUm
        else if slotDims != null then
          slotDims.h
        else
          null;
      # User area is die minus seal ring on each side
      userWidthUm = if effectiveDieWidthUm != null then effectiveDieWidthUm - 2 * sealRingWidth else null;
      userHeightUm =
        if effectiveDieHeightUm != null then effectiveDieHeightUm - 2 * sealRingWidth else null;

      # Generate KLayout LEF/DEF layer map from PDK layer definitions
      lefGdsMapFile = builtins.toFile "lef-gds.map" (
        lib.concatStringsSep "\n" (
          lib.mapAttrsToList (name: val: "${name} ALL ${toString val.layer} ${toString val.datatype}") (
            pdk.lefGdsLayers or { }
          )
        )
      );

      # Default tile die sizes per PDK
      defaultTileDieSizes =
        {
          gf180mcu = {
            Tile = {
              w = 165;
              h = 102;
            };
            IOTile = {
              w = 105;
              h = 30;
            };
            ClockTile = {
              w = 245;
              h = 155;
            };
            BramTile = {
              w = 27;
              h = 45;
            };
            DspBasicTile = {
              w = 71;
              h = 42;
            };
            FabricConfigLoader = {
              w = 30;
              h = 12;
            };
            SerDesTile = {
              w = 950;
              h = 160;
            };
            JtagTap = {
              w = 45;
              h = 30;
            };
          };
          sky130 = {
            # TODO: characterize tile sizes on sky130
            Tile = {
              w = 100;
              h = 60;
            };
            IOTile = {
              w = 70;
              h = 20;
            };
            ClockTile = {
              w = 150;
              h = 90;
            };
            BramTile = {
              w = 18;
              h = 30;
            };
            DspBasicTile = {
              w = 45;
              h = 27;
            };
            FabricConfigLoader = {
              w = 20;
              h = 8;
            };
            SerDesTile = {
              w = 550;
              h = 85;
            };
            JtagTap = {
              w = 30;
              h = 20;
            };
          };
        }
        .${pdk.pdkName} or { };

      # Merge user overrides on top of defaults
      effectiveTileDieSizes = defaultTileDieSizes // tileDieSizes;

      # Find PDK files at eval time
      libFile = "${libsRef}/lib";
      techLefDir = "${libsRef}/lef";

      mkTileMacro =
        tileModule:
        stdenv.mkDerivation {
          name = "aegis-tile-${lib.toLower tileModule}-${deviceName}";

          dontUnpack = true;
          dontConfigure = true;

          nativeBuildInputs = [
            yosys
            openroad
            klayout
          ];

          buildPhase = ''
            runHook preBuild

            # Find PDK files
            LIB_FILE=$(find ${libFile} -name '*tt*' -name '*.lib' -print -quit)
            if [ -z "$LIB_FILE" ]; then
              LIB_FILE=$(find ${libFile} -name '*.lib' -print -quit)
            fi
            TECH_LEF="${techLefDir}/${pdk.techLef}"

            # Skip if this tile type doesn't exist in the device
            if [ ! -f "${aegis-ip}/${deviceName}-yosys-${tileModule}.tcl" ]; then
              echo "Skipping ${tileModule} (not present in device)"
              mkdir -p $out
              exit 0
            fi

            echo "=== Synthesizing ${tileModule} ==="
            cat > synth.tcl << EOF
            set SV_FILE "${aegis-ip}/${deviceName}.sv"
            set LIB_FILE "$LIB_FILE"
            set CELL_LIB "${cellLib}"
            set DEVICE_NAME "${deviceName}"
            source ${aegis-ip}/${deviceName}-yosys-${tileModule}.tcl
            EOF
            yosys -c synth.tcl 2>&1 | tee yosys.log

            echo "=== PnR ${tileModule} macro ==="
            cat > pnr.tcl << EOF
            set LIB_FILE "$LIB_FILE"
            set TECH_LEF "$TECH_LEF"
            set CELL_LEF_DIR "${techLefDir}"
            set DEVICE_NAME "${deviceName}"
            set SITE_NAME "${pdk.siteName}"
            set CELL_LIB "${cellLib}"
            set CLK_PERIOD ${toString clockPeriodNs}
            set TILE_UTIL ${toString tileUtilization}
            ${lib.optionalString (builtins.hasAttr tileModule effectiveTileDieSizes) ''
              set TILE_DIE_W ${toString effectiveTileDieSizes.${tileModule}.w}
              set TILE_DIE_H ${toString effectiveTileDieSizes.${tileModule}.h}
            ''}
            ${lib.optionalString (builtins.hasAttr tileModule tilePlacementDensities) ''
              set TILE_PLACEMENT_DENSITY ${toString tilePlacementDensities.${tileModule}}
            ''}
            ${lib.concatStringsSep "\n" (
              lib.mapAttrsToList (layer: adj: "set LAYER_ADJ(${layer}) ${toString adj}") tileLayerAdjustments
            )}
            source ${aegis-ip}/${deviceName}-openroad-${tileModule}.tcl
            EOF
            openroad -threads $NIX_BUILD_CORES -exit pnr.tcl 2>&1 | tee openroad.log

            echo "=== GDS for ${tileModule} ==="
            if [ -f "${deviceName}_${tileModule}_final.def" ]; then
              CELL_GDS_DIR="${libsRef}/gds" \
              LEF_DIR="${techLefDir}" \
              TECH_LEF="$TECH_LEF" \
              DEF_FILE="${deviceName}_${tileModule}_final.def" \
              OUT_GDS="${deviceName}_${tileModule}_final.gds" \
              LAYER_MAP="${lefGdsMapFile}" \
              QT_QPA_PLATFORM=offscreen \
              klayout -b -r ${./scripts/def2gds.py} 2>&1 | tee klayout.log || true
            fi

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out
            cp ${deviceName}_${tileModule}_synth.v $out/ 2>/dev/null || true
            cp ${deviceName}_${tileModule}_final.def $out/ 2>/dev/null || true
            cp ${deviceName}_${tileModule}_final.v $out/ 2>/dev/null || true
            cp ${deviceName}_${tileModule}_final.gds $out/ 2>/dev/null || true
            cp ${deviceName}_${tileModule}.lef $out/ 2>/dev/null || true
            cp ${deviceName}_${tileModule}.lib $out/ 2>/dev/null || true
            cp ${tileModule}_timing.rpt $out/ 2>/dev/null || true
            cp ${tileModule}_area.rpt $out/ 2>/dev/null || true
            cp yosys.log $out/ 2>/dev/null || true
            cp openroad.log $out/ 2>/dev/null || true
            runHook postInstall
          '';
        };

      # Build all tile macros
      tileMacros = builtins.listToAttrs (
        map
          (mod: {
            name = mod;
            value = mkTileMacro mod;
          })
          [
            "Tile"
            "BramTile"
            "DspBasicTile"
            "ClockTile"
            "IOTile"
            "SerDesTile"
            "FabricConfigLoader"
            "JtagTap"
          ]
      );

      topSynth = stdenv.mkDerivation {
        name = "aegis-top-synth-${deviceName}";

        dontUnpack = true;
        dontConfigure = true;

        nativeBuildInputs = [ yosys ];

        buildPhase = ''
          runHook preBuild

          LIB_FILE=$(find ${libFile} -name '*tt*' -name '*.lib' -print -quit)
          if [ -z "$LIB_FILE" ]; then
            LIB_FILE=$(find ${libFile} -name '*.lib' -print -quit)
          fi

          echo "=== Top-level assembly ==="
          cat > synth.tcl << EOF
          set SV_FILE "${aegis-ip}/${deviceName}.sv"
          set LIB_FILE "$LIB_FILE"
          set CELL_LIB "${cellLib}"
          set DEVICE_NAME "${deviceName}"
          set STUBS_V "${aegis-ip}/${deviceName}_tile_stubs.v"
          source ${aegis-ip}/${deviceName}-yosys.tcl
          EOF
          yosys -c synth.tcl 2>&1 | tee yosys.log

          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          mkdir -p $out
          cp ${deviceName}_synth.v $out/ 2>/dev/null || true
          cp yosys.log $out/ 2>/dev/null || true
          runHook postInstall
        '';
      };

      topPnr = stdenv.mkDerivation {
        name = "aegis-top-pnr-${deviceName}";

        dontUnpack = true;
        dontConfigure = true;

        nativeBuildInputs = [ openroad ];

        buildPhase = ''
          runHook preBuild

          LIB_FILE=$(find ${libFile} -name '*tt*' -name '*.lib' -print -quit)
          if [ -z "$LIB_FILE" ]; then
            LIB_FILE=$(find ${libFile} -name '*.lib' -print -quit)
          fi
          TECH_LEF="${techLefDir}/${pdk.techLef}"

          # Copy tile macro LEFs and liberty timing models into working directory
          ${lib.concatMapStringsSep "\n" (mod: ''
            cp ${tileMacros.${mod}}/${deviceName}_${mod}.lef . 2>/dev/null || true
            cp ${tileMacros.${mod}}/${deviceName}_${mod}.lib . 2>/dev/null || true
          '') (builtins.attrNames tileMacros)}

          cat > constraints.sdc << EOF
          create_clock [get_ports clk] -name clk -period ${toString clockPeriodNs}
          EOF

          echo "=== Top-level PnR (macro-based) ==="
          cat > pnr.tcl << OPENROAD_EOF
          set LIB_FILE "$LIB_FILE"
          set TECH_LEF "$TECH_LEF"
          set CELL_LEF_DIR "${techLefDir}"
          set SYNTH_V "${topSynth}/${deviceName}_synth.v"
          set SDC_FILE "constraints.sdc"
          set DEVICE_NAME "${deviceName}"
          set SITE_NAME "${pdk.siteName}"
          set UTILIZATION ${toString coreUtilization}
          set CELL_LIB "${cellLib}"
          set MACRO_HALO ${toString macroHaloUm}
          set GRID_MARGIN ${toString gridMarginUm}
          set PLACEMENT_DENSITY ${toString topPlacementDensity}
          set DROUTE_END_ITER ${toString topDetailedRouteIter}
          ${lib.optionalString (userWidthUm != null && userHeightUm != null) ''
            set DIE_AREA "0 0 ${toString userWidthUm} ${toString userHeightUm}"
          ''}
          ${lib.concatStringsSep "\n" (
            lib.mapAttrsToList (layer: adj: "set LAYER_ADJ(${layer}) ${toString adj}") topLayerAdjustments
          )}
          source ${aegis-ip}/${deviceName}-openroad.tcl
          OPENROAD_EOF
          openroad -threads $NIX_BUILD_CORES -exit pnr.tcl 2>&1 | tee openroad.log

          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          mkdir -p $out
          cp ${deviceName}_final.def $out/ 2>/dev/null || true
          cp ${deviceName}_final.v $out/ 2>/dev/null || true
          cp timing.rpt $out/ 2>/dev/null || true
          cp area.rpt $out/ 2>/dev/null || true
          cp power.rpt $out/ 2>/dev/null || true
          cp openroad.log $out/ 2>/dev/null || true
          runHook postInstall
        '';
      };
    in
    builtins.removeAttrs args [
      "pdk"
      "cellLib"
      "clockPeriodNs"
      "fabSlot"
      "dieWidthUm"
      "dieHeightUm"
      "coreUtilization"
      "macroHaloUm"
      "gridMarginUm"
      "tileUtilization"
      "tileDieSizes"
      "tilePlacementDensities"
      "topPlacementDensity"
      "topDetailedRouteIter"
    ]
    // {
      inherit name;

      dontUnpack = true;
      dontConfigure = true;

      nativeBuildInputs = (args.nativeBuildInputs or [ ]) ++ [
        klayout
      ];

      buildPhase = ''
        runHook preBuild

        echo "=== GDS generation ==="

        if [ -f "${topPnr}/${deviceName}_final.def" ]; then
          # Collect tile macro GDS and LEF files into directories
          mkdir -p macro_gds macro_lef
          ${lib.concatMapStringsSep "\n" (mod: ''
            if [ -f "${tileMacros.${mod}}/${deviceName}_${mod}_final.gds" ]; then
              cp ${tileMacros.${mod}}/${deviceName}_${mod}_final.gds macro_gds/
            fi
            if [ -f "${tileMacros.${mod}}/${deviceName}_${mod}.lef" ]; then
              cp ${tileMacros.${mod}}/${deviceName}_${mod}.lef macro_lef/
            fi
          '') (builtins.attrNames tileMacros)}

          TECH_LEF="${libsRef}/lef/${pdk.techLef}"

          CELL_GDS_DIR="${libsRef}/gds" \
          MACRO_GDS_DIR="macro_gds" \
          MACRO_LEF_DIR="macro_lef" \
          LEF_DIR="${libsRef}/lef" \
          TECH_LEF="$TECH_LEF" \
          DEF_FILE="${topPnr}/${deviceName}_final.def" \
          OUT_GDS="${deviceName}.gds" \
          LAYER_MAP="${lefGdsMapFile}" \
          QT_QPA_PLATFORM=offscreen \
          klayout -b -r ${./scripts/def2gds.py} \
            2>&1 | tee klayout.log || true

          if [ -f "${deviceName}.gds" ]; then
            echo "=== Stamp Nix store path ==="

            GDS_FILE="${deviceName}.gds" \
            STAMP_TEXT="$out" \
            LAYER="${toString pdk.commentLayer.layer}" \
            DATATYPE="${toString pdk.commentLayer.datatype}" \
            QT_QPA_PLATFORM=offscreen \
            klayout -b -r ${./scripts/stamp_text.py} \
              2>&1 | tee -a klayout.log

            echo "=== Fab finalize ==="

            GDS_FILE="${deviceName}.gds" \
            TOP_CELL="AegisFPGA" \
            ${
              lib.optionalString (effectiveDieWidthUm != null) ''DIE_W_UM="${toString effectiveDieWidthUm}"''
            } \
            ${
              lib.optionalString (effectiveDieHeightUm != null) ''DIE_H_UM="${toString effectiveDieHeightUm}"''
            } \
            ${lib.optionalString (fab ? sealRing) ''SEAL_LAYER="${toString fab.sealRing.layer}"''} \
            ${lib.optionalString (fab ? sealRing) ''SEAL_DATATYPE="${toString fab.sealRing.datatype}"''} \
            ${lib.optionalString (fab ? sealRing) ''SEAL_WIDTH_UM="${toString fab.sealRing.width}"''} \
            ${lib.optionalString (fab ? idCell) ''ID_CELL="${fab.idCell}"''} \
            QT_QPA_PLATFORM=offscreen \
            klayout -b -r ${./scripts/fab_finalize.py} \
              2>&1 | tee -a klayout.log

            echo "=== Density fill ==="

            FILL_SCRIPT="${pdkPath}/pv/klayout/drc/filler_generation/fill_all.rb"
            if [ -f "$FILL_SCRIPT" ]; then
              cp "${deviceName}.gds" "${deviceName}_prefill.gds"
              # Set Metal*_ignore_active to allow fill near active metal
              # (matches wafer.space's LibreLane filler options).
              QT_QPA_PLATFORM=offscreen klayout -b -zz \
                -r "$FILL_SCRIPT" \
                -rd input="${deviceName}_prefill.gds" \
                -rd output="${deviceName}.gds" \
                -rd Metal1_ignore_active=true \
                -rd Metal2_ignore_active=true \
                -rd Metal3_ignore_active=true \
                -rd Metal4_ignore_active=true \
                -rd Metal5_ignore_active=true \
                2>&1 | tee -a klayout.log
              rm "${deviceName}_prefill.gds"
              echo "Density fill complete"

              # Clean up orphan fill cells created by the filler
              GDS_FILE="${deviceName}.gds" \
              TOP_CELL="AegisFPGA" \
              QT_QPA_PLATFORM=offscreen \
              klayout -b -r ${./scripts/fab_finalize.py} \
                2>&1 | tee -a klayout.log
            else
              echo "NOTE: Fill script not found, skipping density fill"
            fi

            # DRC repair is available as a separate step:
            #   klayout -b -r scripts/drc_repair.py -rd input=luna_1.gds -rd output=luna_1_repaired.gds
            # It flattens Metal1 and merges close shapes (1458->55 M1.2a violations).
            # Not run in the build because flat Metal1 makes subsequent DRC checks very slow.

            echo "=== Render layout image ==="

            GDS_FILE="${deviceName}.gds" \
            OUT_PNG="${deviceName}_layout.png" \
            QT_QPA_PLATFORM=offscreen \
            klayout -b -r ${./scripts/render_layout.py} \
              >> klayout.log 2>&1 || true
          fi
        else
          echo "Warning: No DEF output from top-level PnR, skipping GDS generation"
        fi

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall

        mkdir -p $out

        # Tile macro artifacts
        mkdir -p $out/macros
        ${lib.concatMapStringsSep "\n" (mod: ''
          if [ -d "${tileMacros.${mod}}" ]; then
            cp -r ${tileMacros.${mod}}/* $out/macros/ 2>/dev/null || true
          fi
        '') (builtins.attrNames tileMacros)}

        # Top-level synthesis
        cp ${topSynth}/${deviceName}_synth.v $out/ 2>/dev/null || true
        cp ${topSynth}/yosys.log $out/yosys_top.log 2>/dev/null || true

        # Top-level PnR
        cp ${topPnr}/${deviceName}_final.def $out/ 2>/dev/null || true
        cp ${topPnr}/${deviceName}_final.v $out/ 2>/dev/null || true
        cp ${topPnr}/openroad.log $out/openroad_top.log 2>/dev/null || true
        cp ${topPnr}/timing.rpt $out/ 2>/dev/null || true
        cp ${topPnr}/area.rpt $out/ 2>/dev/null || true
        cp ${topPnr}/power.rpt $out/ 2>/dev/null || true

        # GDS
        cp ${deviceName}.gds $out/ 2>/dev/null || true
        cp ${deviceName}_layout.png $out/ 2>/dev/null || true
        cp klayout.log $out/ 2>/dev/null || true

        # Source IP for reference
        cp ${aegis-ip}/${deviceName}.json $out/ 2>/dev/null || true

        runHook postInstall
      '';

      passthru = {
        inherit
          pdk
          cellLib
          clockPeriodNs
          coreUtilization
          macroHaloUm
          gridMarginUm
          tileUtilization
          tileDieSizes
          tilePlacementDensities
          topPlacementDensity
          topDetailedRouteIter
          tileMacros
          topSynth
          topPnr
          ;
        inherit (aegis-ip)
          deviceName
          width
          height
          tracks
          ;
        ip = aegis-ip;
        shell = mkShell {
          name = "aegis-tapeout-${aegis-ip.deviceName}-shell";

          packages = [
            yosys
            openroad
            xschem
            klayout
            magic-vlsi
            ngspice
            surfer
          ];

          PDK_NAME = pdk.pdkName;
          PDK_CELL_LIB = cellLib;
        };
      }
      // (args.passthru or { });
    };
}
