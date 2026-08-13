#!/usr/bin/env bash

# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Masoud Khanalizadeh Imani

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
RESULT_DIR="$TEST_ROOT/baremetal_fixture"
mkdir -p "$RESULT_DIR/system/before" "$RESULT_DIR/system/after"
printf 'architecture=baremetal\nlun_count=2\nrepetitions=3\n' > "$RESULT_DIR/run.env"
printf 'key\tvalue\tdescription\n' > "$RESULT_DIR/benchmark_metadata.tsv"
printf '{}\n' > "$RESULT_DIR/system/before/snapshot.json"
printf '{}\n' > "$RESULT_DIR/system/after/snapshot.json"
printf 'job_id\tjob_name\trepeat\tlun_label\n' > "$RESULT_DIR/manifest.tsv"

scales=(1 2 2 2 2 3)
index=0
for repeat in 01 02 03; do
    repeat_dir="$RESULT_DIR/01_fixture/repeat-$repeat"
    mkdir -p "$repeat_dir"
    for lun in 01 02; do
        scale="${scales[$index]}"
        index=$((index+1))
        jq --argjson s "$scale" '
          .jobs[0].read.bw_bytes *= $s |
          .jobs[0].read.iops *= $s |
          .jobs[0].read.io_bytes *= $s |
          .jobs[0].read.slat_ns.N *= $s |
          .jobs[0].read.clat_ns.N *= $s |
          .jobs[0].read.lat_ns.N *= $s |
          .jobs[0].read.clat_ns.bins |= with_entries(.value *= $s)
        ' "$ROOT_DIR/tests/fixture_jsonplus.json" > "$repeat_dir/lun-$lun.jsonplus.json"
    done
done

"$ROOT_DIR/analyze_results.sh" "$RESULT_DIR" >/dev/null

jq -e '
  length == 1 and
  .[0].repetitions_observed == 3 and
  .[0].metrics.total_bw_MiB_s.mean == 400 and
  .[0].metrics.total_bw_MiB_s.median == 400 and
  .[0].metrics.total_bw_MiB_s.sample_standard_deviation == 100 and
  .[0].metrics.total_bw_MiB_s.min == 300 and
  .[0].metrics.total_bw_MiB_s.max == 500 and
  .[0].metrics.total_bw_MiB_s.cv_percent == 25 and
  .[0].metrics.total_iops.mean == 4000 and
  .[0].pooled_histogram.pooled_p99_clat_ms == 2
' "$RESULT_DIR/analysis/aggregate_statistics.json" >/dev/null

[[ "$(wc -l < "$RESULT_DIR/analysis/aggregate_repeat_summary.csv")" -eq 4 ]]
[[ "$(wc -l < "$RESULT_DIR/analysis/aggregate_statistics.csv")" -eq 14 ]]
jq -e '.schema_version == "2.0" and (.aggregate_repeat|length) == 3' \
    "$RESULT_DIR/analysis/final_result.json" >/dev/null

"$ROOT_DIR/compare_results.sh" "$RESULT_DIR" "$RESULT_DIR" "$TEST_ROOT/self_compare" >/dev/null
jq -e '.comparison|length == 1 and .[0].right_vs_left_bw_pct == 0 and
  .[0].right_vs_left_iops_pct == 0 and .[0].right_vs_left_pooled_p99_pct == 0' \
  "$TEST_ROOT/self_compare.json" >/dev/null

echo "PASS: Kavox analyzer/statistics self-test"
