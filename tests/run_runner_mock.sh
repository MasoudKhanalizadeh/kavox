#!/usr/bin/env bash

# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Masoud Khanalizadeh Imani

set -euo pipefail

SOURCE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
if [[ "${KEEP_TEST_ARTIFACTS:-no}" == "yes" ]]; then
    echo "Mock artifacts will be kept at: $TEST_ROOT"
else
    trap 'rm -rf -- "$TEST_ROOT"' EXIT
fi
SUITE="$TEST_ROOT/suite"
cp -a -- "$SOURCE_ROOT" "$SUITE"

mounts=()
for lun in 1 2; do
    mount_path="$TEST_ROOT/lun-$lun"
    dataset_dir="$mount_path/fio-test"
    dataset="$dataset_dir/fio-data-1TiB.bin"
    mkdir -p "$dataset_dir"
    truncate -s 1099511627776 "$dataset"
    inode="$(stat -c %i -- "$dataset")"
    printf 'Kavox managed FIO dataset\nsize_bytes=1099511627776\nfilesystem_uuid=FIXTURE-UUID\ninode=%s\n' \
        "$inode" > "${dataset}.fio-initialized"
    mounts+=("$mount_path")
done
mount_csv="$(IFS=,; echo "${mounts[*]}")"

export PATH="$SUITE/tests/mock_bin:$PATH"
printf 'YES\n' | "$SUITE/run_tests.sh" baremetal 01 1 "$mount_csv" 3 0 yes 1 \
    normalize-profile '' 'RAID5 Pool A' >/dev/null

run_dir="$(find "$SUITE/results" -mindepth 1 -maxdepth 1 -type d \
    -name 'baremetal_2lun_qd-equal-profile_jobs-01_rt1s_r3_tag-raid5-pool-a_*' -print -quit)"
[[ -n "$run_dir" ]]
grep -Fxq 'run_label=raid5-pool-a' "$run_dir/run.env"
grep -Fxq 'profile_tag=jobs-01' "$run_dir/run.env"
grep -Fxq 'qd_name_tag=qd-equal-profile' "$run_dir/run.env"
grep -Fxq "result_directory_name=$(basename "$run_dir")" "$run_dir/run.env"
[[ "$(find "$run_dir/01_rand_read_300k" -type f -name 'lun-*.jsonplus.json' | wc -l)" -eq 6 ]]
[[ "$(find "$run_dir/01_rand_read_300k" -type f -name 'lun-*.normal.txt' | wc -l)" -eq 6 ]]
[[ "$(wc -l < "$run_dir/manifest.tsv")" -eq 7 ]]
[[ -f "$run_dir/system/before/snapshot.json" ]]
[[ -f "$run_dir/system/after/snapshot.json" ]]
[[ -f "$run_dir/SHA256SUMS" ]]
[[ -f "$run_dir/qd_plan.tsv" ]]
(($(wc -l < "$run_dir/qd_plan.tsv") == 7))
awk -F '\t' 'NR > 1 {sum[$3]+=$11} END {for (r in sum) if (sum[r] != 256) exit 1}' \
    "$run_dir/qd_plan.tsv"
grep -Fxq 'numjobs=8' "$run_dir/01_rand_read_300k/repeat-01/lun-01.fio"
grep -Fxq 'iodepth=16' "$run_dir/01_rand_read_300k/repeat-01/lun-01.fio"
(cd "$run_dir" && sha256sum -c SHA256SUMS >/dev/null)
jq -e 'length == 1 and .[0].repetitions_observed == 3 and
  .[0].metrics.total_bw_MiB_s.mean == 200 and
  .[0].metrics.total_iops.mean == 2000' "$run_dir/analysis/aggregate_statistics.json" >/dev/null
jq -e '.schema_version == "2.0" and (.manifest|length) == 6' \
    "$run_dir/analysis/final_result.json" >/dev/null
grep -Fq 'mock iostat telemetry' "$run_dir/01_rand_read_300k/repeat-01/iostat.txt"
grep -Fq 'mock fio normal output before JSON' \
    "$run_dir/01_rand_read_300k/repeat-01/lun-01.normal.txt"
grep -Fq 'mock fio normal output after JSON' \
    "$run_dir/01_rand_read_300k/repeat-01/lun-01.normal.txt"
! grep -Fq 'mock fio normal output after JSON' \
    "$run_dir/01_rand_read_300k/repeat-01/lun-01.jsonplus.json"

echo "PASS: Kavox meaningful result name, runner mock, QD plan, and output splitter"
