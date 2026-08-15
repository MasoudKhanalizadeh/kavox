# Security and data disclosure

Kavox performs destructive benchmark I/O only after explicit confirmation, but
operators remain responsible for selecting dedicated test targets.

Never run Kavox against a root filesystem, production data, or a mount whose
ownership is uncertain. Review the generated `system/`, `run.env`, and metadata
files before publishing results; they may contain hostnames, UUIDs, serials,
WWNs, device paths, and SAN topology.

For a suspected vulnerability or safety issue, use a
[private GitHub security advisory](https://github.com/MasoudKhanalizadeh/kavox/security/advisories/new)
instead of a public issue when private reporting is available. For non-sensitive
bugs and questions, follow [SUPPORT.md](SUPPORT.md).
