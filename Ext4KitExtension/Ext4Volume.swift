import FSKit
import Foundation
import os

/// Read/write ext4 volume backed by lwext4.
///
/// Lifecycle on a block-backed `FSUnaryFileSystem`:
/// 1. `Ext4FileSystem.loadResource` creates an `Ext4BlockDevice`, registers it
///    with lwext4, constructs this volume, and returns it to FSKit.
/// 2. FSKit calls `activate` — we run `ext4_mount`, replay/start the journal,
///    cache the superblock pointer, and hand back the root `Ext4Item`.
/// 3. VFS operations flow through the `FSVolume.Operations`,
///    `ReadWriteOperations`, `OpenCloseOperations`, `XattrOperations`, and
///    `RenameOperations` conformances below.
/// 4. On unmount, FSKit calls `deactivate` — we stop the journal and
///    `ext4_umount`.
/// 5. `Ext4FileSystem.unloadResource` tears down the block device.
///
/// Concurrency: lwext4 has **no internal locking** (its `EXT4_MP_LOCK` macros
/// are no-ops unless lock callbacks are registered, and several entry points
/// never lock at all), and its mount table lives in unsynchronized globals.
/// FSKit may invoke volume operations from arbitrary threads, so every
/// operation below — and every touch of the item/open-file bookkeeping —
/// runs under `opLock`. The lock is recursive because `setAttributes`
/// re-enters `getAttributes` to build its reply.
///
/// Timestamps: no lwext4 write API updates any timestamp, and freshly created
/// inodes get atime/mtime/ctime of 0 (the epoch). Every mutating operation
/// here explicitly stamps the affected inode and, for namespace operations,
/// the parent directory.
///
/// FSKit's `mount(options:)` / `unmount()` protocol methods are never invoked
/// on this topology — FSKit collapses them into `activate`/`deactivate`. The
/// implementations below exist only for protocol conformance.
final class Ext4Volume: FSVolume,
    FSVolume.Operations,
    FSVolume.ReadWriteOperations,
    FSVolume.OpenCloseOperations,
    FSVolume.XattrOperations,
    FSVolume.RenameOperations
{

    private let log = Logger(subsystem: "dev.ext4kit.fs", category: "volume")

    /// Registered with lwext4 before `init`, unregistered in
    /// `Ext4FileSystem.unloadResource`.
    let blockDevice: Ext4BlockDevice

    /// lwext4 uses this string as an internal mount-table key; it is not a
    /// real filesystem path.
    static let mountPointPath = "/ext4kit/"

    /// Serializes all lwext4 calls and all item/open-file bookkeeping.
    /// Process-global because lwext4's mount and device tables are
    /// unsynchronized globals shared with the maintenance operations
    /// (check/format) in `Ext4FileSystem`.
    static let lwext4Lock = NSRecursiveLock()
    private var opLock: NSRecursiveLock { Self.lwext4Lock }

    private var isMountedInLwext4 = false
    private var isJournalStarted = false
    private var cachedStats: FSStatFSResult
    private var cachedCapabilities: FSVolume.SupportedCapabilities
    /// Cached after `ext4_mount` so `ext4_inode_get_mode` / `_size` can use it.
    private var sblockPtr: UnsafeMutablePointer<ext4_sblock>?
    /// Filesystem block size, cached at activate for pathconf limits.
    private var fsBlockSize: UInt32 = 4096

    /// Root item handed to FSKit at activate; kept alive so child items'
    /// parent chains always terminate in a live object.
    private var rootItem: Ext4Item?

    /// Reserved name prefix for open-unlink orphans parked in the root
    /// directory. Hidden from enumeration/lookup and rejected as an entry
    /// name; stale orphans from a crash are swept at activate.
    private static let orphanPrefix = ".ext4kit-orphan-"

    /// The error FSKit special-cases on a stale enumeration cookie: the
    /// kernel ends/restarts the listing gracefully instead of surfacing an
    /// errno to readdir(2).
    private static let invalidCookieError = NSError(
        domain: FSError.errorDomain,
        code: FSError.Code.invalidDirectoryCookie.rawValue
    )

    /// lwext4's end-of-directory iterator offset
    /// (EXT4_DIR_ENTRY_OFFSET_TERM in src/ext4.c).
    private static let endOfDirectoryCookie = UInt64.max

    /// Persistent file handle opened via `FSVolume.OpenCloseOperations`,
    /// keyed by inode number (hard links share a handle, matching the
    /// kernel's one-vnode-per-inode model). lwext4 file handles track the
    /// inode, not the path, so they survive renames. Invariant: a map entry
    /// exists only while its inode is allocated (open-unlinked files are
    /// parked as orphans rather than freed), so an entry can never alias a
    /// reused inode number.
    private final class OpenFile {
        var file = ext4_file()
        var modes: FSVolume.OpenModes = []
        /// Item instances currently holding kernel opens on this handle —
        /// hard links can present one inode through several items, and each
        /// opener's lifecycle is independent. The handle closes only when
        /// the last opener leaves; an item that is not an opener may never
        /// tear the handle down (it might not even be the same file, if the
        /// inode number was freed and reused).
        var openers: Set<ObjectIdentifier> = []
        /// Open-unlink parking spot whose inode this handle pins; freed when
        /// the handle finally closes.
        var orphanPath: String?
    }
    private var openFiles: [UInt32: OpenFile] = [:]

    /// Set when the resource is non-writable, the mount asked for rdonly, or
    /// the checksum-seed safety check failed. While true: lwext4 mounts
    /// read-only, the journal isn't replayed or started, and every mutating
    /// operation replies EROFS. The kernel's MNT_RDONLY layer blocks user
    /// writes above us too; these gates make our own behavior clean instead
    /// of relying on device-level write failures.
    private(set) var isReadOnly: Bool

    init(
        blockDevice: Ext4BlockDevice,
        volumeID: FSVolume.Identifier,
        volumeName: FSFileName,
        isReadOnly: Bool = false
    ) {
        self.blockDevice = blockDevice
        self.isReadOnly = isReadOnly
        self.cachedStats = FSStatFSResult(fileSystemTypeName: "ext4")
        self.cachedCapabilities = FSVolume.SupportedCapabilities()
        super.init(volumeID: volumeID, volumeName: volumeName)
        cachedCapabilities.supportsSymbolicLinks = true
        cachedCapabilities.supportsHardLinks = true
        cachedCapabilities.supportsJournal = true
        cachedCapabilities.supportsPersistentObjectIDs = true
        cachedCapabilities.supports64BitObjectIDs = true
        cachedCapabilities.supports2TBFiles = true
        cachedCapabilities.supportsFastStatFS = true
        // BSD file flags (uchg/schg) have no lwext4 surface; `flags` is
        // reported as 0 and never consumed on set.
        cachedCapabilities.doesNotSupportImmutableFiles = true
        cachedCapabilities.caseFormat = .sensitive
    }

    // MARK: FSVolume.PathConfOperations

    var maximumLinkCount: Int { 65_000 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
    /// One in-inode/EA-block value is the practical ceiling lwext4 can store.
    var maximumXattrSize: Int { Int(fsBlockSize) }
    /// Extents address 2^32 logical blocks.
    var maximumFileSize: UInt64 { UInt64(fsBlockSize) << 32 }

    // MARK: FSVolumeOperations properties

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities { cachedCapabilities }

    var volumeStatistics: FSStatFSResult {
        withLock {
            if isMountedInLwext4 {
                var stats = ext4_mount_stats()
                let rc = Self.mountPointPath.withCString { ext4_mount_point_stats($0, &stats) }
                if rc == EOK {
                    updateCachedStats(from: stats)
                }
            }
            return cachedStats
        }
    }

    // MARK: activate / deactivate

    func activate(
        options: FSTaskOptions,
        replyHandler: @escaping (FSItem?, Error?) -> Void
    ) {
        withLock {
            // The user's mount options arrive here ("-o" + comma-joined
            // values, per FSActivateOptionSyntax "o:").
            if Self.optionsRequestReadOnly(options) {
                isReadOnly = true
            }
            let readOnly = isReadOnly

            let mountRC = Ext4BlockDevice.deviceName.withCString { dev in
                Self.mountPointPath.withCString { mp in
                    ext4_mount(dev, mp, readOnly)
                }
            }
            guard mountRC == EOK else {
                log.error("ext4_mount failed: rc=\(mountRC, privacy: .public)")
                replyHandler(nil, fs_errorForPOSIXError(Int32(EIO)))
                return
            }
            isMountedInLwext4 = true

            if readOnly {
                log.info("activate: read-only mount; journal left untouched")
            } else {
                // Replay any outstanding journal from a prior unclean shutdown
                // before we touch metadata (ENOTSUP = no journal feature, fine).
                // Mounting read/write on top of a journal that failed to replay
                // would compound pre-crash inconsistency into real corruption,
                // so refuse to activate instead.
                let recoverRC = Self.mountPointPath.withCString { ext4_recover($0) }
                if recoverRC != EOK && recoverRC != ENOTSUP {
                    log.error("ext4_recover failed: rc=\(recoverRC, privacy: .public)")
                    _ = Self.mountPointPath.withCString { ext4_umount($0) }
                    isMountedInLwext4 = false
                    replyHandler(nil, fs_errorForPOSIXError(Int32(EIO)))
                    return
                }

                let journalRC = Self.mountPointPath.withCString { ext4_journal_start($0) }
                if journalRC == EOK {
                    isJournalStarted = true
                } else {
                    log.warning("ext4_journal_start failed: rc=\(journalRC, privacy: .public)")
                }
            }

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
                fsBlockSize = stats.block_size
                log.info(
                    """
                    activate: blocks_total=\(stats.blocks_count, privacy: .public) \
                    blocks_free=\(stats.free_blocks_count, privacy: .public) \
                    inodes_total=\(stats.inodes_count, privacy: .public)
                    """)
            } else {
                log.warning("ext4_mount_point_stats failed: rc=\(statsRC, privacy: .public)")
            }

            if !readOnly {
                sweepStaleOrphans()
            }

            let root = Ext4Item.makeRoot(mountPath: Self.mountPointPath)
            self.rootItem = root
            replyHandler(root, nil)
        }
    }

    func deactivate(
        options: FSDeactivateOptions,
        replyHandler: @escaping (Error?) -> Void
    ) {
        withLock {
            for (ino, state) in openFiles {
                log.warning("deactivate: closing leaked open file inode=\(ino, privacy: .public)")
                _ = ext4_fclose(&state.file)
                if let orphan = state.orphanPath {
                    freeOrphan(orphan)
                    state.orphanPath = nil
                }
            }
            openFiles.removeAll()
            if isMountedInLwext4 && !isReadOnly {
                // Free any open-unlink orphans whose final close never came.
                sweepStaleOrphans()
            }

            if isJournalStarted {
                let rc = Self.mountPointPath.withCString { ext4_journal_stop($0) }
                if rc != EOK {
                    log.warning("ext4_journal_stop failed: rc=\(rc, privacy: .public)")
                }
                isJournalStarted = false
            }
            if isMountedInLwext4 {
                if !isReadOnly {
                    _ = Self.mountPointPath.withCString { ext4_cache_flush($0) }
                }
                let rc = Self.mountPointPath.withCString { ext4_umount($0) }
                if rc != EOK {
                    log.warning("ext4_umount failed: rc=\(rc, privacy: .public)")
                }
                isMountedInLwext4 = false
            }
            sblockPtr = nil
            rootItem = nil
            replyHandler(nil)
        }
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
        withLock {
            if isMountedInLwext4 && !isReadOnly {
                _ = Self.mountPointPath.withCString { ext4_cache_flush($0) }
            }
            replyHandler(nil)
        }
    }

    // MARK: attribute get/set

    func getAttributes(
        _ request: FSItem.GetAttributesRequest,
        of item: FSItem,
        replyHandler: @escaping (FSItem.Attributes?, Error?) -> Void
    ) {
        withLock {
            guard let ext4Item = item as? Ext4Item else {
                replyHandler(nil, fs_errorForPOSIXError(Int32(EINVAL)))
                return
            }

            // The on-disk object may already be unlinked while FSKit still
            // holds the item (it reclaims later). Open-unlinked files stay
            // live under an orphan path; otherwise serve the snapshot taken
            // at removal time.
            guard let path = effectivePath(of: ext4Item),
                var filled = fillInode(at: path)
            else {
                if ext4Item.isRemoved, let attrs = ext4Item.removedAttributes {
                    replyHandler(attrs, nil)
                } else {
                    replyHandler(nil, fs_errorForPOSIXError(Int32(ENOENT)))
                }
                return
            }

            let attrs = FSItem.Attributes()
            packAttributes(
                attrs,
                inode: &filled.inode,
                itemType: ext4Item.itemType,
                fileID: ext4Item.fileID,
                parentID: parentID(of: ext4Item)
            )
            // An open-unlinked file (live only via its orphan parking spot)
            // reports nlink 0, matching fstat(2) after unlink(2).
            if ext4Item.isRemoved {
                attrs.linkCount = 0
            }
            replyHandler(attrs, nil)
        }
    }

    func setAttributes(
        _ request: FSItem.SetAttributesRequest,
        on item: FSItem,
        replyHandler: @escaping (FSItem.Attributes?, Error?) -> Void
    ) {
        withLock {
            guard !isReadOnly else {
                replyHandler(nil, readOnlyError)
                return
            }
            guard let ext4Item = item as? Ext4Item else {
                replyHandler(nil, fs_errorForPOSIXError(Int32(EINVAL)))
                return
            }
            // Open-unlinked files (orphanPath set) still accept setattr —
            // ftruncate on an unlinked-but-open descriptor is legal POSIX.
            guard let path = effectivePath(of: ext4Item) else {
                replyHandler(nil, fs_errorForPOSIXError(Int32(ENOENT)))
                return
            }
            var consumed: FSItem.Attribute = []
            // chmod/chown/truncate update ctime (and truncate mtime) as a
            // side effect unless the request sets those times explicitly.
            var wantsImplicitCtime = false
            var wantsImplicitMtime = false

            if request.isValid(.mode) {
                let rc = path.withCString { ext4_mode_set($0, request.mode & 0x0FFF) }
                if rc != EOK {
                    log.error("ext4_mode_set failed rc=\(rc, privacy: .public)")
                    replyHandler(nil, posixError(rc))
                    return
                }
                consumed.insert(.mode)
                wantsImplicitCtime = true
            }

            if request.isValid(.uid) || request.isValid(.gid) {
                // ext4_owner_set writes both fields in one call; read the
                // current inode to preserve whichever side wasn't requested.
                var currentUID: UInt32 = request.uid
                var currentGID: UInt32 = request.gid
                if !request.isValid(.uid) || !request.isValid(.gid) {
                    if var filled = fillInode(at: path) {
                        if !request.isValid(.uid) { currentUID = ext4_inode_get_uid(&filled.inode) }
                        if !request.isValid(.gid) { currentGID = ext4_inode_get_gid(&filled.inode) }
                    }
                }
                let rc = path.withCString { ext4_owner_set($0, currentUID, currentGID) }
                if rc != EOK {
                    log.error("ext4_owner_set failed rc=\(rc, privacy: .public)")
                    replyHandler(nil, posixError(rc))
                    return
                }
                if request.isValid(.uid) { consumed.insert(.uid) }
                if request.isValid(.gid) { consumed.insert(.gid) }
                wantsImplicitCtime = true
            }

            if request.isValid(.size) {
                // Per FSKit guidance, size changes on non-files are ignored
                // without error.
                if ext4Item.itemType == .file {
                    let target = request.size
                    let rc = withFileHandle(for: ext4Item) { file in
                        let current = ext4_fsize(file)
                        if target > current {
                            // lwext4 cannot grow via ftruncate (silent no-op)
                            // and refuses seeks past EOF, so extend by
                            // appending zeros.
                            return zeroExtend(file, to: target)
                        }
                        return ext4_ftruncate(file, target)
                    }
                    if rc != EOK {
                        log.error("set size failed rc=\(rc, privacy: .public)")
                        replyHandler(nil, posixError(rc))
                        return
                    }
                    consumed.insert(.size)
                    wantsImplicitCtime = true
                    wantsImplicitMtime = true
                }
            }

            if request.isValid(.accessTime) {
                let secs = Self.fsTime(request.accessTime.tv_sec)
                let rc = path.withCString { ext4_atime_set($0, secs) }
                if rc != EOK {
                    log.error("ext4_atime_set failed rc=\(rc, privacy: .public)")
                    replyHandler(nil, posixError(rc))
                    return
                }
                consumed.insert(.accessTime)
                // POSIX: utimes()/utimensat() mark ctime for update.
                wantsImplicitCtime = true
            }

            if request.isValid(.modifyTime) {
                let secs = Self.fsTime(request.modifyTime.tv_sec)
                let rc = path.withCString { ext4_mtime_set($0, secs) }
                if rc != EOK {
                    log.error("ext4_mtime_set failed rc=\(rc, privacy: .public)")
                    replyHandler(nil, posixError(rc))
                    return
                }
                consumed.insert(.modifyTime)
                wantsImplicitCtime = true
            }

            if request.isValid(.changeTime) {
                let secs = Self.fsTime(request.changeTime.tv_sec)
                let rc = path.withCString { ext4_ctime_set($0, secs) }
                if rc != EOK {
                    log.error("ext4_ctime_set failed rc=\(rc, privacy: .public)")
                    replyHandler(nil, posixError(rc))
                    return
                }
                consumed.insert(.changeTime)
            }

            let now = Self.nowSeconds()
            if wantsImplicitMtime && !request.isValid(.modifyTime) {
                setTimes(path: path, mtime: now)
            }
            if wantsImplicitCtime && !request.isValid(.changeTime) {
                setTimes(path: path, ctime: now)
            }

            request.consumedAttributes = consumed

            let getReq = FSItem.GetAttributesRequest()
            getReq.wantedAttributes = [
                .type, .mode, .linkCount, .uid, .gid, .flags,
                .size, .allocSize, .fileID, .parentID,
                .accessTime, .modifyTime, .changeTime, .birthTime,
            ]
            getAttributes(getReq, of: item) { attrs, err in
                replyHandler(attrs, err)
            }
        }
    }

    // MARK: lookup / reclaim

    func lookupItem(
        named name: FSFileName,
        inDirectory directory: FSItem,
        replyHandler: @escaping (FSItem?, FSFileName?, Error?) -> Void
    ) {
        withLock {
            guard let parent = directory as? Ext4Item,
                let nameString = name.string
            else {
                replyHandler(nil, nil, fs_errorForPOSIXError(Int32(EINVAL)))
                return
            }
            guard parent.itemType == .directory, !parent.isRemoved else {
                replyHandler(nil, nil, fs_errorForPOSIXError(Int32(ENOTDIR)))
                return
            }

            if nameString == "." {
                replyHandler(parent, name, nil)
                return
            }
            if nameString == ".." {
                replyHandler(parent.parent ?? parent, name, nil)
                return
            }

            // The orphan namespace (open-unlink emulation) is internal.
            if parent.parent == nil, nameString.hasPrefix(Self.orphanPrefix) {
                replyHandler(nil, nil, fs_errorForPOSIXError(Int32(ENOENT)))
                return
            }

            // Same-instance guarantee: if FSKit already holds an item for
            // this entry, hand the same object back so later rename/remove
            // bookkeeping affects the instance the kernel uses.
            if let cached = parent.cachedChild(named: nameString), !cached.isRemoved {
                replyHandler(cached, name, nil)
                return
            }

            let childPath = Ext4Item.joinPath(parent: parent.absolutePath, child: nameString)
            guard var filled = fillInode(at: childPath) else {
                replyHandler(nil, nil, fs_errorForPOSIXError(Int32(ENOENT)))
                return
            }

            let mode = filled.inode.mode(with: sblockPtr)
            let child = Ext4Item(
                inodeNumber: filled.ino,
                itemType: Self.itemType(fromMode: mode),
                fileID: FSItem.Identifier(rawValue: UInt64(filled.ino)) ?? .invalid,
                name: nameString,
                parent: parent
            )
            parent.cacheChild(child)
            replyHandler(child, name, nil)
        }
    }

    func reclaimItem(
        _ item: FSItem,
        replyHandler: @escaping (Error?) -> Void
    ) {
        withLock {
            if let ext4Item = item as? Ext4Item {
                // Open handles are normally balanced by closeItem; anything
                // left here would dangle once the item goes away. Only this
                // item's own membership may be released — another item
                // (hardlink sibling, or a new file that reused the inode
                // number) may legitimately share or own the same key.
                if let state = openFiles[ext4Item.inodeNumber],
                    state.openers.contains(ObjectIdentifier(ext4Item))
                {
                    log.warning(
                        "reclaim: releasing leaked open inode=\(ext4Item.inodeNumber, privacy: .public)")
                    state.openers.remove(ObjectIdentifier(ext4Item))
                    if state.openers.isEmpty {
                        _ = ext4_fclose(&state.file)
                        openFiles.removeValue(forKey: ext4Item.inodeNumber)
                        if let orphan = state.orphanPath {
                            freeOrphan(orphan)
                            state.orphanPath = nil
                            if ext4Item.orphanPath == orphan { ext4Item.orphanPath = nil }
                        }
                    }
                }
                removeOrphanIfNeeded(for: ext4Item)
                ext4Item.parent?.uncacheChild(named: ext4Item.name, ifIdentical: ext4Item)
            }
            replyHandler(nil)
        }
    }

    // MARK: symbolic links

    func readSymbolicLink(
        _ item: FSItem,
        replyHandler: @escaping (FSFileName?, Error?) -> Void
    ) {
        withLock {
            guard let ext4Item = item as? Ext4Item, !ext4Item.isRemoved else {
                replyHandler(nil, fs_errorForPOSIXError(Int32(EINVAL)))
                return
            }

            // 4 KiB covers every realistic symlink target. ext4 stores short
            // targets inline in the inode and longer ones in a single block,
            // and userspace is capped at `PATH_MAX` (1024 on macOS, 4096 on
            // Linux) anyway, so a truncated read past this ceiling would be
            // unresolvable on either platform regardless.
            var targetBytes = [CChar](repeating: 0, count: 4096)
            var rcnt = size_t(0)
            let rc = ext4Item.absolutePath.withCString { path in
                targetBytes.withUnsafeMutableBufferPointer { buf in
                    ext4_readlink(path, buf.baseAddress, buf.count, &rcnt)
                }
            }
            guard rc == EOK else {
                log.error(
                    """
                    ext4_readlink failed path='\(ext4Item.absolutePath, privacy: .public)' \
                    rc=\(rc, privacy: .public)
                    """)
                replyHandler(nil, posixError(rc))
                return
            }

            let target = targetBytes.withUnsafeBufferPointer { buf -> String in
                let bytes = UnsafeRawBufferPointer(start: buf.baseAddress, count: Int(rcnt))
                return String(decoding: bytes, as: UTF8.self)
            }
            replyHandler(FSFileName(string: target), nil)
        }
    }

    // MARK: create / remove / rename / link

    func createItem(
        named name: FSFileName,
        type: FSItem.ItemType,
        inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest,
        replyHandler: @escaping (FSItem?, FSFileName?, Error?) -> Void
    ) {
        withLock {
            guard !isReadOnly else {
                replyHandler(nil, nil, readOnlyError)
                return
            }
            let context: CreateContext
            switch prepareCreate(named: name, inDirectory: directory) {
            case .failure(let error):
                replyHandler(nil, nil, error)
                return
            case .success(let ctx):
                context = ctx
            }

            var rc: Int32
            switch type {
            case .file:
                var file = ext4_file()
                rc = context.path.withCString { p in
                    "wb".withCString { ext4_fopen(&file, p, $0) }
                }
                if rc == EOK { _ = ext4_fclose(&file) }
            case .directory:
                rc = context.path.withCString { ext4_dir_mk($0) }
            case .fifo:
                rc = context.path.withCString { ext4_mknod($0, Int32(EXT4_DE_FIFO), 0) }
            case .socket:
                rc = context.path.withCString { ext4_mknod($0, Int32(EXT4_DE_SOCK), 0) }
            case .charDevice:
                // FSKit carries no rdev in SetAttributesRequest; nodes are
                // created with a zero device number.
                rc = context.path.withCString { ext4_mknod($0, Int32(EXT4_DE_CHRDEV), 0) }
            case .blockDevice:
                rc = context.path.withCString { ext4_mknod($0, Int32(EXT4_DE_BLKDEV), 0) }
            default:
                replyHandler(nil, nil, fs_errorForPOSIXError(Int32(EINVAL)))
                return
            }
            guard rc == EOK else {
                log.error(
                    """
                    createItem failed path='\(context.path, privacy: .public)' \
                    rc=\(rc, privacy: .public)
                    """)
                replyHandler(nil, nil, posixError(rc))
                return
            }

            finishCreate(
                context: context, type: type, attributes: newAttributes
            ) { item, error in
                replyHandler(item, item != nil ? name : nil, error)
            }
        }
    }

    func createSymbolicLink(
        named name: FSFileName,
        inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest,
        linkContents contents: FSFileName,
        replyHandler: @escaping (FSItem?, FSFileName?, Error?) -> Void
    ) {
        withLock {
            guard !isReadOnly else {
                replyHandler(nil, nil, readOnlyError)
                return
            }
            let context: CreateContext
            switch prepareCreate(named: name, inDirectory: directory) {
            case .failure(let error):
                replyHandler(nil, nil, error)
                return
            case .success(let ctx):
                context = ctx
            }

            guard let target = contents.string, !target.isEmpty else {
                replyHandler(nil, nil, fs_errorForPOSIXError(Int32(EINVAL)))
                return
            }

            let rc = target.withCString { t in
                context.path.withCString { p in ext4_fsymlink(t, p) }
            }
            guard rc == EOK else {
                log.error(
                    """
                    ext4_fsymlink failed path='\(context.path, privacy: .public)' \
                    rc=\(rc, privacy: .public)
                    """)
                replyHandler(nil, nil, posixError(rc))
                return
            }

            finishCreate(
                context: context, type: .symlink, attributes: newAttributes
            ) { item, error in
                replyHandler(item, item != nil ? name : nil, error)
            }
        }
    }

    func createLink(
        to item: FSItem,
        named name: FSFileName,
        inDirectory directory: FSItem,
        replyHandler: @escaping (FSFileName?, Error?) -> Void
    ) {
        withLock {
            guard !isReadOnly else {
                replyHandler(nil, readOnlyError)
                return
            }
            guard let source = item as? Ext4Item, !source.isRemoved else {
                replyHandler(nil, fs_errorForPOSIXError(Int32(ENOENT)))
                return
            }
            guard source.itemType != .directory else {
                replyHandler(nil, fs_errorForPOSIXError(Int32(EPERM)))
                return
            }

            let context: CreateContext
            switch prepareCreate(named: name, inDirectory: directory) {
            case .failure(let error):
                replyHandler(nil, error)
                return
            case .success(let ctx):
                context = ctx
            }

            let sourcePath = source.absolutePath
            if var filled = fillInode(at: sourcePath),
                ext4_inode_get_links_cnt(&filled.inode) >= 65_000
            {
                replyHandler(nil, fs_errorForPOSIXError(Int32(EMLINK)))
                return
            }

            let rc = sourcePath.withCString { src in
                context.path.withCString { dst in ext4_flink(src, dst) }
            }
            guard rc == EOK else {
                log.error(
                    """
                    ext4_flink failed src='\(sourcePath, privacy: .public)' \
                    dst='\(context.path, privacy: .public)' rc=\(rc, privacy: .public)
                    """)
                replyHandler(nil, posixError(rc))
                return
            }

            let now = Self.nowSeconds()
            setTimes(path: sourcePath, ctime: now)
            touchParent(context.directory)
            bumpGeneration(of: context.directory)
            // No new FSItem here by contract — FSKit looks the new name up
            // when it needs it, producing a sibling item for the same inode.
            replyHandler(name, nil)
        }
    }

    func removeItem(
        _ item: FSItem,
        named name: FSFileName,
        fromDirectory directory: FSItem,
        replyHandler: @escaping (Error?) -> Void
    ) {
        withLock {
            guard !isReadOnly else {
                replyHandler(readOnlyError)
                return
            }
            guard let dir = directory as? Ext4Item, dir.itemType == .directory, !dir.isRemoved,
                let ext4Item = item as? Ext4Item,
                let entryName = validEntryName(name, in: dir)
            else {
                replyHandler(fs_errorForPOSIXError(Int32(EINVAL)))
                return
            }

            let path = Ext4Item.joinPath(parent: dir.absolutePath, child: entryName)
            guard var filled = fillInode(at: path) else {
                replyHandler(fs_errorForPOSIXError(Int32(ENOENT)))
                return
            }
            let mode = filled.inode.mode(with: sblockPtr)
            let onDiskType = Self.itemType(fromMode: mode)
            let linkCount = ext4_inode_get_links_cnt(&filled.inode)

            // Snapshot attributes before the unlink: FSKit may keep querying
            // the item until reclaim and the path stops resolving now.
            let snapshot = FSItem.Attributes()
            packAttributes(
                snapshot,
                inode: &filled.inode,
                itemType: ext4Item.itemType,
                fileID: ext4Item.fileID,
                parentID: dir.fileID
            )
            snapshot.linkCount = linkCount > 0 ? UInt32(linkCount - 1) : 0

            let rc: Int32
            var orphanedTo: String?
            if onDiskType == .directory {
                // ext4_dir_rm is recursive and never reports ENOTEMPTY, and
                // ext4_fremove on a directory is a silent no-op — POSIX rmdir
                // semantics have to be enforced here.
                switch directoryHasEntries(path) {
                case .none:
                    replyHandler(fs_errorForPOSIXError(Int32(EIO)))
                    return
                case .some(true):
                    replyHandler(fs_errorForPOSIXError(Int32(ENOTEMPTY)))
                    return
                case .some(false):
                    break
                }
                rc = path.withCString { ext4_dir_rm($0) }
            } else if linkCount <= 1 && openFiles[filled.ino] != nil {
                // Open-unlink: ext4_fremove would free the inode under the
                // kernel's still-open descriptor. Park the last link under a
                // hidden orphan name instead — the inode stays allocated and
                // the persistent handle stays valid until the final close.
                let orphanPath = self.orphanPath(forInode: filled.ino)
                // Clear any cross-session leftover at that name; freeOrphan
                // bumps root's generation since this mutates root's layout.
                freeOrphan(orphanPath)
                rc = path.withCString { src in
                    orphanPath.withCString { dst in ext4_frename(src, dst) }
                }
                if rc == EOK {
                    orphanedTo = orphanPath
                    // The handle's lifetime owns the cleanup — the unlinking
                    // item may be reclaimed long before the last close.
                    openFiles[filled.ino]?.orphanPath = orphanPath
                    if let root = rootItem { bumpGeneration(of: root) }
                }
            } else {
                rc = path.withCString { ext4_fremove($0) }
            }
            guard rc == EOK else {
                log.error(
                    "remove failed path='\(path, privacy: .public)' rc=\(rc, privacy: .public)")
                replyHandler(posixError(rc))
                return
            }

            ext4Item.isRemoved = true
            ext4Item.removedAttributes = snapshot
            ext4Item.orphanPath = orphanedTo
            dir.uncacheChild(named: entryName, ifIdentical: ext4Item)
            touchParent(dir)
            bumpGeneration(of: dir)
            replyHandler(nil)
        }
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
        withLock {
            guard !isReadOnly else {
                replyHandler(nil, readOnlyError)
                return
            }
            guard let moved = item as? Ext4Item, !moved.isRemoved, moved.parent != nil,
                let srcDir = sourceDirectory as? Ext4Item, srcDir.itemType == .directory,
                let dstDir = destinationDirectory as? Ext4Item, dstDir.itemType == .directory,
                !dstDir.isRemoved,
                let srcName = validEntryName(sourceName, in: srcDir),
                let dstName = validEntryName(destinationName, in: dstDir)
            else {
                replyHandler(nil, fs_errorForPOSIXError(Int32(EINVAL)))
                return
            }
            guard dstName.utf8.count <= 255 else {
                replyHandler(nil, fs_errorForPOSIXError(Int32(ENAMETOOLONG)))
                return
            }

            let srcPath = Ext4Item.joinPath(parent: srcDir.absolutePath, child: srcName)
            let dstPath = Ext4Item.joinPath(parent: dstDir.absolutePath, child: dstName)

            if srcPath == dstPath {
                replyHandler(destinationName, nil)
                return
            }

            // lwext4 has no cycle guard: renaming a directory into its own
            // subtree would corrupt the namespace.
            if moved.itemType == .directory, dstDir.isSelfOrDescendant(of: moved) {
                replyHandler(nil, fs_errorForPOSIXError(Int32(EINVAL)))
                return
            }

            // ext4_frename refuses to overwrite (EEXIST), so an existing
            // destination is removed first. Within opLock this is atomic with
            // respect to other volume operations, though not crash-atomic.
            if var dstFilled = fillInode(at: dstPath) {
                let dstMode = dstFilled.inode.mode(with: sblockPtr)
                let dstType = Self.itemType(fromMode: dstMode)
                let dstLinks = ext4_inode_get_links_cnt(&dstFilled.inode)

                if moved.itemType == .directory && dstType != .directory {
                    replyHandler(nil, fs_errorForPOSIXError(Int32(ENOTDIR)))
                    return
                }
                if moved.itemType != .directory && dstType == .directory {
                    replyHandler(nil, fs_errorForPOSIXError(Int32(EISDIR)))
                    return
                }

                let snapshot = FSItem.Attributes()
                packAttributes(
                    snapshot,
                    inode: &dstFilled.inode,
                    itemType: dstType,
                    fileID: FSItem.Identifier(rawValue: UInt64(dstFilled.ino)) ?? .invalid,
                    parentID: dstDir.fileID
                )
                snapshot.linkCount = dstLinks > 0 ? UInt32(dstLinks - 1) : 0

                let removeRC: Int32
                var victimOrphanedTo: String?
                if dstType == .directory {
                    switch directoryHasEntries(dstPath) {
                    case .none:
                        replyHandler(nil, fs_errorForPOSIXError(Int32(EIO)))
                        return
                    case .some(true):
                        replyHandler(nil, fs_errorForPOSIXError(Int32(ENOTEMPTY)))
                        return
                    case .some(false):
                        break
                    }
                    removeRC = dstPath.withCString { ext4_dir_rm($0) }
                } else if dstLinks <= 1 && openFiles[dstFilled.ino] != nil {
                    // The replaced file is open (the classic editor
                    // save-over pattern): park it as an orphan so the open
                    // descriptor keeps working until last close.
                    let orphanPath = self.orphanPath(forInode: dstFilled.ino)
                    // Clear any cross-session leftover; bumps root generation.
                    freeOrphan(orphanPath)
                    removeRC = dstPath.withCString { src in
                        orphanPath.withCString { dst in ext4_frename(src, dst) }
                    }
                    if removeRC == EOK {
                        victimOrphanedTo = orphanPath
                        openFiles[dstFilled.ino]?.orphanPath = orphanPath
                        if let root = rootItem { bumpGeneration(of: root) }
                    }
                } else {
                    removeRC = dstPath.withCString { ext4_fremove($0) }
                }
                guard removeRC == EOK else {
                    log.error(
                        """
                        rename: removing destination '\(dstPath, privacy: .public)' failed \
                        rc=\(removeRC, privacy: .public)
                        """)
                    replyHandler(nil, posixError(removeRC))
                    return
                }
                // The destination directory's layout changed NOW; if the
                // frename below fails and we return early, in-flight
                // enumeration cookies for dstDir must already be invalid.
                bumpGeneration(of: dstDir)

                if let over = overItem as? Ext4Item {
                    over.isRemoved = true
                    over.removedAttributes = snapshot
                    over.orphanPath = victimOrphanedTo
                } else if let victimOrphanedTo {
                    // No FSItem to hang the orphan on — free it right away
                    // rather than leak it until the activate-time sweep.
                    log.warning(
                        "rename: replaced an open file with no overItem; dropping orphan")
                    if let state = openFiles.removeValue(forKey: dstFilled.ino) {
                        _ = ext4_fclose(&state.file)
                    }
                    _ = victimOrphanedTo.withCString { ext4_fremove($0) }
                }
                dstDir.uncacheChild(named: dstName)
            }

            let rc = srcPath.withCString { src in
                dstPath.withCString { dst in ext4_frename(src, dst) }
            }
            guard rc == EOK else {
                log.error(
                    """
                    ext4_frename failed src='\(srcPath, privacy: .public)' \
                    dst='\(dstPath, privacy: .public)' rc=\(rc, privacy: .public)
                    """)
                replyHandler(nil, posixError(rc))
                return
            }

            srcDir.uncacheChild(named: srcName, ifIdentical: moved)
            moved.move(to: dstDir, newName: dstName)

            let now = Self.nowSeconds()
            touchParent(srcDir)
            if srcDir !== dstDir { touchParent(dstDir) }
            setTimes(path: dstPath, ctime: now)
            bumpGeneration(of: srcDir)
            if srcDir !== dstDir { bumpGeneration(of: dstDir) }
            replyHandler(destinationName, nil)
        }
    }

    // MARK: FSVolume.OpenCloseOperations

    func openItem(
        _ item: FSItem,
        modes: FSVolume.OpenModes,
        replyHandler: @escaping (Error?) -> Void
    ) {
        withLock {
            guard let ext4Item = item as? Ext4Item else {
                replyHandler(fs_errorForPOSIXError(Int32(EINVAL)))
                return
            }
            // Only regular files get a persistent lwext4 handle; opens on
            // directories and others are tracked by FSKit itself.
            guard ext4Item.itemType == .file, !ext4Item.isRemoved else {
                replyHandler(nil)
                return
            }

            if let state = openFiles[ext4Item.inodeNumber] {
                state.modes.formUnion(modes)
                state.openers.insert(ObjectIdentifier(ext4Item))
                replyHandler(nil)
                return
            }

            // Always open read/write (read-only volumes excepted): lwext4
            // does no permission checks and its O_RDONLY guards are dead
            // code, so a single handle serves every kernel open mode and
            // never needs reopening on upgrade.
            let state = OpenFile()
            let rc = ext4Item.absolutePath.withCString { p in
                (isReadOnly ? "rb" : "r+b").withCString { ext4_fopen(&state.file, p, $0) }
            }
            guard rc == EOK else {
                log.error(
                    """
                    openItem failed path='\(ext4Item.absolutePath, privacy: .public)' \
                    rc=\(rc, privacy: .public)
                    """)
                replyHandler(posixError(rc))
                return
            }
            state.modes = modes
            state.openers = [ObjectIdentifier(ext4Item)]
            openFiles[ext4Item.inodeNumber] = state
            replyHandler(nil)
        }
    }

    func closeItem(
        _ item: FSItem,
        modes: FSVolume.OpenModes,
        replyHandler: @escaping (Error?) -> Void
    ) {
        withLock {
            guard let ext4Item = item as? Ext4Item else {
                replyHandler(fs_errorForPOSIXError(Int32(EINVAL)))
                return
            }
            // `modes` is the set of modes to KEEP after this close. Only an
            // opener may release the handle — another item with the same
            // inode number may be a hardlink sibling with its own opens, or
            // a different file entirely if the inode number was reused.
            if let state = openFiles[ext4Item.inodeNumber],
                state.openers.contains(ObjectIdentifier(ext4Item))
            {
                if modes.isEmpty {
                    state.openers.remove(ObjectIdentifier(ext4Item))
                    if state.openers.isEmpty {
                        _ = ext4_fclose(&state.file)
                        openFiles.removeValue(forKey: ext4Item.inodeNumber)
                        if let orphan = state.orphanPath {
                            freeOrphan(orphan)
                            state.orphanPath = nil
                            if ext4Item.orphanPath == orphan { ext4Item.orphanPath = nil }
                        }
                    }
                    removeOrphanIfNeeded(for: ext4Item)
                } else {
                    state.modes = modes
                }
            }
            replyHandler(nil)
        }
    }

    // MARK: FSVolume.ReadWriteOperations

    func read(
        from item: FSItem,
        at offset: off_t,
        length: Int,
        into buffer: FSMutableFileDataBuffer,
        replyHandler: @escaping (Int, Error?) -> Void
    ) {
        withLock {
            guard let ext4Item = item as? Ext4Item else {
                replyHandler(0, fs_errorForPOSIXError(Int32(EINVAL)))
                return
            }
            guard ext4Item.itemType == .file else {
                let rc = ext4Item.itemType == .directory ? EISDIR : EINVAL
                replyHandler(0, fs_errorForPOSIXError(Int32(rc)))
                return
            }

            var actuallyRead = size_t(0)
            let rc = withFileHandle(for: ext4Item) { file in
                let fileSize = ext4_fsize(file)
                // Reads at or past EOF return 0 bytes with no error.
                guard offset >= 0, UInt64(offset) < fileSize else { return EOK }

                let seekRC = ext4_fseek(file, Int64(offset), UInt32(SEEK_SET))
                guard seekRC == EOK else { return seekRC }

                // The caller-supplied buffer is sized by FSKit; clamp the
                // read to the smaller of the requested length and the buffer
                // capacity so lwext4 never runs past the end of it.
                let capacity = min(length, Int(buffer.length))
                return buffer.withUnsafeMutableBytes { raw -> Int32 in
                    guard let base = raw.baseAddress else { return Int32(EFAULT) }
                    return ext4_fread(file, base, capacity, &actuallyRead)
                }
            }

            guard rc == EOK else {
                log.error(
                    """
                    read failed path='\(ext4Item.absolutePath, privacy: .public)' \
                    rc=\(rc, privacy: .public)
                    """)
                replyHandler(Int(actuallyRead), posixError(rc))
                return
            }
            replyHandler(Int(actuallyRead), nil)
        }
    }

    func write(
        contents: Data,
        to item: FSItem,
        at offset: off_t,
        replyHandler: @escaping (Int, Error?) -> Void
    ) {
        withLock {
            guard !isReadOnly else {
                replyHandler(0, readOnlyError)
                return
            }
            guard let ext4Item = item as? Ext4Item else {
                replyHandler(0, fs_errorForPOSIXError(Int32(EINVAL)))
                return
            }
            guard ext4Item.itemType == .file else {
                let rc = ext4Item.itemType == .directory ? EISDIR : EINVAL
                replyHandler(0, fs_errorForPOSIXError(Int32(rc)))
                return
            }
            guard offset >= 0 else {
                replyHandler(0, fs_errorForPOSIXError(Int32(EINVAL)))
                return
            }

            // POSIX: a zero-byte write has no effect (and must not extend).
            guard !contents.isEmpty else {
                replyHandler(0, nil)
                return
            }

            var written = size_t(0)
            var mayHaveGrown = false
            let rc = withFileHandle(for: ext4Item) { file in
                // lwext4 rejects seeks past EOF, so a write beyond the
                // current size first extends the file with zeros (no sparse
                // support).
                if UInt64(offset) > ext4_fsize(file) { mayHaveGrown = true }
                var stepRC = zeroExtend(file, to: UInt64(offset))
                guard stepRC == EOK else { return stepRC }

                stepRC = ext4_fseek(file, Int64(offset), UInt32(SEEK_SET))
                guard stepRC == EOK else { return stepRC }

                return contents.withUnsafeBytes { raw -> Int32 in
                    guard let base = raw.baseAddress else { return Int32(EFAULT) }
                    return ext4_fwrite(file, base, contents.count, &written)
                }
            }

            // Stamp times whenever on-disk state may have changed — including
            // a partially completed zero-fill extension that then errored.
            if rc == EOK || written > 0 || mayHaveGrown {
                let now = Self.nowSeconds()
                if let path = effectivePath(of: ext4Item) {
                    setTimes(path: path, mtime: now, ctime: now)
                }
            }

            guard rc == EOK else {
                log.error(
                    """
                    write failed path='\(ext4Item.absolutePath, privacy: .public)' \
                    offset=\(offset, privacy: .public) rc=\(rc, privacy: .public)
                    """)
                replyHandler(Int(written), posixError(rc))
                return
            }
            replyHandler(Int(written), nil)
        }
    }

    // MARK: FSVolume.XattrOperations

    /// macOS xattr names ("com.apple.quarantine", …) carry no Linux xattr
    /// namespace, which lwext4 requires. All macOS xattrs map into the
    /// `user.` namespace — the same convention Linux tools expect for
    /// unprivileged attributes — and listing surfaces only that namespace.
    private static let xattrNamespacePrefix = "user."

    /// `ENOATTR` (93 on Darwin) isn't surfaced by the imported headers.
    private static let enoattr: Int32 = 93

    func getXattr(
        named name: FSFileName,
        of item: FSItem,
        replyHandler: @escaping (Data?, Error?) -> Void
    ) {
        withLock {
            guard let ext4Item = item as? Ext4Item, !ext4Item.isRemoved,
                let xname = onDiskXattrName(name)
            else {
                replyHandler(nil, fs_errorForPOSIXError(Int32(EINVAL)))
                return
            }
            let path = ext4Item.absolutePath

            var valueSize = size_t(0)
            var rc = path.withCString { p in
                xname.withCString { n in
                    ext4_getxattr(p, n, xname.utf8.count, nil, 0, &valueSize)
                }
            }
            guard rc == EOK else {
                replyHandler(nil, xattrError(rc))
                return
            }
            guard valueSize > 0 else {
                replyHandler(Data(), nil)
                return
            }

            var value = Data(count: Int(valueSize))
            var copied = size_t(0)
            rc = value.withUnsafeMutableBytes { raw in
                path.withCString { p in
                    xname.withCString { n in
                        ext4_getxattr(p, n, xname.utf8.count, raw.baseAddress, valueSize, &copied)
                    }
                }
            }
            guard rc == EOK else {
                replyHandler(nil, xattrError(rc))
                return
            }
            replyHandler(value.prefix(Int(copied)), nil)
        }
    }

    func setXattr(
        named name: FSFileName,
        to value: Data?,
        on item: FSItem,
        policy: FSVolume.SetXattrPolicy,
        replyHandler: @escaping (Error?) -> Void
    ) {
        withLock {
            guard !isReadOnly else {
                replyHandler(readOnlyError)
                return
            }
            guard let ext4Item = item as? Ext4Item, !ext4Item.isRemoved,
                let xname = onDiskXattrName(name)
            else {
                replyHandler(fs_errorForPOSIXError(Int32(EINVAL)))
                return
            }
            let path = ext4Item.absolutePath

            func exists() -> Bool {
                var size = size_t(0)
                let rc = path.withCString { p in
                    xname.withCString { n in
                        ext4_getxattr(p, n, xname.utf8.count, nil, 0, &size)
                    }
                }
                return rc == EOK
            }

            let rc: Int32
            switch policy {
            case .delete:
                rc = path.withCString { p in
                    xname.withCString { n in
                        ext4_removexattr(p, n, xname.utf8.count)
                    }
                }
            case .mustCreate, .mustReplace, .alwaysSet:
                guard let value else {
                    // A nil value is only legal with the .delete policy.
                    replyHandler(fs_errorForPOSIXError(Int32(EINVAL)))
                    return
                }
                if policy == .mustCreate && exists() {
                    replyHandler(fs_errorForPOSIXError(Int32(EEXIST)))
                    return
                }
                if policy == .mustReplace && !exists() {
                    replyHandler(fs_errorForPOSIXError(Self.enoattr))
                    return
                }
                // lwext4 dereferences the data pointer; keep it non-nil even
                // for empty values.
                var bytes = [UInt8](value)
                if bytes.isEmpty { bytes = [0] }
                rc = path.withCString { p in
                    xname.withCString { n in
                        ext4_setxattr(p, n, xname.utf8.count, &bytes, value.count)
                    }
                }
            @unknown default:
                replyHandler(fs_errorForPOSIXError(Int32(EINVAL)))
                return
            }

            guard rc == EOK else {
                replyHandler(xattrError(rc))
                return
            }
            setTimes(path: path, ctime: Self.nowSeconds())
            replyHandler(nil)
        }
    }

    func listXattrs(
        of item: FSItem,
        replyHandler: @escaping ([FSFileName]?, Error?) -> Void
    ) {
        withLock {
            guard let ext4Item = item as? Ext4Item, !ext4Item.isRemoved else {
                replyHandler(nil, fs_errorForPOSIXError(Int32(EINVAL)))
                return
            }
            let path = ext4Item.absolutePath

            // lwext4 leaves ret_size untouched when the inode has no xattrs,
            // so it must be pre-zeroed.
            var needed = size_t(0)
            var rc = path.withCString { ext4_listxattr($0, nil, 0, &needed) }
            guard rc == EOK else {
                replyHandler(nil, xattrError(rc))
                return
            }
            guard needed > 0 else {
                replyHandler([], nil)
                return
            }

            var buf = [CChar](repeating: 0, count: Int(needed))
            var filled = size_t(0)
            rc = path.withCString { p in
                buf.withUnsafeMutableBufferPointer { b in
                    ext4_listxattr(p, b.baseAddress, b.count, &filled)
                }
            }
            guard rc == EOK else {
                replyHandler(nil, xattrError(rc))
                return
            }

            // Buffer holds full prefixed names, each NUL-terminated. Only the
            // user. namespace is surfaced (matching what setXattr writes).
            var names: [FSFileName] = []
            var start = 0
            let count = Int(filled)
            for i in 0..<count where buf[i] == 0 {
                if i > start {
                    let bytes = buf[start..<i].map { UInt8(bitPattern: $0) }
                    let full = String(decoding: bytes, as: UTF8.self)
                    if full.hasPrefix(Self.xattrNamespacePrefix) {
                        let display = String(full.dropFirst(Self.xattrNamespacePrefix.count))
                        if !display.isEmpty {
                            names.append(FSFileName(string: display))
                        }
                    }
                }
                start = i + 1
            }
            replyHandler(names, nil)
        }
    }

    // MARK: FSVolume.RenameOperations (volume label)

    func setVolumeName(
        _ name: FSFileName,
        replyHandler: @escaping (FSFileName?, Error?) -> Void
    ) {
        withLock {
            guard !isReadOnly else {
                replyHandler(nil, readOnlyError)
                return
            }
            guard isMountedInLwext4, let sbp = sblockPtr else {
                replyHandler(nil, fs_errorForPOSIXError(Int32(EIO)))
                return
            }

            // s_volume_name is a fixed 16-byte field, NUL-padded.
            let labelBytes = Array((name.string ?? "").utf8.prefix(16))
            withUnsafeMutableBytes(of: &sbp.pointee.volume_name) { raw in
                for i in 0..<raw.count { raw[i] = 0 }
                raw.copyBytes(from: labelBytes)
            }

            // ext4_sb_write recomputes the superblock checksum itself.
            let rc = ext4_sb_write(blockDevice.bdev, sbp)
            guard rc == EOK else {
                log.error("ext4_sb_write failed rc=\(rc, privacy: .public)")
                replyHandler(nil, posixError(rc))
                return
            }
            replyHandler(FSFileName(string: String(decoding: labelBytes, as: UTF8.self)), nil)
        }
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
        withLock {
            guard let dirItem = directory as? Ext4Item, !dirItem.isRemoved else {
                replyHandler(FSDirectoryVerifier(rawValue: 1), fs_errorForPOSIXError(Int32(EINVAL)))
                return
            }
            let currentVerifier = FSDirectoryVerifier(rawValue: dirItem.dirGeneration)

            // Cookies are lwext4 directory byte offsets (`dir.next_off`), so
            // resuming is O(1) — no re-walk. lwext4 reports end-of-directory
            // as offset UInt64.max (EXT4_DIR_ENTRY_OFFSET_TERM); a resume at
            // that cookie has nothing left to pack.
            if cookie.rawValue == Self.endOfDirectoryCookie {
                replyHandler(currentVerifier, nil)
                return
            }

            // Offsets are only meaningful for the directory layout they were
            // minted against: a mutation of this directory between batches
            // can shift entries across blocks, so a stale verifier must
            // invalidate the cookie. FSKit special-cases exactly this error
            // code and ends/recovers the enumeration gracefully instead of
            // failing readdir(2).
            if cookie.rawValue != 0 && verifier.rawValue != dirItem.dirGeneration {
                replyHandler(currentVerifier, Self.invalidCookieError)
                return
            }

            var dir = ext4_dir()
            let dirPath = dirItem.absolutePath
            let openRC = dirPath.withCString { ext4_dir_open(&dir, $0) }
            guard openRC == EOK else {
                log.error(
                    """
                    ext4_dir_open failed path='\(dirPath, privacy: .public)' \
                    rc=\(openRC, privacy: .public)
                    """)
                replyHandler(currentVerifier, posixError(openRC))
                return
            }
            defer { _ = ext4_dir_close(&dir) }

            if cookie.rawValue != 0 {
                // The verifier check above guarantees the offset was minted
                // against this exact directory layout, but bound-check it
                // anyway: lwext4's iterator dereferences NULL when seeded
                // with an offset at or past the directory's size.
                guard cookie.rawValue < dir.f.fsize else {
                    replyHandler(currentVerifier, Self.invalidCookieError)
                    return
                }
                dir.next_off = cookie.rawValue
            }

            while let entryPtr = ext4_dir_entry_next(&dir) {
                // After each call, next_off is the following entry's offset
                // (or the end sentinel) — exactly what a resume needs.
                let resumeCookie = FSDirectoryCookie(rawValue: dir.next_off)

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
                        enumerate: non-utf8 name at \(dirPath, privacy: .public)
                        """)
                    continue
                }

                // FSKit contract: pack "." and ".." only when the caller did NOT
                // request attributes. When it did, the VFS synthesizes them and
                // duplicates appear if we pack them too.
                let isDotOrDotDot = (nameString == "." || nameString == "..")
                if attributes != nil && isDotOrDotDot { continue }

                // Open-unlink orphans are internal bookkeeping, not entries.
                if dirItem.parent == nil, nameString.hasPrefix(Self.orphanPrefix) { continue }

                let itemType = Self.itemType(fromDirentryType: entry.inode_type)
                let childID: FSItem.Identifier
                switch nameString {
                case ".":
                    childID = dirItem.fileID
                case "..":
                    childID = parentID(of: dirItem)
                default:
                    childID = FSItem.Identifier(rawValue: UInt64(entry.inode)) ?? .invalid
                }

                // `packEntry` silently drops entries whose attribute blob is
                // nil when the caller requested non-nil attributes (the common
                // `ls` path), so always hand one over — with real inode data
                // when it resolves, minimal defaults otherwise.
                let attrBlob = FSItem.Attributes()
                var packedReal = false
                if attributes != nil {
                    let childPath = Ext4Item.joinPath(parent: dirPath, child: nameString)
                    if var filled = fillInode(at: childPath) {
                        packAttributes(
                            attrBlob,
                            inode: &filled.inode,
                            itemType: itemType,
                            fileID: childID,
                            parentID: dirItem.fileID
                        )
                        packedReal = true
                    }
                }
                if !packedReal {
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
                }

                let packed = packer.packEntry(
                    name: FSFileName(string: nameString),
                    itemType: itemType,
                    itemID: childID,
                    nextCookie: resumeCookie,
                    attributes: attrBlob
                )
                if !packed { break }
            }

            replyHandler(currentVerifier, nil)
        }
    }

    // MARK: create helpers

    private struct CreateContext {
        let directory: Ext4Item
        let entryName: String
        let path: String
    }

    /// Shared validation for createItem/createSymbolicLink/createLink:
    /// directory sanity, name validity, and an existence check (lwext4's
    /// creating opens happily reuse existing inodes and its O_EXCL is a
    /// no-op, so EEXIST has to be produced here).
    private func prepareCreate(
        named name: FSFileName,
        inDirectory directory: FSItem
    ) -> Result<CreateContext, any Error> {
        guard let dir = directory as? Ext4Item else {
            return .failure(fs_errorForPOSIXError(Int32(EINVAL)))
        }
        guard dir.itemType == .directory else {
            return .failure(fs_errorForPOSIXError(Int32(ENOTDIR)))
        }
        guard !dir.isRemoved else {
            return .failure(fs_errorForPOSIXError(Int32(ENOENT)))
        }
        guard let entryName = validEntryName(name, in: dir) else {
            return .failure(fs_errorForPOSIXError(Int32(EINVAL)))
        }
        guard entryName.utf8.count <= 255 else {
            return .failure(fs_errorForPOSIXError(Int32(ENAMETOOLONG)))
        }
        let path = Ext4Item.joinPath(parent: dir.absolutePath, child: entryName)
        if fillInode(at: path) != nil {
            return .failure(fs_errorForPOSIXError(Int32(EEXIST)))
        }
        return .success(CreateContext(directory: dir, entryName: entryName, path: path))
    }

    /// Post-creation bookkeeping shared by createItem/createSymbolicLink:
    /// applies the requested attributes, stamps timestamps, registers the new
    /// item, and bumps the namespace generation.
    private func finishCreate(
        context: CreateContext,
        type: FSItem.ItemType,
        attributes request: FSItem.SetAttributesRequest,
        replyHandler: (Ext4Item?, Error?) -> Void
    ) {
        // The on-disk entry exists by the time we're called — invalidate
        // enumeration cookies and stamp the parent before anything that can
        // early-return.
        touchParent(context.directory)
        bumpGeneration(of: context.directory)

        guard let filled = fillInode(at: context.path) else {
            log.error(
                "create: new item not found at '\(context.path, privacy: .public)'")
            replyHandler(nil, fs_errorForPOSIXError(Int32(EIO)))
            return
        }

        request.consumedAttributes = applyNewItemAttributes(
            request, path: context.path, type: type)

        let item = Ext4Item(
            inodeNumber: filled.ino,
            itemType: type,
            fileID: FSItem.Identifier(rawValue: UInt64(filled.ino)) ?? .invalid,
            name: context.entryName,
            parent: context.directory
        )
        context.directory.cacheChild(item)
        replyHandler(item, nil)
    }

    /// Applies creation attributes to a just-created inode. lwext4 leaves new
    /// inodes with epoch-zero timestamps and type-default modes, so mode and
    /// all three timestamps are always written, falling back to sensible
    /// defaults when the request doesn't specify them.
    private func applyNewItemAttributes(
        _ request: FSItem.SetAttributesRequest,
        path: String,
        type: FSItem.ItemType
    ) -> FSItem.Attribute {
        var consumed: FSItem.Attribute = []

        let defaultMode: UInt32
        switch type {
        case .directory: defaultMode = 0o755
        case .symlink: defaultMode = 0o777
        default: defaultMode = 0o644
        }
        let mode = request.isValid(.mode) ? (request.mode & 0x0FFF) : defaultMode
        let modeRC = path.withCString { ext4_mode_set($0, mode) }
        if modeRC != EOK {
            log.warning("create: ext4_mode_set rc=\(modeRC, privacy: .public)")
        } else if request.isValid(.mode) {
            consumed.insert(.mode)
        }

        if request.isValid(.uid) || request.isValid(.gid) {
            let uid = request.isValid(.uid) ? request.uid : 0
            let gid = request.isValid(.gid) ? request.gid : 0
            let rc = path.withCString { ext4_owner_set($0, uid, gid) }
            if rc != EOK {
                log.warning("create: ext4_owner_set rc=\(rc, privacy: .public)")
            } else {
                if request.isValid(.uid) { consumed.insert(.uid) }
                if request.isValid(.gid) { consumed.insert(.gid) }
            }
        }

        let now = Self.nowSeconds()
        let atime = request.isValid(.accessTime)
            ? Self.fsTime(request.accessTime.tv_sec) : now
        let mtime = request.isValid(.modifyTime)
            ? Self.fsTime(request.modifyTime.tv_sec) : now
        let ctime = request.isValid(.changeTime)
            ? Self.fsTime(request.changeTime.tv_sec) : now
        setTimes(path: path, atime: atime, mtime: mtime, ctime: ctime)
        if request.isValid(.accessTime) { consumed.insert(.accessTime) }
        if request.isValid(.modifyTime) { consumed.insert(.modifyTime) }
        if request.isValid(.changeTime) { consumed.insert(.changeTime) }

        return consumed
    }

    // MARK: private helpers

    private func withLock<T>(_ body: () -> T) -> T {
        opLock.lock()
        defer { opLock.unlock() }
        return body()
    }

    /// True when the activate/mount FSTaskOptions ask for a read-only mount:
    /// `mount -o rdonly` arrives as ["-o", "rdonly"], `-o ro,noexec` as
    /// ["-o", "ro,noexec"].
    private static func optionsRequestReadOnly(_ options: FSTaskOptions) -> Bool {
        let opts = options.taskOptions
        for (index, element) in opts.enumerated() where element == "-o" {
            guard index + 1 < opts.count else { break }
            let values = opts[index + 1].split(separator: ",")
            if values.contains("ro") || values.contains("rdonly") {
                return true
            }
        }
        // Defensive catch-all matching Apple's msdos module.
        return opts.contains { $0.contains("rdonly") }
    }

    private var readOnlyError: any Error {
        fs_errorForPOSIXError(Int32(EROFS))
    }

    /// Maps an lwext4 return code (positive Darwin errno, since lwext4 is
    /// compiled with CONFIG_HAVE_OWN_ERRNO=0) to an FSKit error.
    private func posixError(_ rc: Int32) -> any Error {
        fs_errorForPOSIXError(rc > 0 ? rc : Int32(EIO))
    }

    /// lwext4 reports missing xattrs as ENODATA; macOS expects ENOATTR.
    private func xattrError(_ rc: Int32) -> any Error {
        if rc == ENODATA { return fs_errorForPOSIXError(Self.enoattr) }
        return posixError(rc)
    }

    private static func nowSeconds() -> UInt32 {
        fsTime(Int(time(nil)))
    }

    /// On-disk ext4 second counters are read as *signed* 32-bit by Linux
    /// (plus epoch bits lwext4 doesn't manage), so clamp to 1970…2038 rather
    /// than the full unsigned range — a post-2038 value written as raw UInt32
    /// would read back on Linux as a pre-1970 date.
    private static func fsTime(_ seconds: Int) -> UInt32 {
        UInt32(clamping: min(max(seconds, 0), Int(Int32.max)))
    }

    /// Bumps the enumeration verifier of a mutated directory.
    private func bumpGeneration(of dir: Ext4Item) {
        dir.dirGeneration &+= 1
        if dir.dirGeneration == 0 { dir.dirGeneration = 1 }
    }

    /// Where this item lives on disk right now: its normal path, its orphan
    /// parking spot (open-unlinked files), or nowhere (`nil`).
    private func effectivePath(of item: Ext4Item) -> String? {
        if item.isRemoved {
            return item.orphanPath
        }
        return item.absolutePath
    }

    private func orphanPath(forInode ino: UInt32) -> String {
        Self.mountPointPath + Self.orphanPrefix + String(ino)
    }

    /// Frees an orphan parking spot and invalidates any root enumeration in
    /// flight (orphans live in the root directory and shift its positional
    /// cookies even though they're hidden from listings).
    private func freeOrphan(_ path: String) {
        let rc = path.withCString { ext4_fremove($0) }
        if rc != EOK && rc != ENOENT {
            log.warning(
                "orphan cleanup failed path='\(path, privacy: .public)' rc=\(rc, privacy: .public)")
        }
        if let root = rootItem { bumpGeneration(of: root) }
    }

    /// Final stage of open-unlink emulation for a removed item. While a live
    /// handle still pins the inode, the cleanup is handed to the handle's
    /// lifetime instead of freeing the inode out from under it.
    private func removeOrphanIfNeeded(for item: Ext4Item) {
        guard let orphan = item.orphanPath else { return }
        if let state = openFiles[item.inodeNumber] {
            if state.orphanPath == nil { state.orphanPath = orphan }
            item.orphanPath = nil
            return
        }
        freeOrphan(orphan)
        item.orphanPath = nil
    }

    /// Removes leftover orphan files from a previous session that crashed
    /// before their final close. Runs once at activate.
    private func sweepStaleOrphans() {
        var dir = ext4_dir()
        guard Self.mountPointPath.withCString({ ext4_dir_open(&dir, $0) }) == EOK else { return }
        var stale: [String] = []
        while let entryPtr = ext4_dir_entry_next(&dir) {
            let nameLen = Int(entryPtr.pointee.name_length)
            guard nameLen > 0 else { continue }
            let nameBytes = withUnsafePointer(to: entryPtr.pointee.name) {
                $0.withMemoryRebound(to: UInt8.self, capacity: nameLen) { base in
                    Array(UnsafeBufferPointer(start: base, count: nameLen))
                }
            }
            let name = String(decoding: nameBytes, as: UTF8.self)
            if name.hasPrefix(Self.orphanPrefix) { stale.append(name) }
        }
        _ = ext4_dir_close(&dir)

        for name in stale {
            let path = Self.mountPointPath + name
            log.info("sweeping stale orphan '\(path, privacy: .public)'")
            _ = path.withCString { ext4_fremove($0) }
        }
    }

    private func setTimes(
        path: String, atime: UInt32? = nil, mtime: UInt32? = nil, ctime: UInt32? = nil
    ) {
        path.withCString { p in
            if let atime, ext4_atime_set(p, atime) != EOK {
                log.warning("ext4_atime_set failed for '\(path, privacy: .public)'")
            }
            if let mtime, ext4_mtime_set(p, mtime) != EOK {
                log.warning("ext4_mtime_set failed for '\(path, privacy: .public)'")
            }
            if let ctime, ext4_ctime_set(p, ctime) != EOK {
                log.warning("ext4_ctime_set failed for '\(path, privacy: .public)'")
            }
        }
    }

    /// Namespace ops update the parent directory's mtime/ctime.
    private func touchParent(_ dir: Ext4Item) {
        let now = Self.nowSeconds()
        setTimes(path: dir.absolutePath, mtime: now, ctime: now)
    }

    private func fillInode(at path: String) -> (ino: UInt32, inode: ext4_inode)? {
        var inode = ext4_inode()
        var ino: UInt32 = 0
        let rc = path.withCString { ext4_raw_inode_fill($0, &ino, &inode) }
        guard rc == EOK else { return nil }
        return (ino, inode)
    }

    private func parentID(of item: Ext4Item) -> FSItem.Identifier {
        guard let parent = item.parent else { return .parentOfRoot }
        return parent.fileID
    }

    /// Fills an `FSItem.Attributes` from a raw inode.
    private func packAttributes(
        _ attrs: FSItem.Attributes,
        inode: inout ext4_inode,
        itemType: FSItem.ItemType,
        fileID: FSItem.Identifier,
        parentID: FSItem.Identifier
    ) {
        attrs.type = itemType
        attrs.fileID = fileID
        attrs.parentID = parentID

        let mode = inode.mode(with: sblockPtr)
        attrs.mode = UInt32(mode & 0x0FFF)
        attrs.linkCount = UInt32(ext4_inode_get_links_cnt(&inode))
        attrs.uid = ext4_inode_get_uid(&inode)
        attrs.gid = ext4_inode_get_gid(&inode)
        attrs.flags = 0

        attrs.size = inode.size(with: sblockPtr)
        if let sbp = sblockPtr {
            // i_blocks is in 512-byte sectors regardless of fs block size.
            attrs.allocSize = ext4_inode_get_blocks_count(sbp, &inode) * 512
        } else {
            attrs.allocSize = attrs.size
        }

        let modTime = ext4_inode_get_modif_time(&inode)
        let accTime = ext4_inode_get_access_time(&inode)
        let chgTime = ext4_inode_get_change_inode_time(&inode)
        attrs.modifyTime = timespec(tv_sec: Int(modTime), tv_nsec: 0)
        attrs.accessTime = timespec(tv_sec: Int(accTime), tv_nsec: 0)
        attrs.changeTime = timespec(tv_sec: Int(chgTime), tv_nsec: 0)

        // Real creation time lives in i_crtime, present only on >=256-byte
        // inodes (the raw little-endian field is host order on arm64/x86_64).
        // Aliasing ctime here would make Finder's "Date Created" drift on
        // every chmod/write.
        let inodeSize = sblockPtr.map { UInt32($0.pointee.inode_size) } ?? 128
        if inodeSize > 128, inode.crtime != 0 {
            attrs.birthTime = timespec(tv_sec: Int(inode.crtime), tv_nsec: 0)
        } else {
            attrs.birthTime = timespec(tv_sec: Int(min(chgTime, modTime)), tv_nsec: 0)
        }
    }

    /// Validates an FSKit entry name for use as a single ext4 path component.
    /// In the root directory the orphan prefix is reserved for open-unlink
    /// emulation (matching where lookup/enumeration hide it; elsewhere such
    /// names are ordinary files, possibly created from Linux).
    private func validEntryName(_ name: FSFileName, in dir: Ext4Item) -> String? {
        guard let s = name.string, !s.isEmpty, s != ".", s != "..", !s.contains("/") else {
            return nil
        }
        if dir.parent == nil && s.hasPrefix(Self.orphanPrefix) {
            return nil
        }
        return s
    }

    /// Runs `body` with an open lwext4 file handle for `item`, preferring the
    /// persistent handle created by `openItem`. Returns the open failure rc
    /// without calling `body` when no handle can be produced.
    ///
    /// A map hit may only be used while this item's inode is provably the one
    /// behind the handle: a live item's name still pins its inode, an orphan
    /// parking spot pins it, and an item that is itself an opener pinned it
    /// by opening. A removed non-opener item without an orphan gives no such
    /// proof — its freed inode number could alias a new file's handle.
    private func withFileHandle(
        for item: Ext4Item,
        _ body: (UnsafeMutablePointer<ext4_file>) -> Int32
    ) -> Int32 {
        if let state = openFiles[item.inodeNumber],
            !item.isRemoved || item.orphanPath != nil
                || state.openers.contains(ObjectIdentifier(item))
        {
            return withUnsafeMutablePointer(to: &state.file) { body($0) }
        }

        guard let path = effectivePath(of: item) else { return Int32(ESTALE) }
        var file = ext4_file()
        let openRC = path.withCString { p in
            (isReadOnly ? "rb" : "r+b").withCString { ext4_fopen(&file, p, $0) }
        }
        guard openRC == EOK else { return openRC }
        defer { _ = ext4_fclose(&file) }
        return withUnsafeMutablePointer(to: &file) { body($0) }
    }

    /// Shared zero-fill source for `zeroExtend` (immutable, so safe to share
    /// across calls instead of reallocating 128 KiB per grow).
    private static let zeroChunk = [UInt8](repeating: 0, count: 128 * 1024)

    /// Appends zeros until the file is at least `target` bytes long. lwext4
    /// can neither truncate-up nor seek past EOF, so this is the only way to
    /// grow a file.
    private func zeroExtend(
        _ file: UnsafeMutablePointer<ext4_file>, to target: UInt64
    ) -> Int32 {
        var size = ext4_fsize(file)
        guard target > size else { return EOK }

        // Fail fast instead of filling the disk with zeros and then hitting
        // ENOSPC anyway. (Approximate: ignores metadata overhead.)
        var stats = ext4_mount_stats()
        let statsRC = Self.mountPointPath.withCString { ext4_mount_point_stats($0, &stats) }
        if statsRC == EOK {
            let freeBytes = saturatingMul(stats.free_blocks_count, UInt64(stats.block_size))
            if target - size > freeBytes { return Int32(ENOSPC) }
        }

        var rc = ext4_fseek(file, Int64(size), UInt32(SEEK_SET))
        guard rc == EOK else { return rc }

        let zeros = Self.zeroChunk
        while size < target {
            let n = Int(min(UInt64(zeros.count), target - size))
            var wcnt = size_t(0)
            rc = zeros.withUnsafeBufferPointer { buf in
                ext4_fwrite(file, buf.baseAddress, n, &wcnt)
            }
            guard rc == EOK else { return rc }
            guard wcnt == n else { return Int32(EIO) }
            size += UInt64(n)
        }
        return EOK
    }

    /// True when the directory contains entries other than "." and "..",
    /// false when empty, nil when it can't be opened. POSIX rmdir semantics
    /// (ENOTEMPTY) are enforced with this because `ext4_dir_rm` would happily
    /// remove a whole subtree.
    private func directoryHasEntries(_ path: String) -> Bool? {
        var dir = ext4_dir()
        guard path.withCString({ ext4_dir_open(&dir, $0) }) == EOK else { return nil }
        defer { _ = ext4_dir_close(&dir) }

        while let entryPtr = ext4_dir_entry_next(&dir) {
            let nameLen = Int(entryPtr.pointee.name_length)
            guard nameLen > 0 else { continue }
            if nameLen <= 2 {
                let bytes = withUnsafePointer(to: entryPtr.pointee.name) {
                    $0.withMemoryRebound(to: UInt8.self, capacity: nameLen) { base in
                        Array(UnsafeBufferPointer(start: base, count: nameLen))
                    }
                }
                if bytes == [UInt8(ascii: ".")] || bytes == [UInt8(ascii: "."), UInt8(ascii: ".")] {
                    continue
                }
            }
            return true
        }
        return false
    }

    private func onDiskXattrName(_ name: FSFileName) -> String? {
        guard let s = name.string, !s.isEmpty else { return nil }
        return Self.xattrNamespacePrefix + s
    }

    /// Saturates instead of trapping — superblock counters are untrusted
    /// on-disk input (a corrupt image must not crash the extension).
    private func saturatingMul(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (value, overflow) = a.multipliedReportingOverflow(by: b)
        return overflow ? .max : value
    }

    private func updateCachedStats(from stats: ext4_mount_stats) {
        let result = FSStatFSResult(fileSystemTypeName: "ext4")
        let bsize = UInt64(stats.block_size)
        let total = stats.blocks_count
        let free = min(stats.free_blocks_count, total)
        result.blockSize = Int(stats.block_size)
        // f_iosize/st_blksize: sizes the I/O that *applications* (stdio, cp,
        // Finder) issue. lwext4 coalesces contiguous file runs into single
        // device transfers, so larger application chunks reach the disk as
        // larger I/Os — and each write call is one journal transaction, so
        // tiny chunks are brutally expensive. Benchmarks (Benchmarks/bench.c,
        // 64 MiB sequential): 4 KiB chunks = 100 MiB/s & 180k device writes;
        // 128 KiB = 322 MiB/s & 5.4k writes; 1 MiB adds little and inflates
        // every stdio buffer. Apple's msdos module uses 32 KiB.
        result.ioSize = 128 * 1024
        result.totalBlocks = total
        result.freeBlocks = free
        result.availableBlocks = free
        result.usedBlocks = total - free
        result.totalBytes = saturatingMul(total, bsize)
        result.freeBytes = saturatingMul(free, bsize)
        result.availableBytes = saturatingMul(free, bsize)
        result.usedBytes = saturatingMul(total - free, bsize)
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
