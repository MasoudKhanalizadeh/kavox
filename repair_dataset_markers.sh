#!/usr/bin/env bash

# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Masoud Khanalizadeh Imani

# Repair only initialization markers for existing exact-size datasets.
# Dataset bytes are read at three sample regions but never written by this script.

set -u
set -o pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DATASET_SPEC_LIB="$ROOT_DIR/lib/dataset_spec.sh"
[[ -r "$DATASET_SPEC_LIB" ]] || { echo "ERROR: dataset specification library is missing" >&2; exit 1; }
# shellcheck source=lib/dataset_spec.sh
source "$DATASET_SPEC_LIB"

MOUNT_PATHS_ARGUMENT="${1:-}"
DATASET_SIZE_INPUT="${2:-1TiB}"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

kavox_configure_dataset_spec "$DATASET_SIZE_INPUT" || {
    kavox_dataset_size_help >&2
    fail "invalid dataset size: $DATASET_SIZE_INPUT"
}
kavox_configure_sample_regions || fail "cannot calculate aligned sample regions"
DATA_SIZE=$DATASET_SIZE_BYTES
SAMPLE_SIZE=$DATASET_SAMPLE_SIZE_BYTES
MIDDLE_OFFSET=$DATASET_MIDDLE_OFFSET_BYTES
END_OFFSET=$DATASET_END_OFFSET_BYTES

MOUNT_PATHS=()
if [[ -n "$MOUNT_PATHS_ARGUMENT" ]]; then
    IFS=',' read -r -a MOUNT_PATHS <<< "$MOUNT_PATHS_ARGUMENT"
else
    read -r -p "Number of LUNs [1]: " LUN_COUNT
    LUN_COUNT="${LUN_COUNT:-1}"
    [[ "$LUN_COUNT" =~ ^[1-9][0-9]*$ ]] || fail "enter a positive whole number"
    for ((INDEX=1; INDEX<=LUN_COUNT; INDEX++)); do
        if (( LUN_COUNT == 1 )); then
            read -r -p "Mount path for LUN 1 [/mnt/storage]: " MOUNT_PATH
            MOUNT_PATH="${MOUNT_PATH:-/mnt/storage}"
        else
            read -r -p "Mount path for LUN $INDEX: " MOUNT_PATH
        fi
        MOUNT_PATHS+=("$MOUNT_PATH")
    done
fi

for REQUIRED_COMMAND in fio mountpoint findmnt stat; do
    command -v "$REQUIRED_COMMAND" >/dev/null 2>&1 || fail "$REQUIRED_COMMAND is unavailable"
done

