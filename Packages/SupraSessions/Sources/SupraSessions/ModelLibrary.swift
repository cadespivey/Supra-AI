import Combine
import Foundation
import SupraCore
import SupraRuntimeClient
import SupraRuntimeInterface
import SupraStore

/// Manages the user's registered local model folders and drives loading the
/// active model into the runtime service.
///
/// All state is published on the main actor for SwiftUI. The orchestration is
/// kept here (rather than in the app target) so it can be unit-tested against a
/// stub `RuntimeClientProtocol` and an in-memory `SupraStore`.
@MainActor
public final class ModelLibrary: ObservableObject {
    public enum LoadState: Equatable, Sendable {
        case idle
        case loading(modelID: String)
        case loaded(modelID: String)
        case failed(message: String)
    }

    @Published public private(set) var models: [ModelSummary] = []
    @Published public private(set) var loadState: LoadState = .idle

    private let store: SupraStore
    private let runtimeClient: any RuntimeClientProtocol

    public init(store: SupraStore, runtimeClient: any RuntimeClientProtocol) {
        self.store = store
        self.runtimeClient = runtimeClient
    }

    /// The currently active model, if one is registered as active.
    public var activeModel: ModelSummary? {
        models.first { $0.isActive }
    }

    /// The strongly typed id of the loaded model once `loadState` is `.loaded`.
    public var loadedModelID: ModelID? {
        guard case let .loaded(modelID) = loadState else { return nil }
        return UUID(uuidString: modelID).map(ModelID.init)
    }

    /// Reloads the registered models from the store.
    public func refresh() {
        models = (try? store.models.fetchModels())?.map(ModelSummary.init) ?? []
    }

    /// Registers a newly selected model folder and returns its summary.
    @discardableResult
    public func addModel(displayName: String, path: String, bookmarkData: Data?) throws -> ModelSummary {
        let modelID = ModelID()
        let record = ModelRecord(
            id: modelID.rawValue.uuidString,
            displayName: displayName,
            path: path,
            bookmarkData: bookmarkData
        )
        try store.models.upsertModel(record)
        refresh()
        return ModelSummary(record: record)
    }

    /// Marks the given model active in the store and loads it into the runtime service.
    public func activateAndLoad(modelID modelIDString: String) async {
        guard
            let record = try? store.models.fetchModel(id: modelIDString),
            let uuid = UUID(uuidString: record.id)
        else {
            loadState = .failed(message: "The selected model could not be found.")
            return
        }

        do {
            try store.models.setActiveModel(id: record.id)
        } catch {
            loadState = .failed(message: error.localizedDescription)
            return
        }
        refresh()

        loadState = .loading(modelID: record.id)

        let request = LoadModelRequest(
            modelID: ModelID(uuid),
            modelPath: record.path,
            displayName: record.displayName
        )

        do {
            let response = try await runtimeClient.loadModel(request)
            switch response.status {
            case .loaded:
                loadState = .loaded(modelID: record.id)
            case .failed:
                loadState = .failed(message: response.error?.message ?? "The model could not be loaded.")
            }
        } catch {
            loadState = .failed(message: error.localizedDescription)
        }
    }
}
