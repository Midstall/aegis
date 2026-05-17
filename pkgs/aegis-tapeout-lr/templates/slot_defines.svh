`ifdef SLOT_1X1

// Power/ground pads for core and I/O
`define NUM_DVDD_PADS 8
`define NUM_DVSS_PADS 10

// Signal pads
`define NUM_INPUT_PADS 12
`define NUM_BIDIR_PADS 40
`define NUM_ANALOG_PADS 2

`endif

`ifdef SLOT_0P5X1

// Power/ground pads for core and I/O
`define NUM_DVDD_PADS 8
`define NUM_DVSS_PADS 8

// Signal pads
`define NUM_INPUT_PADS 4
`define NUM_BIDIR_PADS 44
`define NUM_ANALOG_PADS 6

`endif

`ifdef SLOT_1X0P5

// Power/ground pads for core and I/O
`define NUM_DVDD_PADS 8
`define NUM_DVSS_PADS 8

// Signal pads
`define NUM_INPUT_PADS 4
`define NUM_BIDIR_PADS 46
`define NUM_ANALOG_PADS 4

`endif

`ifdef SLOT_0P5X0P5

// Power/ground pads for core and I/O
`define NUM_DVDD_PADS 4
`define NUM_DVSS_PADS 4

// Signal pads
`define NUM_INPUT_PADS 4
`define NUM_BIDIR_PADS 38
`define NUM_ANALOG_PADS 4

`endif
