#!/usr/bin/env bash

set -euo pipefail

SOURCE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
SUITE="$TEST_ROOT/suite"
cp -a -- "$SOURCE_ROOT" "$SUITE"

mount_path="$TEST_ROOT/lun-1"
dataset_dir="$mount_path/fio-test"
dataset="$dataset_dir/fio-data-1TiB.bin"
mkdir -p "$dataset_dir"
truncate -s 1099511627776 "$dataset"
before_state="$(stat -c '%i:%s:%Y:%b' -- "$dataset")"

export PATH="$SUITE/tests/mock_bin:$PATH"

set +e
"$SUITE/dataset_status.sh" "$mount_path" > "$TEST_ROOT/status-before.txt" 2>&1
status_rc=$?
set -e
[[ "$status_rc" -eq 3 ]]
grep -Fq 'RECOVERABLE' "$TEST_ROOT/status-before.txt"

set +e
"$SUITE/prepare_datasets.sh" "$mount_path" > "$TEST_ROOT/prepare-protected.txt" 2>&1
prepare_rc=$?
set -e
[[ "$prepare_rc" -eq 3 ]]
grep -Fq 'PROTECTED EXISTING 1 TiB FILE - NOT WRITTEN' "$TEST_ROOT/prepare-protected.txt"
[[ ! -e "${dataset}.fio-initialized" ]]
[[ "$(stat -c '%i:%s:%Y:%b' -- "$dataset")" == "$before_state" ]]

printf 'TRUST EXISTING DATASETS\n' | "$SUITE/repair_dataset_markers.sh" "$mount_path" \
    > "$TEST_ROOT/repair.txt" 2>&1
[[ -f "${dataset}.fio-initialized" ]]
[[ "$(stat -c '%i:%s:%Y:%b' -- "$dataset")" == "$before_state" ]]
grep -Fq 'Dataset files were not rewritten.' "$TEST_ROOT/repair.txt"

"$SUITE/dataset_status.sh" "$mount_path" > "$TEST_ROOT/status-after.txt"
grep -Fq 'READY' "$TEST_ROOT/status-after.txt"
"$SUITE/prepare_datasets.sh" "$mount_path" > "$TEST_ROOT/prepare-ready.txt"
grep -Fq 'Nothing was written.' "$TEST_ROOT/prepare-ready.txt"

printf '0\n' | TERM=dumb "$SUITE/kavox.sh" > "$TEST_ROOT/menu.txt"
grep -Fq 'Kavox Lite v0.1.0' "$TEST_ROOT/menu.txt"
grep -Fq 'Goodbye.' "$TEST_ROOT/menu.txt"

echo "PASS: Kavox dataset no-overwrite safety and interactive-menu test"
