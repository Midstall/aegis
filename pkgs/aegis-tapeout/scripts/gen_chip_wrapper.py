#!/usr/bin/env python3
"""Generate a chip-level Verilog wrapper that adds an I/O padring around the
already-elaborated AegisFPGA core.

Inputs (env vars):
  IN_SV         - core SV file containing the AegisFPGA module
  OUT_SV        - output SV file for the chip wrapper
  CORE_MODULE   - name of the core module being wrapped (default AegisFPGA)
  CHIP_MODULE   - name of the new top module (default AegisFPGAChip)
  PAD_BIDIR     - bidirectional pad cell name (e.g. gf180mcu_fd_io__bi_t)
  PAD_INPUT     - input pad cell name (e.g. gf180mcu_fd_io__in_s)
  PAD_VDD       - VDD power-pad cell name
  PAD_VSS       - VSS power-pad cell name
  POWER_PAD_PER_SIDE - number of VDD+VSS pad pairs per die side (default 2)

Each AegisFPGA port becomes a bond-pad-bearing port on the chip wrapper:
  - padIn[i] / padOut[i] / padOutputEnable[i] triplets fold into a single
    bidirectional pad named pad_io[i].
  - Other inputs (clk, reset, ...) get their own input pad.
  - Other outputs (configDone, ...) get their own bidirectional pad with
    OE tied high so it acts as a driver.

Power pads are distributed evenly: every side gets POWER_PAD_PER_SIDE
VDD/VSS pairs, all sharing the chip-level VDD/VSS/DVDD/DVSS rails.

Pads are emitted only as netlist instances. Their physical placement
around the perimeter is handled later by OpenROAD using -fixed
setLocation calls, and corner / filler cells are added there too (they
have no signal connections so they don't need to live in the netlist).
"""
import os
import re
import sys


def parse_ports(content: str, module_name: str):
    """Return a list of {name, dir, msb, lsb, width} for the module."""
    m = re.search(
        rf"module\s+{re.escape(module_name)}\s*\((.*?)\);",
        content,
        re.DOTALL,
    )
    if not m:
        sys.exit(f"could not find module {module_name} in input")
    body = m.group(1)
    ports = []
    for raw in body.split(","):
        line = raw.strip()
        if not line:
            continue
        # input logic [N:M] name   /   output logic name   /   inout ...
        match = re.match(
            r"(input|output|inout)\s+(?:logic\s+)?"
            r"(?:\[\s*(\d+)\s*:\s*(\d+)\s*\]\s+)?"
            r"(\w+)\s*$",
            line,
        )
        if not match:
            sys.exit(f"could not parse port line: {line!r}")
        direction = match.group(1)
        msb = int(match.group(2)) if match.group(2) is not None else None
        lsb = int(match.group(3)) if match.group(3) is not None else None
        width = (msb - lsb + 1) if msb is not None else 1
        ports.append(
            {
                "name": match.group(4),
                "dir": direction,
                "msb": msb,
                "lsb": lsb,
                "width": width,
            }
        )
    return ports


def is_bidir_triplet(ports):
    """Detect padIn / padOut / padOutputEnable triplet and return its width.

    Returns the bus width if the triplet is present and consistent, else None.
    """
    by_name = {p["name"]: p for p in ports}
    needed = ("padIn", "padOut", "padOutputEnable")
    if not all(n in by_name for n in needed):
        return None
    widths = {by_name[n]["width"] for n in needed}
    if len(widths) != 1:
        sys.exit(f"padIn/padOut/padOutputEnable have inconsistent widths: {widths}")
    return widths.pop()


def emit_pad_inst(buf, cell, inst_name, pad_pin, pad_net, a_net, y_net, oe_net):
    """Emit one I/O pad instance.

    The gf180mcu_fd_io__bi_t pin list:
      A      input  - data driven from the chip onto PAD when OE=1
      Y      output - PAD value sampled into the chip when IE=1
      OE     input  - output enable (drive PAD)
      IE     input  - input enable (sample PAD)
      CS     input  - tied 0 (pad current source disabled)
      PD/PU  input  - tied 0 (no internal pull-up/pull-down)
      PDRV0/1 input - tied 1 (max drive strength)
      SL     input  - tied 0 (slow slew, less SI noise)
      PAD    inout  - external bond pad
      VDD/VSS, DVDD/DVSS - power rails (shared chip-wide)
    """
    buf.append(f"  {cell} {inst_name} (")
    buf.append(f"    .PAD({pad_net}),")
    buf.append(f"    .A({a_net}),")
    buf.append(f"    .Y({y_net}),")
    buf.append(f"    .OE({oe_net}),")
    buf.append(f"    .IE(1'b1),")
    buf.append(f"    .CS(1'b0),")
    buf.append(f"    .PD(1'b0),")
    buf.append(f"    .PU(1'b0),")
    buf.append(f"    .PDRV0(1'b1),")
    buf.append(f"    .PDRV1(1'b1),")
    buf.append(f"    .SL(1'b0),")
    buf.append(f"    .DVDD(VDD),")
    buf.append(f"    .DVSS(VSS),")
    buf.append(f"    .VDD(VDD),")
    buf.append(f"    .VSS(VSS)")
    buf.append(f"  );")


