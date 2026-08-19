#!/usr/bin/env bash

# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Masoud Khanalizadeh Imani

# Read-only metadata status check for one or more benchmark datasets.
# Exit codes: 0=all READY, 3=existing exact-size file needs marker repair,
# 4=missing/conflicting/inaccessible dataset, 2=invalid invocation/environment.

set -u
set -o pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DATASET_SPEC_LIB="$ROOT_DIR/lib/dataset_spec.sh"
[[ -r "$DATASET_SPEC_LIB" ]] || { echo "ERROR: dataset specification library is missing" >&2; exit 2; }
# shellcheck source=lib/dataset_spec.sh
source "$DATASET_SPEC_LIB"

MOUNT_PATHS_ARGUMENT="${1:-}"
DATASET_SIZE_INPUT="${2:-1TiB}"

fail() {
    echo "ERROR: $*" >&2
    exit 2
}

kavox_configure_dataset_spec "$DATASET_SIZE_INPUT" || {
    kavox_dataset_size_help >&2
    fail "invalid dataset size: $DATASET_SIZE_INPUT"
}
DATA_SIZE=$DATASET_SIZE_BYTES

read_mount_paths() {
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
    (( ${#MOUNT_PATHS[@]} > 0 )) || fail "no LUN path was provided"
}

for REQUIRED_COMMAND in mountpoint findmnt stat; do
    command -v "$REQUIRED_COMMAND" >/dev/null 2>&1 || fail "$REQUIRED_COMMAND is unavailable"
done

read_mount_paths
READY_COUNT=0
RECOVERABLE_COUNT=0
ERROR_COUNT=0
DATA_FILES=()

echo
echo "Dataset status (read-only; no FIO and no writes):"
for ((INDEX=0; INDEX<${#MOUNT_PATHS[@]}; INDEX++)); do
    MOUNT_PATH="${MOUNT_PATHS[$INDEX]}"
    while [[ "$MOUNT_PATH" != "/" && "$MOUNT_PATH" == */ ]]; do
        MOUNT_PATH="${MOUNT_PATH%/}"
    done
    printf -v LUN_LABEL 'lun-%02d' "$((INDEX+1))"

    if [[ ! "$MOUNT_PATH" =~ ^/[A-Za-z0-9._/-]+$ || "$MOUNT_PATH" == "/" ]]; then
        echo "  INVALID $LUN_LABEL: unsupported mount path - $MOUNT_PATH"
        ERROR_COUNT=$((ERROR_COUNT+1))
        continue
    fi

    DATA_FILE="$MOUNT_PATH/$DATASET_RELATIVE_PATH"
    for PREVIOUS_FILE in "${DATA_FILES[@]:-}"; do
        if [[ "$DATA_FILE" == "$PREVIOUS_FILE" ]]; then
            echo "  INVALID $LUN_LABEL: duplicate dataset path - $DATA_FILE"
            ERROR_COUNT=$((ERROR_COUNT+1))
            continue 2
        fi
    done
    DATA_FILES+=("$DATA_FILE")

    if ! mountpoint -q -- "$MOUNT_PATH"; then
        echo "  NOT MOUNTED $LUN_LABEL: $MOUNT_PATH"
        ERROR_COUNT=$((ERROR_COUNT+1))
        continue
    fi
    FS_TYPE="$(findmnt -nro FSTYPE --target "$MOUNT_PATH" 2>/dev/null || true)"
    FS_UUID="$(findmnt -nro UUID --target "$MOUNT_PATH" 2>/dev/null || true)"
    if [[ "$FS_TYPE" != "xfs" || -z "$FS_UUID" ]]; then
        echo "  INVALID FILESYSTEM $LUN_LABEL: expected mounted XFS with UUID"
        ERROR_COUNT=$((ERROR_COUNT+1))
        continue
    fi
    if [[ ! -e "$DATA_FILE" ]]; then
        echo "  MISSING $LUN_LABEL: $DATA_FILE"
        ERROR_COUNT=$((ERROR_COUNT+1))
        continue
    fi
    if [[ ! -f "$DATA_FILE" || ! -r "$DATA_FILE" || ! -w "$DATA_FILE" ]]; then
        echo "  INACCESSIBLE $LUN_LABEL: $DATA_FILE"
        ERROR_COUNT=$((ERROR_COUNT+1))
        continue
    fi

    ACTUAL_SIZE="$(stat -c %s -- "$DATA_FILE" 2>/dev/null || echo 0)"
    INODE="$(stat -c %i -- "$DATA_FILE" 2>/dev/null || echo 0)"
    MARKER="${DATA_FILE}.fio-initialized"
    if [[ "$ACTUAL_SIZE" != "$DATA_SIZE" ]]; then
        echo "  WRONG SIZE $LUN_LABEL: $ACTUAL_SIZE bytes - $DATA_FILE"
        ERROR_COUNT=$((ERROR_COUNT+1))
    elif [[ -f "$MARKER" ]] && \
         grep -Fxq "size_bytes=$DATA_SIZE" "$MARKER" && \
         grep -Fxq "filesystem_uuid=$FS_UUID" "$MARKER" && \
         grep -Fxq "inode=$INODE" "$MARKER"; then
        echo "  READY $LUN_LABEL: valid $DATASET_SIZE_LABEL dataset and marker - $DATA_FILE"
        READY_COUNT=$((READY_COUNT+1))
    else
        echo "  RECOVERABLE $LUN_LABEL: existing $DATASET_SIZE_LABEL file is protected; marker needs repair"
        echo "      $DATA_FILE"
        RECOVERABLE_COUNT=$((RECOVERABLE_COUNT+1))
    fi
done

echo
echo "Summary: ready=$READY_COUNT recoverable=$RECOVERABLE_COUNT errors=$ERROR_COUNT"
if (( ERROR_COUNT > 0 )); then
    exit 4
elif (( RECOVERABLE_COUNT > 0 )); then
    exit 3
fi
exit 0
