#!/bin/bash
# Prepare AMOS 2022 abdominal CT data for AMOS-using tasks.
#
# Source: HuggingFace mirror `Angelou0516/amos22-ct-dataset` (200 train cases).
# Each case ships an image (`train/imagesTr/amos_NNNN.nii.gz`) and a
# ground-truth multi-organ segmentation (`train/labelsTr/amos_NNNN.nii.gz`)
# with the standard AMOS 2022 label dictionary verified to match
# expectations downstream (1=spleen, 6=liver, 8=aorta, etc.).
#
# Replaces the previous Zenodo download (24 GB amos22.zip, exceeded the
# 5-min container timeout, always fell back to synthetic). HuggingFace
# per-file fetch is ~46 MB image + ~190 KB label, finishes in seconds.
#
# This script downloads ONE case (default `amos_0001`) — every test task
# that uses AMOS data shares this single case ID, so subsequent reuses
# of the same container hit the early-return path.

set -e

AMOS_DIR="/home/ga/Documents/SlicerData/AMOS"
GROUND_TRUTH_DIR="/var/lib/slicer/ground_truth"
CASE_ID="${1:-amos_0001}"

HF_BASE="https://huggingface.co/datasets/Angelou0516/amos22-ct-dataset/resolve/main/train"
CT_FILE="$AMOS_DIR/${CASE_ID}.nii.gz"
LABEL_FILE="$GROUND_TRUTH_DIR/${CASE_ID}_labels.nii.gz"
GT_JSON="$GROUND_TRUTH_DIR/${CASE_ID}_aorta_gt.json"

echo "=== Preparing AMOS 2022 Abdominal CT Data ==="
echo "Case ID: $CASE_ID"
echo "Source: HuggingFace Angelou0516/amos22-ct-dataset"

mkdir -p "$AMOS_DIR" "$GROUND_TRUTH_DIR"

# ----------------------------------------------------------------------
# Skip everything if the case is already fully prepared (reused container).
# ----------------------------------------------------------------------
if [ -s "$CT_FILE" ] && [ -s "$LABEL_FILE" ] && [ -s "$GT_JSON" ]; then
    echo "AMOS data already prepared for $CASE_ID, skipping fetch"
    echo "$CASE_ID" > /tmp/amos_case_id
    exit 0
fi

# ----------------------------------------------------------------------
# Ensure Python deps for ground-truth computation. install_slicer.sh
# pre-installs nibabel/numpy at container build time, so this is a
# defensive retry only — no-op on a healthy image.
# ----------------------------------------------------------------------
pip3 install --break-system-packages -q numpy nibabel 2>/dev/null || true

# ----------------------------------------------------------------------
# Fetch the CT volume + label file. Atomic temp-then-mv (within /tmp on
# same container fs as the destination) so concurrent readers don't
# observe partial files.
# ----------------------------------------------------------------------
fetch_one() {
    local relpath="$1"            # e.g. imagesTr/amos_0001.nii.gz
    local dest="$2"
    local url="$HF_BASE/${relpath}"

    if [ -s "$dest" ]; then
        echo "  [exists] $dest"
        return 0
    fi
    local tmp
    tmp=$(mktemp /tmp/amos.XXXXXX.nii.gz)
    echo "  [fetch] $relpath ..."
    if ! curl -L -f -sS --max-time 120 -o "$tmp" "$url"; then
        rm -f "$tmp"
        echo "ERROR: failed to download $url"
        return 1
    fi
    local first2
    first2=$(head -c 2 "$tmp" | od -An -tx1 | tr -d ' \n')
    if [ "$first2" != "1f8b" ]; then
        rm -f "$tmp"
        echo "ERROR: $url did not return a gzipped NIfTI (first bytes: $first2)"
        return 1
    fi
    mv "$tmp" "$dest"
    echo "  [done] $dest ($(stat -c%s "$dest") bytes)"
}

fetch_one "imagesTr/${CASE_ID}.nii.gz" "$CT_FILE"
fetch_one "labelsTr/${CASE_ID}.nii.gz" "$LABEL_FILE"

