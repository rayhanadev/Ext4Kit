#include "Ext4KitBlockDev.h"

// lwext4 invokes open/close around each (de)registration and mount cycle.
// Our underlying FSBlockDeviceResource is already "open" from the moment
// FSKit hands it to us, so these are no-ops.
int ext4kit_bdev_open(struct ext4_blockdev *bdev) {
    (void)bdev;
    return 0; // EOK
}

int ext4kit_bdev_close(struct ext4_blockdev *bdev) {
    (void)bdev;
    return 0;
}

int ext4kit_bdev_bread(struct ext4_blockdev *bdev, void *buf, uint64_t blk_id, uint32_t blk_cnt) {
    return ext4kit_swift_bread(bdev->bdif->p_user, buf, blk_id, blk_cnt);
}

int ext4kit_bdev_bwrite(struct ext4_blockdev *bdev, const void *buf, uint64_t blk_id, uint32_t blk_cnt) {
    return ext4kit_swift_bwrite(bdev->bdif->p_user, buf, blk_id, blk_cnt);
}
