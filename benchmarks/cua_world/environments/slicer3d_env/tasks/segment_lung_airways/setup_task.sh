#!/bin/bash
echo "=== Setting up Segment Lung Airways Task ==="

# Source utilities
source /workspace/scripts/task_utils.sh 2>/dev/null || true

# Record task start time (CRITICAL for anti-gaming)
date +%s > /tmp/task_start_time.txt
echo "Task start time: $(cat /tmp/task_start_time.txt)"

# ============================================================
# Prepare LIDC data
# ============================================================
LIDC_DIR="/home/ga/Documents/SlicerData/LIDC"
EXPORT_DIR="/home/ga/Documents/SlicerData/Exports"
PATIENT_ID="LIDC-IDRI-0001"

mkdir -p "$LIDC_DIR"
mkdir -p "$EXPORT_DIR"
chown -R ga:ga /home/ga/Documents/SlicerData

echo "Preparing LIDC chest CT data..."
/workspace/scripts/prepare_lidc_data.sh "$PATIENT_ID" 2>&1 || {
    echo "WARNING: LIDC data preparation had issues, continuing..."
}

# Get the patient ID that was actually used
if [ -f /tmp/lidc_patient_id ]; then
    PATIENT_ID=$(cat /tmp/lidc_patient_id)
fi

# prepare_lidc_data.sh writes the chest CT as a single NIfTI
# at LIDC/<PATIENT_ID>/<PATIENT_ID>_img.nii.gz (was a DICOM dir before
# the TCIA API broke; we now fetch from a HuggingFace mirror).
IMG_FILE="$LIDC_DIR/$PATIENT_ID/${PATIENT_ID}_img.nii.gz"
echo "Patient ID: $PATIENT_ID"
echo "Chest CT (NIfTI): $IMG_FILE"

if [ ! -s "$IMG_FILE" ]; then
    echo "ERROR: chest CT not found at $IMG_FILE"
    exit 1
fi
echo "CT file size: $(du -h "$IMG_FILE" | cut -f1)"

# ============================================================
# Record initial state for verification
# ============================================================
echo "Recording initial state..."

# Count existing segmentation files
INITIAL_SEG_COUNT=$(ls -1 "$EXPORT_DIR"/*.seg.nrrd "$EXPORT_DIR"/*.nrrd 2>/dev/null | wc -l || echo "0")
echo "$INITIAL_SEG_COUNT" > /tmp/initial_segmentation_count.txt

# Remove any previous airways segmentation (clean slate)
rm -f "$EXPORT_DIR/airways_segmentation.seg.nrrd" 2>/dev/null || true
rm -f "$EXPORT_DIR/airways*.nrrd" 2>/dev/null || true

# Save setup info
cat > /tmp/task_setup_info.json << EOF
{
    "patient_id": "$PATIENT_ID",
    "ct_file": "$IMG_FILE",
    "export_dir": "$EXPORT_DIR",
    "expected_output": "$EXPORT_DIR/airways_segmentation.seg.nrrd",
    "setup_timestamp": $(date +%s)
}
EOF

# ============================================================
# Kill any existing Slicer and launch fresh
# ============================================================
echo "Preparing 3D Slicer..."
pkill -f "Slicer" 2>/dev/null || true
sleep 2

# Ensure X display is available
export DISPLAY=:1
xhost +local: 2>/dev/null || true

# Launch Slicer with the chest-CT NIfTI pre-loaded via --python-script.
# Replaces the previous "launch empty + DICOM browser import" path which
# depended on the broken TCIA download.
cat > /tmp/load_lidc_ct.py << 'PYEOF'
import slicer
import os

img_file = os.environ.get("IMG_FILE")
print(f"Loading chest CT from NIfTI: {img_file}")

volume_node = slicer.util.loadVolume(img_file)
if volume_node is None:
    print(f"ERROR: slicer.util.loadVolume returned None for {img_file}")
else:
    # Lung window/level for airway visibility.
    displayNode = volume_node.GetDisplayNode()
    if displayNode:
        displayNode.SetAutoWindowLevel(False)
        displayNode.SetWindow(1500)
        displayNode.SetLevel(-500)
    # Set as background in slice views and reset.
    for color in ["Red", "Green", "Yellow"]:
        sw = slicer.app.layoutManager().sliceWidget(color)
        if sw is not None:
            sw.sliceLogic().GetSliceCompositeNode().SetBackgroundVolumeID(volume_node.GetID())
    slicer.util.resetSliceViews()
    print(f"SUCCESS: loaded {volume_node.GetName()} dims={volume_node.GetImageData().GetDimensions()}")
PYEOF

echo "Launching 3D Slicer with chest CT pre-loaded..."
pkill -f "Slicer" 2>/dev/null || true
sleep 2
sudo -u ga DISPLAY=:1 IMG_FILE="$IMG_FILE" /opt/Slicer/Slicer --python-script /tmp/load_lidc_ct.py > /tmp/slicer_launch.log 2>&1 &
wait_for_slicer 90

# ============================================================
# Take initial screenshot
# ============================================================
echo "Capturing initial screenshot..."
sleep 2
DISPLAY=:1 scrot /tmp/task_initial_state.png 2>/dev/null || \
    DISPLAY=:1 import -window root /tmp/task_initial_state.png 2>/dev/null || true

if [ -f /tmp/task_initial_state.png ]; then
    SIZE=$(stat -c %s /tmp/task_initial_state.png 2>/dev/null || echo "0")
    echo "Initial screenshot captured: ${SIZE} bytes"
else
    echo "WARNING: Could not capture initial screenshot"
fi

echo ""
echo "=== Task Setup Complete ==="
echo ""
echo "TASK: Segment the lung airways from the chest CT"
echo ""
echo "Instructions:"
echo "1. Open Segment Editor module"
echo "2. Create a segment named 'Airways'"
echo "3. Use Threshold effect (-1024 to -900 HU for air)"
echo "4. Use Islands effect to keep only the airway tree"
echo "5. Click 'Show 3D' to visualize"
echo "6. Save to: ~/Documents/SlicerData/Exports/airways_segmentation.seg.nrrd"
echo ""
echo "Expected output: Trachea and bronchi as a single connected structure"
echo "                 (NOT including external air around patient)"