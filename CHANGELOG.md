# Changelog

All notable changes to Kavox Lite are documented here.

## [0.2.0] - 2026-08-19

### Added

- Configurable per-LUN dataset sizes using aligned `MiB`, `GiB`, or `TiB` values
- Size-specific dataset filenames, markers, result names, run metadata, and system snapshots
- Dynamic beginning/middle/end validation samples for smaller datasets
- Regression coverage for custom-size safety, validation, and rendered FIO jobs

### Changed

- The runner now renders both the dataset path and exact byte size into every FIO job
- Free-space reserve scales safely for small and large datasets
- The default remains `1TiB`, preserving compatibility with existing datasets and markers

## [0.1.0] - 2026-08-13

### Changed

- Adopted AGPL-3.0-only licensing, standard copyright notices, a trademark policy, and a dual-licensing path before the first public release.

### Added

- Public Kavox Lite release with 19 bundled FIO profiles
- Interactive configuration and guided benchmark workflow
- Safe 1 TiB dataset initialization, validation, and marker repair
- Single-LUN and parallel multi-LUN execution
- Aggregate queue-depth normalization, custom-total QD, and per-LUN scaling modes
- Repetitions, cooldowns, iostat telemetry, and system snapshots
- Normal and JSON+ output splitting with raw-output recovery
- Statistical analysis, pooled latency histograms, and result comparison
- Meaningful result names, manifests, metadata, and SHA-256 checksums
- Mock-based regression tests and GitHub Actions CI
