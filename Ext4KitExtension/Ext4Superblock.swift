import Foundation

/// Minimal ext4 superblock parser. Only the fields needed for probe.
/// See: https://ext4.wiki.kernel.org/index.php/Ext4_Disk_Layout
struct Ext4Superblock {
    static let onDiskOffset: off_t = 1024
    static let size: Int = 1024
    static let magic: UInt16 = 0xEF53

    // Byte offsets within the superblock structure
    private enum Offset {
        static let sMagic = 56  // __le16
        static let sUUID = 104  // 16 bytes
        static let sVolumeName = 120  // 16 bytes, NUL-padded
        static let sFeatureCompat = 92  // __le32
        static let sFeatureIncompat = 96  // __le32
        static let sFeatureROCompat = 100  // __le32
    }

    let magic: UInt16
    let uuid: UUID
    let volumeName: String
    let featureCompat: UInt32
    let featureIncompat: UInt32
    let featureROCompat: UInt32

    init?(_ buf: UnsafeRawPointer) {
        let magic = buf.load(fromByteOffset: Offset.sMagic, as: UInt16.self).littleEndian
        guard magic == Self.magic else { return nil }
        self.magic = magic

        var uuidBytes = [UInt8](repeating: 0, count: 16)
        uuidBytes.withUnsafeMutableBufferPointer { dst in
            _ = memcpy(dst.baseAddress!, buf.advanced(by: Offset.sUUID), 16)
        }
        self.uuid = NSUUID(uuidBytes: uuidBytes) as UUID

        let nameBytes = Data(bytes: buf.advanced(by: Offset.sVolumeName), count: 16)
        let trimmed = nameBytes.prefix(while: { $0 != 0 })
        self.volumeName = String(data: trimmed, encoding: .utf8) ?? ""

        self.featureCompat = buf.load(fromByteOffset: Offset.sFeatureCompat, as: UInt32.self).littleEndian
        self.featureIncompat = buf.load(fromByteOffset: Offset.sFeatureIncompat, as: UInt32.self).littleEndian
        self.featureROCompat = buf.load(fromByteOffset: Offset.sFeatureROCompat, as: UInt32.self).littleEndian
    }

    /// Incompat feature bits the probe side recognizes. A set bit outside
    /// this mask is logged as a warning during probe but isn't fatal; the
    /// actual rejection happens later when lwext4's `ext4_mount` refuses to
    /// load a filesystem whose features it can't parse (e.g. `inline_data`,
    /// `metadata_csum`).
    static let supportedIncompat: UInt32 =
        0x0002  // FILETYPE (dirent contains file type)
        | 0x0040  // EXTENTS
        | 0x0080  // 64BIT
        | 0x0200  // FLEX_BG
        | 0x0010  // META_BG

    var unsupportedIncompatBits: UInt32 {
        featureIncompat & ~Self.supportedIncompat
    }
}
