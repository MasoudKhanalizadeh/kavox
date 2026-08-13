#!/usr/bin/env bash

# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Masoud Khanalizadeh Imani

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
RESULT_DIR="$TEST_ROOT/baremetal_failed"
REPEAT_DIR="$RESULT_DIR/01_rand_read_300k/repeat-01"
mkdir -p "$REPEAT_DIR"

raw_relative="01_rand_read_300k/repeat-01/lun-01.combined.raw"
raw_file="$RESULT_DIR/$raw_relative"
{
    echo "normal text before JSON"
    cat "$ROOT_DIR/tests/fixture_jsonplus.json"
    echo "normal text after JSON"
} > "$raw_file"
cp -- "$raw_file" "$REPEAT_DIR/lun-01.jsonplus.json"
printf 'job_id\tjob_name\trepeat\tlun_label\tdataset\truntime_seconds\tstart_time\tend_time\texit_code\tparse_status\tnormal_output\tjsonplus_output\traw_output\tstderr_output\tiostat_output\n' > "$RESULT_DIR/manifest.tsv"
printf '01\t01_rand_read_300k\trepeat-01\tlun-01\t/dataset\t120\tstart\tend\t0\tFAILED\t01_rand_read_300k/repeat-01/lun-01.normal.txt\t01_rand_read_300k/repeat-01/lun-01.jsonplus.json\t%s\t01_rand_read_300k/repeat-01/lun-01.stderr.log\t01_rand_read_300k/repeat-01/iostat.txt\n' \
    "$raw_relative" >> "$RESULT_DIR/manifest.tsv"

"$ROOT_DIR/recover_result_outputs.sh" "$RESULT_DIR" >/dev/null
jq -e '.jobs | length > 0' "$REPEAT_DIR/lun-01.jsonplus.json" >/dev/null
grep -Fq 'normal text before JSON' "$REPEAT_DIR/lun-01.normal.txt"
grep -Fq 'normal text after JSON' "$REPEAT_DIR/lun-01.normal.txt"
awk -F '\t' 'NR == 2 && $10 == "PASS_RECOVERED" { found=1 } END { exit !found }' \
    "$RESULT_DIR/manifest.tsv"
find "$RESULT_DIR" -maxdepth 1 -name 'manifest.tsv.before-recovery.*' | grep -q .

echo "PASS: Kavox preserved-raw output recovery"
