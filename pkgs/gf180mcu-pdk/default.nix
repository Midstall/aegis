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

  cellLib = "gf180mcu_fd_sc_mcu7t5v0";
  pdkRoot = "${pdk-src}/gf180mcuD";
  scRoot = "${pdkRoot}/libs.ref/${cellLib}";
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

    # Physical verification rule decks (DRC/LVS) from wafer-space fork
    # Maintain path structure: pv/klayout/drc/, pv/klayout/lvs/
    mkdir -p $out/share/pdk/gf180mcu/pv/klayout
    cp -r ${pdkRoot}/libs.tech/klayout/tech/* $out/share/pdk/gf180mcu/pv/klayout/

    runHook postInstall
  '';

  passthru = {
    inherit cellLib;
    siteName = "GF018hv5v_mcu_sc7";
    pdkName = "gf180mcu";
    pdkPath = "share/pdk/gf180mcu";
    techLef = "${cellLib}__nom.tlef";
    # Per-layer routing capacity adjustments (0.0 = full, 1.0 = blocked)
    tileLayerAdjustments = { };
    topLayerAdjustments = { };
    commentLayer = {
      layer = 236;
      datatype = 0;
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
