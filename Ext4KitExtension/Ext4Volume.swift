import FSKit
import Foundation
import os

/// Read-only ext4 volume backed by lwext4.
///
/// Lifecycle on a block-backed `FSUnaryFileSystem`:
/// 1. `Ext4FileSystem.loadResource` creates an `Ext4BlockDevice`, registers it
///    with lwext4, constructs this volume, and returns it to FSKit.
/// 2. FSKit calls `activate` — we run `ext4_mount`, cache the superblock
///    pointer, and hand back the root `Ext4Item`.
/// 3. VFS operations flow through `getAttributes`, `lookupItem`, and
///    `enumerateDirectory`. Mutating ops all return `EROFS`.
/// 4. On unmount, FSKit calls `deactivate` — we run `ext4_umount`.
/// 5. `Ext4FileSystem.unloadResource` tears down the block device.
///
/// FSKit's `mount(options:)` / `unmount()` protocol methods are never invoked
/// on this topology — FSKit collapses them into `activate`/`deactivate`. The
/// implementations below exist only for protocol conformance.
final class Ext4Volume: FSVolume, FSVolume.Operations {

    private let log = Logger(subsystem: "dev.ext4kit.fs", category: "volume")

    /// Registered with lwext4 before `init`, unregistered in
    /// `Ext4FileSystem.unloadResource`.
    let blockDevice: Ext4BlockDevice

    /// lwext4 uses this string as an internal mount-table key; it is not a
    /// real filesystem path.
    static let mountPointPath = "/ext4kit/"

    /// Stable non-initial verifier. FSKit treats `FSDirectoryVerifier.initial`
    /// as "enumeration never ran" and restarts the call (discarding the
    /// listing), so every successful `enumerateDirectory` must reply with a
    /// non-zero value. A constant is fine while the volume is read-only.
    private static let directoryVerifier = FSDirectoryVerifier(rawValue: 1)

    private var isMountedInLwext4 = false
    private var cachedStats: FSStatFSResult
    private var cachedCapabilities: FSVolume.SupportedCapabilities
    /// Cached after `ext4_mount` so `ext4_inode_get_mode` / `_size` can use it.
    private var sblockPtr: UnsafeMutablePointer<ext4_sblock>?

    init(
        blockDevice: Ext4BlockDevice,
        volumeID: FSVolume.Identifier,
        volumeName: FSFileName
    ) {
        self.blockDevice = blockDevice
        self.cachedStats = FSStatFSResult(fileSystemTypeName: "ext4")
        self.cachedCapabilities = FSVolume.SupportedCapabilities()
        super.init(volumeID: volumeID, volumeName: volumeName)
        cachedCapabilities.supportsSymbolicLinks = true
        cachedCapabilities.supportsHardLinks = true
        cachedCapabilities.supportsJournal = true
        cachedCapabilities.supportsPersistentObjectIDs = true
        cachedCapabilities.supports64BitObjectIDs = true
        cachedCapabilities.caseFormat = .sensitive
    }

    // MARK: FSVolumePathConfOperations

    var maximumLinkCount: Int { 65_000 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }

    // MARK: FSVolumeOperations properties

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities { cachedCapabilities }
    var volumeStatistics: FSStatFSResult { cachedStats }

    // MARK: activate / deactivate

    func activate(
        options: FSTaskOptions,
        replyHandler: @escaping (FSItem?, Error?) -> Void
    ) {
        let mountRC = Ext4BlockDevice.deviceName.withCString { dev in
            Self.mountPointPath.withCString { mp in
                ext4_mount(dev, mp, /* read_only: */ true)
            }
        }
        guard mountRC == EOK else {
            log.error("ext4_mount failed: rc=\(mountRC, privacy: .public)")
            replyHandler(nil, fs_errorForPOSIXError(Int32(EIO)))
            return
        }
        isMountedInLwext4 = true

        var sbp: UnsafeMutablePointer<ext4_sblock>?
        let sbRC = Self.mountPointPath.withCString { ext4_get_sblock($0, &sbp) }
        if sbRC == EOK, sbp != nil {
            self.sblockPtr = sbp
        } else {
            log.warning("ext4_get_sblock failed: rc=\(sbRC, privacy: .public)")
        }

        var stats = ext4_mount_stats()
        let statsRC = Self.mountPointPath.withCString { ext4_mount_point_stats($0, &stats) }
        if statsRC == EOK {
            updateCachedStats(from: stats)
            log.info(
                """
                activate: blocks_total=\(stats.blocks_count, privacy: .public) \
                blocks_free=\(stats.free_blocks_count, privacy: .public) \
                inodes_total=\(stats.inodes_count, privacy: .public)
                """)
        } else {
            log.warning("ext4_mount_point_stats failed: rc=\(statsRC, privacy: .public)")
        }

        replyHandler(Ext4Item.makeRoot(mountPath: Self.mountPointPath), nil)
    }

