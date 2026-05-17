{ lib, writeText }:
{
  pdk,
  designName,
  verilogFiles,
  sdcFile,
  pdnConfigFile,
  clockPort,
  clockNet,
  clockPeriodNs,
  placementDensityPct ? 75,
  fabMacros ? { },
  fabIgnoreDisconnectedModules ? [ ],
  extraConfig ? { },
}:

let
  lr = pdk.librelane;
  pdn = lr.pdn;

  config = {
    meta = {
      version = 3;
      flow = "Chip";
    };

    DESIGN_NAME = designName;
    VERILOG_FILES = verilogFiles;

    USE_SLANG = false;

    PRIMARY_GDSII_STREAMOUT_TOOL = "klayout";

    PNR_SDC_FILE = sdcFile;
    SIGNOFF_SDC_FILE = sdcFile;
    FALLBACK_SDC = sdcFile;

    VDD_NETS = [ "VDD" ];
    GND_NETS = [ "VSS" ];

    IGNORE_DISCONNECTED_MODULES = lr.ignoreDisconnectedModules ++ fabIgnoreDisconnectedModules;

    CLOCK_PORT = clockPort;
    CLOCK_NET = clockNet;
    CLOCK_PERIOD = clockPeriodNs;

    PL_RESIZER_HOLD_SLACK_MARGIN = lr.resizer.plHoldSlackMargin;
    GRT_RESIZER_HOLD_SLACK_MARGIN = lr.resizer.grtHoldSlackMargin;

    PL_TARGET_DENSITY_PCT = placementDensityPct;
    GRT_ALLOW_CONGESTION = true;

    DRT_ANTENNA_REPAIR_ITERS = lr.antennaRepair.iters;
    DRT_ANTENNA_REPAIR_MARGIN = lr.antennaRepair.margin;

    PDN_VWIDTH = pdn.vWidth;
    PDN_HWIDTH = pdn.hWidth;
    PDN_VSPACING = pdn.vSpacing;
    PDN_HSPACING = pdn.hSpacing;
    PDN_VPITCH = pdn.vPitch;
    PDN_HPITCH = pdn.hPitch;
    PDN_CORE_RING = pdn.coreRing.enable;
    PDN_CORE_RING_VWIDTH = pdn.coreRing.vWidth;
    PDN_CORE_RING_HWIDTH = pdn.coreRing.hWidth;
    PDN_CORE_RING_CONNECT_TO_PADS = pdn.coreRing.connectToPads;
    PDN_ENABLE_PINS = pdn.coreRing.enablePins;
    PDN_CORE_VERTICAL_LAYER = pdn.coreVerticalLayer;
    PDN_CORE_HORIZONTAL_LAYER = pdn.coreHorizontalLayer;

    FP_MACRO_HORIZONTAL_HALO = pdn.macroHorizontalHalo;
    FP_MACRO_VERTICAL_HALO = pdn.macroVerticalHalo;
    PDN_HORIZONTAL_HALO = pdn.horizontalHalo;
    PDN_VERTICAL_HALO = pdn.verticalHalo;

    ERROR_ON_MAGIC_DRC = lr.errorOnMagicDrc;
    MAGIC_GDS_FLATGLOB = lr.magicGdsFlatglob;
    KLAYOUT_FILLER_OPTIONS = lr.klayoutFillerOptions;
    MAGIC_EXT_UNIQUE = lr.magicExtUnique;

    MACROS = fabMacros;
    PDN_CFG = pdnConfigFile;
  }
  // extraConfig;
in
writeText "${designName}-librelane-config.yaml" (lib.generators.toJSON { } config)
