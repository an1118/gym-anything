#!/bin/bash
echo "=== Exporting Count Lung Nodules Result ==="

source /workspace/scripts/task_utils.sh

LIDC_DIR="/home/ga/Documents/SlicerData/LIDC"
OUTPUT_FILE="/tmp/count_nodules_result.json"
FIDUCIAL_FILE="$LIDC_DIR/nodule_markers.mrk.json"

take_screenshot /tmp/nodule_final.png ga

SLICER_RUNNING=false
if is_slicer_running; then
    SLICER_RUNNING=true
fi

# Check fiducial file and count points
FIDUCIAL_EXISTS=false
FIDUCIAL_COUNT=0
if [ -f "$FIDUCIAL_FILE" ]; then
    FIDUCIAL_EXISTS=true
    FIDUCIAL_COUNT=$(python3 << PYEOF
import json
try:
    with open("$FIDUCIAL_FILE", 'r') as f:
        data = json.load(f)
    markups = data.get('markups', [])
    if markups:
        points = markups[0].get('controlPoints', [])
        print(len(points))
    else:
        print(0)
except:
    print(0)
PYEOF
)
fi

# Check for point markups in Slicer
POINT_COUNT_SLICER=0
if $SLICER_RUNNING; then
    # Capture via tempfile, not bash $() pipe — leaked --no-main-window
    # Slicer grandchild would otherwise hold the $() pipe open and deadlock.
    PCS_PY_FILE=$(mktemp /tmp/pcs_query.XXXXXX.py)
    cat > "$PCS_PY_FILE" << 'PCSPY'
import slicer
nodes = slicer.util.getNodesByClass('vtkMRMLMarkupsFiducialNode')
count = 0
for n in nodes:
    count += n.GetNumberOfControlPoints()
print(count)
PCSPY
    PCS_OUT_FILE=$(mktemp /tmp/pcs_out.XXXXXX.txt)
    timeout 30 sudo -u ga DISPLAY=:1 /opt/Slicer/Slicer --no-main-window --python-script "$PCS_PY_FILE" > "$PCS_OUT_FILE" 2>/dev/null </dev/null || true
    POINT_COUNT_SLICER=$(tail -1 "$PCS_OUT_FILE" 2>/dev/null || echo "0")
    rm -f "$PCS_PY_FILE" "$PCS_OUT_FILE"
fi

cat > "$OUTPUT_FILE" << EOF
{
    "slicer_running": $SLICER_RUNNING,
    "fiducial_file_exists": $FIDUCIAL_EXISTS,
    "fiducial_count_file": $FIDUCIAL_COUNT,
    "fiducial_count_slicer": ${POINT_COUNT_SLICER:-0},
    "screenshot_exists": $([ -f /tmp/nodule_final.png ] && echo "true" || echo "false")
}
EOF

echo "=== Export Complete ==="
cat "$OUTPUT_FILE"
