{ lib, writeText }:
{
  slotName,
  slot,
}:

let
  config = {
    FP_SIZING = "absolute";
    DIE_AREA = slot.dieArea;
    CORE_AREA = slot.coreArea;
    VERILOG_DEFINES = slot.verilogDefines;
    PAD_SOUTH = slot.pads.south;
    PAD_EAST = slot.pads.east;
    PAD_NORTH = slot.pads.north;
    PAD_WEST = slot.pads.west;
  };
in
writeText "slot_${slotName}.yaml" (lib.generators.toJSON { } config)
