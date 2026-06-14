import FSKit
import os

final class Ext4FileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations,
    FSManageableResourceMaintenanceOperations
{
    private let log = Logger(subsystem: "dev.ext4kit.fs", category: "fs")

    /// Held alive between `loadResource` and `unloadResource` so the extension
    /// process can service block I/O for the returned `FSVolume`.
    private var activeBlockDevice: Ext4BlockDevice?

    /// Most recent block resource seen by probe/load. The maintenance
    /// operations (check/format) receive no resource parameter — like Apple's
    /// msdos module, they operate on the one the system probed.
    private var lastResource: FSBlockDeviceResource?

    // MARK: FSUnaryFileSystemOperations

    func probeResource(
        resource: FSResource,
        replyHandler: @escaping (FSProbeResult?, Error?) -> Void
    ) {
        guard let block = resource as? FSBlockDeviceResource else {
            replyHandler(.notRecognized, nil)
            return
        }
        lastResource = block

        guard let sb = readSuperblock(from: block, replyOnError: { replyHandler(nil, $0) })
        else {
            replyHandler(.notRecognized, nil)
            return
        }

        if sb.unsupportedIncompatBits != 0 {
            log.warning(
                """
                ext4 has unsupported incompat features: \
                0x\(String(sb.unsupportedIncompatBits, radix: 16), privacy: .public)
                """)
        }

        let containerID = FSContainerIdentifier(uuid: sb.uuid)
        log.info(
            """
            probe: label='\(sb.volumeName, privacy: .public)' \
            uuid=\(sb.uuid.uuidString, privacy: .public)
            """)
        replyHandler(.usable(name: sb.volumeName, containerID: containerID), nil)
    }

    func loadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler: @escaping (FSVolume?, Error?) -> Void
    ) {
        guard let block = resource as? FSBlockDeviceResource else {
            replyHandler(nil, fs_errorForPOSIXError(Int32(EINVAL)))
            return
        }
        lastResource = block

        // Re-read the superblock so the returned volume can be tagged with
        // the correct UUID and label. Probe already ran but we can't carry
        // state across the two calls.
        var loadError: Error?
        guard let sb = readSuperblock(from: block, replyOnError: { loadError = $0 }) else {
            replyHandler(nil, loadError ?? fs_errorForPOSIXError(Int32(EIO)))
            return
        }

        // Read-only when any of these hold:
        // - the resource was opened non-writable (`mount -o ro|rdonly`,
        //   `mount -r`, or write-protected media — mount(8) opens the device
        //   read-only for all of them);
        // - fskitd's load task carries the documented `--rdonly` option;
        // - the volume stores a custom metadata-checksum seed lwext4 would
        //   ignore, so writes would produce wrongly-seeded checksums.
        var readOnly = false
        if !block.isWritable {
            log.info("loadResource: resource is non-writable; mounting read-only")
            readOnly = true
        }
        if options.taskOptions.contains(where: { $0.contains("rdonly") }) {
            log.info("loadResource: rdonly task option; mounting read-only")
            readOnly = true
        }
        if sb.hasMismatchedChecksumSeed {
            log.warning(
                """
                loadResource: s_checksum_seed doesn't match crc32c(uuid) \
                (UUID changed after format?); degrading to read-only so \
                lwext4's UUID-seeded checksums can't corrupt metadata
                """)
            readOnly = true
        }

        let device = Ext4BlockDevice(resource: block, readOnly: readOnly)
        do {
            try device.register()
        } catch {
            log.error("ext4_device_register failed: \(error.localizedDescription, privacy: .public)")
            replyHandler(nil, fs_errorForPOSIXError(Int32(EIO)))
            return
        }
        self.activeBlockDevice = device

        let volume = Ext4Volume(
            blockDevice: device,
            volumeID: FSVolume.Identifier(uuid: sb.uuid),
            volumeName: FSFileName(string: sb.volumeName.isEmpty ? "ext4" : sb.volumeName),
            isReadOnly: readOnly
        )

        // Must transition out of `.notReady` before replying, or FSKit's
        // `FSModuleConnector` rejects the volume with "unexpected container
        // state" (EAGAIN).
        self.containerStatus = .ready

        log.info(
            """
            loadResource: label='\(sb.volumeName, privacy: .public)' \
            readOnly=\(readOnly, privacy: .public)
            """)
        replyHandler(volume, nil)
    }

    func unloadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler: @escaping (Error?) -> Void
    ) {
        if let device = activeBlockDevice {
            device.unregister()
            self.activeBlockDevice = nil
        }
        self.containerStatus = .notReady(status: fs_errorForPOSIXError(Int32(ENODEV)))
        replyHandler(nil)
    }

    // MARK: FSManageableResourceMaintenanceOperations

    /// `fsck_fskit -t ext4 <device>` and diskarbitrationd's pre-mount check.
    ///
    /// lwext4 has no repair engine, so this is a read-only structural check:
    /// superblock validity, feature support, and a trial read-only mount
    /// (which walks the group descriptors and journal superblock). A pending
    /// journal replay is reported but not a failure — activate replays it.
    /// Options ("nypfv") are accepted and ignored: nothing here ever writes.
    func startCheck(task: FSTask, options: FSTaskOptions) throws -> Progress {
        guard let block = lastResource else {
            throw fs_errorForPOSIXError(Int32(ENODEV))
        }
        let progress = Progress(totalUnitCount: 100)

        DispatchQueue.global(qos: .userInitiated).async { [log] in
            func finish(_ error: Error?) {
                progress.completedUnitCount = 100
                task.didComplete(error: error)
            }

            var sbError: Error?
            guard let sb = self.readSuperblock(from: block, replyOnError: { sbError = $0 })
            else {
                task.logMessage("not an ext4 filesystem (bad magic)")
                finish(sbError ?? fs_errorForPOSIXError(Int32(EINVAL)))
                return
            }
            progress.completedUnitCount = 25

            if sb.unsupportedIncompatBits != 0 {
                task.logMessage(
                    "unsupported incompat features: 0x\(String(sb.unsupportedIncompatBits, radix: 16))")
                finish(fs_errorForPOSIXError(Int32(ENOTSUP)))
                return
            }
            if sb.hasMismatchedChecksumSeed {
                task.logMessage("checksum seed mismatch: volume is mountable read-only only")
            }
            if sb.state & 0x1 == 0 {
                task.logMessage("filesystem was not cleanly unmounted; journal replay pending")
            }
            progress.completedUnitCount = 50

            // Trial read-only mount through a throwaway device registration.
            // lwext4's device/mount tables are process globals — serialize
            // against any active volume.
            let device = Ext4BlockDevice(resource: block, readOnly: true)
            let rc: Int32
            Ext4Volume.lwext4Lock.lock()
            do {
                try device.register(as: "ext4kit-check")
                rc = "ext4kit-check".withCString { dev in
                    "/ext4kit-check/".withCString { mp in
                        let mountRC = ext4_mount(dev, mp, true)
                        if mountRC == EOK {
                            _ = ext4_umount(mp)
                        }
                        return mountRC
                    }
                }
                device.unregister()
                Ext4Volume.lwext4Lock.unlock()
            } catch {
                Ext4Volume.lwext4Lock.unlock()
                finish(fs_errorForPOSIXError(Int32(EIO)))
                return
            }

            if rc != EOK {
                task.logMessage("read-only trial mount failed: rc=\(rc)")
                log.error("startCheck: trial mount rc=\(rc, privacy: .public)")
                finish(fs_errorForPOSIXError(rc))
                return
            }

            task.logMessage("ext4 structures parse cleanly")
            finish(nil)
        }
        return progress
    }

    /// `newfs_fskit -t ext4 [-L label] [-b blocksize] <device>`.
    func startFormat(task: FSTask, options: FSTaskOptions) throws -> Progress {
        guard let block = lastResource else {
            throw fs_errorForPOSIXError(Int32(ENODEV))
        }
        guard block.isWritable else {
            throw fs_errorForPOSIXError(Int32(EROFS))
        }

        // FSFormatOptionSyntax "L:b:" delivers argv-style pairs.
        var label = "ext4"
        var blockSize: UInt32 = 4096
        let opts = options.taskOptions
        var i = 0
        while i < opts.count {
            switch opts[i] {
            case "-L" where i + 1 < opts.count:
                label = opts[i + 1]
                i += 2
            case "-b" where i + 1 < opts.count:
                blockSize = UInt32(opts[i + 1]) ?? 4096
                i += 2
            default:
                i += 1
            }
        }
        guard blockSize == 1024 || blockSize == 2048 || blockSize == 4096 else {
            task.logMessage("unsupported block size \(blockSize) (use 1024/2048/4096)")
            throw fs_errorForPOSIXError(Int32(EINVAL))
        }

        let progress = Progress(totalUnitCount: 100)
        DispatchQueue.global(qos: .userInitiated).async { [log] in
            // ext4_mkfs takes the bdev directly (no lookup by name), but
            // register() is still required: it plants the Unmanaged self
            // pointer the C bread/bwrite trampolines dereference. The
            // device table is a process global — serialize against any
            // active volume.
            Ext4Volume.lwext4Lock.lock()
            defer { Ext4Volume.lwext4Lock.unlock() }

            let device = Ext4BlockDevice(resource: block, readOnly: false)
            do {
                try device.register(as: "ext4kit-mkfs")
            } catch {
                progress.completedUnitCount = 100
                task.didComplete(error: fs_errorForPOSIXError(Int32(EIO)))
                return
            }
            defer { device.unregister() }
            progress.completedUnitCount = 10

            var info = ext4_mkfs_info()
            info.block_size = blockSize
            info.journal = true
            let uuid = UUID().uuid
            withUnsafeMutableBytes(of: &info.uuid) { dst in
                withUnsafeBytes(of: uuid) { src in
                    dst.copyBytes(from: src)
                }
            }

            var fs = ext4_fs()
            let rc = label.withCString { labelC -> Int32 in
                info.label = labelC
                return ext4_mkfs(&fs, device.bdev, &info, Int32(F_SET_EXT4))
            }
            progress.completedUnitCount = 95

            if rc != EOK {
                log.error("ext4_mkfs failed rc=\(rc, privacy: .public)")
                task.logMessage("mkfs failed: rc=\(rc)")
                progress.completedUnitCount = 100
                task.didComplete(error: fs_errorForPOSIXError(rc > 0 ? rc : Int32(EIO)))
                return
            }

            log.info("startFormat: formatted label='\(label, privacy: .public)'")
            task.logMessage("created ext4 filesystem '\(label)' (\(blockSize)-byte blocks, journaled)")
            progress.completedUnitCount = 100
            task.didComplete(error: nil)
        }
        return progress
    }

    // MARK: helpers

    /// Reads and parses the on-disk superblock; calls `replyOnError` for I/O
    /// failures (parse failures just return nil).
    private func readSuperblock(
        from block: FSBlockDeviceResource,
        replyOnError: (Error) -> Void
    ) -> Ext4Superblock? {
        let buf = UnsafeMutableRawBufferPointer.allocate(
            byteCount: Ext4Superblock.size,
            alignment: 8
        )
        defer { buf.deallocate() }

        do {
            _ = try block.read(
                into: buf,
                startingAt: Ext4Superblock.onDiskOffset,
                length: Ext4Superblock.size
            )
        } catch {
            log.error("superblock read failed: \(error.localizedDescription, privacy: .public)")
            replyOnError(error)
            return nil
        }

        guard let base = buf.baseAddress else { return nil }
        return Ext4Superblock(UnsafeRawPointer(base))
    }
}
