#!/bin/bash
# set -euo pipefail

echo "=== Installing Weasis DICOM Viewer and related packages ==="

# Update package manager
export DEBIAN_FRONTEND=noninteractive
apt-get update

# Install Weasis directly from upstream .deb.
#
# We previously tried `snap install weasis` first and fell back to the
# .deb on failure, but snap fundamentally does not work inside
# sysbox-runc: snap packages are squashfs images, and sysbox's user
# namespacing blocks squashfs mounts with
#
#   error: system does not fully support snapd: cannot mount squashfs
#          image using "squashfs"
#
# That's a permanent incompatibility, not a timing issue. The snap
# branch therefore always fails, always falls through, and adds 30+
# seconds + misleading log noise to every cold container start. Go
# straight to the .deb.
WEASIS_VERSION="4.5.1"
echo "Installing Weasis ${WEASIS_VERSION} from upstream .deb..."
wget -q --timeout=60 \
    "https://github.com/nroduit/Weasis/releases/download/v${WEASIS_VERSION}/weasis_${WEASIS_VERSION}-1_amd64.deb" \
    -O /tmp/weasis.deb
dpkg -i /tmp/weasis.deb || apt-get install -f -y
rm -f /tmp/weasis.deb

# The .deb installs the binary at /opt/weasis/bin/Weasis (capital W,
# outside any PATH dir). Task scripts call `command -v weasis` — link
# a lowercase shim into /usr/local/bin so those checks succeed.
ln -sf /opt/weasis/bin/Weasis /usr/local/bin/weasis

# Fail the hook loudly if the install didn't actually produce a working
# binary. Without this, the script would otherwise silently succeed,
# every task's setup_task.sh would be the first thing to notice, and
# every task in the domain would score 0 for reasons unrelated to the
# agent's behavior.
if ! command -v weasis >/dev/null; then
    echo "FATAL: Weasis install did not produce /usr/local/bin/weasis" >&2
    exit 1
fi
echo "Weasis binary: $(command -v weasis) -> $(readlink -f "$(command -v weasis)")"

# Install GUI automation tools
echo "Installing automation tools..."
apt-get install -y \
    xdotool \
    wmctrl \
    x11-utils \
    xclip \
    scrot \
    imagemagick

# Install Python libraries for verification
echo "Installing Python libraries..."
apt-get install -y \
    python3-pip \
    python3-dev

# Ubuntu 24.04 ships Python 3.12 with PEP 668 enabled, so pip into the
# system Python requires --break-system-packages. Without this flag pip
# silently fails and every task that synth-generates DICOM via pydicom
# crashes at setup (activate_mpr_export, probe_pixel_density, etc.).
#
# We prefer apt-packaged versions where they exist (faster cold start,
# no PEP-668 dance, matches what the Dockerfile already does for
# numpy/pillow/scipy) and only fall back to pip for pydicom, which
# isn't packaged in the default Ubuntu repos.
apt-get install -y \
    python3-opencv
pip3 install --no-cache-dir --break-system-packages \
    pydicom

# Install network tools
echo "Installing network tools..."
apt-get install -y \
    curl \
    wget \
    unzip

# Install DICOM tools
echo "Installing DICOM tools..."
apt-get install -y \
    dcmtk || echo "dcmtk not available, skipping"

# Clean up package cache
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "=== Weasis DICOM Viewer installation completed ==="
