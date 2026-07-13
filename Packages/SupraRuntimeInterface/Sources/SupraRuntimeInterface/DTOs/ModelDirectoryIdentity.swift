import Foundation

/// Pins a model-load authorization to one concrete filesystem object.
///
/// A transferable bookmark resolved by a differently signed XPC service can
/// report `bookmarkDataIsStale` even when it still resolves the original object.
/// Device and inode let the app and service distinguish that signer-induced
/// condition from a directory deleted and replaced at the same canonical path.
public struct ModelDirectoryIdentity: Codable, Equatable, Sendable {
    public let deviceID: UInt64
    public let inode: UInt64

    public init(deviceID: UInt64, inode: UInt64) {
        self.deviceID = deviceID
        self.inode = inode
    }

    public init?(url: URL, fileManager: FileManager = .default) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            return nil
        }
        self.init(deviceID: device.uint64Value, inode: inode.uint64Value)
    }
}
