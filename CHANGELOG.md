# Changelog

## Unreleased (0.1.0)

First feature-complete cut of Ext4Kit: a read/write ext4 driver for macOS
built on FSKit and lwext4 — no kernel extensions.

### Filesystem features
- Probe, mount, unmount of ext4 block devices (`mount -F -t ext4`).
- Full read path: enumeration, lookup, file reads, symlinks, real attributes.
- Full write path: create/remove/rename (including rename-over and proper
  `ENOTEMPTY`), hard links, symlinks, special files, file writes with
  zero-fill extension, chmod/chown/utimes/truncate.
- Extended attributes mapped into the Linux `user.` namespace.
- Volume rename (superblock label, checksum maintained).
- Open-unlink emulation via hidden orphan parking; crash-leftover orphans
  swept at mount.
- POSIX timestamp maintenance everywhere (lwext4 maintains none itself).
- Journal replay on mount, journaled metadata writes, refusal to mount
  writable if replay fails.
- Read-only mounts honored (`mount -o ro|rdonly`, non-writable media), with
  every mutating operation gated by `EROFS`.
- Checksum-seed safety: volumes whose `s_checksum_seed` no longer matches
  the UUID (e.g. after `tune2fs -U`) mount read-only, because lwext4 always
  seeds metadata checksums from the UUID.
- `newfs_fskit -t ext4` formatting (label + block-size options) and
  `fsck_fskit -t ext4` read-only structural checking.

### Performance
- lwext4 metadata block cache raised 8 → 1024 buffers (deep-path stats go
  from 18 device reads each to zero on a warm cache).
- statfs `ioSize` 4 KiB → 128 KiB (sequential writes ~3×, 33× fewer device
  writes at the same workload).
- O(1) directory-enumeration resume via byte-offset cookies (~150× on
  20k-entry directories), with per-directory verifiers.

### Tooling
- `Benchmarks/` harness: lwext4-level benchmarks with physical-I/O counters,
  remount data verification, corrupt-image fuzzing (`--fuzz`), and randomized
  mixed-op soak testing (`--soak`).
- CI: Debug/Release builds plus harness verify/fuzz/soak on every push.
- `Scripts/release.sh`: archive → Developer ID export → notarize → staple.

### Known limitations
See README "Not yet": no sparse files, xattr values capped at one block,
non-UTF-8 names hidden, no kernel-offloaded I/O yet.

Note: the soak harness shows bounded heap RSS (~8.5 MB peak at cache=1024)
that does not grow across repeated mount/unmount cycles — `mstats` measured
0 net growth over 100 clean cycles, so it's allocator retention, not a
leak. `ext4_umount` tears down the block cache and journal; the extension's
`deactivate`/`unloadResource` release the volume and device. Harmless in
the fskitd-per-mount model regardless, since process exit reclaims it.
