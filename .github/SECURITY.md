# Security & Data-Integrity Policy

Ext4Kit is **beta software** that reads and writes real ext4 volumes. A bug
here can corrupt a filesystem, so data-integrity reports are treated with
the same priority as security vulnerabilities.

## Supported versions

Only the latest release (and `main`) receive fixes. There are no backports
while the project is pre-1.0.

## Reporting a vulnerability or data-corruption bug

**Please report privately first** — do not open a public issue for anything
that could destroy data or expose a user's disk contents:

- Preferred: [GitHub Security Advisories](https://github.com/rayhanadev/Ext4Kit/security/advisories/new)
- Or email: ray@million.dev

To help reproduce, include where possible:

- macOS version and the Ext4Kit version (or commit)
- How the volume was created (`mkfs.ext4` flags / `newfs_fskit` command),
  and its feature flags (`dumpe2fs -h` output)
- The exact operations that triggered the problem
- `e2fsck -fn` output from a Linux box against the affected image
- A minimal disk image that reproduces it, if you can share one safely

## No warranty

Ext4Kit is distributed under the terms in [LICENSE](../LICENSE) and
[THIRD_PARTY_LICENSES.md](../THIRD_PARTY_LICENSES.md) **with no warranty of
any kind**. Back up important data and test on a scratch volume before
trusting it with anything you can't afford to lose.
