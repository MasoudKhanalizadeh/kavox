# Security and data disclosure

Kavox performs destructive benchmark I/O only after explicit confirmation, but
operators remain responsible for selecting dedicated test targets.

Never run Kavox against a root filesystem, production data, or a mount whose
ownership is uncertain. Review the generated `system/`, `run.env`, and metadata
files before publishing results; they may contain hostnames, UUIDs, serials,
WWNs, device paths, and SAN topology.

For a suspected safety issue, open a GitHub security advisory instead of a
public issue when the repository owner has enabled private reporting.
