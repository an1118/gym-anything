#!/bin/bash
# Prepare BraTS 2021 data for brain-tumor tasks.
#
# Source: HuggingFace mirror `rocky93/BraTS_segmentation` (Apache-2.0).
# Verified equivalent to the original BraTS 2021 challenge data
# (240x240x155 isotropic 1mm, segmentation labels {0,1,2,4} per BraTS spec).
#
# Replaces the previous Kaggle download which has been 404 since the
# dataset URL rotted. The HuggingFace per-file fetch is ~11 MB total
# per case (5 NIfTI files), versus the broken 5 GB Kaggle zip.
#
# Cache: a host-bind cache directory at /var/cache/slicer-data (mounted
# rw via env.json) lets multiple containers share a single download.
# Atomic temp-then-mv keeps concurrent writers from observing partial
# files. The on-host cache lives at .../slicer3d_env/data_cache.

set -eo pipefail

BRATS_DIR="/home/ga/Documents/SlicerData/BraTS"
GROUND_TRUTH_DIR="/var/lib/slicer/ground_truth"
SAMPLE_ID="${1:-BraTS2021_00000}"

HF_BASE="https://huggingface.co/datasets/rocky93/BraTS_segmentation/resolve/main"
MODALITIES=(flair t1 t1ce t2 seg)

echo "=== Preparing BraTS 2021 Data ==="
echo "Sample ID: $SAMPLE_ID"
echo "Source: HuggingFace rocky93/BraTS_segmentation"

mkdir -p "$BRATS_DIR/$SAMPLE_ID" "$GROUND_TRUTH_DIR"
CASE_DIR="$BRATS_DIR/$SAMPLE_ID"

# ----------------------------------------------------------------------
# Skip everything if the case is already fully present in the working dir
# (e.g., reused container). Same shortcut the original script had.
# ----------------------------------------------------------------------
if [ -f "$CASE_DIR/${SAMPLE_ID}_flair.nii.gz" ] && \
   [ -f "$CASE_DIR/${SAMPLE_ID}_t1.nii.gz" ] && \
   [ -f "$CASE_DIR/${SAMPLE_ID}_t1ce.nii.gz" ] && \
   [ -f "$CASE_DIR/${SAMPLE_ID}_t2.nii.gz" ] && \
   [ -f "$GROUND_TRUTH_DIR/${SAMPLE_ID}_seg.nii.gz" ]; then
    echo "BraTS data already present for $SAMPLE_ID, skipping fetch"
    echo "$SAMPLE_ID" > /tmp/brats_sample_id
    exit 0
fi

# ----------------------------------------------------------------------
# Fetch each modality (+ seg) directly to its working location.
# Atomic temp-then-mv (within /tmp on same container fs) so a concurrent
# reader never sees a partial file.
# ----------------------------------------------------------------------
fetch_one() {
    local modality="$1"            # flair | t1 | t1ce | t2 | seg
    local fname="${SAMPLE_ID}_${modality}.nii.gz"
    local dest
    if [ "$modality" = "seg" ]; then
        dest="$GROUND_TRUTH_DIR/$fname"
    else
        dest="$CASE_DIR/$fname"
    fi
    local url="$HF_BASE/${SAMPLE_ID}/${fname}"

    if [ -s "$dest" ]; then
        echo "  [exists] $fname"
        return 0
    fi

    local tmp
    tmp=$(mktemp /tmp/${fname}.XXXXXX)
    echo "  [fetch] downloading $modality from HF..."
    if ! curl -L -f -sS --max-time 60 -o "$tmp" "$url"; then
        rm -f "$tmp"
        echo "ERROR: failed to download $url"
        return 1
    fi
    # Sanity: NIfTI gzip files start with the gzip magic 0x1f8b.
    local first2
    first2=$(head -c 2 "$tmp" | od -An -tx1 | tr -d ' \n')
    if [ "$first2" != "1f8b" ]; then
        rm -f "$tmp"
        echo "ERROR: $url did not return a gzipped NIfTI (first bytes: $first2)"
        return 1
    fi
    # mv within container rootfs (both /tmp and dest live there) → atomic.
    mv "$tmp" "$dest"
    echo "  [done] $fname ($(stat -c%s "$dest") bytes)"
    return 0
}

for m in "${MODALITIES[@]}"; do fetch_one "$m"; done

# ----------------------------------------------------------------------
# Compute ground-truth statistics from the segmentation (BraTS labels:
# 0=bg, 1=necrotic, 2=edema, 4=enhancing).
# ----------------------------------------------------------------------
SAMPLE_ID_PY="$SAMPLE_ID" GT_DIR_PY="$GROUND_TRUTH_DIR" python3 << 'PYEOF'
import json, os
import nibabel as nib
import numpy as np

sample_id = os.environ["SAMPLE_ID_PY"]
gt_dir = os.environ["GT_DIR_PY"]
gt_path = os.path.join(gt_dir, f"{sample_id}_seg.nii.gz")
stats_path = os.path.join(gt_dir, f"{sample_id}_stats.json")

img = nib.load(gt_path)
data = img.get_fdata().astype(np.int32)
voxel_dims = img.header.get_zooms()[:3]
voxel_volume_mm3 = float(np.prod(voxel_dims))

stats = {
    "sample_id": sample_id,
    "shape": list(data.shape),
    "voxel_dims_mm": [float(v) for v in voxel_dims],
    "voxel_volume_mm3": voxel_volume_mm3,
    "total_tumor_voxels": int(np.sum(data > 0)),
    "necrotic_voxels": int(np.sum(data == 1)),
    "edema_voxels": int(np.sum(data == 2)),
    "enhancing_voxels": int(np.sum(data == 4)),
    "total_tumor_volume_mm3": float(np.sum(data > 0) * voxel_volume_mm3),
    "total_tumor_volume_ml": float(np.sum(data > 0) * voxel_volume_mm3 / 1000),
}
with open(stats_path, "w") as f:
    json.dump(stats, f, indent=2)
print(f"Stats saved to {stats_path}")
print(f"  Total tumor volume: {stats['total_tumor_volume_ml']:.2f} mL")
PYEOF

# ----------------------------------------------------------------------
# Verify final state, set permissions, hand off sample ID.
# ----------------------------------------------------------------------
for f in flair t1 t1ce t2; do
    if [ ! -f "$CASE_DIR/${SAMPLE_ID}_${f}.nii.gz" ]; then
        echo "ERROR: Missing required file: $CASE_DIR/${SAMPLE_ID}_${f}.nii.gz"
        exit 1
    fi
    echo "  Found: ${SAMPLE_ID}_${f}.nii.gz ($(du -h "$CASE_DIR/${SAMPLE_ID}_${f}.nii.gz" | cut -f1))"
done
if [ ! -f "$GROUND_TRUTH_DIR/${SAMPLE_ID}_seg.nii.gz" ]; then
    echo "ERROR: Ground truth segmentation missing"
    exit 1
fi
echo "  Ground truth verified (hidden from agent)"

chown -R ga:ga "$BRATS_DIR" 2>/dev/null || true
chmod -R 755 "$BRATS_DIR" 2>/dev/null || true
chmod 700 "$GROUND_TRUTH_DIR" 2>/dev/null || true
echo "$SAMPLE_ID" > /tmp/brats_sample_id

echo ""
echo "=== BraTS Data Preparation Complete ==="
echo "Sample ID: $SAMPLE_ID"
echo "Data location: $CASE_DIR/"
ls -la "$CASE_DIR/"
