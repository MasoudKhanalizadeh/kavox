#!/usr/bin/env bash

# Rebuild derived normal and JSON+ files from preserved combined.raw files.
# Raw FIO output is never modified. The manifest is backed up before updates.

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RESULT_DIR="${1:-}"
[[ -n "$RESULT_DIR" ]] || { echo "Usage: $0 RESULT_DIRECTORY" >&2; exit 2; }
RESULT_DIR="$(readlink -f -- "$RESULT_DIR")"
[[ -d "$RESULT_DIR" ]] || { echo "Result directory not found: $RESULT_DIR" >&2; exit 2; }
[[ -f "$ROOT_DIR/split_fio_output.awk" ]] || { echo "split_fio_output.awk is missing." >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq is required." >&2; exit 2; }

STATUS_MAP="$(mktemp)"
trap 'rm -f -- "$STATUS_MAP"' EXIT
recovered=0
invalid=0

while IFS= read -r -d '' raw_file; do
    base="${raw_file%.combined.raw}"
    normal_file="${base}.normal.txt"
    jsonplus_file="${base}.jsonplus.json"
    raw_relative="${raw_file#$RESULT_DIR/}"

    if awk -v normal_file="$normal_file" -v json_file="$jsonplus_file" \
        -f "$ROOT_DIR/split_fio_output.awk" "$raw_file" && \
       jq -e '.jobs and (.jobs | length > 0) and all(.jobs[]; (.error // 0) == 0)' \
        "$jsonplus_file" >/dev/null 2>&1; then
        printf '%s\tPASS_RECOVERED\n' "$raw_relative" >> "$STATUS_MAP"
        recovered=$((recovered+1))
        echo "RECOVERED: $raw_relative"
    else
        printf '%s\tFAILED\n' "$raw_relative" >> "$STATUS_MAP"
        invalid=$((invalid+1))
        echo "INVALID: $raw_relative" >&2
    fi
done < <(find "$RESULT_DIR" -mindepth 3 -maxdepth 3 -type f -name 'lun-*.combined.raw' -print0 | sort -z)

if (( recovered == 0 && invalid == 0 )); then
    echo "No combined.raw files were found in: $RESULT_DIR" >&2
    exit 1
fi

manifest="$RESULT_DIR/manifest.tsv"
if [[ -f "$manifest" ]]; then
    backup="$RESULT_DIR/manifest.tsv.before-recovery.$(date +%Y%m%d_%H%M%S)"
    cp -- "$manifest" "$backup"
    temporary="${manifest}.tmp.$$"
    awk -F '\t' -v OFS='\t' '
        NR == FNR { status[$1] = $2; next }
        FNR == 1 { print; next }
        ($13 in status) { $10 = status[$13] }
        { print }
    ' "$STATUS_MAP" "$manifest" > "$temporary"
    mv -- "$temporary" "$manifest"
    echo "Manifest backup: $backup"
fi

echo "Recovered outputs: $recovered"
echo "Still invalid: $invalid"
(( invalid == 0 ))