DATA_FILES=()
FILESYSTEM_UUIDS=()
LUN_LABELS=()
REPAIR_INDEXES=()
for ((INDEX=0; INDEX<${#MOUNT_PATHS[@]}; INDEX++)); do
    MOUNT_PATH="${MOUNT_PATHS[$INDEX]}"
    while [[ "$MOUNT_PATH" != "/" && "$MOUNT_PATH" == */ ]]; do
        MOUNT_PATH="${MOUNT_PATH%/}"
    done
    [[ "$MOUNT_PATH" =~ ^/[A-Za-z0-9._/-]+$ && "$MOUNT_PATH" != "/" ]] || fail "invalid mount path: $MOUNT_PATH"
    mountpoint -q -- "$MOUNT_PATH" || fail "not mounted: $MOUNT_PATH"
    FS_TYPE="$(findmnt -nro FSTYPE --target "$MOUNT_PATH" 2>/dev/null || true)"
    FS_UUID="$(findmnt -nro UUID --target "$MOUNT_PATH" 2>/dev/null || true)"
    [[ "$FS_TYPE" == "xfs" && -n "$FS_UUID" ]] || fail "expected mounted XFS with UUID: $MOUNT_PATH"
    DATA_FILE="$MOUNT_PATH/$DATASET_RELATIVE_PATH"
    [[ -f "$DATA_FILE" && -r "$DATA_FILE" ]] || fail "dataset missing or unreadable: $DATA_FILE"
    [[ -w "$(dirname -- "$DATA_FILE")" ]] || fail "dataset directory is not writable for marker repair: $(dirname -- "$DATA_FILE")"
    [[ "$(stat -c %s -- "$DATA_FILE")" == "$DATA_SIZE" ]] || fail "dataset is not exactly $DATASET_SIZE_LABEL: $DATA_FILE"
    for PREVIOUS_FILE in "${DATA_FILES[@]:-}"; do
        [[ "$DATA_FILE" != "$PREVIOUS_FILE" ]] || fail "duplicate dataset path: $DATA_FILE"
    done
    DATA_FILES+=("$DATA_FILE")
    FILESYSTEM_UUIDS+=("$FS_UUID")
    printf -v LUN_LABEL 'lun-%02d' "$((INDEX+1))"
    LUN_LABELS+=("$LUN_LABEL")

    INODE="$(stat -c %i -- "$DATA_FILE")"
    MARKER="${DATA_FILE}.fio-initialized"
    if [[ -f "$MARKER" ]] && \
       grep -Fxq "size_bytes=$DATA_SIZE" "$MARKER" && \
       grep -Fxq "filesystem_uuid=$FS_UUID" "$MARKER" && \
       grep -Fxq "inode=$INODE" "$MARKER"; then
        echo "READY — SKIP: $LUN_LABEL - $DATA_FILE"
    else
        echo "MARKER REPAIR CANDIDATE: $LUN_LABEL - $DATA_FILE"
        REPAIR_INDEXES+=("$INDEX")
    fi
done

if (( ${#REPAIR_INDEXES[@]} == 0 )); then
    echo "All markers are already valid. Nothing was changed."
    exit 0
fi

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RESULT_DIR="$ROOT_DIR/dataset-results/marker_repair_$TIMESTAMP"
JOB_FILE="$RESULT_DIR/sample-read-before-marker-repair.fio"
OUTPUT_FILE="$RESULT_DIR/sample-read-output.txt"
mkdir -p "$RESULT_DIR"
{
    echo "[global]"
    echo "ioengine=libaio"
    echo "direct=1"
    echo "rw=read"
    echo "bs=1048576"
    echo "iodepth=1"
    echo "numjobs=1"
    echo "size=$SAMPLE_SIZE"
    echo "invalidate=1"
    echo "exitall_on_error=1"
    echo
    for INDEX in "${REPAIR_INDEXES[@]}"; do
        SAFE_LABEL="${LUN_LABELS[$INDEX]//-/_}"
        for REGION in begin middle end; do
            case "$REGION" in
                begin) OFFSET=0 ;;
                middle) OFFSET=$MIDDLE_OFFSET ;;
                end) OFFSET=$END_OFFSET ;;
            esac
            echo "[repair_check_${SAFE_LABEL}_${REGION}]"
            echo "filename=${DATA_FILES[$INDEX]}"
            echo "offset=$OFFSET"
            echo
        done
    done
} > "$JOB_FILE"

echo
echo "Running read-only samples from beginning, middle, and end before marker repair..."
fio "$JOB_FILE" 2>&1 | tee "$OUTPUT_FILE"
FIO_RC=${PIPESTATUS[0]}
(( FIO_RC == 0 )) || fail "sample reads failed; no marker was changed"

echo
echo "Sample reads passed. This is not a full $DATASET_SIZE_LABEL checksum and cannot prove how the file was originally created."
echo "This action writes only small .fio-initialized marker files; dataset bytes are never modified."
read -r -p "Type TRUST EXISTING DATASETS to repair markers: " CONFIRM
[[ "$CONFIRM" == "TRUST EXISTING DATASETS" ]] || fail "marker repair was not confirmed; no marker was changed"

for INDEX in "${REPAIR_INDEXES[@]}"; do
    DATA_FILE="${DATA_FILES[$INDEX]}"
    MARKER="${DATA_FILE}.fio-initialized"
    MARKER_TEMP="${MARKER}.tmp.$$"
    INODE="$(stat -c %i -- "$DATA_FILE")"
    {
        echo "Kavox managed FIO dataset"
        echo "size_bytes=$DATA_SIZE"
        echo "size_label=$DATASET_SIZE_LABEL"
        echo "filesystem_uuid=${FILESYSTEM_UUIDS[$INDEX]}"
        echo "inode=$INODE"
        echo "marker_repaired_at=$(date -Is)"
        echo "marker_repair_method=trusted-existing-file-after-three-direct-read-samples"
        echo "fio_version=$(fio --version)"
    } > "$MARKER_TEMP"
    mv -- "$MARKER_TEMP" "$MARKER"
    echo "MARKER REPAIRED: ${LUN_LABELS[$INDEX]} - $MARKER"
done

echo "Dataset files were not rewritten. Repair log: $OUTPUT_FILE"
