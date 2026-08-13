#!/usr/bin/env bash

# Single interactive entry point for the complete Kavox workflow.

set -u
set -o pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$ROOT_DIR/benchmark_config.tsv"
METADATA_FILE="$ROOT_DIR/benchmark_metadata.tsv"
METADATA_TEMPLATE="$ROOT_DIR/benchmark_metadata.example.tsv"
RESULTS_DIR="$ROOT_DIR/results"

ARCHITECTURE="baremetal"
MOUNT_PATHS_CSV=""
RUNTIME_SECONDS="300"
REPETITIONS="3"
COOLDOWN_SECONDS="15"
IOSTAT_ENABLED="yes"
IOSTAT_INTERVAL="5"
QD_POLICY="normalize-profile"
CUSTOM_TOTAL_QD=""

banner() {
    clear 2>/dev/null || true
    echo "============================================================"
    echo " Kavox Lite v0.1.0 — Reproducible FIO Benchmarking"
    echo "============================================================"
}

pause_menu() {
    echo
    read -r -p "Press Enter to return to the main menu..." _
}

ensure_metadata_file() {
    if [[ ! -f "$METADATA_FILE" ]]; then
        [[ -f "$METADATA_TEMPLATE" ]] || {
            echo "Metadata template is missing: $METADATA_TEMPLATE" >&2
            return 1
        }
        cp -- "$METADATA_TEMPLATE" "$METADATA_FILE"
    fi
}

normalize_mount_csv() {
    local raw="$1" item normalized="" seen="," 
    local -a items=()
    IFS=',' read -r -a items <<< "$raw"
    for item in "${items[@]}"; do
        while [[ "$item" != "/" && "$item" == */ ]]; do item="${item%/}"; done
        [[ "$item" =~ ^/[A-Za-z0-9._/-]+$ && "$item" != "/" ]] || return 1
        [[ "$seen" != *",$item,"* ]] || return 1
        seen+="$item,"
        normalized+="${normalized:+,}$item"
    done
    [[ -n "$normalized" ]] || return 1
    printf '%s\n' "$normalized"
}

