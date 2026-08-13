#!/usr/bin/env bash

# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Masoud Khanalizadeh Imani

# Kavox runner: parallel multi-LUN execution, automatic repetitions,
# JSON+ and normal outputs, low-overhead iostat telemetry, system snapshots,
# and automatic per-repeat/statistical analysis.

set -u
set -o pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
JOBS_DIR="$ROOT_DIR/jobs"
RESULTS_DIR="$ROOT_DIR/results"
DATASET_RELATIVE_PATH="fio-test/fio-data-1TiB.bin"
DATA_SIZE=1099511627776
RUNNER_VERSION="0.1.0"

ARCH_LABEL="${1:-}"
SELECTED_IDS="${2:-}"
RUNTIME_SECONDS="${3:-}"
MOUNT_PATHS_ARGUMENT="${4:-}"
REPETITIONS="${5:-}"
COOLDOWN_SECONDS="${6:-}"
IOSTAT_ENABLED="${7:-}"
IOSTAT_INTERVAL="${8:-}"
QD_POLICY="${9:-}"
CUSTOM_TOTAL_QD="${10:-}"
RUN_LABEL_RAW="${11:-}"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

normalize_yes_no() {
    case "${1,,}" in
        y|yes|1|true) echo "yes" ;;
        n|no|0|false) echo "no" ;;
        *) return 1 ;;
    esac
}

