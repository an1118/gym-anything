#!/bin/bash
echo "=== Setting up dicomize_clinical_photo task ==="

source /workspace/scripts/task_utils.sh

# Record task start time
date +%s > /tmp/task_start_time.txt

# Directories
DESKTOP_DIR="/home/ga/Desktop"
EXPORT_DIR="/home/ga/DICOM/exports"
PHOTO_PATH="$DESKTOP_DIR/clinical_photo.jpg"

mkdir -p "$EXPORT_DIR"
chown ga:ga "$EXPORT_DIR"
chmod 777 "$EXPORT_DIR"

# Clean up any existing exported DICOM files to ensure a fresh state
rm -f "$EXPORT_DIR"/*.dcm 2>/dev/null || true
rm -f "$EXPORT_DIR"/*.DCM 2>/dev/null || true

# Download a real clinical photograph (Melanoma) from Wikimedia Commons.
# If the fetch fails we fail the setup loudly rather than fall back to a
# synthetic stand-in — the task is graded against the appearance of a
# real clinical photo and a fallback defeats that.
echo "Fetching clinical photograph..."
if ! wget -q -O "$PHOTO_PATH" "https://upload.wikimedia.org/wikipedia/commons/4/4d/Melanoma.jpg"; then
    echo "ERROR: wget failed for clinical photograph." >&2
    exit 1
fi
if [ ! -s "$PHOTO_PATH" ]; then
    echo "ERROR: clinical photograph downloaded but is empty." >&2
    exit 1
fi

chown ga:ga "$PHOTO_PATH"
chmod 644 "$PHOTO_PATH"

# Ensure Weasis is stopped before starting fresh
pkill -f weasis 2>/dev/null || true
sleep 2

# Launch Weasis without a pre-loaded DICOM file (agent must import)
echo "Launching Weasis..."
launch_weasis_with_dicom
sleep 8

# Wait for Weasis UI to appear
wait_for_weasis 60

# Maximize Weasis Window
WID=$(DISPLAY=:1 wmctrl -l | grep -i "weasis" | head -1 | awk '{print $1}')
if [ -n "$WID" ]; then
    DISPLAY=:1 wmctrl -ir "$WID" -b add,maximized_vert,maximized_horz 2>/dev/null || true
    DISPLAY=:1 wmctrl -ia "$WID" 2>/dev/null || true
fi

# Dismiss first-run dialog if it appears
sleep 2
dismiss_first_run_dialog
sleep 2

# Take initial screenshot
take_screenshot /tmp/task_initial.png

echo "=== Task setup complete ==="
echo "Clinical photo ready at: $PHOTO_PATH"