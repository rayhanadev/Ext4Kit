# Ext4Kit

A read/write ext4 filesystem driver for macOS, built on Apple's **FSKit**.
Ext4Kit ships as an app extension (`.appex`) hosted by a thin SwiftUI app — no
kernel extensions, no SIP workarounds. The filesystem itself is provided by
[lwext4](https://github.com/gkostka/lwext4), a portable C ext2/3/4 library
vendored as a submodule and compiled directly into the extension.

## Status

**Working:**
- Probe an ext4 block device: recognize the superblock, surface the label and
  UUID to DiskArbitration/FSKit.
- Mount a real ext4 image via `sudo mount -F -t ext4 diskN /mnt`. Shows up in
  `mount(1)` as `ext4, fskit`.
- `df -h` reports real block and inode counts read from the on-disk superblock
  via `ext4_mount_point_stats`.
- `ls -la` walks the directory tree. Both the root and nested directories
  return real entries via `ext4_dir_open` / `ext4_dir_entry_next`.
- `stat` returns real inode data: type, mode, link count, size, and
  access/modify/change times from on-disk inodes via `ext4_raw_inode_fill`.
- `cat` reads real file contents through `ext4_fopen` / `ext4_fseek` /
  `ext4_fread`, including multi-block files. Deterministic multi-read
  integrity is verified by `md5` producing an identical hash across
  consecutive runs against a 50 KiB random-data file.
- `readlink` and transparent symlink traversal via `ext4_readlink`. Both
  relative (`link → file.txt`) and absolute (`link → /tmp/something`)
  targets resolve correctly; `cat symlink` follows to the target file.
- Clean unmount through `ext4_journal_stop` + `ext4_umount` on `deactivate`.
- `setAttributes` persists `chmod`, `chown`, `utimes`, and file `truncate`
  (both shrink and zero-fill grow) via lwext4's `ext4_mode_set` /
  `ext4_owner_set` / `ext4_*time_set` / `ext4_ftruncate`. `touch file`
  (existing file) and `chmod 755 file` actually update on-disk state.
- Full namespace mutation: `mkdir`, `rmdir` (with proper `ENOTEMPTY`),
  `rm`, `mv` — including rename-over-existing and cross-directory moves —
  `ln` (hard links, with `EMLINK` at ext4's 65 000-link ceiling), `ln -s`,
  and `mkfifo`/`mknod`-style special files via `createItem`, `removeItem`,
  `renameItem`, `createLink`, and `createSymbolicLink`. Renaming a directory
  into its own subtree is refused (`EINVAL`) — lwext4 itself has no cycle
  guard.
- File writes through `write(contents:to:at:)` via `ext4_fwrite`, including
  writes past EOF (the gap is zero-filled — lwext4 has no sparse files).
  `echo hi > file`, `cp`, `dd`, and Finder copies persist for real.
- Persistent open-file handles via `FSVolume.OpenCloseOperations`: one
  lwext4 handle per inode is held between `openItem`/`closeItem` (hard
  links share it), so sequential reads/writes don't reopen per call.
- Extended attributes via `FSVolume.XattrOperations`. macOS xattr names map
  into the Linux `user.` namespace (`com.apple.quarantine` is stored as
  `user.com.apple.quarantine`), so they round-trip to Linux as ordinary
  user xattrs. Values are capped at one filesystem block.
- Volume rename via `FSVolume.RenameOperations` (`diskutil rename`): the
  superblock label is rewritten in place with its checksum recomputed.
- POSIX-ish timestamp maintenance. lwext4 updates **no** timestamps on its
  own (new inodes are born with epoch-zero times), so the volume stamps
  atime/mtime/ctime on create, mtime/ctime on write/truncate, ctime on
  chmod/chown/link/xattr changes, and parent-directory mtime/ctime on every
  namespace operation.
- Directory-enumeration verifiers: each directory carries a generation
  counter bumped on every mutation, so a `readdir` resumed across a
  concurrent create/delete is invalidated with FSKit's
  `invalidDirectoryCookie` error (which the kernel handles gracefully)
  instead of silently skipping or duplicating entries.
- Open-unlink emulation: removing (or renaming over) the last link of an
  open file parks it under a hidden `.ext4kit-orphan-<ino>` name in the
  root instead of freeing the inode, so reads/writes/ftruncate through the
  still-open descriptor keep working; the inode is freed on last close.
  Stale orphans from a crash are swept at the next mount.
- Stock `mkfs.ext4 -L LABEL image.img` images mount, including
  `metadata_csum` volumes. lwext4 maintains every metadata checksum on
  write (group descriptors, inodes, directory tails, extents, bitmaps,
  superblock) — but it always seeds them from the volume UUID, so a volume
  whose UUID was changed after format (`tune2fs -U`) is automatically
  degraded to read-only rather than risking wrongly-seeded checksums.
- Read-only mounts honored end to end: `mount -o ro|rdonly`, `mount -r`,
  and write-protected media all mount lwext4 read-only, skip journal
  replay, and gate every mutating operation with `EROFS`.
- Format and check via the FSKit maintenance shims:
  `newfs_fskit -t ext4 -L LABEL [-b 4096] /dev/diskNsM` creates a fresh
  journaled ext4 via lwext4's mkfs, and `fsck_fskit -t ext4 /dev/diskNsM`
  runs a read-only structural check (superblock, features, trial mount —
  lwext4 has no repair engine, so it never modifies the volume).

**Not yet:**
- Kernel-offloaded I/O (`FSVolumeKernelOffloadedIOOperations`). Every
  read/write round-trips through the extension process. lwext4 exposes no
  public extent-mapping API, so `blockmapFile` would have to reach into its
  internals.
- Preallocation (`FSVolume.PreallocateOperations`): lwext4 cannot allocate
  blocks without extending the file size, which is not what `fallocate`
  semantics promise, so the protocol isn't adopted.
- Sparse files: writes past EOF physically zero-fill the gap (lwext4 can't
  truncate-up or seek past EOF). Growing a file by gigabytes therefore does
  real zero I/O — and stalls other volume operations while it runs, since
  all lwext4 calls are serialized. Grows larger than the remaining free
  space fail fast with `ENOSPC` instead of filling the disk first.
- Non-UTF-8 entry names (creatable from Linux, where names are raw bytes)
  are hidden from enumeration and can't be looked up or deleted from macOS;
  a directory containing only such entries reports `ENOTEMPTY` on `rmdir`.
- BSD file flags (`chflags uchg` etc.) — reported as 0, never consumed.
- Device-node numbers: FSKit's attribute set carries no `rdev`, so
  char/block device nodes are created with device number 0.
- `atime` is not updated on reads (deliberate, `noatime` behavior).
- `inline_data` — lwext4 can't read files whose content is stored in the
  inode. Images must be formatted with `mkfs.ext4 -O ^inline_data`.

## Performance

Three measured optimizations ship in the default build (all numbers from
`Benchmarks/bench.c`, a harness that drives the vendored lwext4 with the same
call patterns `Ext4Volume` uses, against a file-backed block device, counting
physical block I/Os via lwext4's built-in `bread_ctr`/`bwrite_ctr`):

- **lwext4 block cache: 8 → 1024 buffers** (`CONFIG_BLOCK_DEV_CACHE_SIZE=1024`
  in the extension's build settings, ≈4 MiB). The cache only serves metadata
  (file contents bypass it), and 8 buffers couldn't hold even one path's
  directory blocks: stat of an 8-deep path cost **18 physical reads per
  call** (360k reads for 20k stats); with 1024 buffers it costs **zero** on a
  warm cache (~10× wall clock). Creates dropped from ~32 reads/file to ~2.
  Lookup is an RB-tree (O(log n)) and buffers allocate lazily, so a large
  cap has no downside besides memory.
- **`ioSize` (statfs `f_iosize`/`st_blksize`): 4 KiB → 128 KiB.** This sizes
  the I/O that *applications* issue (stdio, `cp`, Finder); the kernel passes
  big requests through to the extension whole, and lwext4 coalesces
  contiguous file runs into single device transfers — but every tiny write
  call is a full journal transaction. Measured on 64 MiB sequential writes:
  4 KiB chunks = 100 MiB/s and 180k device writes; 128 KiB = 322 MiB/s and
  5.4k writes. (Apple's msdos module uses 32 KiB; 1 MiB added nothing here.)
- **O(1) directory-enumeration resume.** Cookies are now lwext4 directory
  byte offsets (`dir.next_off`) instead of entry counts, so resuming a
  paged `readdir` no longer re-walks from the start (it was O(n²) across a
  listing). At 20 000 entries: positional resume 0.43 s, offset resume
  0.003 s (**~150×**). Stale offsets are fenced by the per-directory
  verifier plus a bounds check (lwext4's iterator crashes on out-of-range
  seeds).

Measured and **rejected**: enabling lwext4's global write-back cache while
journaling — the deferred checkpoints stall the journal head and the
journal-full purge path makes it *slower* than write-through (40k vs 36k
writes on a create storm). The journal itself costs ~3.5× on metadata
storms (every operation is a synchronous commit); it stays on because crash
consistency is the point.

Not yet attempted, in expected-impact order: kernel-offloaded I/O
(`FSVolumeKernelOffloadedIOOperations` — Apple's msdos module moves file
data this way, eliminating per-read upcalls entirely; needs real-mount
testing), and routing lwext4's metadata I/O through
`FSBlockDeviceResource.metadataRead/Write` (kernel buffer cache) — risky to
mix with the raw-`pread` path, so deferred.

Run the harness yourself:

```sh
cd Benchmarks
make CACHE=1024            # mirror the shipping config (or CACHE=8 for old)
./bench-cache1024 /tmp/bench.img --verify
./bench-cache1024 /tmp/big.img --files 20000 --size-mb 1024   # big-dir tests
./bench-cache1024 /tmp/fuzz.img --fuzz 300     # corrupt-image robustness
./bench-cache1024 /tmp/soak.img --soak 60      # randomized mixed-op endurance
```

The fuzz mode corrupts random metadata bytes and mounts/walks/writes the
result (graceful errors pass; crashes and hangs fail — 300/300 rounds clean
as of this writing). The soak mode runs randomized create/write/read/
rename/unlink/truncate traffic and verifies structure plus a data pattern
after remount; CI runs both on every push.

## Repository layout

```
Ext4Kit/
├── Ext4Kit.xcodeproj
├── Ext4Kit/                   host SwiftUI app (carries the extension)
│   ├── Ext4KitApp.swift
│   ├── ContentView.swift
│   └── Assets.xcassets/
├── Benchmarks/                lwext4 benchmark harness (see Performance)
├── Ext4KitExtension/          the .appex — FSKit File System Extension
│   ├── ExtensionMain.swift    @main UnaryFileSystemExtension entry point
│   ├── Ext4FileSystem.swift   FSUnaryFileSystem: probe + load/unload resource
│   ├── Ext4Volume.swift       FSVolume: activate/deactivate + all volume ops
│   ├── Ext4Item.swift         FSItem subclass carrying inode + absolute path
│   ├── Ext4Superblock.swift   minimal on-disk superblock parser for probe
│   ├── Ext4BlockDevice.swift  Swift wrapper owning the lwext4 ext4_blockdev
│   ├── Ext4KitBlockDev.{c,h}  C shim: lwext4 callbacks → Swift trampolines
│   ├── Ext4KitBridge.h        Objective-C bridging header into lwext4 + shim
│   ├── Info.plist
│   └── Ext4KitExtension.entitlements
└── Vendor/
    └── lwext4/                git submodule, compiled into the extension
```

## Architecture

FSKit launches the `.appex` on demand when a `mount -F -t ext4` call arrives.
Inside the extension process:

1. `Ext4FileSystem.probeResource` reads the 1024-byte superblock directly from
   `FSBlockDeviceResource` and validates the ext4 magic.
2. `Ext4FileSystem.loadResource` constructs an `Ext4BlockDevice` that adapts
   `FSBlockDeviceResource` to lwext4's `ext4_blockdev` interface, registers it
   with `ext4_device_register`, and hands back an `Ext4Volume`.
3. `Ext4Volume.activate` calls `ext4_mount` read/write, replays the journal
   (`ext4_recover`), starts journaling (`ext4_journal_start`), and caches the
   superblock pointer returned by `ext4_get_sblock`.
4. VFS operations (`lookupItem`, `createItem`, `write`, `enumerateDirectory`,
   …) run against lwext4's path-based API. `Ext4Item` records its parent item
   and entry name; absolute paths (e.g. `/ext4kit/dir1/inside.txt`) are
   computed on demand by walking the parent chain, so renaming a directory
   never strands cached descendants. All operations are serialized behind one
   recursive lock — lwext4 has no internal locking whatsoever.
5. On unmount, `Ext4Volume.deactivate` closes open handles, stops the journal,
   and calls `ext4_umount`; `Ext4FileSystem.unloadResource` unregisters the
   block device.

The block-device adapter is half C, half Swift. `Ext4KitBlockDev.c` implements
the four function pointers lwext4's `ext4_blockdev_iface` expects (`open`,
`close`, `bread`, `bwrite`). The `bread`/`bwrite` forwarders call Swift
functions declared with `@_cdecl`, which unpack an `Unmanaged<Ext4BlockDevice>`
from `bdev->bdif->p_user` and dispatch to
`FSBlockDeviceResource.read(into:startingAt:length:)` / `write(from:…)`.

## Requirements

- **macOS 15.4 Sequoia or newer.** FSKit went GA in 15.4.
- **Xcode 16.3 or newer.** Earlier Xcodes don't ship the FSKit SDK.
- **A paid Apple Developer account.** The
  `com.apple.developer.fskit.fsmodule` entitlement used by the extension
  requires a real team; personal/free teams cannot sign it.
- **Docker** (or any Linux environment) for creating ext4 test images. macOS
  ships no native `mkfs.ext4`.

## Build

```sh
git clone --recurse-submodules https://github.com/rayhanadev/Ext4Kit.git
cd Ext4Kit
open Ext4Kit.xcodeproj
```

Set your Development Team on both the `Ext4Kit` and `Ext4KitExtension` targets
in Signing & Capabilities (or edit the bundle IDs from `com.rayhanadev.Ext4Kit*`
to your own). Select the `Ext4Kit` scheme, hit Run once — launching the host
app registers the embedded extension with `pluginkit`.

If you cloned without `--recurse-submodules`:

```sh
git submodule update --init --recursive
```

## Enabling the extension

After the first run, enable the extension at
**System Settings → General → Login Items & Extensions → File System
Extensions** and toggle Ext4Kit on.

**Every Xcode rebuild** changes the extension's code signature hash, and macOS
defaults newly-resigned extensions to "ignore". If the mount fails with
`ExtensionKit error 2` after a rebuild, re-enable with:

```sh
pluginkit -e use -i com.rayhanadev.Ext4Kit.Ext4KitExtension
```

## Testing

### 1. Create an ext4 test image

e2fsprogs 1.47+ enables `inline_data` by default; lwext4 can't read inline
data, so disable that bit when formatting. `metadata_csum` is fine to leave on.

```sh
mkdir -p ~/ext4kit-test && cd ~/ext4kit-test
dd if=/dev/zero of=test.img bs=1m count=100
docker run --rm --privileged -v "$PWD":/w alpine sh -c \
  "apk add --no-cache e2fsprogs util-linux >/dev/null && \
   mkfs.ext4 -F -O ^inline_data \
     -L TESTVOL -U $(uuidgen) /w/test.img && \
   mkdir -p /mnt && mount -o loop /w/test.img /mnt && \
   echo 'hello from ext4kit' > /mnt/hello.txt && \
   mkdir /mnt/dir1 /mnt/dir2 && \
   echo 'nested' > /mnt/dir1/inside.txt && \
   umount /mnt"
```

### 2. Attach as a raw block device

```sh
hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount test.img
# -> /dev/disk7 (note the BSD name)
```

`-nomount` tells DiskArbitration not to try any other filesystem first.

### 3. Mount through Ext4Kit

```sh
# terminal A — stream the extension log
log stream --predicate 'subsystem == "dev.ext4kit.fs"' --info

# terminal B
sudo mkdir -p /tmp/ext4test
sudo mount -F -t ext4 disk7 /tmp/ext4test   # BSD name, no /dev/ prefix
```

> **Gotcha:** pass the **BSD name** (`disk7`), not `/dev/disk7`. The `-F` flag
> routes the mount through FSKit, and `fskitd` expects a bare BSD name. Passing
> `/dev/disk7` silently fails to reach the extension.

### 4. Inspect

```sh
mount | grep ext4                   # /dev/disk7 on /private/tmp/ext4test (ext4, fskit)
df -h /tmp/ext4test                 # real block/inode counts
ls -la /tmp/ext4test                # hello.txt, dir1, dir2, lost+found
ls -la /tmp/ext4test/dir1           # inside.txt
stat /tmp/ext4test/hello.txt        # real inode, size, mode, mtime
```

### 5. Exercise the write path

```sh
cd /tmp/ext4test
sudo mkdir newdir                              # createItem(.directory)
echo 'written from macos' | sudo tee newdir/new.txt
sudo cp hello.txt newdir/copy.txt              # create + write
sudo mv newdir/copy.txt newdir/renamed.txt     # renameItem
sudo ln newdir/new.txt newdir/hardlink.txt     # createLink
sudo ln -s new.txt newdir/sym.txt              # createSymbolicLink
sudo chmod 600 newdir/new.txt                  # setAttributes(mode)
sudo truncate -s 1m newdir/new.txt             # grow (zero-filled)
sudo xattr -w user.test hello newdir/new.txt   # XattrOperations
sudo rm newdir/hardlink.txt                    # removeItem
sudo rmdir newdir 2>&1 | grep 'not empty'      # ENOTEMPTY enforced
sudo rm -rf newdir                             # bottom-up removal
```

After unmounting, verify integrity from Linux:

```sh
docker run --rm --privileged -v "$HOME/ext4kit-test":/w alpine sh -c \
  "apk add --no-cache e2fsprogs >/dev/null && e2fsck -f /w/test.img"
```

A clean bill from `e2fsck -f` is expected even on `metadata_csum` images —
lwext4 maintains all metadata checksums on write. Any finding is a real bug.

### 6. Unmount and detach

```sh
sudo umount /tmp/ext4test
hdiutil detach /dev/disk7
```

## Log stream

All extension logs go to subsystem `dev.ext4kit.fs`:

```sh
# live
log stream --predicate 'subsystem == "dev.ext4kit.fs"' --info

# recent history
log show --predicate 'subsystem == "dev.ext4kit.fs"' --info --last 10m
```

Interesting categories inside the subsystem:
- `fs` — probeResource / loadResource / unloadResource
- `volume` — activate / deactivate / enumerate / lookup / getAttributes
- `bdev` — block device reads/writes (errors only by default)

## Troubleshooting

**`mount: File system named ext4 not found`**
: The extension isn't registered or isn't enabled.
  Run `pluginkit -m -v -p com.apple.fskit.fsmodule | grep ext4`. The line
  should start with `+`. If it starts with `!` or is missing, either re-enable
  via `pluginkit -e use -i com.rayhanadev.Ext4Kit.Ext4KitExtension` or re-run
  the host app in Xcode.

**`mount` hangs, no extension logs**
: Usually means `fskit_agent` has a leaked transaction from a previous failed
  launch, or ExtensionKit has a stale `_EXExtensionIdentity` cached against the
  old binary hash. Fix:
  ```sh
  APPEX=/Users/$USER/Library/Developer/Xcode/DerivedData/Ext4Kit-*/Build/Products/Debug/Ext4Kit.app/Contents/Extensions/Ext4KitExtension.appex
  killall -TERM extensionkitservice
  pluginkit -r "$APPEX"
  pluginkit -a "$APPEX"
  pluginkit -e use -i com.rayhanadev.Ext4Kit.Ext4KitExtension
  launchctl kickstart -kp user/$UID/com.apple.fskit.fskit_agent
  ```

**`mount` returns `ExtensionKit error 2` / `NSCocoaErrorDomain 4099`**
: Same root cause as the hang, same fix.

**`ext4_mount failed: rc=45`**
: The test image uses `inline_data`. Recreate it with
  `mkfs.ext4 -O ^inline_data …`.

**`ls` shows an empty directory**
: This was fixed — if you see it now, grab the latest source. The historical
  cause was passing `nil` for `packer.packEntry`'s `attributes` parameter when
  FSKit had requested non-nil attributes; the packer silently drops entries in
  that case.

## License

Ext4Kit's own source code is licensed under the **MIT License** — see
[`LICENSE`](LICENSE) for the full text. This covers everything in `Ext4Kit/`
and `Ext4KitExtension/` (the Swift sources, the C block-device shim, the
bridging header, and the project configuration).

Ext4Kit statically links [lwext4](https://github.com/gkostka/lwext4)
(vendored as a submodule pointing at
[rayhanadev/lwext4](https://github.com/rayhanadev/lwext4), branch
`ext4kit-patches`, which carries one small feature-acceptance patch on top
of upstream). lwext4 carries **mixed file-level licensing**.
Most lwext4 sources are BSD-3-Clause, but two files (`src/ext4_extent.c` and
`src/ext4_xattr.c`) are **GPL-2.0-or-later**. Because `ext4_extent.c` is
load-bearing for ext4 support and is compiled into the extension binary, the
**distributed `Ext4KitExtension.appex` is a combined work subject to GPL-2's
terms**: if you redistribute a built binary, you must also make the complete
corresponding source available to recipients, per GPL-2.

See [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md) for the per-file
breakdown and a longer discussion of the practical effect.
