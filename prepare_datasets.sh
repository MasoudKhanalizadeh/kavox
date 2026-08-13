#!/usr/bin/env bash

# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Masoud Khanalizadeh Imani

# Create one fully written 1 TiB FIO dataset only when the target file is absent.
# Existing dataset files are never deleted, truncated, or overwritten by this script.

set -u
set -o pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DATASET_RELATIVE_PATH="fio-test/fio-data-1TiB.bin"
DATA_SIZE=1099511627776
MIN_FREE_BYTES=$((DATA_SIZE + 1073741824))
MOUNT_PATHS_ARGUMENT="${1:-}"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

read_mount_paths() {
    MOUNT_PATHS=()

    if [[ -n "$MOUNT_PATHS_ARGUMENT" ]]; then
        IFS=',' read -r -a MOUNT_PATHS <<< "$MOUNT_PATHS_ARGUMENT"
    else
        read -r -p "Number of LUNs [1]: " LUN_COUNT
        LUN_COUNT="${LUN_COUNT:-1}"
        [[ "$LUN_COUNT" =~ ^[1-9][0-9]*$ ]] || fail "enter a positive whole number"

        for ((INDEX = 1; INDEX <= LUN_COUNT; INDEX++)); do
            if (( LUN_COUNT == 1 )); then
                read -r -p "Mount path for LUN 1 [/mnt/storage]: " MOUNT_PATH
                MOUNT_PATH="${MOUNT_PATH:-/mnt/storage}"
            else
                read -r -p "Mount path for LUN $INDEX: " MOUNT_PATH
            fi
            MOUNT_PATHS+=("$MOUNT_PATH")
        done
    fi

    (( ${#MOUNT_PATHS[@]} > 0 )) || fail "no LUN path was provided"
}

normalize_and_validate_mounts() {
    DATA_FILES=()
    LUN_LABELS=()
    FILESYSTEM_UUIDS=()

    for ((INDEX = 0; INDEX < ${#MOUNT_PATHS[@]}; INDEX++)); do
        MOUNT_PATH="${MOUNT_PATHS[$INDEX]}"
        while [[ "$MOUNT_PATH" != "/" && "$MOUNT_PATH" == */ ]]; do
            MOUNT_PATH="${MOUNT_PATH%/}"
        done

        [[ "$MOUNT_PATH" =~ ^/[A-Za-z0-9._/-]+$ ]] || fail "mount path contains unsupported characters: $MOUNT_PATH"
        [[ "$MOUNT_PATH" != "/" ]] || fail "the root filesystem cannot be used"
        mountpoint -q -- "$MOUNT_PATH" || fail "not an active mount point: $MOUNT_PATH"

        FS_TYPE="$(findmnt -nro FSTYPE --target "$MOUNT_PATH" 2>/dev/null || true)"
        [[ "$FS_TYPE" == "xfs" ]] || fail "expected XFS on $MOUNT_PATH; detected: ${FS_TYPE:-unknown}"

        FS_UUID="$(findmnt -nro UUID --target "$MOUNT_PATH" 2>/dev/null || true)"
        [[ -n "$FS_UUID" ]] || fail "cannot detect filesystem UUID for $MOUNT_PATH"

        DATA_FILE="$MOUNT_PATH/$DATASET_RELATIVE_PATH"
        for PREVIOUS_FILE in "${DATA_FILES[@]}"; do
            [[ "$DATA_FILE" != "$PREVIOUS_FILE" ]] || fail "duplicate LUN path: $MOUNT_PATH"
        done

        MOUNT_PATHS[$INDEX]="$MOUNT_PATH"
        DATA_FILES+=("$DATA_FILE")
        FILESYSTEM_UUIDS+=("$FS_UUID")
        printf -v LUN_LABEL 'lun-%02d' "$((INDEX + 1))"
        LUN_LABELS+=("$LUN_LABEL")
    done
}

marker_is_valid() {
    local dataset="$1" uuid="$2" marker="${1}.fio-initialized"
    local size inode

    [[ -f "$dataset" && -f "$marker" ]] || return 1
    size="$(stat -c %s -- "$dataset" 2>/dev/null || echo 0)"
    inode="$(stat -c %i -- "$dataset" 2>/dev/null || echo 0)"
    [[ "$size" == "$DATA_SIZE" ]] || return 1
    grep -Fxq "size_bytes=$DATA_SIZE" "$marker" || return 1
    grep -Fxq "filesystem_uuid=$uuid" "$marker" || return 1
    grep -Fxq "inode=$inode" "$marker" || return 1
}

command -v fio >/dev/null 2>&1 || fail "fio is not installed or is not in PATH"
command -v mountpoint >/dev/null 2>&1 || fail "mountpoint is not available"
command -v findmnt >/dev/null 2>&1 || fail "findmnt is not available"

read_mount_paths
normalize_and_validate_mounts

PENDING_INDEXES=()
PROTECTED_INDEXES=()
CONFLICT_INDEXES=()

echo
echo "Dataset preparation plan:"
for ((INDEX = 0; INDEX < ${#DATA_FILES[@]}; INDEX++)); do
    DATA_FILE="${DATA_FILES[$INDEX]}"
    if marker_is_valid "$DATA_FILE" "${FILESYSTEM_UUIDS[$INDEX]}"; then
        echo "  ${LUN_LABELS[$INDEX]}: READY - $DATA_FILE"
    elif [[ -f "$DATA_FILE" ]]; then
        ACTUAL_SIZE="$(stat -c %s -- "$DATA_FILE" 2>/dev/null || echo 0)"
        if [[ "$ACTUAL_SIZE" == "$DATA_SIZE" ]]; then
            echo "  ${LUN_LABELS[$INDEX]}: PROTECTED EXISTING 1 TiB FILE - NOT WRITTEN"
            echo "      $DATA_FILE"
            echo "      Marker is missing or mismatched; use repair_dataset_markers.sh."
            PROTECTED_INDEXES+=("$INDEX")
        else
            echo "  ${LUN_LABELS[$INDEX]}: CONFLICTING EXISTING FILE (${ACTUAL_SIZE} bytes) - NOT WRITTEN"
            echo "      $DATA_FILE"
            CONFLICT_INDEXES+=("$INDEX")
        fi
    elif [[ -e "$DATA_FILE" || -e "${DATA_FILE}.fio-initialized" ]]; then
        echo "  ${LUN_LABELS[$INDEX]}: PATH/MARKER CONFLICT - NOT WRITTEN"
        echo "      $DATA_FILE"
        CONFLICT_INDEXES+=("$INDEX")
    else
        echo "  ${LUN_LABELS[$INDEX]}: NEW - $DATA_FILE"
        PENDING_INDEXES+=("$INDEX")
    fi
done

if (( ${#PROTECTED_INDEXES[@]} > 0 || ${#CONFLICT_INDEXES[@]} > 0 )); then
    echo
    echo "SAFETY STOP: at least one selected path already exists but is not READY."
    echo "No existing dataset or marker was changed, deleted, truncated, or overwritten."
    echo "For an exact 1 TiB file, run repair_dataset_markers.sh after verifying its origin."
    echo "For a wrong-size/conflicting path, inspect it manually and move it out of the way if appropriate."
    exit 3
fi

if (( ${#PENDING_INDEXES[@]} == 0 )); then
    echo
    echo "All datasets are already initialized and valid. Nothing was written."
    exit 0
fi

for INDEX in "${PENDING_INDEXES[@]}"; do
    MOUNT_PATH="${MOUNT_PATHS[$INDEX]}"
    AVAILABLE_BYTES="$(df -B1 --output=avail "$MOUNT_PATH" | awk 'NR==2 {gsub(/[[:space:]]/, "", $0); print $0}')"
    [[ "$AVAILABLE_BYTES" =~ ^[0-9]+$ ]] || fail "cannot determine free space on $MOUNT_PATH"
    (( AVAILABLE_BYTES >= MIN_FREE_BYTES )) || \
        fail "${LUN_LABELS[$INDEX]} needs at least 1 TiB plus 1 GiB free space"

    mkdir -p -- "$(dirname -- "${DATA_FILES[$INDEX]}")"
    WRITE_TEST="$(dirname -- "${DATA_FILES[$INDEX]}")/.fio-write-test.$$"
    : > "$WRITE_TEST" || fail "test directory is not writable: $(dirname -- "${DATA_FILES[$INDEX]}")"
    rm -f -- "$WRITE_TEST"
done

echo
echo "This performs a real sequential write of 1 TiB on each pending LUN."
echo "All pending LUNs will be initialized in parallel."
echo "WARNING: this is heavy write I/O and may take a long time."
echo "Existing files are protected and cannot reach this step."
read -r -p "Type INITIALIZE MISSING DATASETS to start: " CONFIRM
[[ "$CONFIRM" == "INITIALIZE MISSING DATASETS" ]] || fail "initialization was not confirmed"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RESULT_DIR="$ROOT_DIR/dataset-results/prepare_$TIMESTAMP"
JOB_FILE="$RESULT_DIR/prepare-datasets.fio"
OUTPUT_FILE="$RESULT_DIR/fio-output.txt"
mkdir -p "$RESULT_DIR"

{
    echo "[global]"
    echo "ioengine=libaio"
    echo "direct=1"
    echo "rw=write"
    # Use an explicit binary-aligned byte count. With fio's default kb_base=1024,
    # the legacy unit parsing treats 1MiB as 1,000,000 bytes, which is invalid
    # for direct I/O on devices/filesystems that require 512/4096-byte alignment.
    echo "bs=1048576"
    echo "iodepth=16"
    echo "numjobs=1"
    echo "size=$DATA_SIZE"
    echo "fallocate=none"
    echo "refill_buffers=1"
    echo "end_fsync=1"
    echo "exitall_on_error=1"
    echo

    for INDEX in "${PENDING_INDEXES[@]}"; do
        echo "[prepare_${LUN_LABELS[$INDEX]//-/_}]"
        echo "filename=${DATA_FILES[$INDEX]}"
        echo
    done
} > "$JOB_FILE"

echo
echo "Starting FIO dataset initialization..."
echo "Live output: $OUTPUT_FILE"

fio "$JOB_FILE" 2>&1 | tee "$OUTPUT_FILE"
FIO_RC=${PIPESTATUS[0]}
(( FIO_RC == 0 )) || fail "FIO dataset initialization failed with exit code $FIO_RC"

sync

for INDEX in "${PENDING_INDEXES[@]}"; do
    DATA_FILE="${DATA_FILES[$INDEX]}"
    ACTUAL_SIZE="$(stat -c %s -- "$DATA_FILE" 2>/dev/null || echo 0)"
    [[ "$ACTUAL_SIZE" == "$DATA_SIZE" ]] || fail "wrong dataset size after initialization: $DATA_FILE"

    INODE="$(stat -c %i -- "$DATA_FILE")"
    MARKER="${DATA_FILE}.fio-initialized"
    MARKER_TEMP="${MARKER}.tmp.$$"
    {
        echo "Kavox managed FIO dataset"
        echo "size_bytes=$DATA_SIZE"
        echo "filesystem_uuid=${FILESYSTEM_UUIDS[$INDEX]}"
        echo "inode=$INODE"
        echo "initialized_at=$(date -Is)"
        echo "fio_version=$(fio --version)"
    } > "$MARKER_TEMP"
    mv -- "$MARKER_TEMP" "$MARKER"
    echo "READY: ${LUN_LABELS[$INDEX]} - $DATA_FILE"
done

echo
echo "All selected datasets were initialized successfully."
echo "Preparation log: $OUTPUT_FILE"
echo "Next step: ./check_datasets.sh"