    func deactivate(
        options: FSDeactivateOptions,
        replyHandler: @escaping (Error?) -> Void
    ) {
        if isMountedInLwext4 {
            let rc = Self.mountPointPath.withCString { ext4_umount($0) }
            if rc != EOK {
                log.warning("ext4_umount failed: rc=\(rc, privacy: .public)")
            }
            isMountedInLwext4 = false
        }
        sblockPtr = nil
        replyHandler(nil)
    }

    // MARK: mount / unmount / synchronize

    func mount(
        options: FSTaskOptions,
        replyHandler: @escaping (Error?) -> Void
    ) {
        replyHandler(nil)
    }

    func unmount(replyHandler: @escaping () -> Void) {
        replyHandler()
    }

    func synchronize(
        flags: FSSyncFlags,
        replyHandler: @escaping (Error?) -> Void
    ) {
        if isMountedInLwext4 {
            _ = Self.mountPointPath.withCString { ext4_cache_flush($0) }
        }
        replyHandler(nil)
    }

    // MARK: attribute get/set

    func getAttributes(
        _ request: FSItem.GetAttributesRequest,
        of item: FSItem,
        replyHandler: @escaping (FSItem.Attributes?, Error?) -> Void
    ) {
        guard let ext4Item = item as? Ext4Item else {
            replyHandler(nil, fs_errorForPOSIXError(Int32(EINVAL)))
            return
        }

        var inode = ext4_inode()
        var ino: UInt32 = 0
        let rc = ext4Item.absolutePath.withCString { path in
            ext4_raw_inode_fill(path, &ino, &inode)
        }
        guard rc == EOK else {
            replyHandler(nil, fs_errorForPOSIXError(Int32(ENOENT)))
            return
        }

        let attrs = FSItem.Attributes()
        attrs.type = ext4Item.itemType
        attrs.fileID = ext4Item.fileID
        attrs.parentID = ext4Item.fileID == .rootDirectory ? .parentOfRoot : .rootDirectory

        let mode = inode.mode(with: sblockPtr)
        attrs.mode = UInt32(mode & 0x0FFF)
        attrs.linkCount = UInt32(ext4_inode_get_links_cnt(&inode))
        attrs.uid = ext4_inode_get_uid(&inode)
        attrs.gid = ext4_inode_get_gid(&inode)
        attrs.flags = 0

        let size = inode.size(with: sblockPtr)
        attrs.size = size
        attrs.allocSize = size

        let modTime = ext4_inode_get_modif_time(&inode)
        let accTime = ext4_inode_get_access_time(&inode)
        let chgTime = ext4_inode_get_change_inode_time(&inode)
        attrs.modifyTime = timespec(tv_sec: Int(modTime), tv_nsec: 0)
        attrs.accessTime = timespec(tv_sec: Int(accTime), tv_nsec: 0)
        attrs.changeTime = timespec(tv_sec: Int(chgTime), tv_nsec: 0)
        attrs.birthTime = timespec(tv_sec: Int(chgTime), tv_nsec: 0)

        replyHandler(attrs, nil)
    }

    func setAttributes(
        _ request: FSItem.SetAttributesRequest,
        on item: FSItem,
        replyHandler: @escaping (FSItem.Attributes?, Error?) -> Void
    ) {
        replyHandler(nil, fs_errorForPOSIXError(Int32(EROFS)))
    }

    // MARK: lookup / reclaim

    func lookupItem(
        named name: FSFileName,
        inDirectory directory: FSItem,
        replyHandler: @escaping (FSItem?, FSFileName?, Error?) -> Void
    ) {
        guard let parent = directory as? Ext4Item,
            let nameString = name.string
        else {
            replyHandler(nil, nil, fs_errorForPOSIXError(Int32(EINVAL)))
            return
        }

        let childPath = Ext4Item.joinPath(parent: parent.absolutePath, child: nameString)

        var inode = ext4_inode()
        var ino: UInt32 = 0
        let rc = childPath.withCString { ext4_raw_inode_fill($0, &ino, &inode) }
        guard rc == EOK else {
            replyHandler(nil, nil, fs_errorForPOSIXError(Int32(ENOENT)))
            return
        }

        let mode = inode.mode(with: sblockPtr)
        let child = Ext4Item(
            inodeNumber: ino,
            itemType: Self.itemType(fromMode: mode),
            fileID: FSItem.Identifier(rawValue: UInt64(ino)) ?? .invalid,
            absolutePath: childPath
        )
        replyHandler(child, name, nil)
    }

