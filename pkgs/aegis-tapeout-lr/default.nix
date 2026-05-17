{
  lib,
  callPackage,
  stdenv,
  writeText,
  librelane,
  klayout,
  yosys,
  python3,
  aegis-ip,
}:

{
  pdk,
  cellLib ? pdk.cellLib,
  clockPeriodNs ? 20,
  fabSlot ? "1x1",
  designName ? "chip_top",
  clockPort ? "clk_PAD",
  clockNet ? "clk_pad/Y",
  placementDensityPct ? 75,
  fabMacros ? {
    gf180mcu_ws_ip__id = {
      gds = [ "dir::../ip/gf180mcu_ws_ip__id/gds/gf180mcu_ws_ip__id.gds" ];
      lef = [ "dir::../ip/gf180mcu_ws_ip__id/lef/gf180mcu_ws_ip__id.lef" ];
      vh = [ "dir::../ip/gf180mcu_ws_ip__id/vh/gf180mcu_ws_ip__id.v" ];
      lib."*" = [ "dir::../ip/gf180mcu_ws_ip__id/lib/gf180mcu_ws_ip__id.lib" ];
      instances.chip_id = {
        location = [
          26
          26
        ];
        orientation = "N";
      };
    };
    gf180mcu_ws_ip__logo = {
      gds = [ "dir::../ip/gf180mcu_ws_ip__logo/gds/gf180mcu_ws_ip__logo.gds" ];
      lef = [ "dir::../ip/gf180mcu_ws_ip__logo/lef/gf180mcu_ws_ip__logo.lef" ];
      vh = [ "dir::../ip/gf180mcu_ws_ip__logo/vh/gf180mcu_ws_ip__logo.v" ];
      lib."*" = [ "dir::../ip/gf180mcu_ws_ip__logo/lib/gf180mcu_ws_ip__logo.lib" ];
      instances.wafer_space_logo = {
        location = [
          "expr::$DIE_AREA[2] + -169.25"
          "expr::$DIE_AREA[3] + -169.25"
        ];
        orientation = "N";
      };
    };
  },
  fabIgnoreDisconnectedModules ? [
    "gf180mcu_ws_ip__id"
    "gf180mcu_ws_ip__logo"
  ],
  fabRequiredCells ? [
    {
      module = "gf180mcu_ws_ip__id";
      instance = "chip_id";
      comment = "Chip ID - required for tapeout";
    }
    {
      module = "gf180mcu_ws_ip__logo";
      instance = "wafer_space_logo";
      comment = "wafer.space logo - optional";
    }
  ],
  ...
}@args:

let
  inherit (aegis-ip) deviceName;

  config = callPackage ./lib/mk-librelane-config.nix { } {
    inherit
      pdk
      designName
      clockPort
      clockNet
      clockPeriodNs
      placementDensityPct
      fabMacros
      fabIgnoreDisconnectedModules
      ;
    verilogFiles = [
      "dir::../templates/chip_top.sv"
      "dir::../templates/chip_core.sv"
      "dir::../templates/aegis_fpga.sv"
    ];
    sdcFile = "dir::${designName}.sdc";
    pdnConfigFile = "dir::pdn_cfg.tcl";
  };

  padDefines = callPackage ./lib/mk-pad-defines.nix { } { inherit pdk; };
  fabRequiredCellsHeader = callPackage ./lib/mk-fab-required-cells.nix { } {
    cells = fabRequiredCells;
  };

  slot =
    pdk.librelane.slots.${fabSlot}
      or (throw "aegis-tapeout-lr: pdk.librelane.slots has no slot named '${fabSlot}'");
  slotConfig = callPackage ./lib/mk-slot-config.nix { } {
    slotName = fabSlot;
    inherit slot;
  };
in
stdenv.mkDerivation {
  name = "aegis-tapeout-lr-${deviceName}";

  dontUnpack = true;
  dontConfigure = true;

  nativeBuildInputs = [
    librelane
    klayout
    yosys
    python3
  ];

  AEGIS_IP = "${aegis-ip}";
  PDK_ROOT = "${pdk.librelane.pdkRoot}";
  PDK = pdk.librelane.pdkName;

  buildPhase = ''
    runHook preBuild

    echo "=== Setting up LibreLane working directory ==="
    cp -r ${./templates} templates
    cp -r ${./librelane} librelane
    cp -r ${pdk.librelane.fabRequiredIp} ip

    chmod -R u+w templates librelane ip
    install -m 0644 ${config} librelane/config.yaml

    cp ${aegis-ip}/${deviceName}.sv templates/aegis_fpga.sv
    chmod u+w templates/aegis_fpga.sv

    install -m 0644 ${padDefines} templates/pad_defines.svh
    install -m 0644 ${fabRequiredCellsHeader} templates/fab_required_cells.svh

    mkdir -p librelane/slots
    install -m 0644 ${slotConfig} librelane/slots/slot_${fabSlot}.yaml

    echo "=== Running LibreLane Chip flow ==="
    mkdir -p out

    librelane \
      librelane/slots/slot_${fabSlot}.yaml \
      librelane/config.yaml \
      --save-views-to out/final \
      --pdk "$PDK" \
      --pdk-root "$PDK_ROOT" \
      --manual-pdk \
      --skip OpenROAD.STAPostPNR \
      --skip OpenROAD.IRDropReport \
      --skip Checker.SetupViolations \
      --skip Checker.HoldViolations \
      --skip Checker.MaxSlewViolations \
      --skip Checker.MaxCapViolations \
      --skip KLayout.Render \
      2>&1 | tee librelane.log

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    cp -r out/final $out/ 2>/dev/null || true
    cp librelane.log $out/ 2>/dev/null || true
    cp -r librelane/runs $out/runs 2>/dev/null || true

    runHook postInstall
  '';

  passthru = {
    inherit
      pdk
      cellLib
      clockPeriodNs
      fabSlot
      placementDensityPct
      ;
    inherit (aegis-ip) deviceName;
    topCellName = designName;
    librelaneConfig = config;
  };
}
