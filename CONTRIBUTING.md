# Contributing to Ext4Kit

Thanks for your interest! A few project-specific things are worth knowing
before you send a change.

## Building

- **Xcode 16.3+** and a **paid Apple Developer team** (the
  `com.apple.developer.fskit.fsmodule` entitlement can't be signed
  otherwise). Set your team on both targets in *Signing & Capabilities*.
- Clone with submodules: `git clone --recurse-submodules …`.
- Build the extension from the CLI without signing:
  ```sh
  xcodebuild -project Ext4Kit.xcodeproj -scheme Ext4KitExtension \
    -configuration Debug CODE_SIGNING_ALLOWED=NO build
  ```

## Where lwext4 changes go

The on-disk engine is [lwext4](https://github.com/gkostka/lwext4), vendored
as a submodule pointing at the
[rayhanadev/lwext4](https://github.com/rayhanadev/lwext4) fork
(`ext4kit-patches` branch). **Do not edit `Vendor/lwext4` in place and
commit only the parent repo** — the parent can't record submodule
working-tree edits, so the change would be lost on a fresh clone. Instead:

1. Commit the change on the fork's `ext4kit-patches` branch and push it.
2. Bump the submodule pointer in this repo.
3. Ideally also propose it upstream to `gkostka/lwext4`.

## Testing before a PR

The `Benchmarks/` harness exercises lwext4 the same way the extension does,
with no special privileges — run it locally:

```sh
cd Benchmarks
make CACHE=1024
./bench-cache1024 /tmp/t.img --verify     # benchmarks + data verification
./bench-cache1024 /tmp/t.img --fuzz 300   # corrupt-image robustness
./bench-cache1024 /tmp/t.img --soak 60    # randomized mixed-op endurance
./bench-cache1024 /tmp/t.img --crash 50   # crash + journal-replay recovery
```

CI runs build (Debug + Release), `swift-format` lint, and the harness
(verify / fuzz / soak / crash) on every push. Format your code first:

```sh
xcrun swift-format format -i -r Ext4Kit Ext4KitExtension
```

For changes that touch the write path, also do an end-to-end check from
Linux: mount via FSKit, write, unmount, then `e2fsck -f` the image (see the
README's Performance section for the Docker one-liner).

## Scope

Ext4Kit's own Swift/C code is MIT; the combined binary is GPL-2 because of
lwext4. Keep contributions compatible with both.
