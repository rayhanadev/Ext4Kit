import FSKit
import Foundation
import os

/// Bridges an `FSBlockDeviceResource` to lwext4's `ext4_blockdev` C interface.
///
/// The C shim (`Ext4KitBlockDev.c`) stores a retained `Unmanaged<Ext4BlockDevice>`
/// in `ext4_blockdev_iface.p_user` and calls back into the `@_cdecl` trampolines
/// at the bottom of this file for every block read/write lwext4 issues.
///
/// Lifecycle: create → `register()` → pass device name to `ext4_mount` → on
/// unmount, call `unregister()`. Deallocation of the pinned C structs happens
/// in `deinit`.
final class Ext4BlockDevice {
    static let deviceName = "ext4kit0"

    private let log = Logger(subsystem: "dev.ext4kit.fs", category: "bdev")
    let resource: FSBlockDeviceResource
    let blockSize: UInt32
    let blockCount: UInt64
    let readOnly: Bool

    // Pinned C structs. Lifetime tied to self.
    let bdev: UnsafeMutablePointer<ext4_blockdev>
    private let iface: UnsafeMutablePointer<ext4_blockdev_iface>
    private let phbuf: UnsafeMutablePointer<UInt8>
    private var registered = false

    init(resource: FSBlockDeviceResource, readOnly: Bool) {
        self.resource = resource
        self.readOnly = readOnly

        // FSBlockDeviceResource reports block geometry in uint64_t. lwext4's
        // ph_bsize is uint32_t — 4 GiB blocks aren't real, so truncation is safe.
        let bsize = UInt32(resource.blockSize)
        let bcount = UInt64(resource.blockCount)
        self.blockSize = bsize
        self.blockCount = bcount

        self.phbuf = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(bsize))
        self.phbuf.initialize(repeating: 0, count: Int(bsize))

        self.iface = UnsafeMutablePointer<ext4_blockdev_iface>.allocate(capacity: 1)
        self.iface.initialize(to: ext4_blockdev_iface())
        self.iface.pointee.open = ext4kit_bdev_open
        self.iface.pointee.close = ext4kit_bdev_close
        self.iface.pointee.bread = ext4kit_bdev_bread
        self.iface.pointee.bwrite = ext4kit_bdev_bwrite
        self.iface.pointee.ph_bsize = bsize
        self.iface.pointee.ph_bcnt = bcount
        self.iface.pointee.ph_bbuf = phbuf

        self.bdev = UnsafeMutablePointer<ext4_blockdev>.allocate(capacity: 1)
        self.bdev.initialize(to: ext4_blockdev())
        self.bdev.pointee.bdif = iface
        self.bdev.pointee.part_offset = 0
        self.bdev.pointee.part_size = bcount * UInt64(bsize)
    }

    deinit {
        if registered {
            _ = Self.deviceName.withCString { ext4_device_unregister($0) }
        }
        bdev.deinitialize(count: 1)
        bdev.deallocate()
        iface.deinitialize(count: 1)
        iface.deallocate()
        phbuf.deallocate()
    }

    /// Register this device with lwext4 under the global name "ext4kit0" and
    /// plant the unmanaged self-pointer that the C shim reads from p_user.
    func register() throws {
        // Retain self into p_user. Released on unregister().
        iface.pointee.p_user = UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque())
        let rc = Self.deviceName.withCString { ext4_device_register(bdev, $0) }
        if rc != EOK {
            // Balance the passRetained above.
            Unmanaged<Ext4BlockDevice>.fromOpaque(iface.pointee.p_user!).release()
            iface.pointee.p_user = nil
            log.error("ext4_device_register failed: rc=\(rc, privacy: .public)")
            throw POSIXError(.EIO)
        }
        registered = true
    }

    func unregister() {
        guard registered else { return }
        _ = Self.deviceName.withCString { ext4_device_unregister($0) }
        if let user = iface.pointee.p_user {
            Unmanaged<Ext4BlockDevice>.fromOpaque(user).release()
            iface.pointee.p_user = nil
        }
        registered = false
    }

    // MARK: IO

    fileprivate func blockRead(into buf: UnsafeMutableRawPointer, blockId: UInt64, blockCount: UInt32) -> Int32 {
        let byteOffset = off_t(blockId) * off_t(blockSize)
        let byteCount = Int(blockCount) * Int(blockSize)
        let bufferPtr = UnsafeMutableRawBufferPointer(start: buf, count: byteCount)
        do {
            let got = try resource.read(into: bufferPtr, startingAt: byteOffset, length: byteCount)
            if got != byteCount {
                log.error("short bdev read: wanted \(byteCount) got \(got) at \(byteOffset)")
                return Int32(EIO)
            }
            return Int32(EOK)
        } catch {
            log.error("bdev read failed at \(byteOffset): \(error.localizedDescription, privacy: .public)")
            return Int32(EIO)
        }
    }

    fileprivate func blockWrite(from buf: UnsafeRawPointer, blockId: UInt64, blockCount: UInt32) -> Int32 {
        if readOnly { return Int32(EROFS) }
        let byteOffset = off_t(blockId) * off_t(blockSize)
        let byteCount = Int(blockCount) * Int(blockSize)
        let bufferPtr = UnsafeRawBufferPointer(start: buf, count: byteCount)
        do {
            let put = try resource.write(from: bufferPtr, startingAt: byteOffset, length: byteCount)
            if put != byteCount {
                log.error("short bdev write: wanted \(byteCount) put \(put) at \(byteOffset)")
                return Int32(EIO)
            }
            return Int32(EOK)
        } catch {
            log.error("bdev write failed at \(byteOffset): \(error.localizedDescription, privacy: .public)")
            return Int32(EIO)
        }
    }
}

// MARK: - @_cdecl trampolines called by Ext4KitBlockDev.c
//
// The `@_cdecl` string is the exported symbol name that the C shim references
// via `extern int ext4kit_swift_bread(...)`. The Swift function names are
// camelCase because nothing in Swift calls them directly — only the C shim
// does, through the exported symbol.

@_cdecl("ext4kit_swift_bread")
func ext4kitSwiftBread(
    _ user: UnsafeMutableRawPointer?,
    _ buf: UnsafeMutableRawPointer?,
    _ blkId: UInt64,
    _ blkCnt: UInt32
) -> Int32 {
    guard let user, let buf else { return Int32(EINVAL) }
    let dev = Unmanaged<Ext4BlockDevice>.fromOpaque(user).takeUnretainedValue()
    return dev.blockRead(into: buf, blockId: blkId, blockCount: blkCnt)
}

@_cdecl("ext4kit_swift_bwrite")
func ext4kitSwiftBwrite(
    _ user: UnsafeMutableRawPointer?,
    _ buf: UnsafeRawPointer?,
    _ blkId: UInt64,
    _ blkCnt: UInt32
) -> Int32 {
    guard let user, let buf else { return Int32(EINVAL) }
    let dev = Unmanaged<Ext4BlockDevice>.fromOpaque(user).takeUnretainedValue()
    return dev.blockWrite(from: buf, blockId: blkId, blockCount: blkCnt)
}
