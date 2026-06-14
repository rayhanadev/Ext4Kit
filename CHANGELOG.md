# Changelog

## 0.1.0 — 2026-06-14

First public beta. Mount Linux ext4 drives on macOS & read & write them like
any other volume — no kernel extensions, built on Apple's FSKit. Runs on
macOS 15.4+; you don't need a developer account to use it.

> **Beta — back up your data first.** Test on a scratch volume before you
> trust Ext4Kit with anything important. The read/write path is verified
> against live mounts. Formatting (`newfs_fskit`), checking (`fsck_fskit`), &
> read-only mounts pass the build & test harness but haven't been run against
> a live mount yet.

### What you can do

- **Mount & unmount** ext4 volumes: `mount -F -t ext4 diskN /Volumes/ext4`.
- **Read** files, directories, & symlinks, with real permissions & timestamps.
- **Write** for real: create, delete, rename (including renaming over an
  existing file), hard-link, symlink, & edit files.
- **Change metadata** with `chmod`, `chown`, `touch`, & `truncate`.
- **Set extended attributes** — macOS xattrs round-trip through Linux's
  `user.` namespace.
- **Rename a volume** with `diskutil rename`.
- **Format & check**: `newfs_fskit -t ext4 -L LABEL` makes a fresh volume;
  `fsck_fskit -t ext4` runs a read-only structural check.

### Safe by default

- **Journaled writes.** Ext4Kit replays the ext4 journal on mount & refuses
  to mount writable if replay fails, so an interrupted write can't silently
  corrupt the volume.
- **Linux stays happy.** Metadata checksums stay up to date — `e2fsck` comes
  back clean after a macOS write session.
- **Read-only when it should be.** `mount -o ro`, write-protected media, &
  volumes with an unusual checksum seed all mount read-only automatically.
- **Open files survive deletion.** Deleting an open file keeps it readable
  until the last handle closes, the way POSIX expects.

### Faster

- Sequential writes run about 3× faster, with far fewer device writes.
- Listing a 20,000-entry directory pages instantly instead of re-scanning
  from the start (about 150× faster).
- Repeated `stat` of deep paths hits the cache & skips the disk entirely.

### Limitations

- `inline_data` volumes don't mount — format with `mkfs.ext4 -O ^inline_data`.
- No sparse files: writing past the end of a file fills the gap with zeros.
- Extended-attribute values are capped at one filesystem block (about 4 KiB).
- Filenames that aren't valid UTF-8 stay hidden & can't be deleted on macOS.
- File data flows through the extension process — no kernel-offloaded I/O yet.

See the README for the full list.

### Tooling

- `Benchmarks/` — an lwext4 test harness with data-integrity checks,
  corrupt-image fuzzing, randomized soak runs, & crash/journal-replay tests.
- CI builds Debug & Release & runs the full harness on every push.
- `Scripts/release.sh` — archive, Developer ID sign, notarize, & staple.

### License

Ext4Kit's own code is MIT. The shipped app statically links lwext4, so the
binary is a combined work under GPL-2.0-or-later — the complete source is
this tag plus the pinned `Vendor/lwext4` submodule. See
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
