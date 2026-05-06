#!/bin/bash
# Synthetic _warmup task: launch the bare Fiji UI with no fixture so the
# v3 skill pipeline planner can take a screenshot of an idle main window.
# Mirrors the pattern documented in preprocess/skill-pipeline/v3/README.md.
set -e

echo "=== Setting up _warmup (Fiji idle launch, no fixture) ==="

# Record a start timestamp so any common post-task hooks have something
# to read; the warmup verifier ignores it but absent files cause warnings.
date +%s > /tmp/task_start_time

# Launch Fiji using the standard launcher set up by setup_fiji.sh.
# Run as the ga user so the X11/DBus session matches.
if ! pgrep -f "fiji\|ImageJ" >/dev/null; then
    echo "Launching Fiji..."
    if [ -f "/home/ga/launch_fiji.sh" ]; then
        su - ga -c "DISPLAY=:1 /home/ga/launch_fiji.sh" > /dev/null 2>&1 &
    else
        su - ga -c "DISPLAY=:1 fiji" > /dev/null 2>&1 &
    fi

    # Wait up to ~30s for the main window to appear.
    for i in {1..30}; do
        if DISPLAY=:1 wmctrl -l 2>/dev/null | grep -iE 'fiji|imagej' > /dev/null; then
            echo "Fiji window detected"
            break
        fi
        sleep 1
    done
else
    echo "Fiji already running"
fi

# Dismiss GNOME Activities Overview and modal dialogs, then raise+maximize
# the actual Fiji window. Fresh GNOME sessions land in Activities Overview
# by default — without this dismiss, any screenshot captures workspace
# thumbnails + a "Type to search" bar instead of the real application UI.
# Two Escapes (with delays for the exit animation) + raise-by-window-id +
# maximize. Mirrors the pattern in scripts/run-gym-anything/verify_setup.py.
sleep 1

# Resolve Fiji's window id via case-insensitive grep on wmctrl -l.
WIN_ID=$(DISPLAY=:1 wmctrl -l 2>/dev/null | grep -iE 'fiji|imagej' | head -1 | awk '{print $1}')

if [ -n "$WIN_ID" ]; then
    DISPLAY=:1 xdotool key Escape 2>/dev/null || true
    sleep 1
    DISPLAY=:1 xdotool key Escape 2>/dev/null || true
    sleep 1
    DISPLAY=:1 wmctrl -i -a "$WIN_ID" 2>/dev/null || true
    sleep 0.5
    DISPLAY=:1 wmctrl -i -r "$WIN_ID" -b add,maximized_vert,maximized_horz 2>/dev/null || true
    sleep 1
    # Final Escape in case wmctrl -a re-triggered Overview.
    DISPLAY=:1 xdotool key Escape 2>/dev/null || true
    sleep 0.5
else
    # Fiji window not found — at least dismiss Overview so the screenshot
    # doesn't capture workspace thumbnails.
    DISPLAY=:1 xdotool key Escape 2>/dev/null || true
    sleep 1
    DISPLAY=:1 xdotool key Escape 2>/dev/null || true
    sleep 0.5
fi

echo "=== _warmup setup complete ==="
