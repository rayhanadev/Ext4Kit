import Foundation

/// Minimal ext4 superblock parser. Only the fields needed for probe and the
/// mount-time safety checks.
/// See: https://ext4.wiki.kernel.org/index.php/Ext4_Disk_Layout
struct Ext4Superblock {
    static let onDiskOffset: off_t = 1024
    static let size: Int = 1024
    static let magic: UInt16 = 0xEF53

    /// INCOMPAT csum_seed: the metadata checksum seed is stored in
    /// `s_checksum_seed` rather than derived from the UUID. e2fsprogs 1.47
    /// sets this alongside `metadata_csum` by default.
    static let incompatCsumSeed: UInt32 = 0x2000

    /// RO_COMPAT metadata_csum: the volume carries CRC32C checksums on its
    /// metadata. Without it, the csum_seed is moot — there's nothing to seed.
    static let roCompatMetadataCsum: UInt32 = 0x400

    // Byte offsets within the superblock structure
    private enum Offset {
        static let sState = 58  // __le16, EXT4_VALID_FS = 0x0001
        static let sMagic = 56  // __le16
        static let sUUID = 104  // 16 bytes
        static let sVolumeName = 120  // 16 bytes, NUL-padded
        static let sFeatureCompat = 92  // __le32
        static let sFeatureIncompat = 96  // __le32
        static let sFeatureROCompat = 100  // __le32
        static let sChecksumSeed = 0x270  // __le32 (s_checksum_seed)
    }

    let magic: UInt16
    let state: UInt16
    let uuid: UUID
    let uuidBytes: [UInt8]
    let volumeName: String
    let featureCompat: UInt32
    let featureIncompat: UInt32
    let featureROCompat: UInt32
    let checksumSeed: UInt32

    init?(_ buf: UnsafeRawPointer) {
        let magic = buf.load(fromByteOffset: Offset.sMagic, as: UInt16.self).littleEndian
        guard magic == Self.magic else { return nil }
        self.magic = magic
        self.state = buf.load(fromByteOffset: Offset.sState, as: UInt16.self).littleEndian

        var uuidBytes = [UInt8](repeating: 0, count: 16)
        uuidBytes.withUnsafeMutableBufferPointer { dst in
            _ = memcpy(dst.baseAddress!, buf.advanced(by: Offset.sUUID), 16)
        }
        self.uuidBytes = uuidBytes
        self.uuid = NSUUID(uuidBytes: uuidBytes) as UUID

        let nameBytes = Data(bytes: buf.advanced(by: Offset.sVolumeName), count: 16)
        let trimmed = nameBytes.prefix(while: { $0 != 0 })
        self.volumeName = String(data: trimmed, encoding: .utf8) ?? ""

        self.featureCompat = buf.load(fromByteOffset: Offset.sFeatureCompat, as: UInt32.self).littleEndian
        self.featureIncompat = buf.load(fromByteOffset: Offset.sFeatureIncompat, as: UInt32.self).littleEndian
        self.featureROCompat = buf.load(fromByteOffset: Offset.sFeatureROCompat, as: UInt32.self).littleEndian
        self.checksumSeed = buf.load(fromByteOffset: Offset.sChecksumSeed, as: UInt32.self).littleEndian
    }

    /// Incompat feature bits the probe side recognizes. A set bit outside
    /// this mask is logged as a warning during probe but isn't fatal; the
    /// actual rejection happens later when lwext4's `ext4_mount` refuses to
    /// load a filesystem whose features it can't parse (e.g. `inline_data`).
    static let supportedIncompat: UInt32 =
        0x0002  // FILETYPE (dirent contains file type)
        | 0x0040  // EXTENTS
        | 0x0080  // 64BIT
        | 0x0200  // FLEX_BG
        | 0x0010  // META_BG
        | incompatCsumSeed

    var unsupportedIncompatBits: UInt32 {
        featureIncompat & ~Self.supportedIncompat
    }

    /// lwext4 maintains every metadata_csum checksum on write (group
    /// descriptors, inodes, directory tails, extent blocks, bitmaps,
    /// superblock) but always derives the seed as crc32c(~0, uuid) — it
    /// never reads `s_checksum_seed`. That only causes wrong checksums when a
    /// volume BOTH carries metadata checksums (`metadata_csum`) AND stores an
    /// independent seed (`csum_seed`) that disagrees with crc32c(uuid) — e.g.
    /// a volume whose UUID was changed after format (`tune2fs -U` keeps the
    /// old seed and sets the csum_seed bit). Only then must we mount
    /// read-only.
    ///
    /// A volume with the csum_seed bit but no `metadata_csum` (which lwext4's
    /// own mkfs produces) has no checksums to mis-seed, so it stays writable.
    /// Without that guard, every `newfs_fskit`-formatted volume would wrongly
    /// mount read-only.
    var hasMismatchedChecksumSeed: Bool {
        guard featureROCompat & Self.roCompatMetadataCsum != 0,
            featureIncompat & Self.incompatCsumSeed != 0
        else { return false }
        let uuidSeed = uuidBytes.withUnsafeBufferPointer { buf in
            ext4_crc32c(0xFFFF_FFFF, buf.baseAddress, UInt32(buf.count))
        }
        return checksumSeed != uuidSeed
    }
}
