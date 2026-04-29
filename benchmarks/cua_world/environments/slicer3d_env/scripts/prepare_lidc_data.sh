#!/bin/bash
# Prepare LIDC-IDRI chest CT data for LIDC-using tasks.
#
# Source: HuggingFace mirror `hourouu/LIDC_IDRI_PROCESSED` (1010 patients).
# Per case ships:
#   - images/<PATIENT_ID>_img.nii.gz   (real chest CT, ~36 MB)
#   - masks/<PATIENT_ID>_msk.nii.gz    (binary nodule mask, ~500 KB)
#
# Replaces the previous TCIA REST API download which has been broken
# (NBIA-API returns 500 / HTTP hangs). The HuggingFace per-file fetch is
# ~36 MB image + ~500 KB mask, finishes in seconds. Trade-off: format
# is single NIfTI rather than a DICOM directory, and per-nodule attributes
# (sphericity, malignancy, etc.) are lost — only a binary nodule mask
# remains. None of the current LIDC-using tasks rely on per-nodule
# attributes; they all just need a chest CT to navigate and measure.
#
# Output paths:
#   /home/ga/Documents/SlicerData/LIDC/<PATIENT_ID>/<PATIENT_ID>_img.nii.gz
#   /home/ga/Documents/SlicerData/LIDC/<PATIENT_ID>/<PATIENT_ID>_msk.nii.gz
#   /var/lib/slicer/ground_truth/<PATIENT_ID>_nodules.json   (derived from mask)

set -eo pipefail

LIDC_DIR="/home/ga/Documents/SlicerData/LIDC"
GROUND_TRUTH_DIR="/var/lib/slicer/ground_truth"
PATIENT_ID="${1:-LIDC-IDRI-0001}"

HF_BASE="https://huggingface.co/datasets/hourouu/LIDC_IDRI_PROCESSED/resolve/main"
CASE_DIR="$LIDC_DIR/$PATIENT_ID"
IMG_FILE="$CASE_DIR/${PATIENT_ID}_img.nii.gz"
MSK_FILE="$CASE_DIR/${PATIENT_ID}_msk.nii.gz"
GT_JSON="$GROUND_TRUTH_DIR/${PATIENT_ID}_nodules.json"

echo "=== Preparing LIDC-IDRI Chest CT Data ==="
echo "Patient ID: $PATIENT_ID"
echo "Source: HuggingFace hourouu/LIDC_IDRI_PROCESSED"

mkdir -p "$CASE_DIR" "$GROUND_TRUTH_DIR"

# ----------------------------------------------------------------------
# Skip everything if already prepared (reused container).
# ----------------------------------------------------------------------
if [ -s "$IMG_FILE" ] && [ -s "$MSK_FILE" ] && [ -s "$GT_JSON" ]; then
    echo "LIDC data already prepared for $PATIENT_ID, skipping fetch"
    echo "$PATIENT_ID" > /tmp/lidc_patient_id
    exit 0
fi

# Defensive: pip deps for ground-truth computation.
pip3 install --break-system-packages -q numpy nibabel 2>/dev/null || true

# ----------------------------------------------------------------------
# Fetch image + mask from HF. Atomic temp-then-mv (within /tmp on same
# container fs as the destination) so concurrent readers don't observe
# partial files.
# ----------------------------------------------------------------------
fetch_one() {
    local hf_path="$1"            # e.g. images/LIDC-IDRI-0001_img.nii.gz
    local dest="$2"
    local url="$HF_BASE/${hf_path}"

    if [ -s "$dest" ]; then
        echo "  [exists] $dest"
        return 0
    fi
    local tmp
    tmp=$(mktemp /tmp/lidc.XXXXXX.nii.gz)
    echo "  [fetch] $hf_path ..."
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

fetch_one "images/${PATIENT_ID}_img.nii.gz" "$IMG_FILE"
fetch_one "masks/${PATIENT_ID}_msk.nii.gz" "$MSK_FILE"

# ----------------------------------------------------------------------
# Compute nodule ground truth from the binary mask.
# We only have a binary mask (1 = nodule), not per-nodule attributes,
# so the JSON we emit is reduced from the original (no per-reader counts,
# no spiculation, no malignancy). Tasks needing those attributes would
# need a richer source — none of the current LIDC tasks do.
# ----------------------------------------------------------------------
PATIENT_ID_PY="$PATIENT_ID" \
GT_DIR_PY="$GROUND_TRUTH_DIR" \
MSK_PY="$MSK_FILE" \
python3 << 'PYEOF'
import json, os
import nibabel as nib
import numpy as np
from scipy import ndimage

patient_id = os.environ["PATIENT_ID_PY"]
gt_dir = os.environ["GT_DIR_PY"]
msk_path = os.environ["MSK_PY"]

img = nib.load(msk_path)
data = img.get_fdata().astype(np.uint8)
spacing = [float(s) for s in img.header.get_zooms()[:3]]
voxel_volume_mm3 = float(np.prod(spacing))

# Connected-component label each nodule blob.
binary = (data > 0).astype(np.uint8)
labeled, n_blobs = ndimage.label(binary)

nodules = []
for i in range(1, n_blobs + 1):
    blob = (labeled == i)
    voxels = int(blob.sum())
    if voxels < 3:        # ignore tiny noise
        continue
    coords = np.argwhere(blob)
    centroid_vox = coords.mean(axis=0)
    centroid_mm = [float(centroid_vox[k] * spacing[k]) for k in range(3)]
    diameter_mm = 2 * (3 * voxels * voxel_volume_mm3 / (4 * np.pi)) ** (1.0 / 3.0)
    nodules.append({
        "voxels": voxels,
        "centroid_xyz_mm": centroid_mm,
        "approx_diameter_mm": float(round(diameter_mm, 2)),
    })

# Filter to "significant" nodules (≥ 3 mm) and sort by size.
significant = sorted(
    [n for n in nodules if n["approx_diameter_mm"] >= 3.0],
    key=lambda n: -n["voxels"],
)

gt = {
    "patient_id": patient_id,
    "voxel_spacing_mm": spacing,
    "voxel_volume_mm3": voxel_volume_mm3,
    "shape": list(data.shape),
    "total_nodule_voxels": int(binary.sum()),
    "total_nodule_volume_mm3": float(binary.sum() * voxel_volume_mm3),
    "blob_count_all": len(nodules),
    "significant_nodules": significant,
    "minimum_diameter_mm": 3.0,
    "source_note": "Binary mask only (no per-nodule attributes). Derived from "
                   "hourouu/LIDC_IDRI_PROCESSED on HuggingFace.",
}
gt_path = os.path.join(gt_dir, f"{patient_id}_nodules.json")
with open(gt_path, "w") as f:
    json.dump(gt, f, indent=2)
print(f"Ground truth saved: {gt_path}")
print(f"  Significant (≥3mm) nodules: {len(significant)}")
print(f"  Total mask volume: {gt['total_nodule_volume_mm3']:.1f} mm³")
PYEOF

# Permissions + handoff
chown -R ga:ga "$LIDC_DIR" 2>/dev/null || true
chmod -R 755 "$LIDC_DIR" 2>/dev/null || true
chmod 700 "$GROUND_TRUTH_DIR" 2>/dev/null || true
echo "$PATIENT_ID" > /tmp/lidc_patient_id

echo ""
echo "=== LIDC Data Preparation Complete ==="
echo "Patient: $PATIENT_ID"
echo "CT volume:   $IMG_FILE"
echo "Nodule mask: $MSK_FILE"
