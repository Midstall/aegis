// SPDX-FileCopyrightText: (C) 2026 Midstall Inc.
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

// Chip core wrapper that adapts AegisFPGA's ports to the wafer.space
// gf180mcu-project-template chip_core interface. The pad cells live
// in chip_top, this module is what gets placed inside the padring.
//
// Pad budget on the 1x1 slot (per slot_1x1.yaml + slot_defines.svh):
//   - 12 CMOS input pads
//   - 40 bidirectional pads (24mA)
//   - 2 analog pads
//
// Mapping for Luna-1 (23x23 fabric, 92 user-IO pads, no SerDes):
//   inputs[0..7]       <- AegisFPGA.configRead_data[7:0]
//   inputs[8..11]      <- unused (tied off in core)
//   bidir[0..24]       <-> AegisFPGA.padIn / padOut / padOutputEnable[24:0]
//                          (the first 25 of 92 perimeter IO pads get bond pads)
//   bidir[25..28]      <- AegisFPGA.clkOut[3:0]    (driven, OE=1)
//   bidir[29]          <- AegisFPGA.clkLocked     (driven, OE=1)
//   bidir[30..37]      <- AegisFPGA.configRead_addr[7:0]  (driven, OE=1)
//   bidir[38]          <- AegisFPGA.configRead_en  (driven, OE=1)
//   bidir[39]          <- AegisFPGA.configDone     (driven, OE=1)
//   AegisFPGA.padIn[91:25] = 0 (67 IO pads with no bond pad - tied low)
//   analog[*]          <- unused
//
// rst_n is the chip-level active-low reset, AegisFPGA expects active-high
// reset, so we invert.

module chip_core #(
    parameter NUM_INPUT_PADS  = 12,
    parameter NUM_BIDIR_PADS  = 40,
    parameter NUM_ANALOG_PADS = 2
) (
`ifdef USE_POWER_PINS
    inout wire VDD,
    inout wire VSS,
`endif
    input  wire clk,
    input  wire rst_n,

    input  wire [NUM_INPUT_PADS-1:0]  input_in,
    output wire [NUM_INPUT_PADS-1:0]  input_pu,
    output wire [NUM_INPUT_PADS-1:0]  input_pd,

    input  wire [NUM_BIDIR_PADS-1:0]  bidir_in,
    output wire [NUM_BIDIR_PADS-1:0]  bidir_out,
    output wire [NUM_BIDIR_PADS-1:0]  bidir_oe,
    output wire [NUM_BIDIR_PADS-1:0]  bidir_cs,
    output wire [NUM_BIDIR_PADS-1:0]  bidir_sl,
    output wire [NUM_BIDIR_PADS-1:0]  bidir_ie,
    output wire [NUM_BIDIR_PADS-1:0]  bidir_pu,
    output wire [NUM_BIDIR_PADS-1:0]  bidir_pd,

    inout  wire [NUM_ANALOG_PADS-1:0] analog
);

    localparam int FABRIC_USER_IOS  = 92;  // 2*W + 2*H for 23x23 fabric
    localparam int USER_IO_PADS     = 25;  // bidir slots reserved for user IOs

    (* keep = "true" *) wire [FABRIC_USER_IOS-1:0] core_padIn;
    (* keep = "true" *) wire [FABRIC_USER_IOS-1:0] core_padOut;
    (* keep = "true" *) wire [FABRIC_USER_IOS-1:0] core_padOutputEnable;
    (* keep = "true" *) wire [3:0]                 core_clkOut;
    (* keep = "true" *) wire                       core_clkLocked;
    (* keep = "true" *) wire [7:0]                 core_configRead_data;
    (* keep = "true" *) wire [7:0]                 core_configRead_addr;
    (* keep = "true" *) wire                       core_configRead_en;
    (* keep = "true" *) wire                       core_configDone;

    assign core_configRead_data = input_in[7:0];
    // Pull controls: leave all inputs floating (no pull-up / pull-down).
    assign input_pu = {NUM_INPUT_PADS{1'b0}};
    assign input_pd = {NUM_INPUT_PADS{1'b0}};

    assign core_padIn = {
        {(FABRIC_USER_IOS - USER_IO_PADS){1'b0}},
        bidir_in[USER_IO_PADS-1:0]
    };

    // bidir_out: low USER_IO_PADS bits come from AegisFPGA padOut, the
    // remaining 15 are control outputs.
    assign bidir_out[USER_IO_PADS-1:0]   = core_padOut[USER_IO_PADS-1:0];
    assign bidir_out[28:25]              = core_clkOut;
    assign bidir_out[29]                 = core_clkLocked;
    assign bidir_out[37:30]              = core_configRead_addr;
    assign bidir_out[38]                 = core_configRead_en;
    assign bidir_out[39]                 = core_configDone;

    // bidir_oe: user IOs follow padOutputEnable; control outputs always drive.
    assign bidir_oe[USER_IO_PADS-1:0] = core_padOutputEnable[USER_IO_PADS-1:0];
    assign bidir_oe[NUM_BIDIR_PADS-1:USER_IO_PADS] =
        {(NUM_BIDIR_PADS - USER_IO_PADS){1'b1}};

    // Bidir control settings: enable input receivers, drive at 24mA, no
    // pull-up / pull-down, no current source, fast slew.
    assign bidir_cs = {NUM_BIDIR_PADS{1'b0}};
    assign bidir_sl = {NUM_BIDIR_PADS{1'b0}};
    assign bidir_ie = {NUM_BIDIR_PADS{1'b1}};
    assign bidir_pu = {NUM_BIDIR_PADS{1'b0}};
    assign bidir_pd = {NUM_BIDIR_PADS{1'b0}};

    (* keep *)
    AegisFPGA u_core (
        .clk             (clk),
        .reset           (~rst_n),
        .padIn           (core_padIn),
        .configRead_data (core_configRead_data),
        .padOut          (core_padOut),
        .padOutputEnable (core_padOutputEnable),
        .clkOut          (core_clkOut),
        .clkLocked       (core_clkLocked),
        .configRead_en   (core_configRead_en),
        .configRead_addr (core_configRead_addr),
        .configDone      (core_configDone)
    );

    // Analog pads carry no internal connection. They appear on the
    // padring only so the slot pad list stays consistent with the
    // wafer.space template.
    genvar i;
    generate
        for (i = 0; i < NUM_ANALOG_PADS; i = i + 1) begin : g_analog_unused
            // Intentionally empty - analog pad has no driver here.
        end
    endgenerate

endmodule

`default_nettype wire
