#!/usr/bin/env bash

# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Masoud Khanalizadeh Imani

# Shared dataset-size parsing and derived paths for all Kavox entry points.
# Accepted forms: 64MiB, 20GiB, 1TiB, or an aligned raw byte count.

KAVOX_MIB=1048576
KAVOX_GIB=1073741824
KAVOX_TIB=1099511627776
KAVOX_MIN_DATASET_BYTES=$((64 * KAVOX_MIB))
KAVOX_MAX_DATASET_BYTES=$((1024 * KAVOX_TIB))
KAVOX_DATASET_ALIGNMENT_BYTES=$KAVOX_MIB

kavox_configure_dataset_spec() {
    local input="${1:-1TiB}"
    local compact number unit multiplier max_number bytes

    compact="${input//[[:space:]]/}"
    if [[ "$compact" =~ ^([1-9][0-9]*)([mMgGtT][iI][bB])$ ]]; then
        number="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2],,}"
        (( ${#number} <= 10 )) || return 1
        case "$unit" in
            mib) multiplier=$KAVOX_MIB; max_number=$((KAVOX_MAX_DATASET_BYTES / KAVOX_MIB)) ;;
            gib) multiplier=$KAVOX_GIB; max_number=$((KAVOX_MAX_DATASET_BYTES / KAVOX_GIB)) ;;
            tib) multiplier=$KAVOX_TIB; max_number=$((KAVOX_MAX_DATASET_BYTES / KAVOX_TIB)) ;;
            *) return 1 ;;
        esac
        (( number <= max_number )) || return 1
        bytes=$((number * multiplier))
    elif [[ "$compact" =~ ^[1-9][0-9]*$ ]]; then
        (( ${#compact} <= 16 )) || return 1
        bytes=$((10#$compact))
    else
        return 1
    fi

    (( bytes >= KAVOX_MIN_DATASET_BYTES )) || return 1
    (( bytes <= KAVOX_MAX_DATASET_BYTES )) || return 1
    (( bytes % KAVOX_DATASET_ALIGNMENT_BYTES == 0 )) || return 1

    DATASET_SIZE_BYTES=$bytes
    if (( bytes % KAVOX_TIB == 0 )); then
        DATASET_SIZE_LABEL="$((bytes / KAVOX_TIB))TiB"
    elif (( bytes % KAVOX_GIB == 0 )); then
        DATASET_SIZE_LABEL="$((bytes / KAVOX_GIB))GiB"
    else
        DATASET_SIZE_LABEL="$((bytes / KAVOX_MIB))MiB"
    fi
    DATASET_FILENAME="fio-data-${DATASET_SIZE_LABEL}.bin"
    DATASET_RELATIVE_PATH="fio-test/$DATASET_FILENAME"
    return 0
}

kavox_configure_sample_regions() {
    local sample_size=$((64 * KAVOX_MIB))

    if (( DATASET_SIZE_BYTES < sample_size * 4 )); then
        sample_size=$((DATASET_SIZE_BYTES / 4))
        sample_size=$((sample_size / KAVOX_MIB * KAVOX_MIB))
    fi
    (( sample_size >= KAVOX_MIB )) || return 1

    DATASET_SAMPLE_SIZE_BYTES=$sample_size
    DATASET_MIDDLE_OFFSET_BYTES=$((DATASET_SIZE_BYTES / 2))
    DATASET_MIDDLE_OFFSET_BYTES=$((DATASET_MIDDLE_OFFSET_BYTES / KAVOX_MIB * KAVOX_MIB))
    DATASET_END_OFFSET_BYTES=$((DATASET_SIZE_BYTES - sample_size))
}

kavox_configure_free_space_reserve() {
    local reserve=$((DATASET_SIZE_BYTES / 100))

    (( reserve >= 64 * KAVOX_MIB )) || reserve=$((64 * KAVOX_MIB))
    (( reserve <= KAVOX_GIB )) || reserve=$KAVOX_GIB
    DATASET_FREE_SPACE_RESERVE_BYTES=$reserve
    DATASET_MIN_FREE_BYTES=$((DATASET_SIZE_BYTES + reserve))
}

kavox_dataset_size_help() {
    printf '%s\n' \
        'Use a whole-number binary size such as 512MiB, 20GiB, 500GiB, or 1TiB.' \
        'Minimum: 64MiB. The value must be aligned to 1MiB.'
}
