import FSKit
import Foundation

/// FSItem subclass that binds an FSKit item handle to both an ext4 inode number
/// and the absolute path lwext4 expects for its path-based API.
///
/// lwext4's public interface (`ext4_dir_open`, `ext4_raw_inode_fill`,
/// `ext4_fopen`, …) addresses items by full path strings rooted at the lwext4
/// mount point (`/ext4kit/`), not by inode number. To let `lookupItem` and
/// `enumerateDirectory` walk arbitrary subtrees, every `Ext4Item` carries the
/// path used to reach it. The root is created at activate time with the raw
/// mount-point string; children are derived by joining with the child name.
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
    /// lwext4-rooted absolute path, e.g. `/ext4kit/` for the root, `/ext4kit/foo`
    /// for a child of root, `/ext4kit/foo/bar` for a grandchild.
    let absolutePath: String

    init(
        inodeNumber: UInt32,
        itemType: FSItem.ItemType,
        fileID: FSItem.Identifier,
        absolutePath: String
    ) {
        self.inodeNumber = inodeNumber
        self.itemType = itemType
        self.fileID = fileID
        self.absolutePath = absolutePath
        super.init()
    }

    static func makeRoot(mountPath: String) -> Ext4Item {
        Ext4Item(
            inodeNumber: 2,
            itemType: .directory,
            fileID: .rootDirectory,
            absolutePath: mountPath
        )
    }

    /// Join a parent's absolute path with a child name, handling the trailing-slash
    /// convention (root uses `/ext4kit/`, nested items use `/ext4kit/foo`).
    static func joinPath(parent: String, child: String) -> String {
        if parent.hasSuffix("/") {
            return parent + child
        }
        return parent + "/" + child
    }
}
