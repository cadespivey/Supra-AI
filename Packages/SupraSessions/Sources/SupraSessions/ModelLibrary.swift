import Combine
import Foundation
import SupraCore
import SupraRuntimeClient
import SupraRuntimeInterface
import SupraStore

/// Manages registered local model folders, task-route assignments, and runtime
/// model loading.
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
    @Published public private(set) var roleAssignments: ModelRoleAssignments

    private let store: SupraStore
    private let runtimeClient: any RuntimeClientProtocol
    private var hasPersistedRoleAssignments: Bool

    public init(store: SupraStore, runtimeClient: any RuntimeClientProtocol) {
        self.store = store
        self.runtimeClient = runtimeClient
        if let stored = try? store.appSettings.getSetting(
            ModelRoleAssignments.settingsKey,
            as: ModelRoleAssignments.self
        ) {
            self.roleAssignments = stored
            self.hasPersistedRoleAssignments = true
        } else {
            self.roleAssignments = ModelRoleAssignments()
            self.hasPersistedRoleAssignments = false
        }
    }

    /// The startup/manual model, if one is registered as active.
    public var activeModel: ModelSummary? {
        models.first { $0.isActive }
    }

    /// The strongly typed id of the loaded model once `loadState` is `.loaded`.
    public var loadedModelID: ModelID? {
        guard case let .loaded(modelID) = loadState else { return nil }
        return UUID(uuidString: modelID).map(ModelID.init)
    }

    /// The model the runtime currently holds (per `loadState`). May differ from
    /// `activeModel` after reconciling a still-warm runtime, so status UI should
    /// prefer this over `activeModel` to name what is actually loaded.
    public var loadedModel: ModelSummary? {
        guard case let .loaded(modelID) = loadState else { return nil }
        return models.first { $0.id == modelID }
    }

    public func preferredModelID(
        for role: ModelRole,
        configuration: LegalModelConfiguration = .fromEnvironment()
    ) -> ModelID? {
        return resolvedModel(for: role, configuration: configuration)
            .flatMap { UUID(uuidString: $0.id).map(ModelID.init) }
    }

    public func ensureLoadedModelID(
        for role: ModelRole,
        configuration: LegalModelConfiguration = .fromEnvironment()
    ) async -> ModelID? {
        switch await ensureLoadedRoutedModelID(for: role, configuration: configuration) {
        case let .success(modelID):
            modelID
        case .failure:
            nil
        }
    }

    public func ensureLoadedRoutedModelID(
        for role: ModelRole,
        configuration: LegalModelConfiguration = .fromEnvironment()
    ) async -> Result<ModelID, ModelRouteResolutionIssue> {
        refresh()
        let resolution = resolvedModelWithIssue(for: role, configuration: configuration)
        guard let preferred = resolution.model else {
            return .failure(resolution.issue ?? .roleUnassigned(
                role: role,
                configuredIdentifier: configuration.modelIdentifier(for: role)
            ))
        }
        guard let uuid = UUID(uuidString: preferred.id) else {
            return .failure(.assignedModelMissing(role: role, modelID: preferred.id))
        }
        if loadedModelID?.rawValue == uuid {
            return .success(ModelID(uuid))
        }

        await activateAndLoad(modelID: preferred.id)
        if loadedModelID?.rawValue == uuid {
            return .success(ModelID(uuid))
        }
        let message: String
        if case let .failed(failureMessage) = loadState {
            message = failureMessage
        } else {
            message = "The runtime did not confirm that the assigned model is loaded."
        }
        return .failure(.assignedModelLoadFailed(
            role: role,
            displayName: preferred.displayName,
            message: message
        ))
    }

    public func resolvedModel(
        for role: ModelRole,
        configuration: LegalModelConfiguration = .fromEnvironment()
    ) -> ModelSummary? {
        resolvedModelWithIssue(for: role, configuration: configuration).model
    }

    public func assignModel(_ modelID: String?, to role: ModelRole) {
        var updated = roleAssignments
        updated.setModelID(modelID, for: role)
        roleAssignments = updated
        hasPersistedRoleAssignments = true
        persistRoleAssignments()
    }

    /// Reloads the registered models from the store.
    public func refresh() {
        models = (try? store.models.fetchModels())?.map(ModelSummary.init) ?? []
        bootstrapRoleAssignmentsIfNeeded(configuration: .fromEnvironment())
    }

    /// Reconciles the published load state with a model the runtime already holds
    /// from a previous session, so chat is enabled on launch without a manual
    /// re-load. No-op unless we're idle and the id matches a registered model.
    public func reconcileLoadedModel(_ runtimeModelID: ModelID?) {
        guard case .idle = loadState, let runtimeModelID else { return }
        let idString = runtimeModelID.rawValue.uuidString
        guard (try? store.models.fetchModel(id: idString)) != nil else { return }
        loadState = .loaded(modelID: idString)
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
        // Ignore overlapping loads so concurrent taps cannot leave the published
        // load state and the runtime out of sync.
        if case .loading = loadState { return }

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

        // Resolve a transferable bookmark so the sandboxed runtime service can
        // read the model directory. Hold any security scope until the load RPC
        // returns (the multi-GB read happens service-side during that call).
        var scopedAccess: SecurityScopedModelAccess?
        defer { scopedAccess?.release() }

        let modelBookmark: Data?
        if record.bookmarkData != nil {
            // User-selected folder: hold the app's own access while minting.
            let access = SecurityScopedModelAccess(bookmarkData: record.bookmarkData)
            scopedAccess = access

            guard access.hasAccess else {
                loadState = .failed(message: "Could not access the model folder. Re-add it from the Models tab.")
                return
            }
            // Refresh a stale bookmark so access survives future launches.
            if access.isStale, let refreshed = access.makePersistentBookmark() {
                var updated = record
                updated.bookmarkData = refreshed
                try? store.models.upsertModel(updated)
                refresh()
            }
            modelBookmark = access.makeTransferableBookmark()
        } else if ManagedModelStorage.isManaged(path: record.path) {
            // App-downloaded model: the app owns the files, so it can mint a plain
            // transferable bookmark directly without a security scope.
            guard let managedBookmark = try? URL(fileURLWithPath: record.path, isDirectory: true)
                .bookmarkData(options: []) else {
                loadState = .failed(message: "The downloaded model files could not be found. Re-download the model.")
                return
            }
            modelBookmark = managedBookmark
        } else {
            // No bookmark available; only readable if the service is unsandboxed.
            modelBookmark = nil
        }

        let request = LoadModelRequest(
            modelID: ModelID(uuid),
            modelPath: record.path,
            displayName: record.displayName,
            modelBookmark: modelBookmark
        )

        do {
            let response = try await runtimeClient.loadModel(request)
            switch response.status {
            case .loaded:
                loadState = .loaded(modelID: record.id)
            case .failed:
                loadState = .failed(message: Self.failureMessage(response.error))
            }
        } catch {
            loadState = .failed(message: error.localizedDescription)
        }
    }

    /// Surfaces the runtime's technical detail (the real cause) alongside the
    /// top-line message, so a failed load explains itself.
    private static func failureMessage(_ error: RuntimeError?) -> String {
        guard let error else { return "The model could not be loaded." }
        if let details = error.technicalDetails, !details.isEmpty {
            return "\(error.message) — \(redactingAbsolutePaths(details))"
        }
        return error.message
    }

    /// Redacts filesystem paths from user-facing failure text: the home directory
    /// is replaced with `~` (so even a bare `/Users/<name>` reveals no username),
    /// and any other absolute path is shortened to its final component. URLs
    /// (anything containing `://`, e.g. a Hugging Face link) are left intact.
    private static func redactingAbsolutePaths(_ text: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return text
            .split(separator: " ", omittingEmptySubsequences: false)
            .map { token -> String in
                var value = String(token)
                // Always collapse the home directory first, so the username never
                // leaks even inside a file:// URL.
                if !home.isEmpty, value.contains(home) {
                    value = value.replacingOccurrences(of: home, with: "~")
                }
                // Preserve web links intact; only shorten bare absolute paths.
                if value.contains("://") { return value }
                if value.hasPrefix("/"), value.dropFirst().contains("/") {
                    value = "…/" + (value as NSString).lastPathComponent
                }
                return value
            }
            .joined(separator: " ")
    }

    private func matchingModel(forIdentifier identifier: String) -> ModelSummary? {
        let target = Self.normalizedModelIdentifier(identifier)
        guard !target.isEmpty else { return nil }

        return models.first { model in
            let candidates = [
                model.displayName,
                model.path,
                URL(fileURLWithPath: model.path).lastPathComponent,
                model.path.replacingOccurrences(of: "__", with: "/")
            ]
            return candidates.contains {
                let normalized = Self.normalizedModelIdentifier($0)
                return normalized == target
                    || normalized.contains(target)
                    || target.contains(normalized)
            }
        }
    }

    private static func normalizedModelIdentifier(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "mlx-community/", with: "")
            .replacingOccurrences(of: "-mlx", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    private func resolvedModelWithIssue(
        for role: ModelRole,
        configuration: LegalModelConfiguration
    ) -> (model: ModelSummary?, issue: ModelRouteResolutionIssue?) {
        guard !models.isEmpty else {
            return (nil, .noRegisteredModels(role: role))
        }

        if let assignedModelID = roleAssignments.modelID(for: role) {
            if let model = models.first(where: { $0.id == assignedModelID }) {
                return (model, nil)
            }
            return (nil, .assignedModelMissing(role: role, modelID: assignedModelID))
        }

        let configuredIdentifier = configuration.modelIdentifier(for: role)
        if let configured = matchingModel(forIdentifier: configuredIdentifier) {
            return (configured, nil)
        }
        return (nil, .roleUnassigned(role: role, configuredIdentifier: configuredIdentifier))
    }

    private func bootstrapRoleAssignmentsIfNeeded(configuration: LegalModelConfiguration) {
        guard !hasPersistedRoleAssignments else { return }
        var updated = roleAssignments
        // Cross-role uniqueness: fuzzy identifier matching means one generic-named
        // model could match several role identifiers. Don't let auto-bootstrap fill
        // multiple distinct roles with the same model — the user can still assign it
        // to additional roles manually if they intend to share it.
        var assignedModelIDs = Set(ModelRole.allCases.compactMap { updated.modelID(for: $0) })
        for role in ModelRole.allCases where updated.modelID(for: role) == nil {
            if let model = matchingModel(forIdentifier: configuration.modelIdentifier(for: role)),
               !assignedModelIDs.contains(model.id) {
                updated.setModelID(model.id, for: role)
                assignedModelIDs.insert(model.id)
            }
        }
        guard updated != roleAssignments else { return }
        roleAssignments = updated
        hasPersistedRoleAssignments = true
        persistRoleAssignments()
    }

    private func persistRoleAssignments() {
        try? store.appSettings.setSetting(ModelRoleAssignments.settingsKey, value: roleAssignments)
    }
}