    func reclaimItem(
        _ item: FSItem,
        replyHandler: @escaping (Error?) -> Void
    ) {
        replyHandler(nil)
    }

    // MARK: symbolic links

    func readSymbolicLink(
        _ item: FSItem,
        replyHandler: @escaping (FSFileName?, Error?) -> Void
    ) {
        replyHandler(nil, fs_errorForPOSIXError(Int32(EINVAL)))
    }

    // MARK: mutating operations — all EROFS

    func createItem(
        named name: FSFileName,
        type: FSItem.ItemType,
        inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest,
        replyHandler: @escaping (FSItem?, FSFileName?, Error?) -> Void
    ) {
        replyHandler(nil, nil, fs_errorForPOSIXError(Int32(EROFS)))
    }

    func createSymbolicLink(
        named name: FSFileName,
        inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest,
        linkContents contents: FSFileName,
        replyHandler: @escaping (FSItem?, FSFileName?, Error?) -> Void
    ) {
        replyHandler(nil, nil, fs_errorForPOSIXError(Int32(EROFS)))
    }

    func createLink(
        to item: FSItem,
        named name: FSFileName,
        inDirectory directory: FSItem,
        replyHandler: @escaping (FSFileName?, Error?) -> Void
    ) {
        replyHandler(nil, fs_errorForPOSIXError(Int32(EROFS)))
    }

    func removeItem(
        _ item: FSItem,
        named name: FSFileName,
        fromDirectory directory: FSItem,
        replyHandler: @escaping (Error?) -> Void
    ) {
        replyHandler(fs_errorForPOSIXError(Int32(EROFS)))
    }

    func renameItem(
        _ item: FSItem,
        inDirectory sourceDirectory: FSItem,
        named sourceName: FSFileName,
        to destinationName: FSFileName,
        inDirectory destinationDirectory: FSItem,
        overItem: FSItem?,
        replyHandler: @escaping (FSFileName?, Error?) -> Void
    ) {
        replyHandler(nil, fs_errorForPOSIXError(Int32(EROFS)))
    }

    // MARK: enumerate

    func enumerateDirectory(
        _ directory: FSItem,
        startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier,
        attributes: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker,
        replyHandler: @escaping (FSDirectoryVerifier, Error?) -> Void
    ) {
        guard let dirItem = directory as? Ext4Item else {
            replyHandler(Self.directoryVerifier, fs_errorForPOSIXError(Int32(EINVAL)))
            return
        }

        var dir = ext4_dir()
        let openRC = dirItem.absolutePath.withCString { ext4_dir_open(&dir, $0) }
        guard openRC == EOK else {
            log.error(
                """
                ext4_dir_open failed path='\(dirItem.absolutePath, privacy: .public)' \
                rc=\(openRC, privacy: .public)
                """)
            replyHandler(Self.directoryVerifier, fs_errorForPOSIXError(Int32(EIO)))
            return
        }
        defer { _ = ext4_dir_close(&dir) }

        // Simple cookie semantics: `seen` is a 1-based count of entries the
        // directory walk has traversed so far. On a resume call, re-open and
        // skip `cookie.rawValue` entries before packing anything new. This is
        // O(n) in the skip count but lwext4 offers no seekdir primitive.
        let skipCount = cookie.rawValue
        var seen: UInt64 = 0

        while let entryPtr = ext4_dir_entry_next(&dir) {
            seen += 1
            if seen <= skipCount { continue }

            let entry = entryPtr.pointee
            let nameLen = Int(entry.name_length)
            guard nameLen > 0 else { continue }

            let nameBytes = withUnsafePointer(to: entry.name) {
                $0.withMemoryRebound(to: UInt8.self, capacity: nameLen) { base in
                    Array(UnsafeBufferPointer(start: base, count: nameLen))
                }
            }
            guard let nameString = String(bytes: nameBytes, encoding: .utf8) else {
                log.warning(
                    """
                    enumerate: non-utf8 name at \(dirItem.absolutePath, privacy: .public)
                    """)
                continue
            }

            // FSKit contract: pack "." and ".." only when the caller did NOT
            // request attributes. When it did, the VFS synthesizes them and
            // duplicates appear if we pack them too.
            let isDotOrDotDot = (nameString == "." || nameString == "..")
            if attributes != nil && isDotOrDotDot { continue }

            let itemType = Self.itemType(fromDirentryType: entry.inode_type)
            let childID: FSItem.Identifier
            switch nameString {
            case ".":
                childID = dirItem.fileID
            case "..":
                childID = dirItem.fileID == .rootDirectory ? .parentOfRoot : .rootDirectory
            default:
                childID = FSItem.Identifier(rawValue: UInt64(entry.inode)) ?? .invalid
            }

            // `packEntry` silently drops entries whose attribute blob is nil
            // when the caller requested non-nil attributes (the common `ls`
            // path). Hand over a minimal blob regardless; real inode data
            // comes from `getAttributes` on demand.
            let attrBlob = FSItem.Attributes()
            attrBlob.type = itemType
            attrBlob.fileID = childID
            attrBlob.parentID = dirItem.fileID
            attrBlob.linkCount = (itemType == .directory) ? 2 : 1
            attrBlob.mode = (itemType == .directory) ? 0o755 : 0o644
            attrBlob.uid = 0
            attrBlob.gid = 0
            attrBlob.flags = 0
            attrBlob.size = 0
            attrBlob.allocSize = 0

            let packed = packer.packEntry(
                name: FSFileName(string: nameString),
                itemType: itemType,
                itemID: childID,
                nextCookie: FSDirectoryCookie(rawValue: seen),
                attributes: attrBlob
            )
            if !packed { break }
        }

        replyHandler(Self.directoryVerifier, nil)
    }