load_config() {
    [[ -f "$CONFIG_FILE" ]] || return 1
    local key value extra
    while IFS=$'\t' read -r key value extra; do
        case "$key" in
            architecture) ARCHITECTURE="$value" ;;
            mount_paths) MOUNT_PATHS_CSV="$value" ;;
            runtime_seconds) RUNTIME_SECONDS="$value" ;;
            repetitions) REPETITIONS="$value" ;;
            cooldown_seconds) COOLDOWN_SECONDS="$value" ;;
            iostat_enabled) IOSTAT_ENABLED="$value" ;;
            iostat_interval) IOSTAT_INTERVAL="$value" ;;
            qd_policy) QD_POLICY="$value" ;;
            custom_total_qd) CUSTOM_TOTAL_QD="$value" ;;
        esac
    done < "$CONFIG_FILE"

    [[ "$ARCHITECTURE" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    MOUNT_PATHS_CSV="$(normalize_mount_csv "$MOUNT_PATHS_CSV")" || return 1
    [[ "$RUNTIME_SECONDS" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "$REPETITIONS" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "$COOLDOWN_SECONDS" =~ ^[0-9]+$ ]] || return 1
    [[ "$IOSTAT_ENABLED" == "yes" || "$IOSTAT_ENABLED" == "no" ]] || return 1
    [[ "$IOSTAT_INTERVAL" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "$QD_POLICY" == "normalize-profile" || "$QD_POLICY" == "custom-total" || \
       "$QD_POLICY" == "per-lun-profile" ]] || return 1
    if [[ "$QD_POLICY" == "custom-total" ]]; then
        [[ "$CUSTOM_TOTAL_QD" =~ ^[1-9][0-9]*$ ]] || return 1
    else
        CUSTOM_TOTAL_QD=""
    fi
}

save_config() {
    local temporary="${CONFIG_FILE}.tmp.$$"
    {
        printf 'architecture\t%s\n' "$ARCHITECTURE"
        printf 'mount_paths\t%s\n' "$MOUNT_PATHS_CSV"
        printf 'runtime_seconds\t%s\n' "$RUNTIME_SECONDS"
        printf 'repetitions\t%s\n' "$REPETITIONS"
        printf 'cooldown_seconds\t%s\n' "$COOLDOWN_SECONDS"
        printf 'iostat_enabled\t%s\n' "$IOSTAT_ENABLED"
        printf 'iostat_interval\t%s\n' "$IOSTAT_INTERVAL"
        printf 'qd_policy\t%s\n' "$QD_POLICY"
        printf 'custom_total_qd\t%s\n' "$CUSTOM_TOTAL_QD"
    } > "$temporary"
    mv -- "$temporary" "$CONFIG_FILE"
}

auto_discover_mounts() {
    local discovered=""
    local dataset mount_path
    while IFS= read -r dataset; do
        mount_path="${dataset%/fio-test/fio-data-1TiB.bin}"
        discovered+="${discovered:+,}$mount_path"
    done < <(find /mnt -mindepth 3 -maxdepth 3 -type f -path '*/fio-test/fio-data-1TiB.bin' -print 2>/dev/null | sort)
    printf '%s\n' "$discovered"
}

configure_environment() {
    banner
    echo "Test environment configuration"
    echo
    echo "Architecture:"
    echo "  1) Bare Metal"
    echo "  2) ESXi VM"
    local architecture_default=1
    [[ "$ARCHITECTURE" == "esxi" ]] && architecture_default=2
    read -r -p "Choice [$architecture_default]: " choice
    case "${choice:-}" in
        "") : ;;
        1) ARCHITECTURE="baremetal" ;;
        2) ARCHITECTURE="esxi" ;;
        *) echo "Invalid choice."; return 1 ;;
    esac

    local -a current_mounts=()
    if [[ -z "$MOUNT_PATHS_CSV" ]]; then
        MOUNT_PATHS_CSV="$(auto_discover_mounts)"
        [[ -n "$MOUNT_PATHS_CSV" ]] && echo "Detected existing datasets: $MOUNT_PATHS_CSV"
    fi
    [[ -n "$MOUNT_PATHS_CSV" ]] && IFS=',' read -r -a current_mounts <<< "$MOUNT_PATHS_CSV"
    local default_count="${#current_mounts[@]}"
    (( default_count > 0 )) || default_count=1
    read -r -p "Number of LUNs [$default_count]: " lun_count
    lun_count="${lun_count:-$default_count}"
    [[ "$lun_count" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid LUN count."; return 1; }

    local new_mounts="" default_path path index value
    for ((index=1; index<=lun_count; index++)); do
        default_path="${current_mounts[$((index-1))]:-}"
        if [[ -z "$default_path" && "$lun_count" == "1" ]]; then default_path="/mnt/storage"; fi
        if [[ -n "$default_path" ]]; then
            read -r -p "Mount path for LUN $index [$default_path]: " path
            path="${path:-$default_path}"
        else
            read -r -p "Mount path for LUN $index: " path
        fi
        new_mounts+="${new_mounts:+,}$path"
    done
    MOUNT_PATHS_CSV="$(normalize_mount_csv "$new_mounts")" || { echo "Invalid or duplicate mount path."; return 1; }

    echo
    echo "Queue-depth policy:"
    echo "  1) Equal aggregate QD (recommended): preserve each profile's single-LUN total QD"
    echo "  2) Custom aggregate QD: one total QD value shared by all selected profiles"
    echo "  3) Fixed QD per LUN: legacy scaling/load behavior"
    local qd_default=1
    [[ "$QD_POLICY" == "custom-total" ]] && qd_default=2
    [[ "$QD_POLICY" == "per-lun-profile" ]] && qd_default=3
    read -r -p "Choice [$qd_default]: " choice
    case "${choice:-$qd_default}" in
        1) QD_POLICY="normalize-profile"; CUSTOM_TOTAL_QD="" ;;
        2)
            QD_POLICY="custom-total"
            read -r -p "Aggregate QD target [${CUSTOM_TOTAL_QD:-256}]: " value
            CUSTOM_TOTAL_QD="${value:-${CUSTOM_TOTAL_QD:-256}}"
            [[ "$CUSTOM_TOTAL_QD" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid aggregate QD."; return 1; }
            (( CUSTOM_TOTAL_QD >= lun_count )) || {
                echo "Aggregate QD must be at least the number of active LUNs ($lun_count)."; return 1;
            }
            ;;
        3) QD_POLICY="per-lun-profile"; CUSTOM_TOTAL_QD="" ;;
        *) echo "Invalid queue-depth choice."; return 1 ;;
    esac

    read -r -p "Runtime per repetition in seconds [$RUNTIME_SECONDS]: " value
    RUNTIME_SECONDS="${value:-$RUNTIME_SECONDS}"
    [[ "$RUNTIME_SECONDS" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid runtime."; return 1; }
    read -r -p "Repetitions per job [$REPETITIONS]: " value
    REPETITIONS="${value:-$REPETITIONS}"
    [[ "$REPETITIONS" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid repetition count."; return 1; }
    read -r -p "Cooldown seconds [$COOLDOWN_SECONDS]: " value
    COOLDOWN_SECONDS="${value:-$COOLDOWN_SECONDS}"
    [[ "$COOLDOWN_SECONDS" =~ ^[0-9]+$ ]] || { echo "Invalid cooldown."; return 1; }
    read -r -p "Enable iostat telemetry? [${IOSTAT_ENABLED/yes/Y}]: " value
    case "${value:-$IOSTAT_ENABLED}" in
        y|Y|yes|YES) IOSTAT_ENABLED="yes" ;;
        n|N|no|NO) IOSTAT_ENABLED="no" ;;
        *) echo "Invalid iostat choice."; return 1 ;;
    esac
    if [[ "$IOSTAT_ENABLED" == "yes" ]]; then
        read -r -p "iostat interval in seconds [$IOSTAT_INTERVAL]: " value
        IOSTAT_INTERVAL="${value:-$IOSTAT_INTERVAL}"
        [[ "$IOSTAT_INTERVAL" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid iostat interval."; return 1; }
    fi

    save_config
    echo
    echo "Configuration saved."
    show_config
}

show_config() {
    echo "  Architecture : $ARCHITECTURE"
    echo "  Mount paths  : $MOUNT_PATHS_CSV"
    echo "  Runtime      : $RUNTIME_SECONDS seconds"
    echo "  Repetitions  : $REPETITIONS"
    echo "  Cooldown     : $COOLDOWN_SECONDS seconds"
    echo "  iostat       : $IOSTAT_ENABLED (interval ${IOSTAT_INTERVAL}s)"
    case "$QD_POLICY" in
        normalize-profile) echo "  QD policy    : equal aggregate QD (profile default; recommended)" ;;
        custom-total) echo "  QD policy    : custom aggregate QD = $CUSTOM_TOTAL_QD" ;;
        per-lun-profile) echo "  QD policy    : fixed profile QD per LUN (scaling mode)" ;;
    esac
}

