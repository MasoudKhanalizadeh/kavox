#!/usr/bin/env bash

# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Masoud Khanalizadeh Imani

set -euo pipefail

SOURCE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
SUITE="$TEST_ROOT/suite"
cp -a -- "$SOURCE_ROOT" "$SUITE"

# shellcheck source=../lib/dataset_spec.sh
source "$SUITE/lib/dataset_spec.sh"
kavox_configure_dataset_spec 2147483648
[[ "$DATASET_SIZE_LABEL" == "2GiB" ]]
[[ "$DATASET_RELATIVE_PATH" == "fio-test/fio-data-2GiB.bin" ]]
kavox_configure_sample_regions
[[ "$DATASET_SAMPLE_SIZE_BYTES" -eq 67108864 ]]

mounts=()
datasets=()
for lun in 1 2; do
    mount_path="$TEST_ROOT/lun-$lun"
    dataset_dir="$mount_path/fio-test"
    dataset="$dataset_dir/fio-data-2GiB.bin"
    mkdir -p "$dataset_dir"
    truncate -s 2147483648 "$dataset"
    mounts+=("$mount_path")
    datasets+=("$dataset")
done
mount_csv="$(IFS=,; echo "${mounts[*]}")"
before_state="$(stat -c '%i:%s:%Y:%b' -- "${datasets[0]}")"

export PATH="$SUITE/tests/mock_bin:$PATH"

set +e
"$SUITE/dataset_status.sh" "$mount_csv" 2GiB > "$TEST_ROOT/status-recoverable.txt" 2>&1
status_rc=$?
set -e
[[ "$status_rc" -eq 3 ]]
grep -Fq 'RECOVERABLE' "$TEST_ROOT/status-recoverable.txt"

set +e
"$SUITE/prepare_datasets.sh" "$mount_csv" 2GiB > "$TEST_ROOT/prepare-protected.txt" 2>&1
prepare_rc=$?
set -e
[[ "$prepare_rc" -eq 3 ]]
grep -Fq 'PROTECTED EXISTING 2GiB FILE - NOT WRITTEN' "$TEST_ROOT/prepare-protected.txt"
[[ "$(stat -c '%i:%s:%Y:%b' -- "${datasets[0]}")" == "$before_state" ]]

for dataset in "${datasets[@]}"; do
    inode="$(stat -c %i -- "$dataset")"
    printf 'Kavox managed FIO dataset\nsize_bytes=2147483648\nfilesystem_uuid=FIXTURE-UUID\ninode=%s\n' \
        "$inode" > "${dataset}.fio-initialized"
done

"$SUITE/dataset_status.sh" "$mount_csv" 2GiB > "$TEST_ROOT/status-ready.txt"
grep -Fq 'valid 2GiB dataset' "$TEST_ROOT/status-ready.txt"
"$SUITE/check_datasets.sh" "$mount_csv" 2GiB > "$TEST_ROOT/check.txt"
grep -Fq 'not a full 2GiB checksum scan' "$TEST_ROOT/check.txt"

printf 'YES\n' | "$SUITE/run_tests.sh" customsize 01 1 "$mount_csv" 1 0 no 1 \
    normalize-profile '' variable-size 2GiB >/dev/null

run_dir="$(find "$SUITE/results" -mindepth 1 -maxdepth 1 -type d \
    -name 'customsize_2lun_ds-2GiB_qd-equal-profile_jobs-01_rt1s_r1_tag-variable-size_*' \
    -print -quit)"
[[ -n "$run_dir" ]]
grep -Fxq 'dataset_size_label=2GiB' "$run_dir/run.env"
grep -Fxq 'dataset_size_bytes=2147483648' "$run_dir/run.env"
grep -Fxq 'dataset_relative_path=fio-test/fio-data-2GiB.bin' "$run_dir/run.env"
for rendered_job in "$run_dir/01_rand_read_300k/repeat-01"/lun-*.fio; do
    grep -Fxq 'size=2147483648' "$rendered_job"
    grep -Eq '^filename=.*/fio-test/fio-data-2GiB\.bin$' "$rendered_job"
done
jq -e '.dataset_size_label == "2GiB" and .dataset_size_bytes == 2147483648' \
    "$run_dir/system/before/snapshot.json" >/dev/null
jq -e '.dataset_size_label == "2GiB" and .dataset_size_bytes == 2147483648' \
    "$run_dir/analysis/final_result.json" >/dev/null
grep -Fq 'Dataset size per LUN: 2GiB (2147483648 bytes)' \
    "$run_dir/analysis/FINAL_REPORT.txt"

for invalid_size in 2GB 1.5GiB 32MiB 1073741825; do
    set +e
    "$SUITE/dataset_status.sh" "$mount_csv" "$invalid_size" >/dev/null 2>&1
    invalid_rc=$?
    set -e
    [[ "$invalid_rc" -eq 2 ]]
done

# Missing custom-size datasets must be created at the requested size and marked.
small_mount="$TEST_ROOT/lun-small"
mkdir -p "$small_mount"
printf 'INITIALIZE MISSING DATASETS\n' | \
    "$SUITE/prepare_datasets.sh" "$small_mount" 64MiB > "$TEST_ROOT/prepare-small.txt"
small_dataset="$small_mount/fio-test/fio-data-64MiB.bin"
[[ -f "$small_dataset" ]]
[[ "$(stat -c %s -- "$small_dataset")" -eq 67108864 ]]
grep -Fxq 'size_bytes=67108864' "${small_dataset}.fio-initialized"
grep -Fxq 'size_label=64MiB' "${small_dataset}.fio-initialized"
small_prepare_job="$(find "$SUITE/dataset-results" -type f -name prepare-datasets.fio \
    -print -quit)"
grep -Fxq 'size=67108864' "$small_prepare_job"
"$SUITE/check_datasets.sh" "$small_mount" 64MiB > "$TEST_ROOT/check-small.txt"
small_check_job="$(find "$SUITE/dataset-results" -type f -name check-datasets.fio \
    -printf '%T@\t%p\n' | sort -rn | head -n 1 | cut -f2-)"
grep -Fxq 'size=16777216' "$small_check_job"
grep -Fxq 'offset=33554432' "$small_check_job"
grep -Fxq 'offset=50331648' "$small_check_job"

# The interactive entry point must persist the canonical size in its TSV config.
printf '2\n\n2GiB\n\n\n\n\n\n\nn\n\n0\n' | TERM=dumb "$SUITE/kavox.sh" \
    > "$TEST_ROOT/menu-configure.txt"
grep -Fq $'dataset_size\t2GiB' "$SUITE/benchmark_config.tsv"
grep -Fq 'Dataset size : 2GiB (2147483648 bytes per LUN)' "$TEST_ROOT/menu-configure.txt"
grep -Fq 'Dataset file : fio-test/fio-data-2GiB.bin' "$TEST_ROOT/menu-configure.txt"

echo "PASS: Kavox configurable dataset size, isolation, rendering, and validation"