normalize_run_label() {
    local label="${1,,}"

    # Make a short human label filesystem-safe and predictable. Spaces become
    # hyphens; all other accepted characters are preserved.
    label="${label// /-}"
    while [[ "$label" == *--* ]]; do label="${label//--/-}"; done
    [[ -z "$label" || "$label" == "-" || "$label" == "none" ]] && {
        printf '\n'
        return 0
    }
    (( ${#label} <= 40 )) || return 1
    [[ "$label" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || return 1
    printf '%s\n' "$label"
}

read_profile_integer() {
    local job_file="$1"
    local key="$2"
    local value

    value="$(awk -F '=' -v wanted="$key" '
        {
            name=$1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
            if (name == wanted) {
                result=$2
                sub(/[;#].*$/, "", result)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", result)
                count++
            }
        }
        END {
            if (count != 1 || result !~ /^[1-9][0-9]*$/) exit 1
            print result
        }
    ' "$job_file")" || die "Profile must contain exactly one positive integer $key: $job_file"
    printf '%s\n' "$value"
}

# Sets APPLIED_NUMJOBS, APPLIED_IODEPTH, APPLIED_QD, AGGREGATE_TARGET_QD,
# and QD_ALLOCATION_METHOD for one LUN. Extra workers/depth are rotated across
# LUNs on later repetitions so the same LUN is not always favored.
calculate_qd_allocation() {
    local source_numjobs="$1"
    local source_iodepth="$2"
    local lun_index="$3"
    local repeat_number="$4"
    local lun_count="${#DATA_FILES[@]}"
    local source_qd=$((source_numjobs * source_iodepth))
    local target_qd total_workers base remainder rotation distance extra lun_qd

    if [[ "$QD_POLICY" == "per-lun-profile" ]]; then
        APPLIED_NUMJOBS="$source_numjobs"
        APPLIED_IODEPTH="$source_iodepth"
        APPLIED_QD="$source_qd"
        AGGREGATE_TARGET_QD=$((source_qd * lun_count))
        QD_ALLOCATION_METHOD="fixed-per-lun"
        return 0
    fi

    if [[ "$QD_POLICY" == "custom-total" ]]; then
        target_qd="$CUSTOM_TOTAL_QD"
    else
        target_qd="$source_qd"
    fi
    (( target_qd >= lun_count )) || die \
        "Aggregate QD $target_qd is smaller than LUN count $lun_count; every LUN needs at least QD 1."
    AGGREGATE_TARGET_QD="$target_qd"

    # Prefer preserving the profile's iodepth and distribute its total workers.
    # Example: 16 jobs x depth 16 over 3 LUNs becomes 6/5/5 jobs x depth 16.
    if (( target_qd % source_iodepth == 0 )); then
        total_workers=$((target_qd / source_iodepth))
    else
        total_workers=0
    fi
    if (( total_workers >= lun_count )); then
        base=$((total_workers / lun_count))
        remainder=$((total_workers % lun_count))
        rotation=$(((repeat_number - 1) % lun_count))
        distance=$(((lun_index - rotation + lun_count) % lun_count))
        extra=0
        (( distance < remainder )) && extra=1
        APPLIED_NUMJOBS=$((base + extra))
        APPLIED_IODEPTH="$source_iodepth"
        APPLIED_QD=$((APPLIED_NUMJOBS * APPLIED_IODEPTH))
        QD_ALLOCATION_METHOD="distribute-numjobs"
        return 0
    fi

    # When there are fewer source workers than LUNs (typical sequential job),
    # keep one worker per LUN and split aggregate queue slots exactly.
    base=$((target_qd / lun_count))
    remainder=$((target_qd % lun_count))
    rotation=$(((repeat_number - 1) % lun_count))
    distance=$(((lun_index - rotation + lun_count) % lun_count))
    extra=0
    (( distance < remainder )) && extra=1
    lun_qd=$((base + extra))
    APPLIED_NUMJOBS=1
    APPLIED_IODEPTH="$lun_qd"
    APPLIED_QD="$lun_qd"
    QD_ALLOCATION_METHOD="distribute-iodepth"
}

if [[ -z "$ARCH_LABEL" ]]; then
    echo "Select architecture:"
    echo "  1) Bare Metal"
    echo "  2) ESXi VM"
    read -r -p "Choice [1]: " ARCH_CHOICE
    case "${ARCH_CHOICE:-1}" in
        1) ARCH_LABEL="baremetal" ;;
        2) ARCH_LABEL="esxi" ;;
        *) die "Invalid architecture choice." ;;
    esac
fi
[[ "$ARCH_LABEL" =~ ^[A-Za-z0-9._-]+$ ]] || die "Architecture label contains unsupported characters."

echo
echo "Available FIO jobs:"
echo "  01) Random Read 300KiB       08) Mixed 30R/70W 300KiB"
echo "  02) Random Write 300KiB      09) Mixed 10R/90W 300KiB"
echo "  03) Sequential Read 1MiB     10) Zipf 90R/10W 300KiB"
echo "  04) Sequential Write 1MiB    11) Zipf 70R/30W 300KiB"
echo "  05) Mixed 90R/10W 300KiB     12) Zipf 50R/50W 300KiB"
echo "  06) Mixed 70R/30W 300KiB     13) Zipf 30R/70W 300KiB"
echo "  07) Mixed 50R/50W 300KiB     14) Zipf 10R/90W 300KiB"
echo "  15) Zipf Random Read 8KiB"
echo "  16) Zipf Random Write 8KiB"
echo "  17) Zipf Mixed 70R/30W 8KiB"
echo "  18) Sequential Read 4MiB"
echo "  19) Sequential Write 4MiB"
echo

if [[ -z "$SELECTED_IDS" ]]; then
    read -r -p "Enter all or comma-separated IDs [all]: " SELECTED_IDS
    SELECTED_IDS="${SELECTED_IDS:-all}"
fi
SELECTED_IDS="${SELECTED_IDS// /}"
if [[ "$SELECTED_IDS" != "all" && ! "$SELECTED_IDS" =~ ^(0[1-9]|1[0-9])(,(0[1-9]|1[0-9]))*$ ]]; then
    die "Use all or IDs 01 through 19 separated by commas."
fi

if [[ -z "$RUNTIME_SECONDS" ]]; then
    read -r -p "Runtime for each repetition in seconds: " RUNTIME_SECONDS
fi
[[ "$RUNTIME_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "Runtime must be a positive whole number."

if [[ -z "$REPETITIONS" ]]; then
    read -r -p "Number of repetitions for each job [3]: " REPETITIONS
    REPETITIONS="${REPETITIONS:-3}"
fi
[[ "$REPETITIONS" =~ ^[1-9][0-9]*$ ]] || die "Repetitions must be a positive whole number."

if [[ -z "$COOLDOWN_SECONDS" ]]; then
    read -r -p "Cooldown between repetitions in seconds [15]: " COOLDOWN_SECONDS
    COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-15}"
fi
[[ "$COOLDOWN_SECONDS" =~ ^[0-9]+$ ]] || die "Cooldown must be a non-negative whole number."

if [[ -z "$IOSTAT_ENABLED" ]]; then
    read -r -p "Enable iostat telemetry? [Y]: " IOSTAT_ENABLED
    IOSTAT_ENABLED="${IOSTAT_ENABLED:-Y}"
fi
IOSTAT_ENABLED="$(normalize_yes_no "$IOSTAT_ENABLED")" || die "iostat choice must be yes or no."

if [[ "$IOSTAT_ENABLED" == "yes" ]]; then
    if [[ -z "$IOSTAT_INTERVAL" ]]; then
        read -r -p "iostat sampling interval in seconds [5]: " IOSTAT_INTERVAL
        IOSTAT_INTERVAL="${IOSTAT_INTERVAL:-5}"
    fi
    [[ "$IOSTAT_INTERVAL" =~ ^[1-9][0-9]*$ ]] || die "iostat interval must be a positive whole number."
else
    IOSTAT_INTERVAL="0"
fi

MOUNT_PATHS=()
if [[ -n "$MOUNT_PATHS_ARGUMENT" ]]; then
    IFS=',' read -r -a MOUNT_PATHS <<< "$MOUNT_PATHS_ARGUMENT"
else
    echo
    read -r -p "Number of LUNs [1]: " LUN_COUNT
    LUN_COUNT="${LUN_COUNT:-1}"
    [[ "$LUN_COUNT" =~ ^[1-9][0-9]*$ ]] || die "LUN count must be a positive whole number."
    for ((LUN_INDEX=1; LUN_INDEX<=LUN_COUNT; LUN_INDEX++)); do
        if (( LUN_COUNT == 1 )); then
            read -r -p "Mount path for LUN 1 [/mnt/storage]: " MOUNT_PATH
            MOUNT_PATH="${MOUNT_PATH:-/mnt/storage}"
        else
            read -r -p "Mount path for LUN $LUN_INDEX: " MOUNT_PATH
        fi
        [[ -n "$MOUNT_PATH" ]] || die "Mount path cannot be empty."
        MOUNT_PATHS+=("$MOUNT_PATH")
    done
fi
(( ${#MOUNT_PATHS[@]} > 0 )) || die "No LUN path was provided."

DATA_FILES=()
LUN_LABELS=()
for ((LUN_INDEX=0; LUN_INDEX<${#MOUNT_PATHS[@]}; LUN_INDEX++)); do
    MOUNT_PATH="${MOUNT_PATHS[$LUN_INDEX]}"
    while [[ "$MOUNT_PATH" != "/" && "$MOUNT_PATH" == */ ]]; do
        MOUNT_PATH="${MOUNT_PATH%/}"
    done
    [[ "$MOUNT_PATH" =~ ^/[A-Za-z0-9._/-]+$ && "$MOUNT_PATH" != "/" ]] || \
        die "Invalid mount path: $MOUNT_PATH"
    MOUNT_PATHS[$LUN_INDEX]="$MOUNT_PATH"
    DATA_FILE="$MOUNT_PATH/$DATASET_RELATIVE_PATH"
    for PREVIOUS_DATA_FILE in "${DATA_FILES[@]:-}"; do
        [[ "$DATA_FILE" != "$PREVIOUS_DATA_FILE" ]] || die "Duplicate LUN path: $MOUNT_PATH"
    done
    DATA_FILES+=("$DATA_FILE")
    printf -v LUN_LABEL 'lun-%02d' "$((LUN_INDEX+1))"
    LUN_LABELS+=("$LUN_LABEL")
done
MOUNT_PATHS_CSV="$(IFS=,; echo "${MOUNT_PATHS[*]}")"

for REQUIRED_COMMAND in fio jq awk mountpoint findmnt stat sha256sum readlink; do
    command -v "$REQUIRED_COMMAND" >/dev/null 2>&1 || die "$REQUIRED_COMMAND is required but unavailable."
done
[[ -x "$ROOT_DIR/collect_system_info.sh" ]] || die "collect_system_info.sh is missing or not executable."
[[ -x "$ROOT_DIR/analyze_results.sh" ]] || die "analyze_results.sh is missing or not executable."
[[ -f "$ROOT_DIR/split_fio_output.awk" ]] || die "split_fio_output.awk is missing."

IOSTAT_AVAILABLE="no"
if [[ "$IOSTAT_ENABLED" == "yes" ]]; then
    if command -v iostat >/dev/null 2>&1; then
        IOSTAT_AVAILABLE="yes"
    else
        echo "WARNING: iostat is unavailable; telemetry will be skipped without stopping FIO." >&2
    fi
fi

for ((LUN_INDEX=0; LUN_INDEX<${#DATA_FILES[@]}; LUN_INDEX++)); do
    DATA_FILE="${DATA_FILES[$LUN_INDEX]}"
    LUN_LABEL="${LUN_LABELS[$LUN_INDEX]}"
    MOUNT_PATH="${MOUNT_PATHS[$LUN_INDEX]}"
    mountpoint -q -- "$MOUNT_PATH" || die "Mount point is not active for $LUN_LABEL: $MOUNT_PATH"
    FS_TYPE="$(findmnt -nro FSTYPE --target "$MOUNT_PATH" 2>/dev/null || true)"
    FS_UUID="$(findmnt -nro UUID --target "$MOUNT_PATH" 2>/dev/null || true)"
    [[ "$FS_TYPE" == "xfs" && -n "$FS_UUID" ]] || die "Expected mounted XFS with UUID for $LUN_LABEL."
    [[ -f "$DATA_FILE" && -r "$DATA_FILE" && -w "$DATA_FILE" ]] || die "Dataset is missing or inaccessible: $DATA_FILE"
    FILE_SIZE="$(stat -c %s -- "$DATA_FILE")"
    (( FILE_SIZE == DATA_SIZE )) || die "Dataset is not exactly 1 TiB: $DATA_FILE"
    MARKER="${DATA_FILE}.fio-initialized"
    INODE="$(stat -c %i -- "$DATA_FILE" 2>/dev/null || echo 0)"
    if [[ ! -f "$MARKER" ]] || \
       ! grep -Fxq "size_bytes=$DATA_SIZE" "$MARKER" || \
       ! grep -Fxq "filesystem_uuid=$FS_UUID" "$MARKER" || \
       ! grep -Fxq "inode=$INODE" "$MARKER"; then
        die "Dataset marker is missing or invalid for $LUN_LABEL. Use ./kavox.sh -> Dataset status; do not recreate an existing 1 TiB file."
    fi
done

SELECTED_JOBS=()
shopt -s nullglob
for JOB_FILE in "$JOBS_DIR"/*.fio; do
    JOB_NAME="$(basename "$JOB_FILE")"
    JOB_ID="${JOB_NAME%%_*}"
    if [[ "$SELECTED_IDS" == "all" || ",$SELECTED_IDS," == *",$JOB_ID,"* ]]; then
        SELECTED_JOBS+=("$JOB_FILE")
    fi
done
shopt -u nullglob
(( ${#SELECTED_JOBS[@]} > 0 )) || die "No job was selected."

if [[ -z "$QD_POLICY" ]]; then
    echo
    echo "Queue-depth policy:"
    echo "  1) Equal aggregate QD (recommended for fair architecture comparison)"
    echo "     Keep each profile's original single-LUN total QD and divide it across all LUNs."
    echo "  2) Custom aggregate QD"
    echo "     Use one user-supplied total QD for every selected profile and divide it across all LUNs."
    echo "  3) Fixed QD per LUN (scaling/load test; legacy behavior)"
    echo "     Apply the original profile unchanged to every LUN, so aggregate QD grows with LUN count."
    read -r -p "Choice [1]: " QD_CHOICE
    case "${QD_CHOICE:-1}" in
        1) QD_POLICY="normalize-profile" ;;
        2) QD_POLICY="custom-total" ;;
        3) QD_POLICY="per-lun-profile" ;;
        *) die "Invalid queue-depth policy." ;;
    esac
fi
case "$QD_POLICY" in
    1|normalize|normalized|normalize-profile) QD_POLICY="normalize-profile" ;;
    2|custom|custom-total) QD_POLICY="custom-total" ;;
    3|scaling|per-lun|per-lun-profile) QD_POLICY="per-lun-profile" ;;
    *) die "QD policy must be normalize-profile, custom-total, or per-lun-profile." ;;
esac

if [[ "$QD_POLICY" == "custom-total" ]]; then
    if [[ -z "$CUSTOM_TOTAL_QD" ]]; then
        read -r -p "Aggregate QD target shared by all selected profiles: " CUSTOM_TOTAL_QD
    fi
    [[ "$CUSTOM_TOTAL_QD" =~ ^[1-9][0-9]*$ ]] || die "Custom aggregate QD must be a positive whole number."
    (( CUSTOM_TOTAL_QD >= ${#DATA_FILES[@]} )) || die \
        "Custom aggregate QD must be at least the number of active LUNs (${#DATA_FILES[@]})."
else
    CUSTOM_TOTAL_QD=""
fi

declare -A SOURCE_NUMJOBS_BY_JOB=()
declare -A SOURCE_IODEPTH_BY_JOB=()
declare -A SOURCE_QD_BY_JOB=()
for JOB_FILE in "${SELECTED_JOBS[@]}"; do
    JOB_NAME="$(basename "$JOB_FILE" .fio)"
    SOURCE_NUMJOBS_BY_JOB[$JOB_NAME]="$(read_profile_integer "$JOB_FILE" numjobs)"
    SOURCE_IODEPTH_BY_JOB[$JOB_NAME]="$(read_profile_integer "$JOB_FILE" iodepth)"
    SOURCE_QD_BY_JOB[$JOB_NAME]=$(( \
        SOURCE_NUMJOBS_BY_JOB[$JOB_NAME] * SOURCE_IODEPTH_BY_JOB[$JOB_NAME] \
    ))
    if [[ "$QD_POLICY" == "normalize-profile" ]] && \
       (( SOURCE_QD_BY_JOB[$JOB_NAME] < ${#DATA_FILES[@]} )); then
        die "Profile $JOB_NAME has QD ${SOURCE_QD_BY_JOB[$JOB_NAME]}, smaller than active LUN count ${#DATA_FILES[@]}."
    fi
done

if (( $# < 11 )) && [[ -t 0 ]]; then
    echo
    echo "Optional run label helps distinguish storage layouts or test campaigns."
    echo "Example: raid5-pool-a (English letters/numbers; spaces become hyphens; max 40 chars)"
    read -r -p "Run label [none]: " RUN_LABEL_RAW
fi
RUN_LABEL="$(normalize_run_label "$RUN_LABEL_RAW")" || die \
    "Run label must start with a letter/number and use only English letters, numbers, dot, underscore, hyphen, or spaces (max 40)."

PROFILE_IDS_DASHED=""
for JOB_FILE in "${SELECTED_JOBS[@]}"; do
    JOB_NAME="$(basename "$JOB_FILE" .fio)"
    JOB_ID="${JOB_NAME%%_*}"
    PROFILE_IDS_DASHED+="${PROFILE_IDS_DASHED:+-}$JOB_ID"
done
if [[ "$SELECTED_IDS" == "all" ]]; then
    PROFILE_TAG="jobs-all${#SELECTED_JOBS[@]}"
else
    PROFILE_TAG="jobs-$PROFILE_IDS_DASHED"
fi
case "$QD_POLICY" in
    normalize-profile) QD_NAME_TAG="qd-equal-profile" ;;
    custom-total) QD_NAME_TAG="qd-total-$CUSTOM_TOTAL_QD" ;;
    per-lun-profile) QD_NAME_TAG="qd-perlun-profile" ;;
esac

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RUN_BASENAME="${ARCH_LABEL}_${#DATA_FILES[@]}lun_${QD_NAME_TAG}_${PROFILE_TAG}_rt${RUNTIME_SECONDS}s_r${REPETITIONS}"
[[ -n "$RUN_LABEL" ]] && RUN_BASENAME+="_tag-${RUN_LABEL}"
RUN_BASENAME+="_${TIMESTAMP}"
(( ${#RUN_BASENAME} <= 240 )) || die "Generated result directory name is too long. Shorten the architecture or run label."

TOTAL_REPEATS=$(( ${#SELECTED_JOBS[@]} * REPETITIONS ))
ESTIMATED_SECONDS=$(( TOTAL_REPEATS * RUNTIME_SECONDS + (TOTAL_REPEATS > 0 ? (TOTAL_REPEATS - 1) * COOLDOWN_SECONDS : 0) ))

echo
echo "Architecture : $ARCH_LABEL"
echo "Selected IDs : $SELECTED_IDS"
echo "Runtime      : $RUNTIME_SECONDS seconds per repetition"
echo "Repetitions  : $REPETITIONS per job"
echo "Cooldown     : $COOLDOWN_SECONDS seconds"
echo "Job count    : ${#SELECTED_JOBS[@]}"
echo "LUN count    : ${#DATA_FILES[@]}"
echo "QD policy    : $QD_POLICY"
[[ "$QD_POLICY" == "custom-total" ]] && echo "Custom QD    : $CUSTOM_TOTAL_QD aggregate"
echo "Run label    : ${RUN_LABEL:-none}"
echo "Result name  : $RUN_BASENAME"
echo "Output       : normal + JSON+ (one FIO execution)"
echo "iostat       : $IOSTAT_ENABLED; available=$IOSTAT_AVAILABLE; interval=${IOSTAT_INTERVAL}s"
printf 'Estimated FIO/cooldown time: %02d:%02d:%02d\n' \
    "$((ESTIMATED_SECONDS/3600))" "$(((ESTIMATED_SECONDS%3600)/60))" "$((ESTIMATED_SECONDS%60))"
for ((LUN_INDEX=0; LUN_INDEX<${#DATA_FILES[@]}; LUN_INDEX++)); do
    echo "  ${LUN_LABELS[$LUN_INDEX]}       : ${DATA_FILES[$LUN_INDEX]}"
done
echo
echo "Queue-depth plan for repeat 1:"
printf '  %-32s %-17s %-18s %s\n' "Profile" "Source" "Aggregate target" "Per-LUN allocation"
for JOB_FILE in "${SELECTED_JOBS[@]}"; do
    JOB_NAME="$(basename "$JOB_FILE" .fio)"
    SOURCE_NUMJOBS="${SOURCE_NUMJOBS_BY_JOB[$JOB_NAME]}"
    SOURCE_IODEPTH="${SOURCE_IODEPTH_BY_JOB[$JOB_NAME]}"
    ALLOCATION_TEXT=""
    for ((LUN_INDEX=0; LUN_INDEX<${#DATA_FILES[@]}; LUN_INDEX++)); do
        calculate_qd_allocation "$SOURCE_NUMJOBS" "$SOURCE_IODEPTH" "$LUN_INDEX" 1
        ALLOCATION_TEXT+="${ALLOCATION_TEXT:+, }L$((LUN_INDEX+1)):${APPLIED_NUMJOBS}x${APPLIED_IODEPTH}=${APPLIED_QD}"
    done
    printf '  %-32s %-17s %-18s %s\n' "$JOB_NAME" \
        "${SOURCE_NUMJOBS}x${SOURCE_IODEPTH}=${SOURCE_QD_BY_JOB[$JOB_NAME]}" \
        "$AGGREGATE_TARGET_QD" "$ALLOCATION_TEXT"
done
echo
echo "Within each repetition, all LUNs run in parallel; jobs and repetitions are serial."
if [[ "$QD_POLICY" != "per-lun-profile" ]]; then
    echo "Aggregate QD is held exact. Any indivisible extra workers/depth rotate between LUNs across repetitions."
else
    echo "SCALING MODE: aggregate QD increases in direct proportion to the number of active LUNs."
fi
echo "WARNING: Write and mixed BENCHMARK jobs intentionally write inside the existing dedicated dataset files."
echo "They do not delete or recreate the files, but their contents and modification time will change."
read -r -p "Type YES to start: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || { echo "Cancelled."; exit 0; }

RUN_DIR="$RESULTS_DIR/$RUN_BASENAME"
COLLISION_INDEX=2
while [[ -e "$RUN_DIR" ]]; do
    RUN_DIR="$RESULTS_DIR/${RUN_BASENAME}_$COLLISION_INDEX"
    COLLISION_INDEX=$((COLLISION_INDEX+1))
done
mkdir -p "$RUN_DIR/system/before" "$RUN_DIR/system/after" "$RUN_DIR/system/repeats" "$RUN_DIR/analysis"
RUN_LOG="$RUN_DIR/run.log"
MANIFEST="$RUN_DIR/manifest.tsv"
QD_PLAN="$RUN_DIR/qd_plan.tsv"
if [[ -f "$ROOT_DIR/benchmark_metadata.tsv" ]]; then
    cp -- "$ROOT_DIR/benchmark_metadata.tsv" "$RUN_DIR/benchmark_metadata.tsv"
elif [[ -f "$ROOT_DIR/benchmark_metadata.example.tsv" ]]; then
    cp -- "$ROOT_DIR/benchmark_metadata.example.tsv" "$RUN_DIR/benchmark_metadata.tsv"
fi
printf 'job_id\tjob_name\trepeat\tlun_label\tdataset\truntime_seconds\tstart_time\tend_time\texit_code\tparse_status\tnormal_output\tjsonplus_output\traw_output\tstderr_output\tiostat_output\n' > "$MANIFEST"
printf 'job_id\tjob_name\trepeat\tlun_label\tqd_policy\tsource_numjobs\tsource_iodepth\tsource_qd\tapplied_numjobs\tapplied_iodepth\tapplied_qd\taggregate_target_qd\tallocation_method\n' > "$QD_PLAN"
for JOB_FILE in "${SELECTED_JOBS[@]}"; do
    JOB_NAME="$(basename "$JOB_FILE" .fio)"
    JOB_ID="${JOB_NAME%%_*}"
    SOURCE_NUMJOBS="${SOURCE_NUMJOBS_BY_JOB[$JOB_NAME]}"
    SOURCE_IODEPTH="${SOURCE_IODEPTH_BY_JOB[$JOB_NAME]}"
    for ((PLAN_REPEAT=1; PLAN_REPEAT<=REPETITIONS; PLAN_REPEAT++)); do
        printf -v PLAN_REPEAT_LABEL 'repeat-%02d' "$PLAN_REPEAT"
        for ((LUN_INDEX=0; LUN_INDEX<${#DATA_FILES[@]}; LUN_INDEX++)); do
            calculate_qd_allocation "$SOURCE_NUMJOBS" "$SOURCE_IODEPTH" "$LUN_INDEX" "$PLAN_REPEAT"
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$JOB_ID" "$JOB_NAME" "$PLAN_REPEAT_LABEL" "${LUN_LABELS[$LUN_INDEX]}" "$QD_POLICY" \
                "$SOURCE_NUMJOBS" "$SOURCE_IODEPTH" "${SOURCE_QD_BY_JOB[$JOB_NAME]}" \
                "$APPLIED_NUMJOBS" "$APPLIED_IODEPTH" "$APPLIED_QD" "$AGGREGATE_TARGET_QD" \
                "$QD_ALLOCATION_METHOD" >> "$QD_PLAN"
        done
    done
done

{
    echo "runner_version=$RUNNER_VERSION"
    echo "result_directory_name=$(basename "$RUN_DIR")"
    echo "architecture=$ARCH_LABEL"
    echo "selected_ids=$SELECTED_IDS"
    echo "profile_tag=$PROFILE_TAG"
    echo "runtime_seconds=$RUNTIME_SECONDS"
    echo "repetitions=$REPETITIONS"
    echo "cooldown_seconds=$COOLDOWN_SECONDS"
    echo "iostat_requested=$IOSTAT_ENABLED"
    echo "iostat_available=$IOSTAT_AVAILABLE"
    echo "iostat_interval_seconds=$IOSTAT_INTERVAL"
    echo "lun_count=${#DATA_FILES[@]}"
    echo "qd_policy=$QD_POLICY"
    echo "qd_name_tag=$QD_NAME_TAG"
    echo "custom_total_qd=${CUSTOM_TOTAL_QD:-not-set}"
    echo "run_label=${RUN_LABEL:-not-set}"
    echo "qd_plan=qd_plan.tsv"
    echo "mount_paths=$MOUNT_PATHS_CSV"
    echo "dataset_relative_path=$DATASET_RELATIVE_PATH"
    echo "started_at=$(date -Is)"
    echo "hostname=$(hostname 2>/dev/null || echo unknown)"
    echo "kernel=$(uname -r 2>/dev/null || echo unknown)"
    echo "fio_version=$(fio --version 2>/dev/null || echo unknown)"
    echo "virtualization=$(systemd-detect-virt 2>/dev/null || echo none-or-unknown)"
} > "$RUN_DIR/run.env"

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $*" | tee -a "$RUN_LOG"
}

collect_repeat_state() {
    local output_dir="$1"
    local label="$2"
    mkdir -p "$output_dir"
    {
        echo "label=$label"
        echo "captured_at=$(date -Is)"
        echo "uptime_seconds=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)"
        echo "load_average=$(cat /proc/loadavg 2>/dev/null || true)"
    } > "$output_dir/state.txt"
    free -b > "$output_dir/free.txt" 2>&1 || true
    vmstat -s > "$output_dir/vmstat.txt" 2>&1 || true
    df -B1 -T "${MOUNT_PATHS[@]}" > "$output_dir/df.txt" 2>&1 || true
    ps -eo pid,ppid,psr,ni,stat,pcpu,pmem,comm --sort=-pcpu > "$output_dir/processes.txt" 2>&1 || true
    {
        for host in /sys/class/fc_host/host*; do
            [[ -d "$host" ]] || continue
            echo "[$(basename "$host")]"
            for field in port_name node_name port_state speed; do
                [[ -r "$host/$field" ]] && printf '%s=%s\n' "$field" "$(<"$host/$field")"
            done
            for stat_file in "$host"/statistics/*; do
                [[ -r "$stat_file" ]] && printf 'statistics.%s=%s\n' "$(basename "$stat_file")" "$(<"$stat_file")"
            done
        done
    } > "$output_dir/fibre-channel.txt" 2>&1
}

split_fio_output() {
    local combined_file="$1"
    local normal_file="$2"
    local jsonplus_file="$3"

    awk -v normal_file="$normal_file" -v json_file="$jsonplus_file" \
        -f "$ROOT_DIR/split_fio_output.awk" "$combined_file" || return 1
    jq -e '.jobs and (.jobs|length>0) and all(.jobs[]; (.error // 0) == 0)' "$jsonplus_file" >/dev/null 2>&1
}

start_iostat() {
    local output_file="$1"
    IOSTAT_PID=""
    if [[ "$IOSTAT_ENABLED" == "yes" && "$IOSTAT_AVAILABLE" == "yes" ]]; then
        printf 'iostat -xmdt -y %q\n' "$IOSTAT_INTERVAL" > "${output_file%.txt}.command.txt"
        iostat -xmdt -y "$IOSTAT_INTERVAL" > "$output_file" 2>&1 &
        IOSTAT_PID="$!"
    else
        printf '# not executed: requested=%s available=%s\n' \
            "$IOSTAT_ENABLED" "$IOSTAT_AVAILABLE" > "${output_file%.txt}.command.txt"
        printf '# iostat telemetry not captured: requested=%s available=%s\n' \
            "$IOSTAT_ENABLED" "$IOSTAT_AVAILABLE" > "$output_file"
    fi
}

stop_iostat() {
    if [[ -n "${IOSTAT_PID:-}" ]]; then
        kill -TERM "$IOSTAT_PID" 2>/dev/null || true
        for ((WAIT_STEP=0; WAIT_STEP<20; WAIT_STEP++)); do
            kill -0 "$IOSTAT_PID" 2>/dev/null || break
            sleep 0.1
        done
        kill -0 "$IOSTAT_PID" 2>/dev/null && kill -KILL "$IOSTAT_PID" 2>/dev/null || true
        wait "$IOSTAT_PID" 2>/dev/null || true
        IOSTAT_PID=""
    fi
}

finalize_system_and_analysis() {
    local reason="$1"
    {
        echo "ended_at=$(date -Is)"
        echo "final_status=$reason"
    } >> "$RUN_DIR/run.env"
    log_message "Collecting final system snapshot ($reason)"
    "$ROOT_DIR/collect_system_info.sh" "$RUN_DIR/system/after" "$MOUNT_PATHS_CSV" "after-$reason" >> "$RUN_LOG" 2>&1 || \
        log_message "WARNING: final system snapshot returned a non-zero exit code"
    {
        echo "System changes selected from before/after snapshots"
        echo "Generated: $(date -Is)"
        for file in fibre-channel.txt block-queue-settings.txt df.txt findmnt.txt lsblk.txt multipath.txt dmsetup-status.txt; do
            if [[ -f "$RUN_DIR/system/before/$file" && -f "$RUN_DIR/system/after/$file" ]]; then
                echo
                echo "===== $file ====="
                diff -u "$RUN_DIR/system/before/$file" "$RUN_DIR/system/after/$file" || true
            fi
        done
    } > "$RUN_DIR/system/SELECTED_CHANGES.diff"
    if "$ROOT_DIR/analyze_results.sh" "$RUN_DIR" >> "$RUN_LOG" 2>&1; then
        log_message "Automatic analysis completed"
    else
        log_message "WARNING: automatic analysis is incomplete; raw outputs are preserved"
    fi
}

write_final_checksums() {
    find "$RUN_DIR" -type f ! -path "$RUN_DIR/SHA256SUMS" -print0 | sort -z | \
        xargs -0 -r sha256sum | sed "s#${RUN_DIR}/##" > "$RUN_DIR/SHA256SUMS"
}

CURRENT_JOB_NAME=""
CURRENT_JOB_ID=""
CURRENT_REPEAT=""
CURRENT_PIDS=()
CURRENT_LUN_INDEXES=()
CURRENT_START_TIMES=()
CURRENT_RAW_PARTS=()
IOSTAT_PID=""

cleanup_on_interrupt() {
    trap - INT TERM
    echo
    log_message "INTERRUPTED by user"
    stop_iostat
    for PID in "${CURRENT_PIDS[@]:-}"; do
        [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null && kill -TERM "$PID" 2>/dev/null || true
    done
    for PID in "${CURRENT_PIDS[@]:-}"; do
        [[ -n "$PID" ]] && wait "$PID" 2>/dev/null || true
    done
    for ((ARRAY_INDEX=0; ARRAY_INDEX<${#CURRENT_LUN_INDEXES[@]}; ARRAY_INDEX++)); do
        LUN_INDEX="${CURRENT_LUN_INDEXES[$ARRAY_INDEX]}"
        RAW_PART="${CURRENT_RAW_PARTS[$ARRAY_INDEX]}"
        INTERRUPTED_RAW="${RAW_PART%.part}.interrupted"
        [[ -f "$RAW_PART" ]] && mv -- "$RAW_PART" "$INTERRUPTED_RAW"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$CURRENT_JOB_ID" "$CURRENT_JOB_NAME" "$CURRENT_REPEAT" "${LUN_LABELS[$LUN_INDEX]}" \
            "${DATA_FILES[$LUN_INDEX]}" "$RUNTIME_SECONDS" "${CURRENT_START_TIMES[$ARRAY_INDEX]}" \
            "$(date -Is)" "130" "INTERRUPTED" "" "" "${INTERRUPTED_RAW#$RUN_DIR/}" "" \
            "${CURRENT_IOSTAT_FILE#$RUN_DIR/}" >> "$MANIFEST"
    done
    finalize_system_and_analysis "interrupted"
    log_message "Completed outputs and interrupted diagnostics were preserved"
    log_message "Results: $RUN_DIR"
    write_final_checksums
    exit 130
}
trap cleanup_on_interrupt INT TERM

log_message "FIO quick test v$RUNNER_VERSION started"
log_message "Architecture: $ARCH_LABEL"
log_message "Selected jobs: $SELECTED_IDS"
log_message "Result directory name: $(basename "$RUN_DIR")"
log_message "Run label: ${RUN_LABEL:-not-set}"
log_message "Runtime: $RUNTIME_SECONDS seconds; repetitions: $REPETITIONS; cooldown: $COOLDOWN_SECONDS seconds"
log_message "Parallel LUN count: ${#DATA_FILES[@]}"
log_message "QD policy: $QD_POLICY; custom aggregate target: ${CUSTOM_TOTAL_QD:-not-set}"
log_message "Exact per-job/per-repeat allocation: qd_plan.tsv"
log_message "iostat requested=$IOSTAT_ENABLED available=$IOSTAT_AVAILABLE interval=${IOSTAT_INTERVAL}s"
log_message "Collecting full pre-test system snapshot"
"$ROOT_DIR/collect_system_info.sh" "$RUN_DIR/system/before" "$MOUNT_PATHS_CSV" "before-run" >> "$RUN_LOG" 2>&1 || \
    log_message "WARNING: pre-test system snapshot returned a non-zero exit code"

TOTAL_JOBS="${#SELECTED_JOBS[@]}"
CURRENT_JOB_NUMBER=0
COMPLETED_REPEATS=0
for JOB_FILE in "${SELECTED_JOBS[@]}"; do
    CURRENT_JOB_NUMBER=$((CURRENT_JOB_NUMBER+1))
    JOB_NAME="$(basename "$JOB_FILE" .fio)"
    JOB_ID="${JOB_NAME%%_*}"
    SOURCE_NUMJOBS="${SOURCE_NUMJOBS_BY_JOB[$JOB_NAME]}"
    SOURCE_IODEPTH="${SOURCE_IODEPTH_BY_JOB[$JOB_NAME]}"
    JOB_OUTPUT_DIR="$RUN_DIR/$JOB_NAME"
    mkdir -p "$JOB_OUTPUT_DIR"

    for ((REPEAT_NUMBER=1; REPEAT_NUMBER<=REPETITIONS; REPEAT_NUMBER++)); do
        printf -v REPEAT_LABEL 'repeat-%02d' "$REPEAT_NUMBER"
        REPEAT_OUTPUT_DIR="$JOB_OUTPUT_DIR/$REPEAT_LABEL"
        REPEAT_SYSTEM_DIR="$RUN_DIR/system/repeats/$JOB_NAME/$REPEAT_LABEL"
        mkdir -p "$REPEAT_OUTPUT_DIR" "$REPEAT_SYSTEM_DIR"

        CURRENT_JOB_NAME="$JOB_NAME"
        CURRENT_JOB_ID="$JOB_ID"
        CURRENT_REPEAT="$REPEAT_LABEL"
        CURRENT_PIDS=()
        CURRENT_LUN_INDEXES=()
        CURRENT_START_TIMES=()
        CURRENT_RAW_PARTS=()

        collect_repeat_state "$REPEAT_SYSTEM_DIR/before" "before-$JOB_NAME-$REPEAT_LABEL"
        CURRENT_IOSTAT_FILE="$REPEAT_OUTPUT_DIR/iostat.txt"
        start_iostat "$CURRENT_IOSTAT_FILE"
        log_message "[$CURRENT_JOB_NUMBER/$TOTAL_JOBS][$REPEAT_NUMBER/$REPETITIONS] START $JOB_NAME on all LUNs"

        for ((LUN_INDEX=0; LUN_INDEX<${#DATA_FILES[@]}; LUN_INDEX++)); do
            LUN_LABEL="${LUN_LABELS[$LUN_INDEX]}"
            DATA_FILE="${DATA_FILES[$LUN_INDEX]}"
            RENDERED_JOB="$REPEAT_OUTPUT_DIR/${LUN_LABEL}.fio"
            RAW_PART="$REPEAT_OUTPUT_DIR/${LUN_LABEL}.combined.raw.part"
            STDERR_FILE="$REPEAT_OUTPUT_DIR/${LUN_LABEL}.stderr.log"
            START_TIME="$(date -Is)"

            calculate_qd_allocation "$SOURCE_NUMJOBS" "$SOURCE_IODEPTH" "$LUN_INDEX" "$REPEAT_NUMBER"

            awk -v dataset="$DATA_FILE" -v applied_numjobs="$APPLIED_NUMJOBS" \
                -v applied_iodepth="$APPLIED_IODEPTH" '
                BEGIN { filename_replaced=0; numjobs_replaced=0; iodepth_replaced=0 }
                /^[[:space:]]*filename[[:space:]]*=/ {
                    print "filename=" dataset; filename_replaced=1; next
                }
                /^[[:space:]]*numjobs[[:space:]]*=/ {
                    print "numjobs=" applied_numjobs; numjobs_replaced=1; next
                }
                /^[[:space:]]*iodepth[[:space:]]*=/ {
                    print "iodepth=" applied_iodepth; iodepth_replaced=1; next
                }
                { print }
                END {
                    if (filename_replaced != 1 || numjobs_replaced != 1 || iodepth_replaced != 1) exit 42
                }
            ' "$JOB_FILE" > "$RENDERED_JOB" || die "Cannot render dataset path for: $JOB_FILE"

            sha256sum "$RENDERED_JOB" > "$RENDERED_JOB.sha256"
            printf 'qd_policy=%s\nsource_numjobs=%s\nsource_iodepth=%s\nsource_qd=%s\n' \
                "$QD_POLICY" "$SOURCE_NUMJOBS" "$SOURCE_IODEPTH" \
                "${SOURCE_QD_BY_JOB[$JOB_NAME]}" > "$REPEAT_OUTPUT_DIR/${LUN_LABEL}.qd.env"
            printf 'applied_numjobs=%s\napplied_iodepth=%s\napplied_qd=%s\naggregate_target_qd=%s\nallocation_method=%s\n' \
                "$APPLIED_NUMJOBS" "$APPLIED_IODEPTH" "$APPLIED_QD" "$AGGREGATE_TARGET_QD" \
                "$QD_ALLOCATION_METHOD" >> "$REPEAT_OUTPUT_DIR/${LUN_LABEL}.qd.env"
            printf 'fio --eta=never --runtime=%q --output-format=normal,json+ --output=%q %q\n' \
                "$RUNTIME_SECONDS" "$RAW_PART" "$RENDERED_JOB" > "$REPEAT_OUTPUT_DIR/${LUN_LABEL}.command.txt"
            fio --eta=never --runtime="$RUNTIME_SECONDS" --output-format=normal,json+ \
                --output="$RAW_PART" "$RENDERED_JOB" 2> "$STDERR_FILE" &
            CURRENT_PIDS+=("$!")
            CURRENT_LUN_INDEXES+=("$LUN_INDEX")
            CURRENT_START_TIMES+=("$START_TIME")
            CURRENT_RAW_PARTS+=("$RAW_PART")
            log_message "QD $JOB_NAME $REPEAT_LABEL $LUN_LABEL: ${APPLIED_NUMJOBS}x${APPLIED_IODEPTH}=${APPLIED_QD}; aggregate target=${AGGREGATE_TARGET_QD}"
        done

        REPEAT_FAILED=0
        for ((ARRAY_INDEX=0; ARRAY_INDEX<${#CURRENT_PIDS[@]}; ARRAY_INDEX++)); do
            PID="${CURRENT_PIDS[$ARRAY_INDEX]}"
            LUN_INDEX="${CURRENT_LUN_INDEXES[$ARRAY_INDEX]}"
            LUN_LABEL="${LUN_LABELS[$LUN_INDEX]}"
            START_TIME="${CURRENT_START_TIMES[$ARRAY_INDEX]}"
            RAW_PART="${CURRENT_RAW_PARTS[$ARRAY_INDEX]}"
            RAW_FILE="${RAW_PART%.part}"
            NORMAL_FILE="$REPEAT_OUTPUT_DIR/${LUN_LABEL}.normal.txt"
            JSONPLUS_FILE="$REPEAT_OUTPUT_DIR/${LUN_LABEL}.jsonplus.json"
            STDERR_FILE="$REPEAT_OUTPUT_DIR/${LUN_LABEL}.stderr.log"

            wait "$PID"
            FIO_RC=$?
            END_TIME="$(date -Is)"
            CURRENT_PIDS[$ARRAY_INDEX]=""
            [[ -f "$RAW_PART" ]] && mv -- "$RAW_PART" "$RAW_FILE"
            PARSE_STATUS="NOT_PARSED"
            if [[ -s "$RAW_FILE" ]] && split_fio_output "$RAW_FILE" "$NORMAL_FILE" "$JSONPLUS_FILE"; then
                PARSE_STATUS="PASS"
            else
                PARSE_STATUS="FAILED"
                REPEAT_FAILED=1
            fi
            if (( FIO_RC != 0 )); then
                REPEAT_FAILED=1
                log_message "FAILED $JOB_NAME $REPEAT_LABEL on $LUN_LABEL with FIO exit code $FIO_RC"
            else
                log_message "DONE $JOB_NAME $REPEAT_LABEL on $LUN_LABEL; parse=$PARSE_STATUS"
            fi

            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$JOB_ID" "$JOB_NAME" "$REPEAT_LABEL" "$LUN_LABEL" "${DATA_FILES[$LUN_INDEX]}" \
                "$RUNTIME_SECONDS" "$START_TIME" "$END_TIME" "$FIO_RC" "$PARSE_STATUS" \
                "${NORMAL_FILE#$RUN_DIR/}" "${JSONPLUS_FILE#$RUN_DIR/}" "${RAW_FILE#$RUN_DIR/}" \
                "${STDERR_FILE#$RUN_DIR/}" "${CURRENT_IOSTAT_FILE#$RUN_DIR/}" >> "$MANIFEST"
        done

        stop_iostat
        collect_repeat_state "$REPEAT_SYSTEM_DIR/after" "after-$JOB_NAME-$REPEAT_LABEL"
        if (( REPEAT_FAILED != 0 )); then
            log_message "Stopped because $JOB_NAME $REPEAT_LABEL failed or its JSON+ output was invalid"
            finalize_system_and_analysis "failed"
            log_message "Results: $RUN_DIR"
            write_final_checksums
            exit 1
        fi

        log_message "[$CURRENT_JOB_NUMBER/$TOTAL_JOBS][$REPEAT_NUMBER/$REPETITIONS] DONE $JOB_NAME on all LUNs"
        COMPLETED_REPEATS=$((COMPLETED_REPEATS+1))
        CURRENT_JOB_NAME=""
        CURRENT_JOB_ID=""
        CURRENT_REPEAT=""
        CURRENT_PIDS=()
        CURRENT_LUN_INDEXES=()
        CURRENT_START_TIMES=()
        CURRENT_RAW_PARTS=()
        if (( COMPLETED_REPEATS < TOTAL_REPEATS && COOLDOWN_SECONDS > 0 )); then
            log_message "Cooldown: $COOLDOWN_SECONDS seconds"
            sleep "$COOLDOWN_SECONDS"
        fi
    done
done

log_message "All selected FIO jobs and repetitions completed successfully"
finalize_system_and_analysis "completed"
log_message "Results: $RUN_DIR"
write_final_checksums

echo
echo "Finished."
echo "Results: $RUN_DIR"
echo "Final report: $RUN_DIR/analysis/FINAL_REPORT.txt"
echo "Final JSON:  $RUN_DIR/analysis/final_result.json"
