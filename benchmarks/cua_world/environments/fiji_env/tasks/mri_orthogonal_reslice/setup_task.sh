#!/bin/bash
set -e
echo "=== Setting up MRI Orthogonal Reslice Task ==="

# 1. Record task start time for anti-gaming verification
date +%s > /tmp/task_start_time.txt

# 2. Create directories
mkdir -p /home/ga/Fiji_Data/raw/t1-head
mkdir -p /home/ga/Fiji_Data/results/reslice
chown -R ga:ga /home/ga/Fiji_Data

# 3. Clean up previous results
rm -f /home/ga/Fiji_Data/results/reslice/*

# 4. Prepare the T1 Head dataset
# imagej.net's t1-head-raw.zip now ships JeffT1_le.tif (a multi-page TIFF)
# rather than a .raw file. We copy it through PIL to strip any resolution
# metadata, so the agent starts with an uncalibrated TIFF as the task
# requires (the agent must set the calibration as part of the workflow).
if [ ! -f "/home/ga/Fiji_Data/raw/t1-head/t1-head.tif" ]; then
    echo "Downloading and preparing T1 Head data..."

    cd /tmp
    wget -q --tries=5 --timeout=60 \
        "https://imagej.net/ij/images/t1-head-raw.zip" -O t1-head-raw.zip
    unzip -q -o t1-head-raw.zip

    python3 -c "
from PIL import Image
import os

src = 'JeffT1_le.tif'
if not os.path.exists(src):
    print(f'Error: {src} not found in zip; zip contents may have changed again')
    raise SystemExit(1)

img = Image.open(src)
frames = []
try:
    while True:
        frames.append(img.copy())
        img.seek(img.tell() + 1)
except EOFError:
    pass

# Re-save without resolution metadata so the agent must add it.
frames[0].save(
    '/home/ga/Fiji_Data/raw/t1-head/t1-head.tif',
    save_all=True, append_images=frames[1:],
)
print(f'Saved uncalibrated TIFF: {len(frames)} pages')
"
    rm -f JeffT1_le.tif t1-head-raw.zip
    chown ga:ga /home/ga/Fiji_Data/raw/t1-head/t1-head.tif
fi

# 5. Launch Fiji
echo "Launching Fiji..."
if ! pgrep -f "fiji" > /dev/null && ! pgrep -f "ImageJ" > /dev/null; then
    su - ga -c "DISPLAY=:1 /home/ga/launch_fiji.sh" &
    sleep 10
fi

# 6. Wait for window and maximize
for i in {1..30}; do
    if DISPLAY=:1 wmctrl -l | grep -i "Fiji\|ImageJ"; then
        echo "Fiji window detected."
        DISPLAY=:1 wmctrl -r "Fiji" -b add,maximized_vert,maximized_horz 2>/dev/null || \
        DISPLAY=:1 wmctrl -r "ImageJ" -b add,maximized_vert,maximized_horz 2>/dev/null || true
        break
    fi
    sleep 1
done

# 7. Open the image for the agent (optional convenience, but good for starting state)
# We use xdotool to open the file via the menu or command line if possible.
# Simpler: Just rely on agent to open it, but let's pre-load it for better UX if possible.
# Actually, the task desc says "Open the image...". We will leave it to the agent or 
# we can use the 'fiji <file>' command. Let's restart fiji with the file to be helpful.
pkill -f "fiji" || true
pkill -f "ImageJ" || true
sleep 2
su - ga -c "DISPLAY=:1 /home/ga/launch_fiji.sh /home/ga/Fiji_Data/raw/t1-head/t1-head.tif" &
sleep 10

# Maximize again
DISPLAY=:1 wmctrl -r "t1-head.tif" -b add,maximized_vert,maximized_horz 2>/dev/null || true

# 8. Capture initial screenshot
echo "Capturing initial state..."
DISPLAY=:1 scrot /tmp/task_initial.png 2>/dev/null || true

echo "=== Setup complete ==="