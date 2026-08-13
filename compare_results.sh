#!/usr/bin/env bash

# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Masoud Khanalizadeh Imani

# Compare repeat statistics from two Kavox result directories.

set -u
set -o pipefail

LEFT_DIR="${1:-}"
RIGHT_DIR="${2:-}"
OUTPUT_PREFIX="${3:-comparison}"
if [[ -z "$LEFT_DIR" || -z "$RIGHT_DIR" ]]; then
    echo "Usage: $0 LEFT_RESULT_DIR RIGHT_RESULT_DIR [OUTPUT_PREFIX]" >&2
    exit 2
fi
LEFT_JSON="$LEFT_DIR/analysis/aggregate_statistics.json"
RIGHT_JSON="$RIGHT_DIR/analysis/aggregate_statistics.json"
[[ -f "$LEFT_JSON" && -f "$RIGHT_JSON" ]] || {
    echo "Both result directories must contain analysis/aggregate_statistics.json." >&2
    echo "Run ./analyze_results.sh RESULT_DIRECTORY first." >&2
    exit 2
}
command -v jq >/dev/null 2>&1 || { echo "jq is required." >&2; exit 2; }

LEFT_LABEL="$(jq -r '.[0].architecture // "left"' "$LEFT_JSON")"
RIGHT_LABEL="$(jq -r '.[0].architecture // "right"' "$RIGHT_JSON")"
OUTPUT_JSON="${OUTPUT_PREFIX}.json"
OUTPUT_TSV="${OUTPUT_PREFIX}.tsv"
OUTPUT_CSV="${OUTPUT_PREFIX}.csv"
OUTPUT_REPORT="${OUTPUT_PREFIX}.txt"

jq -n --arg generated_at "$(date -Is)" --arg left_label "$LEFT_LABEL" --arg right_label "$RIGHT_LABEL" \
    --slurpfile left "$LEFT_JSON" --slurpfile right "$RIGHT_JSON" '
  def pct_change($new;$old):
    if $old == null or $old == 0 or $new == null then null
    else (((($new-$old)/$old)*10000|round)/100) end;
  def by_job($rows): reduce $rows[] as $row ({}; .[$row.job_id]=$row);
  (by_job($right[0])) as $right_index |
  {generated_at:$generated_at,left_label:$left_label,right_label:$right_label,
   comparison:[
    $left[0][] as $l | ($right_index[$l.job_id] // null) as $r | select($r != null) |
    {job_id:$l.job_id,job_name:$l.job_name,left_label:$left_label,right_label:$right_label,
     left_repetitions:$l.repetitions_observed,right_repetitions:$r.repetitions_observed,
     left_total_bw_mean_MiB_s:$l.metrics.total_bw_MiB_s.mean,
     right_total_bw_mean_MiB_s:$r.metrics.total_bw_MiB_s.mean,
     right_vs_left_bw_pct:pct_change($r.metrics.total_bw_MiB_s.mean;$l.metrics.total_bw_MiB_s.mean),
     left_total_iops_mean:$l.metrics.total_iops.mean,
     right_total_iops_mean:$r.metrics.total_iops.mean,
     right_vs_left_iops_pct:pct_change($r.metrics.total_iops.mean;$l.metrics.total_iops.mean),
     left_avg_clat_mean_ms:$l.metrics.avg_clat_ms.mean,
     right_avg_clat_mean_ms:$r.metrics.avg_clat_ms.mean,
     right_vs_left_avg_clat_pct:pct_change($r.metrics.avg_clat_ms.mean;$l.metrics.avg_clat_ms.mean),
     left_pooled_p99_ms:$l.pooled_histogram.pooled_p99_clat_ms,
     right_pooled_p99_ms:$r.pooled_histogram.pooled_p99_clat_ms,
     right_vs_left_pooled_p99_pct:pct_change($r.pooled_histogram.pooled_p99_clat_ms;$l.pooled_histogram.pooled_p99_clat_ms)}
   ]}' > "$OUTPUT_JSON"

HEADER='job_id\tjob_name\tleft_label\tright_label\tleft_repetitions\tright_repetitions\tleft_total_bw_mean_MiB_s\tright_total_bw_mean_MiB_s\tright_vs_left_bw_pct\tleft_total_iops_mean\tright_total_iops_mean\tright_vs_left_iops_pct\tleft_avg_clat_mean_ms\tright_avg_clat_mean_ms\tright_vs_left_avg_clat_pct\tleft_pooled_p99_ms\tright_pooled_p99_ms\tright_vs_left_pooled_p99_pct'
ROW='[.job_id,.job_name,.left_label,.right_label,.left_repetitions,.right_repetitions,.left_total_bw_mean_MiB_s,.right_total_bw_mean_MiB_s,.right_vs_left_bw_pct,.left_total_iops_mean,.right_total_iops_mean,.right_vs_left_iops_pct,.left_avg_clat_mean_ms,.right_avg_clat_mean_ms,.right_vs_left_avg_clat_pct,.left_pooled_p99_ms,.right_pooled_p99_ms,.right_vs_left_pooled_p99_pct]'
{
    printf '%b\n' "$HEADER"
    jq -r ".comparison[] | $ROW | @tsv" "$OUTPUT_JSON"
} > "$OUTPUT_TSV"
HEADER_JSON="$(printf '%b\n' "$HEADER" | awk -F '\t' '{for(i=1;i<=NF;i++) print $i}' | jq -R . | jq -s .)"
{
    jq -nr --argjson header "$HEADER_JSON" '$header | @csv'
    jq -r ".comparison[] | $ROW | @csv" "$OUTPUT_JSON"
} > "$OUTPUT_CSV"
{
    echo "KAVOX FIO RESULT COMPARISON"
    echo "Generated: $(date -Is)"
    echo "Left:  $LEFT_LABEL ($LEFT_DIR)"
    echo "Right: $RIGHT_LABEL ($RIGHT_DIR)"
    echo "BW/IOPS compare repetition means. Latency p99 compares pooled JSON+ histograms."
    echo "Positive BW/IOPS means right is higher; positive latency means right is slower."
    echo
    column -t -s $'\t' "$OUTPUT_TSV" 2>/dev/null || sed 's/\t/  /g' "$OUTPUT_TSV"
} > "$OUTPUT_REPORT"

echo "Created: $OUTPUT_JSON"
echo "Created: $OUTPUT_TSV"
echo "Created: $OUTPUT_CSV"
echo "Created: $OUTPUT_REPORT"
