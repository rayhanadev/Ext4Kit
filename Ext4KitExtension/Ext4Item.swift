import FSKit
import Foundation

/// FSItem subclass that binds an FSKit item handle to an ext4 inode number and
/// a position in the namespace (parent + name).
///
/// lwext4's public interface (`ext4_dir_open`, `ext4_raw_inode_fill`,
/// `ext4_fopen`, …) addresses items by full path strings rooted at the lwext4
/// mount point (`/ext4kit/`), not by inode number. Rather than freezing the
/// absolute path at creation time — which would go stale for every descendant
/// the moment a directory is renamed — each item records its parent and entry
/// name, and `absolutePath` is computed on demand by walking the parent chain.
/// Renaming a directory therefore re-points exactly one node and every cached
/// descendant resolves correctly afterwards.
///
/// Directories additionally carry a weak child cache so `lookupItem` can hand
/// FSKit back the same `Ext4Item` instance it already holds for a given entry.
/// That instance identity is what lets `renameItem`/`removeItem` bookkeeping
/// take effect for items the kernel still references. The cache holds children
/// weakly (children hold their parent strongly), so dropping an item from
/// FSKit's side — signalled via `reclaimItem` — is what actually frees it.
///
/// All mutable state on this class is guarded by `Ext4Volume`'s operation
/// lock; nothing here is independently thread-safe.
final class Ext4Item: FSItem {
    /// ext4 inode number. 2 is always the root directory on ext[234].
    let inodeNumber: UInt32
    /// File-system item type derived from the inode mode (or the direntry type
    /// when we see the entry first and haven't loaded the inode yet).
    let itemType: FSItem.ItemType
    /// Opaque identifier FSKit uses for item caching. The root uses the reserved
    /// `rootDirectory` sentinel; everything else uses its inode number cast into
    /// the `FSItem.Identifier` raw value.
    let fileID: FSItem.Identifier

    /// Entry name within `parent`. For the root this holds the raw lwext4
    /// mount-point string (e.g. `/ext4kit/`) and never appears as a name.
    private(set) var name: String
    /// Strong reference: a live child must keep its ancestors alive so path
    /// computation always works. `nil` only for the root.
    private(set) var parent: Ext4Item?

    /// Set when the on-disk object behind this item has been unlinked (or
    /// replaced by a rename). FSKit may still hold and query the item until
    /// `reclaimItem`; `removedAttributes` preserves the last known attributes
    /// so those queries don't have to hit a path that no longer resolves.
    var isRemoved = false
    var removedAttributes: FSItem.Attributes?

    /// When the last link of an *open* file is unlinked, the entry is parked
    /// under a hidden orphan name instead of being freed (open-unlink
    /// emulation). This is that name's path; the real `ext4_fremove` happens
    /// at last close / reclaim.
    var orphanPath: String?

    /// Directory-enumeration verifier: bumped on every mutation of *this*
    /// directory's entries. Starts at 1 because FSKit treats verifier 0
    /// (`FSDirectoryVerifier.initial`) as "enumeration never ran".
    var dirGeneration: UInt64 = 1

    private struct WeakChild {
        weak var item: Ext4Item?
    }

    /// Weak cache of live child items, keyed by entry name. Only meaningful
    /// for directories.
    private var childCache: [String: WeakChild] = [:]

    init(
        inodeNumber: UInt32,
        itemType: FSItem.ItemType,
        fileID: FSItem.Identifier,
        name: String,
        parent: Ext4Item?
    ) {
        self.inodeNumber = inodeNumber
        self.itemType = itemType
        self.fileID = fileID
        self.name = name
        self.parent = parent
        super.init()
    }

    static func makeRoot(mountPath: String) -> Ext4Item {
        Ext4Item(
            inodeNumber: 2,
            itemType: .directory,
            fileID: .rootDirectory,
            name: mountPath,
            parent: nil
        )
    }

    /// lwext4-rooted absolute path, e.g. `/ext4kit/` for the root,
    /// `/ext4kit/foo` for a child of root, `/ext4kit/foo/bar` for a grandchild.
    var absolutePath: String {
        guard let parent else { return name }
        return Self.joinPath(parent: parent.absolutePath, child: name)
    }

    /// Join a parent's absolute path with a child name, handling the trailing-slash
    /// convention (root uses `/ext4kit/`, nested items use `/ext4kit/foo`).
    static func joinPath(parent: String, child: String) -> String {
        if parent.hasSuffix("/") {
            return parent + child
        }
        return parent + "/" + child
    }

    // MARK: child cache (volume lock held by all callers)

    func cachedChild(named name: String) -> Ext4Item? {
        guard let boxed = childCache[name] else { return nil }
        guard let item = boxed.item else {
            childCache.removeValue(forKey: name)
            return nil
        }
        return item
    }

    func cacheChild(_ item: Ext4Item) {
        childCache[item.name] = WeakChild(item: item)
    }

    /// Drop a cache entry. When `ifIdentical` is given, the entry is only
    /// removed if it still maps to that exact instance — this keeps a stale
    /// reclaim from evicting a newer item that reused the name.
    func uncacheChild(named name: String, ifIdentical item: Ext4Item? = nil) {
        if let item, let cur = childCache[name]?.item, cur !== item {
            return
        }
        childCache.removeValue(forKey: name)
    }

    /// Re-home this item under a new parent/name (rename bookkeeping).
    func move(to newParent: Ext4Item, newName: String) {
        parent?.uncacheChild(named: name, ifIdentical: self)
        name = newName
        parent = newParent
        newParent.cacheChild(self)
    }

    /// True if `possibleAncestor` appears on this item's parent chain
    /// (including the item itself). Used to refuse renaming a directory into
    /// its own subtree, which lwext4 does not guard against.
    func isSelfOrDescendant(of possibleAncestor: Ext4Item) -> Bool {
        var node: Ext4Item? = self
        while let current = node {
            if current === possibleAncestor { return true }
            node = current.parent
        }
        return false
    }
}
