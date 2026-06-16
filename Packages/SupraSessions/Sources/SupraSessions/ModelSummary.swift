import Foundation
import SupraCore
import SupraStore

/// A view-facing snapshot of a registered local model.
///
/// Decouples SwiftUI from the GRDB `ModelRecord` so the controllers can publish
/// immutable value types instead of leaking persistence records into the view layer.
public struct ModelSummary: Identifiable, Sendable, Equatable {
    public let id: String
    public var displayName: String
    public var path: String
    public var isActive: Bool
    public var validationStatus: String?

    public init(
        id: String,
        displayName: String,
        path: String,
        isActive: Bool,
        validationStatus: String?
    ) {
        self.id = id
        self.displayName = displayName
        self.path = path
        self.isActive = isActive
        self.validationStatus = validationStatus
    }

    init(record: ModelRecord) {
        self.init(
            id: record.id,
            displayName: record.displayName,
            path: record.path,
            isActive: record.isActive,
            validationStatus: record.validationStatus
        )
    }

    /// The strongly typed runtime identifier, or `nil` if the stored id is not a UUID.
    public var modelID: ModelID? {
        UUID(uuidString: id).map(ModelID.init)
    }
}