# ----------------------------------------------------------------------
# Compute aorta ground-truth from the real label volume. This logic is
# unchanged from the original script's "real-data" branch — same script
# now always runs because we always download real data.
# ----------------------------------------------------------------------
export CASE_ID GROUND_TRUTH_DIR
python3 << 'PYEOF'
import os, sys, json
import numpy as np
import nibabel as nib

case_id = os.environ.get("CASE_ID", "amos_0001")
gt_dir = os.environ.get("GROUND_TRUTH_DIR", "/var/lib/slicer/ground_truth")
label_path = os.path.join(gt_dir, f"{case_id}_labels.nii.gz")

seg = nib.load(label_path)
data = seg.get_fdata().astype(np.int32)
spacing = seg.header.get_zooms()[:3]

# AMOS 2022 spec: label 8 = aorta. Original script also accepted 10 as a
# fallback (synthetic data used 10), but real AMOS uses 8.
aorta_label = None
for candidate in [8, 10]:
    if np.sum(data == candidate) > 100:
        aorta_label = candidate
        break
if aorta_label is None:
    print("ERROR: No aorta found in label volume")
    sys.exit(1)

aorta = (data == aorta_label)
max_diameter = 0.0
max_slice_idx = 0
max_slice_center = [0.0, 0.0, 0.0]
for z in range(aorta.shape[2]):
    sl = aorta[:, :, z]
    if not np.any(sl):
        continue
    area = np.sum(sl) * float(spacing[0]) * float(spacing[1])
    diam = 2.0 * np.sqrt(area / np.pi)
    if diam > max_diameter:
        max_diameter = diam
        max_slice_idx = z
        rows = np.any(sl, axis=1); cols = np.any(sl, axis=0)
        r0, r1 = np.where(rows)[0][[0, -1]]
        c0, c1 = np.where(cols)[0][[0, -1]]
        max_slice_center = [
            float((r0 + r1) / 2 * spacing[0]),
            float((c0 + c1) / 2 * spacing[1]),
            float(z * spacing[2]),
        ]

classification = "Normal" if max_diameter < 30 else ("Ectatic" if max_diameter < 35 else "Aneurysmal")
total_z = aorta.shape[2] * float(spacing[2])
zf = max_slice_idx * float(spacing[2]) / total_z if total_z > 0 else 0.5
levels = [(0.2, "L4"), (0.4, "L3"), (0.6, "L2"), (0.8, "L1")]
vertebral_level = "T12"
for thresh, lvl in levels:
    if zf < thresh:
        vertebral_level = lvl
        break

gt_data = {
    "case_id": case_id, "aorta_label": int(aorta_label),
    "max_diameter_mm": float(round(max_diameter, 2)),
    "max_slice_index": int(max_slice_idx),
    "max_slice_center_mm": max_slice_center,
    "classification": classification,
    "approximate_vertebral_level": vertebral_level,
    "ct_shape": list(data.shape),
    "voxel_spacing_mm": [float(s) for s in spacing],
    "total_aorta_voxels": int(np.sum(aorta)),
    "aorta_extent_slices": int(np.sum(np.any(aorta, axis=(0, 1)))),
}
gt_path = os.path.join(gt_dir, f"{case_id}_aorta_gt.json")
with open(gt_path, "w") as f:
    json.dump(gt_data, f, indent=2)
print(f"Ground truth saved: {gt_path}")
print(f"  Diameter: {gt_data['max_diameter_mm']:.1f} mm, Class: {gt_data['classification']}")
PYEOF

# Permissions + handoff
chown -R ga:ga "$AMOS_DIR" 2>/dev/null || true
chmod -R 755 "$AMOS_DIR" 2>/dev/null || true
chmod 700 "$GROUND_TRUTH_DIR" 2>/dev/null || true
echo "$CASE_ID" > /tmp/amos_case_id

echo ""
echo "=== Abdominal CT Data Preparation Complete ==="
echo "Case ID: $CASE_ID"
echo "CT volume: $CT_FILE"
echo "Labels: $LABEL_FILE"