def emit_power_pad(buf, cell, inst_name, label):
    """Emit a power or ground pad. Power-pad cells only carry the rails
    relevant to their domain - the dvdd cell omits VDD (it sources it),
    the dvss cell omits VSS - so we need to skip those pins to keep the
    netlist legal."""
    # Map every pad power pin onto the chip-level VDD / VSS rails so the
    # design has a single power domain. The cell's DVDD pin (pad/IO power)
    # is tied to chip VDD, DVSS to chip VSS - we treat IO and core power
    # as the same supply for this digital flow.
    if cell.endswith("__dvdd"):
        pin_map = (("DVDD", "VDD"), ("DVSS", "VSS"), ("VSS", "VSS"))
    elif cell.endswith("__dvss"):
        pin_map = (("DVDD", "VDD"), ("DVSS", "VSS"), ("VDD", "VDD"))
    else:
        pin_map = (
            ("DVDD", "VDD"),
            ("DVSS", "VSS"),
            ("VDD", "VDD"),
            ("VSS", "VSS"),
        )
    buf.append(f"  // {label}")
    buf.append(f"  {cell} {inst_name} (")
    for j, (pin, net) in enumerate(pin_map):
        sep = "," if j < len(pin_map) - 1 else ""
        buf.append(f"    .{pin}({net}){sep}")
    buf.append(f"  );")


