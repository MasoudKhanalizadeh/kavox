# Kavox Lite

**Official repository:** [https://github.com/MasoudKhanalizadeh/kavox](https://github.com/MasoudKhanalizadeh/kavox)
**Support:** [Bug reports, questions, and contact options](SUPPORT.md)

Reproducible, safety-focused storage benchmarking with FIO on Linux, bare metal,
virtual machines, and parallel LUNs.

> **Destructive I/O warning:** dataset preparation performs a real 1 TiB write
> on every selected target. Write and mixed benchmark profiles modify the
> dataset. Use dedicated test storage only—never a root filesystem or production
> data path.

[راهنمای فارسی](README_FA.md)

## Why Kavox?

Raw FIO job files are easy to run but difficult to compare consistently. Kavox
adds the repeatable workflow around FIO: target validation, queue-depth policy,
repetitions, telemetry, result provenance, statistical analysis, and comparable
output names.

## Features

- One interactive entry point for configuration, datasets, runs, analysis, and comparison
- 19 bundled random, sequential, mixed, and Zipf profiles
- Parallel execution across multiple LUNs, with serial jobs and repetitions
- Exact aggregate-QD normalization for fair single-LUN versus multi-LUN comparisons
- Custom aggregate QD and fixed-per-LUN scaling modes
- Normal and JSON+ output from one FIO execution
- IOPS, bandwidth, weighted latency, p50/p95/p99/p99.9, mean, median, sample SD, and CV
- Optional iostat telemetry and before/after system snapshots
- Meaningful result directory names and per-run manifests
- Existing-dataset protection, SHA-256 manifests, and mock-based self-tests

## Requirements

- Linux with Bash 4+
- XFS benchmark targets
- Required: `fio`, `jq`, `awk`, `mountpoint`, `findmnt`, `stat`, `sha256sum`, `readlink`
- Optional: `iostat` (`sysstat`), `tmux`, `xfs_info`, `multipath`, `lsscsi`, `dmidecode`, `lspci`, `numactl`, `sensors`

Ubuntu/Debian:

```bash
sudo apt update
sudo apt install fio jq sysstat
```

## Quick start

```bash
git clone https://github.com/MasoudKhanalizadeh/kavox.git
cd kavox
chmod +x *.sh tests/*.sh tests/mock_bin/*
./kavox.sh
```

For long tests, run Kavox inside `tmux`:

```bash
tmux new -s kavox
./kavox.sh
```

The guided workflow performs:

```text
Configuration -> Dependency check -> Dataset status -> Read-only samples
-> Optional metadata -> Job selection -> Benchmark -> Analysis
```

## Dataset safety model

Each target uses:

```text
MOUNT_PATH/fio-test/fio-data-1TiB.bin
```

Kavox classifies it before any run:

| State | Meaning | Automatic action |
| --- | --- | --- |
| `READY` | Exact 1 TiB file and matching marker | Safe to benchmark |
| `RECOVERABLE` | Exact 1 TiB file without a valid marker | Protect file; allow marker repair only after explicit trust |
| `MISSING` | Dataset does not exist | Allow initialization after typed confirmation |
| `WRONG SIZE/CONFLICT` | Unexpected file or path state | Stop for manual inspection |

Preparation never deletes, truncates, or recreates an existing dataset. The
benchmark itself intentionally writes to the dataset when a write or mixed
profile is selected.

## Queue-depth policies

| Policy | Purpose | Aggregate QD |
| --- | --- | --- |
| `normalize-profile` | Fair architecture comparison; recommended | Preserves the profile's single-LUN QD |
| `custom-total` | Test an exact user-selected total | Fixed custom total across all LUNs |
| `per-lun-profile` | Scaling/load test | Grows with LUN count |

For normalized runs, Kavox distributes `numjobs` or `iodepth` across targets and
rotates indivisible extras between repetitions. The effective plan is recorded
in `qd_plan.tsv`, per-LUN environment files, and rendered FIO job files.

## Result layout

Example:

```text
baremetal_3lun_qd-equal-profile_jobs-01-03-15_rt300s_r3_tag-raid5-pool-a_20260812-003015
```

```text
results/RUN_NAME/
├── run.env
├── benchmark_metadata.tsv
├── manifest.tsv
├── qd_plan.tsv
├── run.log
├── SHA256SUMS
├── system/
├── JOB/repeat-XX/
└── analysis/
    ├── aggregate_statistics.{json,tsv,csv}
    ├── per_lun_statistics.json
    ├── pooled_histograms.json
    ├── final_result.json
    └── FINAL_REPORT.txt
```

Bandwidth is reported in MiB/s and latency in milliseconds.

## Direct runner usage

The interactive menu is recommended. Advanced users may call the runner:

```bash
./run_tests.sh \
  baremetal \
  01,02,03,04,15,16,17,18,19 \
  300 \
  /mnt/lun1,/mnt/lun2,/mnt/lun3 \
  3 \
  15 \
  yes \
  5 \
  normalize-profile \
  '' \
  raid5-pool-a
```

The final typed `YES` confirmation remains mandatory.

## Tests

The test suite uses sparse temporary fixtures and mock commands; it does not run
real storage I/O:

```bash
make test
```

## Publishing results safely

Result snapshots can contain hostnames, filesystem UUIDs, disk/LUN identifiers,
WWNs, serial numbers, and SAN topology. Generated output is ignored by Git, but
review and anonymize any result package before sharing it publicly.

## Project status

This repository is the first public release, **Kavox Lite v0.1.0**. The Lite
edition is the practical local runner. Future full-Kavox work may add SSH test
orchestration, resume/continue, declarative suites, and centralized result
tracking.

## License

[GNU AGPL v3](LICENSE)


## License and support

Kavox is free and open-source under **AGPL-3.0-only**. See the [NOTICE](NOTICE),
[trademark policy](TRADEMARKS.md), and [commercial licensing](COMMERCIAL-LICENSE.md)
documents. Use [SUPPORT.md](SUPPORT.md) to report a bug, ask a usage question,
or find the appropriate contact route.
