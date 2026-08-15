# Contributing

Contributions are welcome. Please keep changes focused, preserve the dataset
safety checks, and include a regression test for behavior changes.

Before opening a pull request, see [SUPPORT.md](SUPPORT.md) for the appropriate
route for bug reports, usage questions, and security concerns.

## Development checks

```bash
make check
make test
```

Tests must not issue real storage I/O. Use the commands under `tests/mock_bin`
and sparse temporary fixtures for runner, dataset, and analysis tests.

## Pull requests

- Explain the benchmark behavior being changed.
- State whether output schemas, job profiles, or queue-depth behavior change.
- Update `CHANGELOG.md` for user-visible changes.
- Do not commit benchmark results, system snapshots, customer metadata, serials,
  WWNs, credentials, or production mount paths.
