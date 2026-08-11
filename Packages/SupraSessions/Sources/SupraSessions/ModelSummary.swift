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
    /// Repository identity read from a structurally valid manifest inside an
    /// app-configured managed root. Presentation metadata only; it does not prove
    /// artifact bytes or authorize a runtime load.
    public var managedRepositoryID: String?

    public init(
        id: String,
        displayName: String,
        path: String,
        isActive: Bool,
        validationStatus: String?,
        managedRepositoryID: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.path = path
        self.isActive = isActive
        self.validationStatus = validationStatus
        self.managedRepositoryID = managedRepositoryID
    }

    init(record: ModelRecord, managedRepositoryID: String? = nil) {
        self.init(
            id: record.id,
            displayName: record.displayName,
            path: record.path,
            isActive: record.isActive,
            validationStatus: record.validationStatus,
            managedRepositoryID: managedRepositoryID
        )
    }

    /// The strongly typed runtime identifier, or `nil` if the stored id is not a UUID.
    public var modelID: ModelID? {
        UUID(uuidString: id).map(ModelID.init)
    }
}
