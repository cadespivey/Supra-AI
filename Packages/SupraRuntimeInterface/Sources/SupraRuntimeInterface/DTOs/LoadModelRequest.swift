import Foundation
import SupraCore

public struct LoadModelRequest: Codable, Sendable {
    public let modelID: ModelID
    public let modelPath: String
    public let displayName: String
    /// A plain (non-security-scoped) bookmark of the model directory, minted by
    /// the app while it holds its own access. Resolving it in the sandboxed
    /// runtime service transfers read access to the directory without granting
    /// the service any file-access entitlement. `nil` when no bookmark is
    /// available (e.g. an unsandboxed service reads `modelPath` directly).
    public let modelBookmark: Data?

    public init(modelID: ModelID, modelPath: String, displayName: String, modelBookmark: Data? = nil) {
        self.modelID = modelID
        self.modelPath = modelPath
        self.displayName = displayName
        self.modelBookmark = modelBookmark
    }
}
