import ExtensionFoundation
import FSKit

@main
struct ExtensionMain: UnaryFileSystemExtension {
    var fileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations {
        Ext4FileSystem()
    }
}
