#!/bin/bash
echo "=== Setting up PET/CT Image Fusion task ==="

. /workspace/scripts/task_utils.sh 2>/dev/null || true

# Record task start time (for anti-gaming timestamp checks)
date +%s > /tmp/task_start_time.txt

PET_CT_DIR="/home/ga/DICOM/pet_ct"
EXPORT_DIR="/home/ga/DICOM/exports"

# Create directories
mkdir -p "$PET_CT_DIR"
mkdir -p "$EXPORT_DIR"

# Ensure export dir is empty to avoid stale outputs
rm -f "$EXPORT_DIR"/* 2>/dev/null || true

# Download real PET/CT sample dataset if not present. Previous version
# masked every failure with `|| true` and still announced "downloaded
# and extracted successfully" even when Rubo Medical served an HTML
# error page — leaving the task running with an empty PET_CT_DIR. Fail
# loud instead: check wget, check that the file is a real zip, check
# that unzip produced DICOMs, and abort on any of those.
if [ ! -f "$PET_CT_DIR/loaded.flag" ]; then
    echo "Downloading Rubo Medical clinical PET/CT sample dataset..."
    if ! wget -q "https://www.rubomedical.com/dicom_files/dicom_viewer_0006.zip" \
            -O /tmp/pet_ct.zip; then
        echo "ERROR: wget failed for PET/CT sample dataset." >&2
        exit 1
    fi
    if ! unzip -tq /tmp/pet_ct.zip >/dev/null 2>&1; then
        echo "ERROR: /tmp/pet_ct.zip is not a valid zip file (server likely" \
             "returned an HTML error page). Check network / URL validity." >&2
        rm -f /tmp/pet_ct.zip
        exit 1
    fi
    if ! unzip -q -o /tmp/pet_ct.zip -d "$PET_CT_DIR/"; then
        echo "ERROR: unzip of /tmp/pet_ct.zip into $PET_CT_DIR failed." >&2
        exit 1
    fi
    rm -f /tmp/pet_ct.zip
    # Sanity check: at least one DICOM-like file landed in PET_CT_DIR.
    if [ -z "$(find "$PET_CT_DIR" -type f \( -name '*.dcm' -o -name '*.DCM' \
                                              -o -name '*[0-9]' \) 2>/dev/null | head -1)" ]; then
        echo "ERROR: unzip succeeded but no DICOM files found in $PET_CT_DIR." >&2
        exit 1
    fi
    touch "$PET_CT_DIR/loaded.flag"
    echo "PET/CT data downloaded and extracted successfully."
fi

# Set correct permissions so the agent user can read/write
chown -R ga:ga "/home/ga/DICOM"
chmod -R 777 "$EXPORT_DIR"

# Ensure no existing instances are running
pkill -f "weasis" 2>/dev/null || true
sleep 2

# Start Weasis explicitly as the ga user
echo "Starting Weasis..."
launch_weasis_with_dicom "$PET_CT_DIR"

# Wait for Weasis window to appear
for i in {1..60}; do
    if DISPLAY=:1 wmctrl -l | grep -qi "weasis"; then
        echo "Weasis window detected."
        break
    fi
    sleep 1
done

# Dismiss any first-run dialogs natively
sleep 3
DISPLAY=:1 xdotool key Escape 2>/dev/null || true
sleep 0.5
DISPLAY=:1 xdotool key Return 2>/dev/null || true

# Maximize and focus the Weasis window for standard agent interaction
DISPLAY=:1 wmctrl -r "Weasis" -b add,maximized_vert,maximized_horz 2>/dev/null || true
DISPLAY=:1 wmctrl -a "Weasis" 2>/dev/null || true

# Wait for UI stabilization before the initial screenshot
sleep 2

# Take screenshot of initial state as proof of clean setup
echo "Capturing initial state..."
DISPLAY=:1 scrot /tmp/task_initial.png 2>/dev/null || \
    DISPLAY=:1 import -window root /tmp/task_initial.png 2>/dev/null || true

echo "=== Task setup complete ==="