SHELL := /usr/bin/env bash

.PHONY: check test checksums package

check:
	@bash -n *.sh tests/*.sh tests/mock_bin/*
	@awk 'BEGIN { failed=0 } /^filename=\// && $$0 !~ /^filename=\/mnt\/storage\/fio-test\/fio-data-1TiB\.bin$$/ { print "Unexpected profile path: " FILENAME ":" $$0; failed=1 } END { exit failed }' jobs/*.fio

test: check
	@./tests/run_self_test.sh
	@./tests/run_output_recovery_test.sh
	@./tests/run_dataset_safety_test.sh
	@./tests/run_qd_normalization_test.sh
	@./tests/run_runner_mock.sh

checksums:
	@find . -type f \
		! -path './.git/*' \
		! -path './results/*' \
		! -path './comparisons/*' \
		! -path './dataset-results/*' \
		! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS

package: test checksums
	@cd .. && zip -qr kavox-lite-v$$(cat kavox-lite/VERSION).zip kavox-lite \
		-x 'kavox-lite/.git/*' 'kavox-lite/results/*' 'kavox-lite/comparisons/*' \
		'kavox-lite/dataset-results/*' 'kavox-lite/benchmark_config.tsv' \
		'kavox-lite/benchmark_metadata.tsv'
