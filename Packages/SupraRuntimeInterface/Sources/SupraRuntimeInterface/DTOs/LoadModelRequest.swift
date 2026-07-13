import Foundation
import SupraCore

public struct LoadModelRequest: Codable, Sendable {
    public let modelID: ModelID
    public let modelPath: String
    public let displayName: String
    /// A plain (non-security-scoped) bookmark of the model directory, minted by
    /// the app while it holds its own access. Resolving it in the sandboxed
    /// runtime service transfers read access to the directory without granting
    /// the service any file-access entitlement. Nil is representable for
    /// decoding/backward compatibility but is rejected by the service.
    public let modelBookmark: Data?

    /// Canonical app-managed root for downloaded models. When present, the XPC
    /// service requires the resolved bookmark target to remain inside this root
    /// after standardization and symlink resolution. User-selected folders leave
    /// this nil and are authorized solely by their transferable bookmark.
    public let managedRootPath: String?

    public init(
        modelID: ModelID,
        modelPath: String,
        displayName: String,
        modelBookmark: Data? = nil,
        managedRootPath: String? = nil
    ) {
        self.modelID = modelID
        self.modelPath = modelPath
        self.displayName = displayName
        self.modelBookmark = modelBookmark
        self.managedRootPath = managedRootPath
    }
}
