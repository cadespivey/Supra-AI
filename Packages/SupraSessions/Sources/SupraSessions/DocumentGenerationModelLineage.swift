import Foundation
import SupraCore
import SupraStore

/// Stable identity for the model artifacts that produced a saved document
/// output. This is intentionally independent from the runtime's per-load UUID.
public struct DocumentGenerationModelLineage: Codable, Equatable, Sendable {
    public var modelRepository: String
    public var modelRevision: String

    public init(modelRepository: String, modelRevision: String) {
        self.modelRepository = modelRepository
        self.modelRevision = modelRevision
    }

    private enum CodingKeys: String, CodingKey {
        case modelRepository = "model_repository"
        case modelRevision = "model_revision"
    }

    static func decode(json: String?) -> Self? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    static func resolve(modelID: ModelID, store: SupraStore) -> Self? {
        guard let record = try? store.models.fetchModel(id: modelID.rawValue.uuidString),
              let manifest = try? ManagedModelStorage.loadVerifiedManifest(
                  at: URL(fileURLWithPath: record.path, isDirectory: true)
              ) else {
            return nil
        }
        return Self(
            modelRepository: manifest.repositoryID,
            modelRevision: manifest.revision
        )
    }
}

public enum DocumentGenerationLineageError: LocalizedError, Equatable {
    case stableModelIdentityUnavailable

    public var errorDescription: String? {
        "The selected model does not expose a verified repository and revision, so the document output was not saved."
    }
}
