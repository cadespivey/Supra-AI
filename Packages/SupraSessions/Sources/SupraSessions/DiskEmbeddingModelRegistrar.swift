import Foundation
import SupraStore

/// Failure modes for reconstructing the exact embedding-model row used by an
/// isolated headless control. The registrar never guesses another repository.
public enum DiskEmbeddingModelRegistrationError: Error, Equatable, Sendable {
    case verifiedArtifactNotFound(String)
    case invalidConfiguration(String)
}

/// Rebuilds one embedding-model registry row from verified disk truth without
/// opening the user's Store. Unlike a normal setup flow, registration alone does
/// not select the model or claim that the runtime loaded it successfully. The
/// headless control must first execute a real embedding request and only then
/// stamp its throwaway Store as verified/selected.
public enum DiskEmbeddingModelRegistrar {
    @discardableResult
    public static func registerVerifiedModel(
        into store: SupraStore,
        root: URL,
        repositoryID: String,
        fileManager: FileManager = .default
    ) throws -> DocumentEmbeddingModelRecord {
        let folders = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let manifest = try? ManagedModelStorage.loadVerifiedManifest(at: folder),
                  manifest.repositoryID == repositoryID else { continue }
            let configuration = try configuration(at: folder, repositoryID: repositoryID)
            _ = try store.documentSettings.loadSettings()
            let existing = try store.documentSettings.fetchEmbeddingModels()
                .first { $0.repoID == repositoryID }
            let record = DocumentEmbeddingModelRecord(
                id: existing?.id ?? UUID().uuidString,
                repoID: repositoryID,
                localPath: folder.path,
                displayName: repositoryID,
                dimension: configuration.dimension,
                runtimeFamily: configuration.runtimeFamily,
                revision: manifest.revision,
                isDefault: false,
                isSelected: false,
                lastTestLoadAt: nil,
                lastTestLoadResult: nil,
                createdAt: existing?.createdAt ?? Date(),
                updatedAt: Date()
            )
            try store.documentSettings.upsertEmbeddingModel(record)
            return record
        }
        throw DiskEmbeddingModelRegistrationError.verifiedArtifactNotFound(repositoryID)
    }

    private static func configuration(
        at modelDirectory: URL,
        repositoryID: String
    ) throws -> (dimension: Int, runtimeFamily: String) {
        let url = modelDirectory.appendingPathComponent("config.json", isDirectory: false)
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelType = object["model_type"] as? String,
              !modelType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DiskEmbeddingModelRegistrationError.invalidConfiguration(repositoryID)
        }
        let nested = object["text_config"] as? [String: Any]
        let dimension = (object["hidden_size"] as? NSNumber)?.intValue
            ?? (nested?["hidden_size"] as? NSNumber)?.intValue
        guard let dimension, dimension > 0 else {
            throw DiskEmbeddingModelRegistrationError.invalidConfiguration(repositoryID)
        }
        return (dimension, modelType)
    }
}