    // MARK: private helpers

    private func updateCachedStats(from stats: ext4_mount_stats) {
        let result = FSStatFSResult(fileSystemTypeName: "ext4")
        let bsize = UInt64(stats.block_size)
        result.blockSize = Int(stats.block_size)
        result.ioSize = Int(stats.block_size)
        result.totalBlocks = stats.blocks_count
        result.freeBlocks = stats.free_blocks_count
        result.availableBlocks = stats.free_blocks_count
        result.usedBlocks = stats.blocks_count - stats.free_blocks_count
        result.totalBytes = stats.blocks_count * bsize
        result.freeBytes = stats.free_blocks_count * bsize
        result.availableBytes = stats.free_blocks_count * bsize
        result.usedBytes = (stats.blocks_count - stats.free_blocks_count) * bsize
        result.totalFiles = UInt64(stats.inodes_count)
        result.freeFiles = UInt64(stats.free_inodes_count)
        self.cachedStats = result
    }

    /// Map an ext4 inode mode (Linux `S_IFMT` encoding in the high nibble) to
    /// an `FSItem.ItemType`.
    private static func itemType(fromMode mode: UInt32) -> FSItem.ItemType {
        switch mode & 0xF000 {
        case 0x8000: return .file
        case 0x4000: return .directory
        case 0xA000: return .symlink
        case 0x1000: return .fifo
        case 0x2000: return .charDevice
        case 0x6000: return .blockDevice
        case 0xC000: return .socket
        default: return .unknown
        }
    }

    /// Map an `ext4_direntry.inode_type` byte (`EXT4_DE_*`) to an
    /// `FSItem.ItemType`. Directory entries carry the type inline so we avoid
    /// a second inode read during enumeration.
    private static func itemType(fromDirentryType direntType: UInt8) -> FSItem.ItemType {
        switch Int(direntType) {
        case Int(EXT4_DE_REG_FILE): return .file
        case Int(EXT4_DE_DIR): return .directory
        case Int(EXT4_DE_SYMLINK): return .symlink
        case Int(EXT4_DE_FIFO): return .fifo
        case Int(EXT4_DE_CHRDEV): return .charDevice
        case Int(EXT4_DE_BLKDEV): return .blockDevice
        case Int(EXT4_DE_SOCK): return .socket
        default: return .unknown
        }
    }
}

// MARK: - ext4_inode convenience accessors

/// `ext4_inode_get_mode` and `ext4_inode_get_size` take `struct ext4_sblock *`
/// because large-file (>4 GiB) sizes require superblock features to interpret
/// correctly. These wrappers keep call sites free of `withUnsafePointer(to:)`
/// plumbing and provide a raw-field fallback when the pointer isn't available.
extension ext4_inode {
    mutating func mode(with sblockPtr: UnsafeMutablePointer<ext4_sblock>?) -> UInt32 {
        guard let sblockPtr else { return UInt32(self.mode) }
        return ext4_inode_get_mode(sblockPtr, &self)
    }

    mutating func size(with sblockPtr: UnsafeMutablePointer<ext4_sblock>?) -> UInt64 {
        guard let sblockPtr else { return UInt64(self.size_lo) }
        return ext4_inode_get_size(sblockPtr, &self)
    }
}
