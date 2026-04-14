# Ext4Kit

A read-only ext4 filesystem driver for macOS, built on Apple's **FSKit**.
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
- Clean unmount through `ext4_umount` on `deactivate`.
- All mutating operations return `EROFS`. Write support isn't implemented.

**Not yet:**
- File contents. `cat /mnt/file.txt` returns `Operation not supported` because
  `FSVolume.ReadWriteOperations` is not yet implemented.
- Symbolic link resolution (`readSymbolicLink` returns `EINVAL`).
- Any write path: create, delete, rename, mkdir, chmod, chown, truncate.
- `inline_data` and `metadata_csum` ext4 features — lwext4 doesn't implement
  them, so images must be created with `mkfs.ext4 -O ^inline_data,^metadata_csum`.

## Repository layout

```
Ext4Kit/
├── Ext4Kit.xcodeproj
├── Ext4Kit/                   host SwiftUI app (carries the extension)
│   ├── Ext4KitApp.swift
│   ├── ContentView.swift
│   └── Assets.xcassets/
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
3. `Ext4Volume.activate` calls `ext4_mount` read-only and caches the superblock
   pointer returned by `ext4_get_sblock`.
4. VFS operations (`lookupItem`, `getAttributes`, `enumerateDirectory`, …) run
   against lwext4's path-based API. `Ext4Item` carries a full absolute path
   (e.g. `/ext4kit/dir1/inside.txt`) so path-based lookups can address any
   subtree entry.
5. On unmount, `Ext4Volume.deactivate` calls `ext4_umount` and
   `Ext4FileSystem.unloadResource` unregisters the block device.

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

e2fsprogs 1.47+ enables `inline_data` and `metadata_csum` by default; lwext4
doesn't support either, so disable them when formatting:

```sh
mkdir -p ~/ext4kit-test && cd ~/ext4kit-test
dd if=/dev/zero of=test.img bs=1m count=100
docker run --rm --privileged -v "$PWD":/w alpine sh -c \
  "apk add --no-cache e2fsprogs util-linux >/dev/null && \
   mkfs.ext4 -F -O ^inline_data,^metadata_csum \
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

### 5. Unmount and detach

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
: The test image uses `inline_data` or `metadata_csum`. Recreate it with
  `mkfs.ext4 -O ^inline_data,^metadata_csum …`.

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

Ext4Kit statically links [lwext4](https://github.com/gkostka/lwext4), which
is vendored under `Vendor/lwext4/` and carries **mixed file-level licensing**.
Most lwext4 sources are BSD-3-Clause, but two files (`src/ext4_extent.c` and
`src/ext4_xattr.c`) are **GPL-2.0-or-later**. Because `ext4_extent.c` is
load-bearing for ext4 support and is compiled into the extension binary, the
**distributed `Ext4KitExtension.appex` is a combined work subject to GPL-2's
terms**: if you redistribute a built binary, you must also make the complete
corresponding source available to recipients, per GPL-2.

See [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md) for the per-file
breakdown and a longer discussion of the practical effect.
