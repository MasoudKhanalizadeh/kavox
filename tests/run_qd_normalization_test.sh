#!/usr/bin/env bash

# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Masoud Khanalizadeh Imani

set -euo pipefail

SOURCE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
SUITE="$TEST_ROOT/suite"
cp -a -- "$SOURCE_ROOT" "$SUITE"

mounts=()
for lun in 1 2 3; do
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
printf 'YES\n' | "$SUITE/run_tests.sh" baremetal 01,03 1 "$mount_csv" 3 0 no 1 \
    normalize-profile >/dev/null

run_dir="$(find "$SUITE/results" -mindepth 1 -maxdepth 1 -type d \
    -name 'baremetal_3lun_ds-1TiB_qd-equal-profile_jobs-01-03_rt1s_r3_*' -print -quit)"
[[ -n "$run_dir" && -f "$run_dir/qd_plan.tsv" ]]

# 2 profiles x 3 repeats x 3 LUNs, plus the header.
[[ "$(wc -l < "$run_dir/qd_plan.tsv")" -eq 19 ]]

# Every repeat must preserve the exact original aggregate QD: 256 random, 16 sequential.
awk -F '\t' '
    NR > 1 { sum[$2 SUBSEP $3] += $11 }
    END {
        for (key in sum) {
            split(key, parts, SUBSEP)
            expected=(parts[1] == "01_rand_read_300k" ? 256 : 16)
            if (sum[key] != expected) exit 1
        }
    }
' "$run_dir/qd_plan.tsv"

# The indivisible remainder rotates: 6/5/5 workers for random and 6/5/5 depth for sequential.
for repeat in 01 02 03; do
    heavy_lun="$(printf '%02d' "$repeat")"
    grep -Fxq 'numjobs=6' "$run_dir/01_rand_read_300k/repeat-$repeat/lun-$heavy_lun.fio"
    grep -Fxq 'iodepth=6' "$run_dir/03_seq_read_1m/repeat-$repeat/lun-$heavy_lun.fio"
done

# The applied values must be independently recorded next to every rendered job.
grep -Fxq 'aggregate_target_qd=256' \
    "$run_dir/01_rand_read_300k/repeat-01/lun-01.qd.env"
grep -Fxq 'aggregate_target_qd=16' \
    "$run_dir/03_seq_read_1m/repeat-01/lun-01.qd.env"

# Custom aggregate QD must also be exact for every selected profile.
printf 'YES\n' | "$SUITE/run_tests.sh" customtest 01,03 1 "$mount_csv" 1 0 no 1 \
    custom-total 240 >/dev/null
custom_dir="$(find "$SUITE/results" -mindepth 1 -maxdepth 1 -type d \
    -name 'customtest_3lun_ds-1TiB_qd-total-240_jobs-01-03_rt1s_r1_*' -print -quit)"
awk -F '\t' '
    NR > 1 { sum[$2 SUBSEP $3] += $11 }
    END { for (key in sum) if (sum[key] != 240) exit 1 }
' "$custom_dir/qd_plan.tsv"
grep -Fxq 'numjobs=5' "$custom_dir/01_rand_read_300k/repeat-01/lun-01.fio"
grep -Fxq 'iodepth=16' "$custom_dir/01_rand_read_300k/repeat-01/lun-01.fio"

# Legacy scaling mode intentionally multiplies the profile QD by LUN count.
printf 'YES\n' | "$SUITE/run_tests.sh" scaletest 01 1 "$mount_csv" 1 0 no 1 \
    per-lun-profile >/dev/null
scale_dir="$(find "$SUITE/results" -mindepth 1 -maxdepth 1 -type d \
    -name 'scaletest_3lun_ds-1TiB_qd-perlun-profile_jobs-01_rt1s_r1_*' -print -quit)"
awk -F '\t' 'NR > 1 {sum += $11} END {exit !(sum == 768)}' "$scale_dir/qd_plan.tsv"
grep -Fxq 'numjobs=16' "$scale_dir/01_rand_read_300k/repeat-01/lun-03.fio"
grep -Fxq 'iodepth=16' "$scale_dir/01_rand_read_300k/repeat-01/lun-03.fio"

echo "PASS: Kavox normalized, custom-total, and per-LUN scaling QD policies"
