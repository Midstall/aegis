"""Convert a DEF file to GDS, merging with cell and macro GDS libraries.

Environment variables:
  CELL_GDS_DIR  - directory containing PDK standard cell GDS files
  MACRO_GDS_DIR - directory containing tile macro GDS files (optional)
  MACRO_LEF_DIR - directory containing tile macro LEF files (optional)
  LEF_DIR       - directory containing LEF files for cell/macro definitions
  TECH_LEF      - path to tech LEF file
  DEF_FILE      - path to routed DEF file
  OUT_GDS       - output GDS path
  LAYER_MAP     - path to KLayout LEF/DEF layer map file (optional)
"""

import glob
import os

import pya

cell_gds_dir = os.environ["CELL_GDS_DIR"]
macro_gds_dir = os.environ.get("MACRO_GDS_DIR", "")
macro_lef_dir = os.environ.get("MACRO_LEF_DIR", "")
lef_dir = os.environ.get("LEF_DIR", "")
tech_lef = os.environ.get("TECH_LEF", "")
def_file = os.environ["DEF_FILE"]
out_gds = os.environ["OUT_GDS"]
layer_map = os.environ.get("LAYER_MAP", "")

layout = pya.Layout()
# Use default DBU (0.001um) to match standard cell GDS files.
# The DEF reader handles DATABASE MICRONS conversion internally.

# Collect standard cell and tech LEF files for the DEF reader
lef_files = []
if tech_lef and os.path.exists(tech_lef):
    lef_files.append(tech_lef)
if lef_dir and os.path.isdir(lef_dir):
    for lef in sorted(glob.glob(os.path.join(lef_dir, "*.lef"))):
        if "tech" not in os.path.basename(lef).lower():
            lef_files.append(lef)

# Read tile macro LEFs first so their MACRO definitions are in the
# layout database before the DEF reader tries to resolve them.
macro_lef_files = []
if macro_lef_dir and os.path.isdir(macro_lef_dir):
    macro_lef_files = sorted(glob.glob(os.path.join(macro_lef_dir, "*.lef")))
    for lef in macro_lef_files:
        lef_files.append(lef)
    print(f"Including {len(macro_lef_files)} macro LEF files from {macro_lef_dir}")

# Read all LEFs first, then read DEF referencing them
opts = pya.LoadLayoutOptions()
lefdef = opts.lefdef_config
lefdef.read_lef_with_def = True
lefdef.lef_files = lef_files
if layer_map and os.path.exists(layer_map):
    lefdef.map_file = layer_map
    print(f"Using layer map: {layer_map}")
print(f"Reading DEF with {len(lef_files)} LEF files")
print(f"  Tech LEF: {tech_lef}")

# Also read macro LEFs independently into the layout to pre-populate
# macro cell definitions before the DEF reader processes COMPONENTS.
if macro_lef_files:
    lef_opts = pya.LoadLayoutOptions()
    lef_lefdef = lef_opts.lefdef_config
    # Include tech LEF for layer definitions needed by macro LEFs
    if tech_lef and os.path.exists(tech_lef):
        lef_lefdef.read_lef_with_def = True
        lef_lefdef.lef_files = [tech_lef]
    if layer_map and os.path.exists(layer_map):
        lef_lefdef.map_file = layer_map
    for lef in macro_lef_files:
        print(f"  Pre-reading macro LEF: {os.path.basename(lef)}")
        layout.read(lef, lef_opts)

print(f"Reading DEF: {def_file}")
layout.read(def_file, opts)

# When merging GDS files, use CellConflictResolution to replace
# LEF abstract cells with full GDS geometry.
gds_opts = pya.LoadLayoutOptions()
gds_opts.cell_conflict_resolution = (
    pya.LoadLayoutOptions.CellConflictResolution.OverwriteCell
)

# Read all standard cell GDS files from the PDK
gds_files = sorted(glob.glob(os.path.join(cell_gds_dir, "*.gds")))
print(f"Reading {len(gds_files)} cell GDS files from {cell_gds_dir}")
for gds in gds_files:
    layout.read(gds, gds_opts)

# Read tile macro GDS files - these replace the LEF abstract shapes
# with full physical geometry including Metal2/Metal3 routing
if macro_gds_dir and os.path.isdir(macro_gds_dir):
    macro_files = sorted(glob.glob(os.path.join(macro_gds_dir, "*.gds")))
    print(f"Reading {len(macro_files)} macro GDS files from {macro_gds_dir}")
    for gds in macro_files:
        layout.read(gds, gds_opts)

layout.write(out_gds)
print(f"Wrote {out_gds}")