ensure_config() {
    if ! load_config; then
        echo "No valid saved configuration was found."
        configure_environment || return 1
    fi
}

check_dependencies() {
    local missing_required=() missing_optional=() command_name
    for command_name in bash fio jq awk mountpoint findmnt stat sha256sum readlink; do
        command -v "$command_name" >/dev/null 2>&1 || missing_required+=("$command_name")
    done
    for command_name in iostat tmux xfs_info multipath lsscsi dmidecode lspci numactl sensors; do
        command -v "$command_name" >/dev/null 2>&1 || missing_optional+=("$command_name")
    done
    if (( ${#missing_required[@]} > 0 )); then
        echo "Missing required tools: ${missing_required[*]}"
        echo "Ubuntu/Debian: sudo apt install fio jq util-linux coreutils"
        return 1
    fi
    echo "Required dependencies: PASS"
    if (( ${#missing_optional[@]} > 0 )); then
        echo "Optional tools not found: ${missing_optional[*]}"
        echo "iostat comes from sysstat; missing optional tools do not stop the benchmark."
    else
        echo "Optional observability tools: PASS"
    fi
}

dataset_status() {
    ensure_config || return 1
    "$ROOT_DIR/dataset_status.sh" "$MOUNT_PATHS_CSV"
}

check_datasets() {
    ensure_config || return 1
    if ! "$ROOT_DIR/dataset_status.sh" "$MOUNT_PATHS_CSV"; then
        echo "Dataset check stopped before FIO sample reads. Use Dataset preparation/marker repair as indicated."
        return 1
    fi
    "$ROOT_DIR/check_datasets.sh" "$MOUNT_PATHS_CSV"
}

prepare_missing_datasets() {
    ensure_config || return 1
    "$ROOT_DIR/prepare_datasets.sh" "$MOUNT_PATHS_CSV"
}

repair_markers() {
    ensure_config || return 1
    "$ROOT_DIR/repair_dataset_markers.sh" "$MOUNT_PATHS_CSV"
}

guided_metadata_editor() {
    ensure_metadata_file || return 1
    local metadata="$METADATA_FILE"
    local temporary="${metadata}.tmp.$$"
    [[ -f "$metadata" ]] || { echo "Metadata template is missing."; return 1; }
    echo "Enter a new value, press Enter to keep the current value, or type - to clear it."
    local field value description input
    IFS=$'\t' read -r field value description < "$metadata"
    printf '%s\t%s\t%s\n' "$field" "$value" "$description" > "$temporary"
    while IFS=$'\t' read -r field value description; do
        echo
        echo "$field — $description"
        read -r -p "Value [${value:-empty}]: " input
        if [[ "$input" == "-" ]]; then value=""; elif [[ -n "$input" ]]; then value="$input"; fi
        value="${value//$'\t'/ }"
        printf '%s\t%s\t%s\n' "$field" "$value" "$description" >> "$temporary"
    done < <(tail -n +2 "$metadata")
    mv -- "$temporary" "$metadata"
    echo "Metadata saved."
}

edit_metadata() {
    ensure_metadata_file || return 1
    echo "  1) Guided field-by-field editor"
    echo "  2) Open in a text editor"
    read -r -p "Choice [1]: " choice
    case "${choice:-1}" in
        1) guided_metadata_editor ;;
        2)
            local editor="${EDITOR:-}"
            if [[ -z "$editor" ]]; then
                if command -v nano >/dev/null 2>&1; then editor="nano"; elif command -v vi >/dev/null 2>&1; then editor="vi"; else
                    echo "No text editor found. Use the guided editor instead."; return 1
                fi
            fi
            "$editor" "$METADATA_FILE"
            ;;
        *) echo "Invalid choice."; return 1 ;;
    esac
}

run_benchmark() {
    ensure_config || return 1
    echo "Pre-run safety gate: validating datasets and performing read-only samples."
    check_dependencies || return 1
    check_datasets || return 1
    echo
    echo "Datasets are READY. The benchmark runner will now ask which jobs to run."
    "$ROOT_DIR/run_tests.sh" "$ARCHITECTURE" "" "$RUNTIME_SECONDS" "$MOUNT_PATHS_CSV" \
        "$REPETITIONS" "$COOLDOWN_SECONDS" "$IOSTAT_ENABLED" "$IOSTAT_INTERVAL" \
        "$QD_POLICY" "$CUSTOM_TOTAL_QD"
}

select_result_directory() {
    local prompt="$1" selection index
    local -a result_dirs=()
    mapfile -t result_dirs < <(find "$RESULTS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T@\t%p\n' 2>/dev/null | sort -rn | cut -f2-)
    if (( ${#result_dirs[@]} == 0 )); then
        echo "No result directories found under $RESULTS_DIR"
        read -r -p "Enter the full path of an existing result: " selection
        SELECTED_RESULT="$selection"
        [[ -d "$SELECTED_RESULT" ]] || { echo "Result directory not found: $SELECTED_RESULT"; return 1; }
        return 0
    fi
    echo "$prompt"
    for ((index=0; index<${#result_dirs[@]}; index++)); do
        printf '  %d) %s\n' "$((index+1))" "${result_dirs[$index]}"
    done
    read -r -p "Number or full result path: " selection
    if [[ "$selection" =~ ^[1-9][0-9]*$ ]] && (( selection <= ${#result_dirs[@]} )); then
        SELECTED_RESULT="${result_dirs[$((selection-1))]}"
    else
        SELECTED_RESULT="$selection"
    fi
    [[ -d "$SELECTED_RESULT" ]] || { echo "Result directory not found: $SELECTED_RESULT"; return 1; }
}

reanalyze_result() {
    select_result_directory "Select a result to recover and analyze again:" || return 1
    echo "Recovering derived Normal/JSON+ files from preserved combined.raw files."
    "$ROOT_DIR/recover_result_outputs.sh" "$SELECTED_RESULT" || return 1
    "$ROOT_DIR/analyze_results.sh" "$SELECTED_RESULT" || return 1
    find "$SELECTED_RESULT" -type f ! -path "$SELECTED_RESULT/SHA256SUMS" -print0 | sort -z | \
        xargs -0 -r sha256sum | sed "s#${SELECTED_RESULT}/##" > "$SELECTED_RESULT/SHA256SUMS"
    echo "Result checksums refreshed."
}

compare_results() {
    local left right name output_dir
    select_result_directory "Select the LEFT/baseline result:" || return 1
    left="$SELECTED_RESULT"
    select_result_directory "Select the RIGHT/comparison result:" || return 1
    right="$SELECTED_RESULT"
    read -r -p "Comparison name [comparison]: " name
    name="${name:-comparison}"
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Use only letters, numbers, dot, underscore, or hyphen."; return 1; }
    output_dir="$ROOT_DIR/comparisons/${name}_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$output_dir"
    "$ROOT_DIR/compare_results.sh" "$left" "$right" "$output_dir/$name"
    echo "Comparison directory: $output_dir"
}

verify_package() {
    (cd "$ROOT_DIR" && sha256sum -c SHA256SUMS)
}

guided_workflow() {
    ensure_config || return 1
    echo
    show_config
    echo
    check_dependencies || return 1
    echo
    if ! check_datasets; then
        echo
        echo "The benchmark was NOT started. Choose preparation or marker repair from the main menu."
        return 1
    fi
    echo
    read -r -p "Edit benchmark metadata before the run? [y/N]: " answer
    case "$answer" in y|Y|yes|YES) edit_metadata || return 1 ;; esac
    echo
    "$ROOT_DIR/run_tests.sh" "$ARCHITECTURE" "" "$RUNTIME_SECONDS" "$MOUNT_PATHS_CSV" \
        "$REPETITIONS" "$COOLDOWN_SECONDS" "$IOSTAT_ENABLED" "$IOSTAT_INTERVAL" \
        "$QD_POLICY" "$CUSTOM_TOTAL_QD"
}

main_menu() {
    while :; do
        load_config >/dev/null 2>&1 || true
        banner
        if [[ -n "$MOUNT_PATHS_CSV" ]]; then show_config; else echo "  Environment is not configured yet."; fi
        echo
        echo "  1) Guided workflow: preflight -> dataset check -> metadata -> benchmark"
        echo "  2) Configure architecture, LUNs, QD policy, repeats, runtime, and iostat"
        echo "  3) Dataset status (read-only, no FIO)"
        echo "  4) Validate datasets (read-only sample reads)"
        echo "  5) Prepare missing datasets only"
        echo "  6) Repair markers for protected existing 1 TiB files"
        echo "  7) Edit benchmark metadata"
        echo "  8) Run benchmark (includes safety checks)"
        echo "  9) Recover and analyze an existing result again"
        echo " 10) Compare two existing results"
        echo " 11) Check dependencies"
        echo " 12) Verify package SHA-256"
        echo "  0) Exit"
        echo
        read -r -p "Select an option: " option
        case "$option" in
            1) guided_workflow; pause_menu ;;
            2) configure_environment; pause_menu ;;
            3) dataset_status; pause_menu ;;
            4) check_datasets; pause_menu ;;
            5) prepare_missing_datasets; pause_menu ;;
            6) repair_markers; pause_menu ;;
            7) edit_metadata; pause_menu ;;
            8) run_benchmark; pause_menu ;;
            9) reanalyze_result; pause_menu ;;
            10) compare_results; pause_menu ;;
            11) check_dependencies; pause_menu ;;
            12) verify_package; pause_menu ;;
            0) echo "Goodbye."; exit 0 ;;
            *) echo "Invalid option."; pause_menu ;;
        esac
    done
}

main_menu
