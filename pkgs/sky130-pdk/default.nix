{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
}:

let
  # High Density standard cell library
  fd_sc_hd = fetchFromGitHub {
    owner = "google";
    repo = "skywater-pdk-libs-sky130_fd_sc_hd";
    rev = "ac7fb61f06e6470b94e8afdf7c25268f62fbd7b1";
    hash = "sha256-Y/vEGy+k+deGTAE5SV1IhPEAgH1AsvV7Be2zRVTqSX8=";
  };
in
stdenvNoCC.mkDerivation {
  pname = "sky130-pdk";
  version = "0-unstable-2025-03-31";

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  # NOTE: Sky130's Google repo stores timing data as JSON, not liberty.
  # Liberty generation requires open_pdks or a separate conversion step.
  # This package currently provides LEF, GDS, and Verilog only.
  # For full synthesis support, use the open_pdks build.

  installPhase = ''
    runHook preInstall

    local sc=$out/share/pdk/sky130/libs.ref/sky130_fd_sc_hd
    mkdir -p $sc/{lib,lef,gds,verilog,spice}

    # Tech LEF files
    find ${fd_sc_hd}/tech -name '*.lef' -exec cp -n {} $sc/lef/ \; 2>/dev/null || true

    # Cell files
    find ${fd_sc_hd}/cells -name '*.lef' ! -name '*.magic.lef' -exec cp -n {} $sc/lef/ \; 2>/dev/null || true
    find ${fd_sc_hd}/cells -name '*.gds' -exec cp -n {} $sc/gds/ \; 2>/dev/null || true
    find ${fd_sc_hd}/cells -name '*.v' -exec cp -n {} $sc/verilog/ \; 2>/dev/null || true
    find ${fd_sc_hd}/cells -name '*.spice' -exec cp -n {} $sc/spice/ \; 2>/dev/null || true

    # Simulation models
    if [ -d "${fd_sc_hd}/models" ]; then
      mkdir -p $out/share/pdk/sky130/models
      cp -r ${fd_sc_hd}/models/* $out/share/pdk/sky130/models/
    fi

    runHook postInstall
  '';

  passthru = {
    cellLib = "sky130_fd_sc_hd";
    siteName = "unithd";
    pdkName = "sky130";
    pdkPath = "share/pdk/sky130";
    commentLayer = {
      layer = 236;
      datatype = 0;
    };
    # LEF layer name -> GDS layer/datatype mapping for KLayout DEF->GDS
    lefGdsLayers = {
      li1 = {
        layer = 67;
        datatype = 20;
      };
      mcon = {
        layer = 67;
        datatype = 44;
      };
      met1 = {
        layer = 68;
        datatype = 20;
      };
      via = {
        layer = 68;
        datatype = 44;
      };
      met2 = {
        layer = 69;
        datatype = 20;
      };
      via2 = {
        layer = 69;
        datatype = 44;
      };
      met3 = {
        layer = 70;
        datatype = 20;
      };
      via3 = {
        layer = 70;
        datatype = 44;
      };
      met4 = {
        layer = 71;
        datatype = 20;
      };
      via4 = {
        layer = 71;
        datatype = 44;
      };
      met5 = {
        layer = 72;
        datatype = 20;
      };
    };
  };

  meta = {
    description = "SkyWater Sky130 130nm PDK High Density standard cell library (LEF/GDS/Verilog only - liberty requires open_pdks build)";
    homepage = "https://github.com/google/skywater-pdk";
    license = lib.licenses.asl20;
    platforms = lib.platforms.all;
  };
}
