#ifndef EXT4KIT_BRIDGE_H
#define EXT4KIT_BRIDGE_H

// lwext4 public API surface that Swift code in the extension may call.
// The order matters: ext4_config.h must be seen with the preprocessor
// macros set in GCC_PREPROCESSOR_DEFINITIONS (CONFIG_USE_DEFAULT_CFG=1,
// CONFIG_DEBUG_PRINTF=0, CONFIG_HAVE_OWN_ERRNO=0).
#include <ext4_config.h>
#include <ext4_types.h>
#include <ext4_errno.h>
#include <ext4_oflags.h>
#include <ext4_blockdev.h>
#include <ext4_inode.h>
#include <ext4_super.h>
#include <ext4.h>

#include "Ext4KitBlockDev.h"

#endif /* EXT4KIT_BRIDGE_H */
