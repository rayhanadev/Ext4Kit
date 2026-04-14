import FSKit
import os

final class Ext4FileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {
    private let log = Logger(subsystem: "dev.ext4kit.fs", category: "fs")

    /// Held alive between `loadResource` and `unloadResource` so the extension
    /// process can service block I/O for the returned `FSVolume`.
    private var activeBlockDevice: Ext4BlockDevice?

    // MARK: FSUnaryFileSystemOperations

    func probeResource(
        resource: FSResource,
        replyHandler: @escaping (FSProbeResult?, Error?) -> Void
    ) {
        guard let block = resource as? FSBlockDeviceResource else {
            replyHandler(.notRecognized, nil)
            return
        }

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
            log.error("probe read failed: \(error.localizedDescription, privacy: .public)")
            replyHandler(nil, error)
            return
        }

        guard let base = buf.baseAddress,
            let sb = Ext4Superblock(UnsafeRawPointer(base))
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

        // Re-read the superblock so the returned volume can be tagged with
        // the correct UUID and label. Probe already ran but we can't carry
        // state across the two calls.
        let buf = UnsafeMutableRawBufferPointer.allocate(
            byteCount: Ext4Superblock.size,
            alignment: 8
        )
        defer { buf.deallocate() }

        let sb: Ext4Superblock
        do {
            _ = try block.read(
                into: buf,
                startingAt: Ext4Superblock.onDiskOffset,
                length: Ext4Superblock.size
            )
            guard let base = buf.baseAddress,
                let parsed = Ext4Superblock(UnsafeRawPointer(base))
            else {
                replyHandler(nil, fs_errorForPOSIXError(Int32(EIO)))
                return
            }
            sb = parsed
        } catch {
            log.error("loadResource read failed: \(error.localizedDescription, privacy: .public)")
            replyHandler(nil, error)
            return
        }

        let device = Ext4BlockDevice(resource: block, readOnly: true)
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
            volumeName: FSFileName(string: sb.volumeName.isEmpty ? "ext4" : sb.volumeName)
        )

        // Must transition out of `.notReady` before replying, or FSKit's
        // `FSModuleConnector` rejects the volume with "unexpected container
        // state" (EAGAIN).
        self.containerStatus = .ready

        log.info("loadResource: label='\(sb.volumeName, privacy: .public)'")
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
}
