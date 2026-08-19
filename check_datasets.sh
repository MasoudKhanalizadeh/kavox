#!/usr/bin/env bash

# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Masoud Khanalizadeh Imani

# Validate dataset metadata and perform direct sample reads from the beginning,
# middle and end of every selected configurable-size dataset.

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
command -v fio >/dev/null 2>&1 || fail "fio is not installed or is not in PATH"
command -v mountpoint >/dev/null 2>&1 || fail "mountpoint is not available"
command -v findmnt >/dev/null 2>&1 || fail "findmnt is not available"

DATA_FILES=()
LUN_LABELS=()
ERROR_COUNT=0

echo
echo "Dataset metadata check:"

for ((INDEX = 0; INDEX < ${#MOUNT_PATHS[@]}; INDEX++)); do
    MOUNT_PATH="${MOUNT_PATHS[$INDEX]}"
    while [[ "$MOUNT_PATH" != "/" && "$MOUNT_PATH" == */ ]]; do
        MOUNT_PATH="${MOUNT_PATH%/}"
    done
    MOUNT_PATHS[$INDEX]="$MOUNT_PATH"
    printf -v LUN_LABEL 'lun-%02d' "$((INDEX + 1))"
    LUN_LABELS+=("$LUN_LABEL")

    if [[ ! "$MOUNT_PATH" =~ ^/[A-Za-z0-9._/-]+$ || "$MOUNT_PATH" == "/" ]]; then
        echo "  FAIL $LUN_LABEL: invalid mount path: $MOUNT_PATH"
        ERROR_COUNT=$((ERROR_COUNT + 1))
        DATA_FILES+=("")
        continue
    fi

    DATA_FILE="$MOUNT_PATH/$DATASET_RELATIVE_PATH"
    DATA_FILES+=("$DATA_FILE")

    for ((PREVIOUS = 0; PREVIOUS < INDEX; PREVIOUS++)); do
        if [[ -n "${DATA_FILES[$PREVIOUS]}" && "$DATA_FILE" == "${DATA_FILES[$PREVIOUS]}" ]]; then
            echo "  FAIL $LUN_LABEL: duplicate dataset path"
            ERROR_COUNT=$((ERROR_COUNT + 1))
            continue 2
        fi
    done

    if ! mountpoint -q -- "$MOUNT_PATH"; then
        echo "  FAIL $LUN_LABEL: not mounted at $MOUNT_PATH"
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi

    FS_TYPE="$(findmnt -nro FSTYPE --target "$MOUNT_PATH" 2>/dev/null || true)"
    FS_UUID="$(findmnt -nro UUID --target "$MOUNT_PATH" 2>/dev/null || true)"
    MARKER="${DATA_FILE}.fio-initialized"

    if [[ "$FS_TYPE" != "xfs" ]]; then
        echo "  FAIL $LUN_LABEL: expected XFS; detected ${FS_TYPE:-unknown}"
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi
    if [[ ! -f "$DATA_FILE" || ! -r "$DATA_FILE" || ! -w "$DATA_FILE" ]]; then
        echo "  FAIL $LUN_LABEL: dataset is missing or is not readable/writable"
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi
    if [[ ! -f "$MARKER" ]]; then
        echo "  FAIL $LUN_LABEL: trusted initialization marker is missing"
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi

    ACTUAL_SIZE="$(stat -c %s -- "$DATA_FILE" 2>/dev/null || echo 0)"
    INODE="$(stat -c %i -- "$DATA_FILE" 2>/dev/null || echo 0)"
    if [[ "$ACTUAL_SIZE" != "$DATA_SIZE" ]] || \
       ! grep -Fxq "size_bytes=$DATA_SIZE" "$MARKER" || \
       ! grep -Fxq "filesystem_uuid=$FS_UUID" "$MARKER" || \
       ! grep -Fxq "inode=$INODE" "$MARKER"; then
        echo "  FAIL $LUN_LABEL: dataset or marker metadata mismatch"
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi

    echo "  PASS $LUN_LABEL: metadata valid - $DATA_FILE"
done

(( ERROR_COUNT == 0 )) || fail "$ERROR_COUNT dataset metadata check(s) failed"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RESULT_DIR="$ROOT_DIR/dataset-results/check_$TIMESTAMP"
JOB_FILE="$RESULT_DIR/check-datasets.fio"
OUTPUT_FILE="$RESULT_DIR/fio-read-check.txt"
mkdir -p "$RESULT_DIR"

{
    echo "[global]"
    echo "ioengine=libaio"
    echo "direct=1"
    echo "rw=read"
    # Keep direct sample reads aligned to 1,048,576 bytes (binary 1 MiB).
    echo "bs=1048576"
    echo "iodepth=1"
    echo "numjobs=1"
    echo "size=$SAMPLE_SIZE"
    echo "invalidate=1"
    echo "exitall_on_error=1"
    echo

    for ((INDEX = 0; INDEX < ${#DATA_FILES[@]}; INDEX++)); do
        SAFE_LABEL="${LUN_LABELS[$INDEX]//-/_}"
        echo "[check_${SAFE_LABEL}_begin]"
        echo "filename=${DATA_FILES[$INDEX]}"
        echo "offset=0"
        echo
        echo "[check_${SAFE_LABEL}_middle]"
        echo "filename=${DATA_FILES[$INDEX]}"
        echo "offset=$MIDDLE_OFFSET"
        echo
        echo "[check_${SAFE_LABEL}_end]"
        echo "filename=${DATA_FILES[$INDEX]}"
        echo "offset=$END_OFFSET"
        echo
    done
} > "$JOB_FILE"

echo
echo "Running direct sample reads from the beginning, middle and end of every dataset..."
fio "$JOB_FILE" 2>&1 | tee "$OUTPUT_FILE"
FIO_RC=${PIPESTATUS[0]}
(( FIO_RC == 0 )) || fail "direct sample read failed with exit code $FIO_RC"

echo
echo "All datasets passed metadata and direct-read checks."
echo "Check log: $OUTPUT_FILE"
echo "Note: this confirms preparation state and readability; it is not a full $DATASET_SIZE_LABEL checksum scan."