def main():
    in_sv = os.environ["IN_SV"]
    out_sv = os.environ["OUT_SV"]
    core_module = os.environ.get("CORE_MODULE", "AegisFPGA")
    chip_module = os.environ.get("CHIP_MODULE", "AegisFPGAChip")
    pad_bidir = os.environ.get("PAD_BIDIR", "gf180mcu_fd_io__bi_t")
    pad_input = os.environ.get("PAD_INPUT", "gf180mcu_fd_io__in_s")
    pad_vdd = os.environ.get("PAD_VDD", "gf180mcu_fd_io__dvdd")
    pad_vss = os.environ.get("PAD_VSS", "gf180mcu_fd_io__dvss")
    power_pad_per_side = int(os.environ.get("POWER_PAD_PER_SIDE", "2"))

    with open(in_sv) as f:
        content = f.read()

    ports = parse_ports(content, core_module)
    bidir_w = is_bidir_triplet(ports)

    bidir_names = {"padIn", "padOut", "padOutputEnable"}
    other_ports = [p for p in ports if p["name"] not in bidir_names]

    out = []
    out.append(f"// Auto-generated chip-level wrapper for {core_module}.")
    out.append(f"// Adds a padring around the core. Do not edit by hand.")
    out.append("//")
    out.append("// The chip wrapper exposes VDD/VSS as the only top-level ports.")
    out.append("// Bond-pad signal connections happen at the pad cells' PAD pins")
    out.append("// directly - those pins are physical bond points, not routable")
    out.append("// nets, so we keep them as internal wires with no other endpoint.")
    out.append("// This avoids OpenROAD's detailed router trying to find an")
    out.append("// access point to the PAD pin from inside the die (DRT-0073).")
    out.append("")
    out.append(f"module {chip_module} (")
    # Only VDD/VSS leave the chip as named ports. Bond-wire signals stay
    # at pad cells' PAD pins.
    out.append("  inout wire VDD,")
    out.append("  inout wire VSS")
    out.append(");")
    out.append("")

    # Internal wires: chip-side nets that attach to pad PAD pins. These
    # nets have only the PAD-pin endpoint, which is fine - the bond
    # wire physically connects them off-chip.
    if bidir_w is not None:
        out.append(f"  wire [{bidir_w - 1}:0] pad_io;")
    for p in other_ports:
        sz = "" if p["width"] == 1 else f" [{p['msb']}:{p['lsb']}]"
        out.append(f"  wire{sz} pad_{p['name']};")
    out.append("")
    # Internal core-side nets.
    if bidir_w is not None:
        out.append(f"  wire [{bidir_w - 1}:0] core_padIn;")
        out.append(f"  wire [{bidir_w - 1}:0] core_padOut;")
        out.append(f"  wire [{bidir_w - 1}:0] core_padOutputEnable;")
    for p in other_ports:
        sz = "" if p["width"] == 1 else f" [{p['msb']}:{p['lsb']}]"
        out.append(f"  wire{sz} core_{p['name']};")
    out.append("")

    # Bidirectional I/O pads via generate-for so the netlist stays compact.
    if bidir_w is not None:
        out.append(f"  // {bidir_w} bidirectional user-IO pads")
        out.append(f"  genvar i;")
        out.append(f"  generate")
        out.append(f"    for (i = 0; i < {bidir_w}; i = i + 1) begin : g_io_pad")
        out.append(f"      {pad_bidir} u_pad_io (")
        out.append(f"        .PAD(pad_io[i]),")
        out.append(f"        .A(core_padOut[i]),")
        out.append(f"        .Y(core_padIn[i]),")
        out.append(f"        .OE(core_padOutputEnable[i]),")
        out.append(f"        .IE(1'b1),")
        out.append(f"        .CS(1'b0),")
        out.append(f"        .PD(1'b0),")
        out.append(f"        .PU(1'b0),")
        out.append(f"        .PDRV0(1'b1),")
        out.append(f"        .PDRV1(1'b1),")
        out.append(f"        .SL(1'b0),")
        out.append(f"        .DVDD(VDD),")
        out.append(f"        .DVSS(VSS),")
        out.append(f"        .VDD(VDD),")
        out.append(f"        .VSS(VSS)")
        out.append(f"      );")
        out.append(f"    end")
        out.append(f"  endgenerate")
        out.append("")

    # Per-port pads for the non-bus signals.
    for p in other_ports:
        for bit in range(p["width"]):
            if p["width"] == 1:
                inst = f"u_pad_{p['name']}"
                pad_net = f"pad_{p['name']}"
                core_net = f"core_{p['name']}"
            else:
                inst = f"u_pad_{p['name']}_{bit}"
                pad_net = f"pad_{p['name']}[{bit + p['lsb']}]"
                core_net = f"core_{p['name']}[{bit + p['lsb']}]"
            out.append(
                f"  // pad for {p['dir']} {p['name']}{'' if p['width']==1 else f'[{bit}]'}"
            )
            if p["dir"] == "input":
                emit_pad_inst(
                    out,
                    pad_bidir,
                    inst,
                    "PAD",
                    pad_net,
                    a_net="1'b0",
                    y_net=core_net,
                    oe_net="1'b0",
                )
            else:
                emit_pad_inst(
                    out,
                    pad_bidir,
                    inst,
                    "PAD",
                    pad_net,
                    a_net=core_net,
                    y_net="",
                    oe_net="1'b1",
                )
        out.append("")

    # Power pads, distributed evenly across the four sides. Naming carries
    # the side index so the OpenROAD placer can lay them out symmetrically.
    out.append("  // Power pads (VDD/VSS) distributed around the perimeter")
    side_names = ["n", "s", "e", "w"]
    for s in side_names:
        for k in range(power_pad_per_side):
            emit_power_pad(out, pad_vdd, f"u_pad_vdd_{s}{k}", f"VDD pad {s}{k}")
            emit_power_pad(out, pad_vss, f"u_pad_vss_{s}{k}", f"VSS pad {s}{k}")
    out.append("")

    # Instantiate the core, hooking up every port to its core-side wire.
    out.append(f"  // Core instance: {core_module}")
    out.append(f"  {core_module} u_core (")
    conn = []
    for p in ports:
        conn.append(f"    .{p['name']}(core_{p['name']})")
    out.append(",\n".join(conn))
    out.append("  );")
    out.append("")
    out.append(f"endmodule")
    out.append("")

    with open(out_sv, "w") as f:
        f.write("\n".join(out))

    print(f"Wrote {out_sv} ({len(ports)} core ports, {bidir_w or 0} bidir pads)")


if __name__ == "__main__":
    main()
