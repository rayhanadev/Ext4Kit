#ifndef EXT4KIT_BLOCKDEV_H
#define EXT4KIT_BLOCKDEV_H

#include <ext4_blockdev.h>
#include <stdint.h>

// C callbacks that lwext4 invokes. They forward to the Swift-implemented
// ext4kit_swift_* functions via the bdev->bdif->p_user pointer, which the
// Swift side sets to an unmanaged retain of its Ext4BlockDevice instance.
int ext4kit_bdev_open(struct ext4_blockdev *bdev);
int ext4kit_bdev_close(struct ext4_blockdev *bdev);
int ext4kit_bdev_bread(struct ext4_blockdev *bdev, void *buf, uint64_t blk_id, uint32_t blk_cnt);
int ext4kit_bdev_bwrite(struct ext4_blockdev *bdev, const void *buf, uint64_t blk_id, uint32_t blk_cnt);

// Swift-side implementations, invoked by the C adapter above.
// Declared here so the C shim can link against them; defined in Swift with @_cdecl.
int ext4kit_swift_bread(void *p_user, void *buf, uint64_t blk_id, uint32_t blk_cnt);
int ext4kit_swift_bwrite(void *p_user, const void *buf, uint64_t blk_id, uint32_t blk_cnt);

#endif /* EXT4KIT_BLOCKDEV_H */
