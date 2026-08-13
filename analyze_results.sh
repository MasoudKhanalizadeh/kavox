#!/usr/bin/env bash

# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Masoud Khanalizadeh Imani

# Analyze one Kavox result directory without rerunning FIO.
# Layer 1: per-LUN and all-LUN aggregation inside every repetition.
# Layer 2: descriptive statistics across repetitions.

set -euo pipefail

RESULT_DIR="${1:-}"
if [[ -z "$RESULT_DIR" ]]; then
    echo "Usage: $0 RESULT_DIRECTORY" >&2
    exit 2
fi
RESULT_DIR="$(readlink -f -- "$RESULT_DIR")"
[[ -d "$RESULT_DIR" ]] || { echo "Result directory not found: $RESULT_DIR" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq is required for JSON analysis." >&2; exit 2; }

ARCH_LABEL="$(sed -n 's/^architecture=//p' "$RESULT_DIR/run.env" 2>/dev/null | head -n 1)"
ARCH_LABEL="${ARCH_LABEL:-unknown}"
EXPECTED_LUNS="$(sed -n 's/^lun_count=//p' "$RESULT_DIR/run.env" 2>/dev/null | head -n 1)"
EXPECTED_REPETITIONS="$(sed -n 's/^repetitions=//p' "$RESULT_DIR/run.env" 2>/dev/null | head -n 1)"
[[ "$EXPECTED_LUNS" =~ ^[1-9][0-9]*$ ]] || EXPECTED_LUNS=0
[[ "$EXPECTED_REPETITIONS" =~ ^[1-9][0-9]*$ ]] || EXPECTED_REPETITIONS=0

ANALYSIS_DIR="$RESULT_DIR/analysis"
mkdir -p "$ANALYSIS_DIR"
PER_LUN_JSONL="$ANALYSIS_DIR/per_lun_repeat.jsonl"
AGGREGATE_JSONL="$ANALYSIS_DIR/aggregate_repeat.jsonl"
POOLED_JSONL="$ANALYSIS_DIR/pooled_histograms.jsonl"
INVALID_TSV="$ANALYSIS_DIR/invalid_or_incomplete.tsv"
: > "$PER_LUN_JSONL"
: > "$AGGREGATE_JSONL"
: > "$POOLED_JSONL"
printf 'job_name\trepeat\tlun_label\tproblem\tfile\n' > "$INVALID_TSV"

JQ_STATS='def n: if . == null then 0 else . end;
  def addbins($a;$b):
    reduce (($b // {}) | to_entries[]) as $e
      ($a; .[$e.key] = ((.[$e.key] // 0) + ($e.value|n)));
  def bins_for($jobs;$direction):
    reduce $jobs[] as $j ({}; addbins(.; $j[$direction].clat_ns.bins));
  def combined_bins($jobs):
    reduce $jobs[] as $j ({};
      addbins(addbins(.; $j.read.clat_ns.bins); $j.write.clat_ns.bins));
  def percentile_from_bins($bins;$percentile):
    ($bins | to_entries | map({latency_ns:(.key|tonumber),count:(.value|n)}) | sort_by(.latency_ns)) as $items |
    ($items | map(.count) | add // 0) as $total |
    if $total == 0 then null
    else (($total * $percentile / 100) | ceil) as $rank |
      (reduce $items[] as $item
        ({cumulative:0,value:null,found:false};
         if .found then .
         else .cumulative += $item.count |
              if .cumulative >= $rank
              then .value=$item.latency_ns | .found=true
              else . end
         end) | .value)
    end;
  def weighted_mean_ns($jobs;$field):
    ([$jobs[] |
      ((.read[$field].mean|n) * (.read[$field].N|n)) +
      ((.write[$field].mean|n) * (.write[$field].N|n))] | add // 0) as $sum |
    ([$jobs[] | (.read[$field].N|n) + (.write[$field].N|n)] | add // 0) as $count |
    if $count > 0 then ($sum / $count) else 0 end;
  def round3: if . == null then null else ((. * 1000 | round) / 1000) end;
  def ns_to_ms: if . == null then null else (. / 1000000 | round3) end;
  def stats($jobs):
    ([$jobs[] | .read.bw_bytes|n] | add // 0) as $read_bw |
    ([$jobs[] | .write.bw_bytes|n] | add // 0) as $write_bw |
    ([$jobs[] | .read.iops|n] | add // 0) as $read_iops |
    ([$jobs[] | .write.iops|n] | add // 0) as $write_iops |
    ([$jobs[] | .read.io_bytes|n] | add // 0) as $read_bytes |
    ([$jobs[] | .write.io_bytes|n] | add // 0) as $write_bytes |
    ([$jobs[] | (.read.clat_ns.N|n)+(.write.clat_ns.N|n)] | add // 0) as $io_count |
    ([$jobs[] | (.read.clat_ns.max|n),(.write.clat_ns.max|n)] | max // 0) as $max_clat |
    ([$jobs[] | (.read.runtime|n),(.write.runtime|n)] | max // 0) as $runtime_ms |
    (combined_bins($jobs)) as $all_bins |
    (bins_for($jobs;"read")) as $read_bins |
    (bins_for($jobs;"write")) as $write_bins |
    {
      read_bw_MiB_s:($read_bw/1048576|round3),
      write_bw_MiB_s:($write_bw/1048576|round3),
      total_bw_MiB_s:(($read_bw+$write_bw)/1048576|round3),
      read_iops:($read_iops|round3), write_iops:($write_iops|round3),
      total_iops:(($read_iops+$write_iops)|round3),
      read_data_GiB:($read_bytes/1073741824|round3),
      write_data_GiB:($write_bytes/1073741824|round3),
      total_data_GiB:(($read_bytes+$write_bytes)/1073741824|round3),
      io_count:$io_count, runtime_ms:$runtime_ms,
      avg_slat_ms:(weighted_mean_ns($jobs;"slat_ns")|ns_to_ms),
      avg_clat_ms:(weighted_mean_ns($jobs;"clat_ns")|ns_to_ms),
      avg_total_lat_ms:(weighted_mean_ns($jobs;"lat_ns")|ns_to_ms),
      max_clat_ms:($max_clat|ns_to_ms),
      p50_clat_ms:(percentile_from_bins($all_bins;50)|ns_to_ms),
      p95_clat_ms:(percentile_from_bins($all_bins;95)|ns_to_ms),
      p99_clat_ms:(percentile_from_bins($all_bins;99)|ns_to_ms),
      p99_9_clat_ms:(percentile_from_bins($all_bins;99.9)|ns_to_ms),
      read_p99_clat_ms:(percentile_from_bins($read_bins;99)|ns_to_ms),
      write_p99_clat_ms:(percentile_from_bins($write_bins;99)|ns_to_ms),
      histogram_io_count:([$all_bins[]]|add//0),
      fio_error:([$jobs[]|.error|n]|max//0)
    };'

VALID_PER_LUN=0
VALID_AGGREGATE=0
VALID_POOLED=0

while IFS= read -r -d '' JOB_DIR; do
    JOB_NAME="$(basename "$JOB_DIR")"
    JOB_ID="${JOB_NAME%%_*}"
    ALL_JOB_FILES=()
    OBSERVED_REPEATS=0

    while IFS= read -r -d '' REPEAT_DIR; do
        REPEAT_LABEL="$(basename "$REPEAT_DIR")"
        OBSERVED_REPEATS=$((OBSERVED_REPEATS+1))
        VALID_FILES=()

        while IFS= read -r -d '' JSONPLUS_FILE; do
            LUN_LABEL="$(basename "$JSONPLUS_FILE" .jsonplus.json)"
            if ! jq -e '.jobs and (.jobs|length>0) and all(.jobs[]; (.error // 0) == 0)' "$JSONPLUS_FILE" >/dev/null 2>&1; then
                printf '%s\t%s\t%s\t%s\t%s\n' "$JOB_NAME" "$REPEAT_LABEL" "$LUN_LABEL" \
                    "invalid JSON+ or FIO error" "${JSONPLUS_FILE#$RESULT_DIR/}" >> "$INVALID_TSV"
                continue
            fi

            if jq -c --arg architecture "$ARCH_LABEL" --arg job_id "$JOB_ID" \
                --arg job_name "$JOB_NAME" --arg repeat "$REPEAT_LABEL" --arg lun_label "$LUN_LABEL" \
                --arg source "${JSONPLUS_FILE#$RESULT_DIR/}" \
                "$JQ_STATS .jobs as \$jobs |
                 {architecture:\$architecture,job_id:\$job_id,job_name:\$job_name,repeat:\$repeat,
                  scope:\"PER_LUN_REPEAT\",lun_label:\$lun_label,source_jsonplus:\$source} + stats(\$jobs)" \
                "$JSONPLUS_FILE" >> "$PER_LUN_JSONL"; then
                VALID_FILES+=("$JSONPLUS_FILE")
                VALID_PER_LUN=$((VALID_PER_LUN+1))
            else
                printf '%s\t%s\t%s\t%s\t%s\n' "$JOB_NAME" "$REPEAT_LABEL" "$LUN_LABEL" \
                    "analysis failed" "${JSONPLUS_FILE#$RESULT_DIR/}" >> "$INVALID_TSV"
            fi
        done < <(find "$REPEAT_DIR" -maxdepth 1 -type f -name 'lun-*.jsonplus.json' -print0 | sort -z)

        if (( ${#VALID_FILES[@]} == 0 )); then
            printf '%s\t%s\t%s\t%s\t%s\n' "$JOB_NAME" "$REPEAT_LABEL" "ALL_LUNS" \
                "no valid JSON+ files" "${REPEAT_DIR#$RESULT_DIR/}" >> "$INVALID_TSV"
            continue
        fi
        if (( EXPECTED_LUNS > 0 && ${#VALID_FILES[@]} != EXPECTED_LUNS )); then
            printf '%s\t%s\t%s\t%s\t%s\n' "$JOB_NAME" "$REPEAT_LABEL" "ALL_LUNS" \
                "valid LUN count ${#VALID_FILES[@]}; expected $EXPECTED_LUNS" "${REPEAT_DIR#$RESULT_DIR/}" >> "$INVALID_TSV"
            continue
        fi

        ALL_JOB_FILES+=("${VALID_FILES[@]}")

        SOURCES_JSON="$(printf '%s\n' "${VALID_FILES[@]#$RESULT_DIR/}" | jq -R . | jq -s .)"
        if jq -sc --arg architecture "$ARCH_LABEL" --arg job_id "$JOB_ID" --arg job_name "$JOB_NAME" \
            --arg repeat "$REPEAT_LABEL" --argjson target_count "${#VALID_FILES[@]}" --argjson sources "$SOURCES_JSON" \
            "$JQ_STATS [.[] | .jobs[]] as \$jobs |
             {architecture:\$architecture,job_id:\$job_id,job_name:\$job_name,repeat:\$repeat,
              scope:\"ALL_LUNS_REPEAT\",lun_label:\"ALL_LUNS\",target_count:\$target_count,
              source_jsonplus:\$sources} + stats(\$jobs)" "${VALID_FILES[@]}" >> "$AGGREGATE_JSONL"; then
            VALID_AGGREGATE=$((VALID_AGGREGATE+1))
        else
            printf '%s\t%s\t%s\t%s\t%s\n' "$JOB_NAME" "$REPEAT_LABEL" "ALL_LUNS" \
                "aggregate analysis failed" "${REPEAT_DIR#$RESULT_DIR/}" >> "$INVALID_TSV"
        fi
    done < <(find "$JOB_DIR" -mindepth 1 -maxdepth 1 -type d -name 'repeat-[0-9][0-9]*' -print0 | sort -z)

    if (( EXPECTED_REPETITIONS > 0 && OBSERVED_REPEATS != EXPECTED_REPETITIONS )); then
        printf '%s\t%s\t%s\t%s\t%s\n' "$JOB_NAME" "ALL_REPEATS" "ALL_LUNS" \
            "observed repeat count $OBSERVED_REPEATS; expected $EXPECTED_REPETITIONS" "${JOB_DIR#$RESULT_DIR/}" >> "$INVALID_TSV"
    fi

    if (( ${#ALL_JOB_FILES[@]} > 0 )); then
        if jq -sc --arg architecture "$ARCH_LABEL" --arg job_id "$JOB_ID" --arg job_name "$JOB_NAME" \
            --argjson source_file_count "${#ALL_JOB_FILES[@]}" \
            "$JQ_STATS [.[] | .jobs[]] as \$jobs | stats(\$jobs) as \$s |
             {architecture:\$architecture,job_id:\$job_id,job_name:\$job_name,
              source_file_count:\$source_file_count,histogram_io_count:\$s.histogram_io_count,
              pooled_p50_clat_ms:\$s.p50_clat_ms,pooled_p95_clat_ms:\$s.p95_clat_ms,
              pooled_p99_clat_ms:\$s.p99_clat_ms,pooled_p99_9_clat_ms:\$s.p99_9_clat_ms,
              pooled_read_p99_clat_ms:\$s.read_p99_clat_ms,
              pooled_write_p99_clat_ms:\$s.write_p99_clat_ms}" \
            "${ALL_JOB_FILES[@]}" >> "$POOLED_JSONL"; then
            VALID_POOLED=$((VALID_POOLED+1))
        fi
    fi
done < <(find "$RESULT_DIR" -mindepth 1 -maxdepth 1 -type d -name '[0-9][0-9]_*' -print0 | sort -z)

jq -s '.' "$PER_LUN_JSONL" > "$ANALYSIS_DIR/per_lun_repeat_summary.json"
jq -s '.' "$AGGREGATE_JSONL" > "$ANALYSIS_DIR/aggregate_repeat_summary.json"
jq -s '.' "$POOLED_JSONL" > "$ANALYSIS_DIR/pooled_histograms.json"

JQ_DESCRIPTIVE='def round3: if . == null then null else ((. * 1000 | round) / 1000) end;
  def values($rows;$field): [$rows[] | .[$field] | select(. != null)] | sort;
  def stat($values):
    ($values|length) as $n |
    if $n == 0 then {count:0,mean:null,median:null,sample_standard_deviation:null,min:null,max:null,cv_percent:null}
    else ($values|add/$n) as $mean |
      (if ($n%2)==1 then $values[($n/2|floor)]
       else (($values[$n/2-1]+$values[$n/2])/2) end) as $median |
      (if $n > 1 then (([$values[] | . as $x | (($x-$mean)*($x-$mean))] | add / ($n-1)) | sqrt) else 0 end) as $sd |
      {count:$n,mean:($mean|round3),median:($median|round3),
       sample_standard_deviation:($sd|round3),min:($values[0]|round3),max:($values[-1]|round3),
       cv_percent:(if $mean == 0 then null else (($sd/$mean*100)|round3) end)} end;
  def metrics($rows): {
    read_bw_MiB_s:stat(values($rows;"read_bw_MiB_s")),
    write_bw_MiB_s:stat(values($rows;"write_bw_MiB_s")),
    total_bw_MiB_s:stat(values($rows;"total_bw_MiB_s")),
    read_iops:stat(values($rows;"read_iops")),
    write_iops:stat(values($rows;"write_iops")),
    total_iops:stat(values($rows;"total_iops")),
    avg_clat_ms:stat(values($rows;"avg_clat_ms")),
    avg_total_lat_ms:stat(values($rows;"avg_total_lat_ms")),
    max_clat_ms:stat(values($rows;"max_clat_ms")),
    p50_clat_ms:stat(values($rows;"p50_clat_ms")),
    p95_clat_ms:stat(values($rows;"p95_clat_ms")),
    p99_clat_ms:stat(values($rows;"p99_clat_ms")),
    p99_9_clat_ms:stat(values($rows;"p99_9_clat_ms"))
  };'

jq "$JQ_DESCRIPTIVE
    group_by(.job_id + \"|\" + .lun_label) |
    map(. as \$rows | {architecture:\$rows[0].architecture,job_id:\$rows[0].job_id,
      job_name:\$rows[0].job_name,lun_label:\$rows[0].lun_label,
      repetitions_observed:(\$rows|length),repeat_labels:[\$rows[].repeat],metrics:metrics(\$rows)})" \
    "$ANALYSIS_DIR/per_lun_repeat_summary.json" > "$ANALYSIS_DIR/per_lun_statistics.json"

jq --slurpfile pooled "$ANALYSIS_DIR/pooled_histograms.json" "$JQ_DESCRIPTIVE
    (\$pooled[0] | map({key:.job_id,value:.}) | from_entries) as \$pool |
    group_by(.job_id) |
    map(. as \$rows | {architecture:\$rows[0].architecture,job_id:\$rows[0].job_id,
      job_name:\$rows[0].job_name,target_count:\$rows[0].target_count,
      repetitions_observed:(\$rows|length),repeat_labels:[\$rows[].repeat],
      metrics:metrics(\$rows),pooled_histogram:(\$pool[\$rows[0].job_id] // null)})" \
    "$ANALYSIS_DIR/aggregate_repeat_summary.json" > "$ANALYSIS_DIR/aggregate_statistics.json"

REPEAT_HEADER='architecture\tjob_id\tjob_name\trepeat\tscope\tlun_label\ttarget_count\tread_bw_MiB_s\twrite_bw_MiB_s\ttotal_bw_MiB_s\tread_iops\twrite_iops\ttotal_iops\tavg_clat_ms\tmax_clat_ms\tp50_clat_ms\tp95_clat_ms\tp99_clat_ms\tp99_9_clat_ms\tfio_error'
REPEAT_ROW='[.architecture,.job_id,.job_name,.repeat,.scope,.lun_label,(.target_count//1),.read_bw_MiB_s,.write_bw_MiB_s,.total_bw_MiB_s,.read_iops,.write_iops,.total_iops,.avg_clat_ms,.max_clat_ms,.p50_clat_ms,.p95_clat_ms,.p99_clat_ms,.p99_9_clat_ms,.fio_error]'
for BASE in per_lun_repeat aggregate_repeat; do
    {
        printf '%b\n' "$REPEAT_HEADER"
        jq -r ".[] | $REPEAT_ROW | @tsv" "$ANALYSIS_DIR/${BASE}_summary.json"
    } > "$ANALYSIS_DIR/${BASE}_summary.tsv"
    HEADER_JSON="$(printf '%b\n' "$REPEAT_HEADER" | awk -F '\t' '{for(i=1;i<=NF;i++) print $i}' | jq -R . | jq -s .)"
    {
        jq -nr --argjson header "$HEADER_JSON" '$header | @csv'
        jq -r ".[] | $REPEAT_ROW | @csv" "$ANALYSIS_DIR/${BASE}_summary.json"
    } > "$ANALYSIS_DIR/${BASE}_summary.csv"
done

STAT_HEADER='architecture\tjob_id\tjob_name\trepetitions\tmetric\tmean\tmedian\tsample_sd\tmin\tmax\tcv_percent'
{
    printf '%b\n' "$STAT_HEADER"
    jq -r '.[] as $r | $r.metrics | to_entries[] |
      [$r.architecture,$r.job_id,$r.job_name,$r.repetitions_observed,.key,
       .value.mean,.value.median,.value.sample_standard_deviation,.value.min,.value.max,.value.cv_percent] | @tsv' \
      "$ANALYSIS_DIR/aggregate_statistics.json"
} > "$ANALYSIS_DIR/aggregate_statistics.tsv"
STAT_HEADER_JSON="$(printf '%b\n' "$STAT_HEADER" | awk -F '\t' '{for(i=1;i<=NF;i++) print $i}' | jq -R . | jq -s .)"
{
    jq -nr --argjson header "$STAT_HEADER_JSON" '$header | @csv'
    jq -r '.[] as $r | $r.metrics | to_entries[] |
      [$r.architecture,$r.job_id,$r.job_name,$r.repetitions_observed,.key,
       .value.mean,.value.median,.value.sample_standard_deviation,.value.min,.value.max,.value.cv_percent] | @csv' \
      "$ANALYSIS_DIR/aggregate_statistics.json"
} > "$ANALYSIS_DIR/aggregate_statistics.csv"

if [[ -f "$RESULT_DIR/manifest.tsv" ]]; then
    jq -Rn '(input | split("\t")) as $header |
      [inputs | split("\t") as $row | reduce range(0; $header|length) as $i
       ({}; .[$header[$i]] = ($row[$i] // ""))]' "$RESULT_DIR/manifest.tsv" > "$ANALYSIS_DIR/manifest.json"
else
    echo '[]' > "$ANALYSIS_DIR/manifest.json"
fi

if [[ -f "$RESULT_DIR/benchmark_metadata.tsv" ]]; then
    jq -Rn 'input | [inputs | split("\t") | select(length >= 2 and .[0] != "") |
      {key:.[0],value:(.[1]//""),description:(.[2]//"")}] |
      {values:(map({key:.key,value:.value})|from_entries),fields:.}' \
      "$RESULT_DIR/benchmark_metadata.tsv" > "$ANALYSIS_DIR/benchmark_metadata.json"
else
    echo '{"values":{},"fields":[]}' > "$ANALYSIS_DIR/benchmark_metadata.json"
fi

BEFORE_SNAPSHOT="$RESULT_DIR/system/before/snapshot.json"
AFTER_SNAPSHOT="$RESULT_DIR/system/after/snapshot.json"
jq -n --arg schema_version "2.0" --arg generated_at "$(date -Is)" \
    --arg result_directory "$(basename "$RESULT_DIR")" --arg architecture "$ARCH_LABEL" \
    --slurpfile per_lun_repeat "$ANALYSIS_DIR/per_lun_repeat_summary.json" \
    --slurpfile aggregate_repeat "$ANALYSIS_DIR/aggregate_repeat_summary.json" \
    --slurpfile per_lun_statistics "$ANALYSIS_DIR/per_lun_statistics.json" \
    --slurpfile aggregate_statistics "$ANALYSIS_DIR/aggregate_statistics.json" \
    --slurpfile pooled_histograms "$ANALYSIS_DIR/pooled_histograms.json" \
    --slurpfile manifest "$ANALYSIS_DIR/manifest.json" \
    --slurpfile benchmark_metadata "$ANALYSIS_DIR/benchmark_metadata.json" \
    --slurpfile before <(if [[ -f "$BEFORE_SNAPSHOT" ]]; then cat "$BEFORE_SNAPSHOT"; else echo '{}'; fi) \
    --slurpfile after <(if [[ -f "$AFTER_SNAPSHOT" ]]; then cat "$AFTER_SNAPSHOT"; else echo '{}'; fi) \
    '{schema_version:$schema_version,generated_at:$generated_at,result_directory:$result_directory,
      architecture:$architecture,system:{before:$before[0],after:$after[0]},
      benchmark_metadata:$benchmark_metadata[0],manifest:$manifest[0],
      per_lun_repeat:$per_lun_repeat[0],aggregate_repeat:$aggregate_repeat[0],
      per_lun_statistics:$per_lun_statistics[0],aggregate_statistics:$aggregate_statistics[0],
      pooled_histograms:$pooled_histograms[0]}' > "$ANALYSIS_DIR/final_result.json"

{
    echo "KAVOX FIO BENCHMARK FINAL REPORT"
    echo "Original creator: Masoud Khanalizadeh Imani"
    echo "Generated: $(date -Is)"
    echo "Architecture: $ARCH_LABEL"
    echo "Result directory: $RESULT_DIR"
    echo "Expected repetitions per job: $EXPECTED_REPETITIONS"
    echo "Valid per-LUN/repeat results: $VALID_PER_LUN"
    echo "Valid all-LUN/repeat aggregates: $VALID_AGGREGATE"
    echo "Statistics: arithmetic mean, median, sample SD (n-1), min, max, and CV%."
    echo "Per-repeat aggregation: BW/IOPS sum; average latency is I/O-count weighted."
    echo "Pooled percentiles: JSON+ histograms are merged across all valid LUNs and repetitions."
    echo
    echo "PRIMARY STATISTICS"
    printf 'job_id\tjob_name\trepeats\tmetric\tmean\tmedian\tsample_sd\tmin\tmax\tcv_percent\n'
    jq -r '.[] as $r | ["total_bw_MiB_s","total_iops","avg_clat_ms","p99_clat_ms"][] as $m |
      ($r.metrics[$m]) as $s | [$r.job_id,$r.job_name,$r.repetitions_observed,$m,
       $s.mean,$s.median,$s.sample_standard_deviation,$s.min,$s.max,$s.cv_percent] | @tsv' \
      "$ANALYSIS_DIR/aggregate_statistics.json"
    echo
    echo "POOLED HISTOGRAM PERCENTILES"
    printf 'job_id\tjob_name\tp50_ms\tp95_ms\tp99_ms\tp99.9_ms\thistogram_io_count\n'
    jq -r '.[] | [.job_id,.job_name,.pooled_histogram.pooled_p50_clat_ms,
      .pooled_histogram.pooled_p95_clat_ms,.pooled_histogram.pooled_p99_clat_ms,
      .pooled_histogram.pooled_p99_9_clat_ms,.pooled_histogram.histogram_io_count] | @tsv' \
      "$ANALYSIS_DIR/aggregate_statistics.json"
    if (( $(wc -l < "$INVALID_TSV") > 1 )); then
        echo
        echo "INVALID OR INCOMPLETE RESULTS"
        cat "$INVALID_TSV"
    fi
} > "$ANALYSIS_DIR/FINAL_REPORT.txt"

find "$ANALYSIS_DIR" -maxdepth 1 -type f ! -name SHA256SUMS -print0 | sort -z | \
    xargs -0 -r sha256sum | sed "s#${RESULT_DIR}/##" > "$ANALYSIS_DIR/SHA256SUMS"

echo "Created: $ANALYSIS_DIR/aggregate_repeat_summary.tsv"
echo "Created: $ANALYSIS_DIR/aggregate_statistics.tsv"
echo "Created: $ANALYSIS_DIR/final_result.json"
echo "Created: $ANALYSIS_DIR/FINAL_REPORT.txt"

if (( VALID_AGGREGATE > 0 && VALID_POOLED > 0 )); then
    exit 0
fi
exit 1
