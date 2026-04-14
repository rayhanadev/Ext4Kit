//
//  Ext4KitExtensionFileSystem.swift
//  Ext4KitExtension
//
//  Created by Ray Arayilakath on 4/13/26.
//

import Foundation
import FSKit

@objc
class Ext4KitExtensionFileSystem : FSUnaryFileSystem & FSUnaryFileSystemOperations {
    func probeResource(resource: FSResource, replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        replyHandler(.notRecognized, nil)
    }
    
    func loadResource(resource: FSResource, options: FSTaskOptions, replyHandler: @escaping (FSVolume?, (any Error)?) -> Void) {
        replyHandler(FSVolume(volumeID: .init(uuid: UUID()), volumeName: FSFileName(string: "My Volume")), nil)
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions) async throws {
    }
}
