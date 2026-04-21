"""Finalize GDS for fab submission.

Performs fab-specific post-processing on the merged GDS:
  - Adds seal ring on the specified layer
  - Adds an empty ID cell (fab fills with QR code)
  - Removes orphan top-level cells (unused standard cells)
  - Offsets layout to center within die (accounting for seal ring)
  - Validates origin and dimensions

Environment variables:
  GDS_FILE       - input/output GDS path (modified in place)
  TOP_CELL       - name of the top-level cell
  DIE_W_UM       - full die width in um (including seal ring)
  DIE_H_UM       - full die height in um (including seal ring)
  SEAL_LAYER     - seal ring GDS layer (optional)
  SEAL_DATATYPE  - seal ring GDS datatype (optional)
  SEAL_WIDTH_UM  - seal ring width in um (optional)
  ID_CELL        - name of required ID cell (optional)
"""

import os
import pya

gds_file = os.environ["GDS_FILE"]
top_cell_name = os.environ["TOP_CELL"]
die_w = float(os.environ.get("DIE_W_UM", "0"))
die_h = float(os.environ.get("DIE_H_UM", "0"))
seal_layer = int(os.environ.get("SEAL_LAYER", "0"))
seal_datatype = int(os.environ.get("SEAL_DATATYPE", "0"))
seal_width = float(os.environ.get("SEAL_WIDTH_UM", "0"))
id_cell_name = os.environ.get("ID_CELL", "")

layout = pya.Layout()
layout.read(gds_file)

top = layout.cell(top_cell_name)
if top is None:
    print(f"ERROR: Top cell '{top_cell_name}' not found")
    exit(1)

dbu = layout.dbu

# Remove orphan top-level cells (standard cells loaded but not instantiated)
orphans = []
for cell in layout.each_cell():
    if cell.is_top() and cell.name != top_cell_name:
        orphans.append(cell.cell_index())
if orphans:
    print(f"Removing {len(orphans)} orphan top-level cells")
    for ci in orphans:
        layout.delete_cell(ci)

# Add seal ring if configured
if seal_width > 0 and die_w > 0 and die_h > 0:
    li = layout.layer(seal_layer, seal_datatype)
    sw = int(seal_width / dbu)
    dw = int(die_w / dbu)
    dh = int(die_h / dbu)

    # Get current layout bounds
    bbox = top.bbox()
    # Offset to center user area within die (seal ring on all sides)
    ox = sw  # offset from die origin to user area
    oy = sw

    # Move all existing geometry by the seal ring offset
    top.transform(pya.Trans(ox, oy))

    # Draw seal ring as a frame around the full die
    # Outer boundary
    outer = pya.Box(0, 0, dw, dh)
    # Inner boundary (user area)
    inner = pya.Box(sw, sw, dw - sw, dh - sw)
    # Create ring as outer minus inner
    ring = pya.Region(outer) - pya.Region(inner)
    for poly in ring.each():
        top.shapes(li).insert(poly)

    print(f"Added seal ring: {seal_width}um wide on layer {seal_layer}/{seal_datatype}")
    print(f"Die: {die_w}x{die_h}um, User area offset: ({seal_width},{seal_width})um")

# Add ID cell if required (with correct bounding box for precheck QR code)
id_w = float(os.environ.get("ID_CELL_W_UM", "142.8"))
id_h = float(os.environ.get("ID_CELL_H_UM", "142.8"))
if id_cell_name:
    id_cell = layout.cell(id_cell_name)
    if id_cell is None:
        id_cell = layout.create_cell(id_cell_name)
    else:
        id_cell.clear()
    # Create a bounding box matching the precheck's QR code dimensions
    # exactly. The precheck asserts id_cell.bbox() == qrcode_cell.bbox().
    # Use Metal1 (34/0) as a placeholder since the QR code uses metal layers.
    m1_li = layout.layer(34, 0)
    iw = int(round(id_w / dbu))
    ih = int(round(id_h / dbu))
    id_cell.shapes(m1_li).insert(pya.Box(0, 0, iw, ih))
    # Place it in the top cell (fab precheck will replace contents)
    if not any(
        layout.cell(inst.cell_index).name == id_cell_name for inst in top.each_inst()
    ):
        top.insert(pya.CellInstArray(id_cell.cell_index(), pya.Trans()))
    print(f"Added ID cell: {id_cell_name} ({id_w}x{id_h}um)")

# Validate
final_bbox = top.bbox()
print(f"Final layout: {final_bbox.width()*dbu:.1f}x{final_bbox.height()*dbu:.1f}um")
print(f"Origin: ({final_bbox.left*dbu:.1f}, {final_bbox.bottom*dbu:.1f})")

# Count top-level cells
top_count = sum(1 for c in layout.each_cell() if c.is_top())
if top_count != 1:
    print(f"WARNING: {top_count} top-level cells (expected 1)")
else:
    print("OK: exactly 1 top-level cell")

layout.write(gds_file)
print(f"Wrote {gds_file}")
