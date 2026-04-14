//
//  Ext4KitExtension.swift
//  Ext4KitExtension
//
//  Created by Ray Arayilakath on 4/13/26.
//

import ExtensionFoundation
import Foundation
import FSKit

@main
struct Ext4KitExtension : UnaryFileSystemExtension {
    var fileSystem : FSUnaryFileSystem & FSUnaryFileSystemOperations {
        Ext4KitExtensionFileSystem()
    }
}
