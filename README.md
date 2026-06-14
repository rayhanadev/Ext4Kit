# Ext4Kit

**Native read/write ext4 for macOS.** No kernel extensions, no FUSE, no
SIP workarounds — Ext4Kit is a userspace file system built on Apple's
[FSKit](https://developer.apple.com/documentation/fskit), with the on-disk
heavy lifting done by [lwext4](https://github.com/gkostka/lwext4).

Plug in a Linux-formatted drive, mount it, and use it like any other volume:
read, write, rename, link, set permissions and xattrs — with the ext4
journal kept intact so Linux still trusts the disk afterwards.

```sh
sudo mount -F -t ext4 disk4 /Volumes/linux
cp ~/big-file.mkv /Volumes/linux/
sudo umount /Volumes/linux
```

> [!WARNING]
> **Beta software (0.1.0).** Ext4Kit writes to real ext4 volumes. Back up
> anything you care about and test on a scratch volume first. It's tested
> hard (see [Performance](#performance)) but it hasn't seen broad
> real-world use yet. No warranty — see [LICENSE](LICENSE).

## Features

- **Full read/write** — create, delete, rename (including over existing
  files), hard links, symlinks, file I/O with proper `ENOTEMPTY`/`EEXIST`/
  `EROFS` semantics, chmod/chown/touch/truncate.
- **Journaled** — metadata writes go through the ext4 journal; unclean
  shutdowns are replayed on the next mount, and a volume that fails replay
  is refused rather than corrupted further.
- **Plays nice with Linux** — metadata checksums (`metadata_csum`) are
  maintained on write; `e2fsck -f` comes back clean after a macOS write
  session.
- **Extended attributes** — macOS xattrs map into the Linux `user.`
  namespace and round-trip both ways.
- **Read-only when it should be** — `mount -o ro`, write-protected media,
  and volumes with unusual checksum seeding all mount read-only
  automatically.
- **Format and check** — `newfs_fskit -t ext4` creates fresh journaled
  ext4 volumes; `fsck_fskit -t ext4` runs a read-only structural check.
- **Fast** — a tuned metadata cache, 128 KiB preferred I/O size, and O(1)
  directory paging. Sequential I/O runs at hundreds of MB/s; see
  [Performance](#performance).

## Requirements

**To run a notarized release:** just macOS 15.4+ — no developer account, no
SIP changes. (FSKit went GA in 15.4.)

**To build it yourself**, additionally:

- **Xcode 16.3+**
- **A paid Apple Developer account** — the
  `com.apple.developer.fskit.fsmodule` entitlement can't be signed by
  free/personal teams. This is a _build_-time requirement only; people you
  distribute a signed, notarized build to need nothing but macOS 15.4.

## Install

Download the latest notarized build from
[Releases](https://github.com/rayhanadev/Ext4Kit/releases), move `Ext4Kit.app`
to your Applications folder, and open it once. Then skip to step 3 below to
enable the extension.

### Build from source

```sh
git clone --recurse-submodules https://github.com/rayhanadev/Ext4Kit.git
cd Ext4Kit
open Ext4Kit.xcodeproj
```

1. Set your Development Team on both targets in _Signing & Capabilities_
   (or change the bundle IDs from `com.rayhanadev.Ext4Kit*` to your own).
2. Run the `Ext4Kit` scheme once — launching the host app registers the
   extension.
3. Enable it: **System Settings → General → Login Items & Extensions →
   File System Extensions** → toggle **Ext4Kit** on. The host app shows
   live status and a shortcut button.

> **Rebuilding?** Every rebuild changes the extension's code signature and
> macOS quietly disables it. Re-enable with:
> `pluginkit -e use -i com.rayhanadev.Ext4Kit.Ext4KitExtension`

## Usage

**Mount** (note: the _BSD name_ without `/dev/` — `fskitd` requires it):

```sh
diskutil list external                  # find your disk, e.g. disk4
sudo mkdir -p /Volumes/linux
sudo mount -F -t ext4 disk4 /Volumes/linux
```

**Unmount / eject:**

```sh
sudo umount /Volumes/linux
```

**Format a device as ext4:**

```sh
newfs_fskit -t ext4 -L MYDRIVE /dev/disk4s1
```

**Check a volume (read-only, never modifies):**

```sh
fsck_fskit -t ext4 /dev/disk4s1
```

**Mount read-only:**

```sh
sudo mount -F -t ext4 -o rdonly disk4 /Volumes/linux
```

## Limitations

- **`inline_data` volumes don't mount** — lwext4 can't read files stored
  inside the inode. Format with `mkfs.ext4 -O ^inline_data` (e2fsprogs
  1.47+ enables it by default).
- **No sparse files** — writing far past EOF physically writes zeros for
  the gap, and very large gaps are slow. Grows beyond free space fail fast
  with `ENOSPC`.
- **xattr values are capped at one filesystem block** (~4 KiB) — Finder
  copies of files with large resource forks will report errors for those
  forks.
- **Non-UTF-8 filenames** (creatable from Linux) are hidden from listings
  and can't be deleted from macOS.
- **Volumes with a custom checksum seed** (UUID changed after format via
  `tune2fs -U`) mount read-only — lwext4 seeds checksums from the UUID, so
  writing would produce mis-seeded checksums.
- BSD file flags (`chflags`) and device-node numbers aren't supported;
  `atime` is not updated on reads (`noatime` behavior).
- All I/O flows through the extension process — kernel-offloaded I/O
  (Apple's own data path for its msdos module) is the next planned
  improvement.

## Performance

Three measured optimizations ship in the default build (numbers from
`Benchmarks/bench.c`, which drives the bundled lwext4 with the same call
patterns the extension uses and counts physical device I/O):

| Optimization                                            | Effect                                                                                                     |
| ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Metadata block cache, 8 → 1024 buffers (~4 MiB)         | Deep-path stat: 18 device reads each → **0** on a warm cache; file creates issue 16× fewer reads           |
| Preferred I/O size (`statfs f_iosize`), 4 KiB → 128 KiB | Sequential writes 100 → **322 MiB/s**, 33× fewer device writes (each small write is a full journal commit) |
| O(1) directory paging (byte-offset cookies)             | Paged listing of a 20 000-entry directory: 0.43 s → **0.003 s**                                            |

Measured and rejected: lwext4's write-back cache mode (slower than
write-through when journaled — checkpoint churn), and journal-off mode
(3.5× faster metadata storms, but crash consistency is the point).

```sh
cd Benchmarks
make CACHE=1024
./bench-cache1024 /tmp/bench.img --verify       # benchmarks + data integrity
./bench-cache1024 /tmp/fuzz.img  --fuzz 300     # corrupt-image robustness
./bench-cache1024 /tmp/soak.img  --soak 60      # randomized mixed-op endurance
```

The fuzzer corrupts random metadata and mounts/walks/writes the result —
graceful errors pass, crashes and hangs fail (300/300 rounds clean as of
this writing). The soak runs randomized create/write/read/rename/unlink
traffic, then verifies structure and a data pattern after remount. CI runs
both on every push.

For end-to-end verification from the Linux side, fsck a test image in
Docker after a macOS write session:

```sh
docker run --rm --privileged -v /tmp:/w alpine sh -c \
  "apk add --no-cache e2fsprogs >/dev/null && e2fsck -f /w/test.img"
```

A clean bill is the expected result; any finding is a bug worth reporting.

## How it works

```
mount -F -t ext4 disk4 /Volumes/linux
        │
        ▼
  fskitd / lifs (kernel VFS layer)
        │  FSKit XPC
        ▼
  Ext4KitExtension.appex (this project)
        │  Swift: FSVolume operations, item lifecycle, locking,
        │  open-unlink emulation, timestamps, read-only policy
        ▼
  lwext4 (C, statically linked)
        │  ext4 structures, extents, journal, block cache
        ▼
  FSBlockDeviceResource ──► the raw partition
```

- `Ext4FileSystem.swift` — probe/load/unload, read-only policy,
  `newfs`/`fsck` maintenance operations
- `Ext4Volume.swift` — every VFS operation; one lock serializes lwext4
  (which has no internal locking)
- `Ext4Item.swift` — FSItem identity: parent + name, computed paths, child
  cache
- `Ext4BlockDevice.swift` + `Ext4KitBlockDev.c` — lwext4's block-device
  callbacks bridged to `FSBlockDeviceResource`
- `Benchmarks/` — the lwext4 test/benchmark/fuzz harness (no special
  privileges needed)
- `Vendor/lwext4` — submodule of
  [rayhanadev/lwext4](https://github.com/rayhanadev/lwext4)
  (`ext4kit-patches`): upstream `gkostka/lwext4` plus exactly one patch —
  [`837ef73`](https://github.com/rayhanadev/lwext4/commit/837ef73), which
  adds `EXT4_FINCOM_BG_USE_META_CSUM` to lwext4's supported-incompat set so
  e2fsprogs 1.47+ `metadata_csum` volumes mount. If the fork is ever
  unavailable, apply that one-line change to upstream `include/ext4_types.h`
  and point the submodule there.

Deeper details — the open-unlink orphan scheme, directory-cookie
verifiers, checksum-seed policy, timestamp semantics — are documented as
doc comments at their implementation sites, and the development history
lives in [CHANGELOG.md](CHANGELOG.md).

## Troubleshooting

**`mount: File system named ext4 not found`**
— The extension isn't enabled. Check
`pluginkit -m -v -p com.apple.fskit.fsmodule | grep ext4` (should start
with `+`); re-enable via the host app or
`pluginkit -e use -i com.rayhanadev.Ext4Kit.Ext4KitExtension`.

**`mount` hangs or returns `ExtensionKit error 2` after a rebuild**
— Stale ExtensionKit state against the old binary hash:

```sh
APPEX=~/Library/Developer/Xcode/DerivedData/Ext4Kit-*/Build/Products/Debug/Ext4Kit.app/Contents/Extensions/Ext4KitExtension.appex
killall -TERM extensionkitservice
pluginkit -r "$APPEX" && pluginkit -a "$APPEX"
pluginkit -e use -i com.rayhanadev.Ext4Kit.Ext4KitExtension
launchctl kickstart -kp user/$UID/com.apple.fskit.fskit_agent
```

**`ext4_mount failed: rc=45`**
— The volume uses `inline_data`; reformat with `-O ^inline_data`.

**Live logs** (subsystem `dev.ext4kit.fs`, categories `fs`, `volume`,
`bdev`):

```sh
log stream --predicate 'subsystem == "dev.ext4kit.fs"' --info
```

## License

Ext4Kit's own code (everything outside `Vendor/`) is **MIT** — see
[LICENSE](LICENSE).

The bundled lwext4 carries mixed per-file licensing: mostly BSD-3-Clause,
but `ext4_extent.c` and `ext4_xattr.c` are **GPL-2.0-or-later**, and both
are compiled into the extension. **A distributed `Ext4KitExtension.appex`
is therefore a combined work under GPL-2 terms**: anyone redistributing
binaries must provide the complete corresponding source. See
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) for the per-file
breakdown.
