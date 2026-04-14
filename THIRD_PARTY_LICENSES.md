# Third-party licenses

Ext4Kit's own source code is licensed under the MIT License (see `LICENSE`).
Ext4Kit's extension binary statically links against the following third-party
software, which carries its own licensing terms.

## lwext4

Upstream: https://github.com/gkostka/lwext4
Vendored at: `Vendor/lwext4/` (git submodule)

lwext4 has **mixed, file-level licensing**. The repository's top-level
`LICENSE` file contains the GNU General Public License version 2 as a fallback
for files that do not carry their own header. However, most lwext4 source
files are individually licensed under the 3-clause BSD license, and a small
number are licensed under GPL-2.0-or-later. Each file's license is controlled
by the copyright header inside that file, per the note at the top of lwext4's
`LICENSE`:

> Some files in lwext4 contain a different license statement. Those files are
> licensed under the license contained in the file itself.

### File-level breakdown (as of the vendored commit)

**BSD 3-Clause** (Copyright (c) 2012–2014 Grzegorz Kostka, Martin Sucha,
Frantisek Princ):

- `src/ext4.c`
- `src/ext4_balloc.c`
- `src/ext4_bcache.c`
- `src/ext4_bitmap.c`
- `src/ext4_block_group.c`
- `src/ext4_blockdev.c`
- `src/ext4_crc32.c`
- `src/ext4_debug.c`
- `src/ext4_dir.c`
- `src/ext4_dir_idx.c`
- `src/ext4_fs.c`
- `src/ext4_hash.c`
- `src/ext4_ialloc.c`
- `src/ext4_inode.c`
- `src/ext4_journal.c`
- `src/ext4_mbr.c`
- `src/ext4_mkfs.c`
- `src/ext4_super.c`
- `src/ext4_trans.c`
- All files under `include/` and `include/misc/`

The 3-clause BSD text (consistent across files) is:

```
Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

- Redistributions of source code must retain the above copyright notice,
  this list of conditions and the following disclaimer.
- Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.
- The name of the author may not be used to endorse or promote products
  derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR "AS IS" AND ANY EXPRESS OR IMPLIED
WARRANTIES [...] ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR BE LIABLE [...]
```

**GPL-2.0-or-later** (Copyright (c) 2017 Grzegorz Kostka and Kaho Ng):

- `src/ext4_extent.c`
- `src/ext4_xattr.c`

These files carry the header:

```
This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.
```

The full GPL-2 text is available at `Vendor/lwext4/LICENSE`.

## Practical effect for binaries

Because `ext4_extent.c` is compiled into `Ext4KitExtension.appex` and
implements critical ext4 functionality (the extent tree used by ext4 to
store file block pointers), the **compiled extension binary is a combined
work that includes GPL-2-licensed code**. Under GPL-2's terms this means:

1. Ext4Kit's *source code* remains available under the MIT License, and
   reusing Ext4Kit's original files in another project under the MIT terms
   is permitted.
2. If you distribute a **built** copy of `Ext4KitExtension.appex`, you must
   comply with GPL-2.0's obligations for the combined work: provide, or
   offer to provide, the complete corresponding source code of the combined
   work to recipients. In practice this means either shipping the
   Ext4KitExtension.appex alongside a link to the public Ext4Kit source
   repository (which itself links the lwext4 submodule) or bundling the
   source directly.
3. `ext4_xattr.c` is also GPL-2-or-later, though Ext4Kit does not currently
   exercise any xattr functionality. It is compiled into the binary today
   and contributes to the same constraint; a future revision may exclude it
   from the build to reduce GPL-2 exposure if write-side xattr support is
   not needed.

Ext4Kit's MIT license for its own original code (`Ext4Kit/`,
`Ext4KitExtension/*.swift`, `Ext4KitExtension/Ext4KitBlockDev.{c,h}`,
`Ext4KitExtension/Ext4KitBridge.h`) is unaffected. You can lift those files
into a differently-licensed project without inheriting lwext4's terms,
provided you don't also lift the lwext4 sources.
