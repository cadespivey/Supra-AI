import Combine
import Foundation
import SupraCore
import SupraDocuments
import SupraRuntimeClient
import SupraRuntimeInterface
import SupraStore

/// Orchestrates app-wide Document Intelligence setup (plan §2): chat-model
/// readiness, embedding-model selection/test-load, converter/OCR capability
/// checks, managed-storage initialization, and notification permission. Persists
/// state in `document_intelligence_settings` and gates document import until
/// setup is complete.
@MainActor
public final class DocumentIntelligenceSetupController: ObservableObject {
    @Published public private(set) var settings: DocumentIntelligenceSettingsRecord
    @Published public private(set) var availableEmbeddingModels: [DocumentEmbeddingModelRecord] = []
    @Published public private(set) var selectedEmbeddingModel: DocumentEmbeddingModelRecord?
    @Published public private(set) var chatModelLoaded = false
    @Published public private(set) var toolchain: DocumentToolchainCapabilities?
    @Published public private(set) var storageInitialized = false
    @Published public private(set) var notificationStatus: DocumentNotificationAuthorizationStatus = .unknown
    @Published public private(set) var embeddingTestPassed = false
    /// True only while an embedding model is being auto-verified (loaded into the
    /// runtime to confirm it works). Distinct from `isBusy` so the Models-tab verify
    /// spinner doesn't couple to the broader Settings refresh state.
    @Published public private(set) var embeddingVerifyInFlight = false
    @Published public private(set) var isBusy = false
    @Published public private(set) var message: String?
    /// Days before soft-deleted documents are auto-purged (0 disables). Plan §12.2.
    @Published public private(set) var autoPurgeDays: Int = DocumentMaintenance.defaultAutoPurgeDays

    private let store: SupraStore
    private let runtimeClient: any ModelExecutionGateway
    private var modelExecutionGateway: any ModelExecutionGateway { runtimeClient }
    private let notifier: any DocumentNotifying
    private let storage: DocumentStorage
    private let capabilitiesProvider: @Sendable () -> DocumentToolchainCapabilities
    private var reindexEnqueuer: (@MainActor @Sendable (String) -> Void)?

    public init(
        store: SupraStore,
        runtimeClient: any ModelExecutionGateway,
        notifier: any DocumentNotifying = SystemDocumentNotifier(),
        storage: DocumentStorage = .makeDefault(),
        capabilitiesProvider: @escaping @Sendable () -> DocumentToolchainCapabilities = { DocumentToolchain.detectCapabilities() }
    ) {
        self.store = store
        self.runtimeClient = runtimeClient
        self.notifier = notifier
        self.storage = storage
        self.capabilitiesProvider = capabilitiesProvider
        self.settings = (try? store.documentSettings.loadSettings()) ?? DocumentIntelligenceSettingsRecord()
        self.autoPurgeDays = (try? store.appSettings.getSetting(DocumentMaintenance.autoPurgeDaysKey, as: Int.self)) ?? DocumentMaintenance.defaultAutoPurgeDays
        reloadLocalState()
    }

    /// Updates the trash auto-purge retention (days; 0 disables).
    public func updateAutoPurgeDays(_ days: Int) {
        let clamped = max(0, days)
        autoPurgeDays = clamped
        try? store.appSettings.setSetting(DocumentMaintenance.autoPurgeDaysKey, value: clamped)
    }

    // MARK: - Derived gating

    /// True when every required setup check currently passes. The completion
    /// timestamp is stamped automatically when this first becomes true.
    public var isComplete: Bool {
        canCompleteSetup && settings.setupInvalidatedReason == nil
    }

    public var isReadyForImport: Bool { isComplete }

    /// True when a runtime chat model is loaded right now or has successfully
    /// loaded at least once before. The setup step stays satisfied (green) after
    /// the runtime unloads the model, since loading proved it works.
    public var chatModelReady: Bool {
        chatModelLoaded || settings.chatModelLastLoadedAt != nil
    }

    /// True when every required setup step passes.
    public var canCompleteSetup: Bool {
        completedRequiredStepCount == requiredStepCount
    }

    public var requiredStepCount: Int { 4 }

    public var completedRequiredStepCount: Int {
        [
            chatModelReady,
            selectedEmbeddingModel != nil && embeddingTestPassed,
            toolchain?.meetsMinimumForSetup ?? false,
            storageInitialized
        ].filter { $0 }.count
    }

    /// Human-readable list of required steps still outstanding, for the setup UI.
    public var requiredOutstandingSteps: [String] {
        var steps: [String] = []
        if !chatModelReady { steps.append("Load a runtime text model in the Models tab.") }
        if selectedEmbeddingModel == nil { steps.append("Download and select an embedding model.") }
        else if !embeddingTestPassed {
            steps.append(embeddingVerifyInFlight
                ? "Verifying the selected embedding model…"
                : "The selected embedding model failed to verify — pick another.")
        }
        if !(toolchain?.meetsMinimumForSetup ?? false) { steps.append("Confirm the local extraction/OCR toolchain.") }
        if !storageInitialized { steps.append("Initialize document storage.") }
        return steps
    }

    public var optionalOutstandingSteps: [String] {
        var steps: [String] = []
        if notificationStatus == .notDetermined { steps.append("Allow completion notifications (optional).") }
        return steps
    }

    /// Human-readable list of all remaining setup notes, required first.
    public var outstandingSteps: [String] {
        requiredOutstandingSteps + optionalOutstandingSteps
    }

    // MARK: - Refresh

    /// Reloads persisted state and re-runs all live capability/status checks.
    public func refreshAll() async {
        isBusy = true
        defer { isBusy = false }
        reloadSettings()
        await refreshChatModelStatus()
        refreshToolchain()
        refreshStorage()
        await refreshNotificationStatus()
        reloadLocalState()
    }

    public func refreshChatModelStatus() async {
        guard let status = try? await modelExecutionGateway.runtimeStatus() else {
            chatModelLoaded = false
            syncCompletionStateIfNeeded()
            return
        }
        chatModelLoaded = status.loadedModelID != nil
        if chatModelLoaded {
            settings = (try? store.documentSettings.updateSettings { settings in
                settings.selectedChatModelID = status.loadedModelID?.rawValue.uuidString
                settings.chatModelLastLoadedAt = Date()
            }) ?? settings
        }
        syncCompletionStateIfNeeded()
    }

    /// Detects and persists the local extraction/OCR toolchain capabilities.
    @discardableResult
    public func refreshToolchain() -> DocumentToolchainCapabilities {
        let capabilities = capabilitiesProvider()
        let priorVersion = settings.converterToolchainVersion
        toolchain = capabilities
        if let priorVersion, priorVersion != capabilities.version {
            markConverterLineageStale(from: priorVersion, to: capabilities.version)
        }
        let json = try? JSONEncoder().encode(capabilities)
        settings = (try? store.documentSettings.updateSettings { settings in
            settings.converterToolchainVersion = capabilities.version
            settings.ocrAvailable = capabilities.ocr
            settings.ocrCheckedAt = Date()
            settings.converterCapabilityJSON = json.flatMap { String(data: $0, encoding: .utf8) }
        }) ?? settings
        syncCompletionStateIfNeeded()
        return capabilities
    }

    public func refreshStorage() {
        storageInitialized = storage.isInitialized()
        syncCompletionStateIfNeeded()
    }

    public func refreshNotificationStatus() async {
        notificationStatus = await notifier.authorizationStatus()
    }

    // MARK: - Actions

    /// Connects model-selection changes to the app-wide FIFO queue. Kept as a
    /// post-init seam because the queue owns the import service while the setup
    /// controller must exist first during app composition.
    public func setReindexEnqueuer(
        _ enqueuer: @escaping @MainActor @Sendable (String) -> Void
    ) {
        reindexEnqueuer = enqueuer
    }

    /// Creates the managed storage layout and records initialization.
    public func initializeStorage() {
        do {
            try storage.initializeStorage()
            storageInitialized = true
            settings = (try? store.documentSettings.updateSettings { $0.storageInitializedAt = Date() }) ?? settings
            syncCompletionStateIfNeeded()
        } catch {
            message = "Could not initialize document storage: \(error.localizedDescription)"
        }
    }

    public func requestNotificationPermission() async {
        let status = await notifier.requestAuthorization()
        notificationStatus = status
        settings = (try? store.documentSettings.updateSettings { $0.notificationPermissionStatus = status.rawValue }) ?? settings
    }

    public func selectEmbeddingModel(id: String) {
        let previousID = settings.selectedEmbeddingModelID
        let previousModel = previousID.flatMap { try? store.documentSettings.fetchEmbeddingModel(id: $0) }
        do {
            guard let nextModel = try store.documentSettings.fetchEmbeddingModel(id: id) else {
                throw DocumentReadinessTransitionError.modelNotFound(id)
            }
            guard nextModel.lastTestLoadResult == "passed",
                  let verifiedAt = nextModel.lastTestLoadAt else {
                // An attempted switch to an artifact that has not loaded yet is
                // not an activation. Keep the current verified identity intact,
                // but make the incomplete setup state visible until the caller
                // uses the async verify-and-select action.
                settings = try store.documentSettings.updateSettings {
                    $0.setupCompletedAt = nil
                    $0.setupInvalidatedReason = "embedding model changed"
                }
                // Represent the user's pending choice in the setup surface
                // without publishing it as the Store's active model.
                selectedEmbeddingModel = nextModel
                embeddingTestPassed = false
                message = "Verify this embedding model before selecting it."
                return
            }
            _ = try store.documentSettings.activateVerifiedEmbeddingModel(
                DocumentVerifiedEmbeddingModelSelectionCommand(
                    expectedModel: Self.readinessIdentity(for: nextModel),
                    verifiedAt: verifiedAt,
                    setupInvalidationReason: "embedding model changed"
                )
            )
            reloadSettings()
            reloadLocalState()
            finishEmbeddingModelActivation(
                previousID: previousID,
                previousModel: previousModel,
                nextModel: nextModel
            )
        } catch {
            message = "Could not select the embedding model: \(error.localizedDescription)"
            reloadSettings()
            reloadLocalState()
        }
    }

    /// Selects an embedding model and immediately verifies it loads. Used by the
    /// "Select for use" dropdown so switching the active model re-verifies it
    /// without a separate button.
    public func selectAndVerifyEmbeddingModel(id: String) async {
        await verifyAndActivateEmbeddingModel(id: id)
    }

    /// Called after a download registers a new embedding model. Registration is
    /// deliberately not activation: the exact artifact must load successfully
    /// before the Store may make it active.
    public func handleEmbeddingModelDownloaded(
        modelID: String? = nil,
        selectAfterDownload: Bool = true
    ) {
        reloadSettings()
        reloadLocalState()
        guard selectAfterDownload else { return }
        let candidateID = modelID
            ?? settings.selectedEmbeddingModelID
            ?? availableEmbeddingModels.max(by: { $0.updatedAt < $1.updatedAt })?.id
        guard let candidateID else {
            message = "The downloaded embedding model could not be found."
            return
        }
        Task { await verifyAndActivateEmbeddingModel(id: candidateID) }
    }

    /// Loads the selected embedding model into the runtime to prove it can be
    /// initialized, checking the produced dimension (plan §2.1).
    public func testLoadEmbeddingModel() async {
        guard let selectedID = selectedEmbeddingModel?.id else {
            message = "Select an embedding model first."
            return
        }
        await verifyAndActivateEmbeddingModel(id: selectedID)
    }

    private func verifyAndActivateEmbeddingModel(id: String) async {
        guard let model = try? store.documentSettings.fetchEmbeddingModel(id: id) else {
            message = "The selected embedding model could not be found."
            return
        }
        guard let path = model.localPath, !path.isEmpty else {
            message = "The selected embedding model is not downloaded."
            return
        }
        do {
            try Self.verifyManagedEmbeddingModel(model)
        } catch {
            embeddingTestPassed = false
            message = error.localizedDescription
            try? store.documentSettings.recordTestLoad(modelID: model.id, result: "failed: integrity verification")
            return
        }
        isBusy = true
        embeddingVerifyInFlight = true
        defer {
            isBusy = false
            embeddingVerifyInFlight = false
        }

        let response: LoadEmbeddingModelResponse
        do {
            response = try await loadEmbeddingModel(model)
        } catch {
            embeddingTestPassed = false
            message = error.localizedDescription
            try? store.documentSettings.recordTestLoad(
                modelID: model.id,
                result: "failed: \(error.localizedDescription)"
            )
            reloadSettings()
            reloadLocalState()
            return
        }

        switch response.state {
        case .loaded:
            do {
                var verifiedModel = model
                // Capture the dimension the runtime actually produced for a model
                // registered without one (custom repo), so indexing and the
                // expected-dimension guard work on subsequent loads.
                if model.dimension <= 0, let discovered = response.dimension, discovered > 0,
                   var record = try store.documentSettings.fetchEmbeddingModel(id: model.id) {
                    record.dimension = discovered
                    record.updatedAt = Date()
                    try store.documentSettings.upsertEmbeddingModel(record)
                    verifiedModel = record
                }
                let verifiedAt = Date()
                try store.documentSettings.recordTestLoad(
                    modelID: verifiedModel.id,
                    at: verifiedAt,
                    result: "passed"
                )
                guard let persistedVerifiedModel = try store.documentSettings
                    .fetchEmbeddingModel(id: verifiedModel.id),
                    let persistedVerifiedAt = persistedVerifiedModel.lastTestLoadAt else {
                    throw DocumentReadinessTransitionError.modelNotVerified(
                        verifiedModel.id
                    )
                }
                verifiedModel = persistedVerifiedModel
                let previousID = settings.selectedEmbeddingModelID
                let previousModel = previousID.flatMap {
                    try? store.documentSettings.fetchEmbeddingModel(id: $0)
                }
                _ = try store.documentSettings.activateVerifiedEmbeddingModel(
                    DocumentVerifiedEmbeddingModelSelectionCommand(
                        expectedModel: Self.readinessIdentity(for: verifiedModel),
                        verifiedAt: persistedVerifiedAt,
                        setupInvalidationReason: previousID == verifiedModel.id
                            ? "embedding model verification refreshed"
                            : "embedding model changed"
                    )
                )
                embeddingTestPassed = true
                message = nil
                _ = try? store.auditEvents.recordEvent(
                    eventType: "document_intelligence_setup_changed", actor: "user",
                    summary: "Embedding model \(verifiedModel.displayName) test-loaded",
                    relatedTable: "document_embedding_models", relatedID: verifiedModel.id
                )
                reloadSettings()
                reloadLocalState()
                finishEmbeddingModelActivation(
                    previousID: previousID,
                    previousModel: previousModel,
                    nextModel: verifiedModel
                )
            } catch {
                // The runtime verification remains truthful evidence even when
                // the atomic activation rejects. Do not relabel a model that
                // actually loaded as failed.
                embeddingTestPassed = false
                message = "The embedding model verified, but could not be selected: \(error.localizedDescription)"
            }
        default:
            embeddingTestPassed = false
            let detail = response.error?.message ?? "The embedding model failed to load."
            message = detail
            try? store.documentSettings.recordTestLoad(
                modelID: model.id,
                result: "failed: \(detail)"
            )
        }
        reloadSettings()
        reloadLocalState()
    }

    private static func readinessIdentity(
        for model: DocumentEmbeddingModelRecord
    ) -> DocumentReadinessEmbeddingModelIdentity {
        DocumentReadinessEmbeddingModelIdentity(
            id: model.id,
            repoID: model.repoID,
            revision: model.revision,
            dimension: model.dimension
        )
    }

    private func finishEmbeddingModelActivation(
        previousID: String?,
        previousModel: DocumentEmbeddingModelRecord?,
        nextModel: DocumentEmbeddingModelRecord
    ) {
        guard previousID != nextModel.id else { return }
        if let previousModel {
            do {
                let service = OutputStalenessService(store: store)
                for matter in try store.matters.fetchMatters() {
                    _ = try service.embeddingModelChanged(
                        matterID: matter.id,
                        fromModelID: previousModel.repoID,
                        fromRevision: previousModel.revision ?? "unresolved",
                        toModelID: nextModel.repoID,
                        toRevision: nextModel.revision ?? "unresolved"
                    )
                }
            } catch {
                message = "The embedding model changed, but dependent output status could not be refreshed: \(error.localizedDescription)"
            }
        }
        enqueueMattersMissingEmbeddings(modelID: nextModel.id)
    }

    private var embeddingWarmInFlight = false
    private var warmedEmbeddingModelID: String?

    /// Fire-and-forget warm of the selected embedding model into its (separate) runtime
    /// slot, so the first Document Q&A / semantic search / import indexing doesn't wait
    /// on the load. Runs quietly — no busy/verify state, no audit — and only once per
    /// model per session (the embedding slot is independent of the chat model, so this
    /// never evicts it). No-op unless a verified embedding model is selected.
    public func prewarmEmbeddingModel() {
        guard !isBusy, !embeddingWarmInFlight,
              warmedEmbeddingModelID != selectedEmbeddingModel?.id,
              let model = selectedEmbeddingModel,
              embeddingTestPassed,
              let path = model.localPath, !path.isEmpty,
              (try? Self.verifyManagedEmbeddingModel(model)) != nil else { return }
        embeddingWarmInFlight = true
        warmedEmbeddingModelID = model.id
        Task {
            defer { embeddingWarmInFlight = false }
            do {
                _ = try await loadEmbeddingModel(model)
            } catch {
                warmedEmbeddingModelID = nil // allow a retry on the next trigger
            }
        }
    }

    private func loadEmbeddingModel(
        _ model: DocumentEmbeddingModelRecord
    ) async throws -> LoadEmbeddingModelResponse {
        guard let path = model.localPath, !path.isEmpty else {
            throw TextEmbedderError.modelNotDownloaded
        }
        let embeddingModelID = DocumentEmbeddingModelID(
            UUID(uuidString: model.id) ?? UUID()
        )
        let expectedDimension = model.dimension > 0 ? model.dimension : nil
        let modelDirectory = URL(fileURLWithPath: path, isDirectory: true)

        if ManagedModelStorage.isManagedEmbedding(path: path) {
            let prepared = try await ContentBoundEmbeddingAuthorizationExecutor.live.prepare(
                modelDirectory: modelDirectory,
                managedRoot: ManagedModelStorage.embeddingModelsDirectory(),
                embeddingModelID: embeddingModelID,
                displayName: model.displayName,
                revision: model.revision,
                expectedDimension: expectedDimension
            )
            let response = try await modelExecutionGateway.loadEmbeddingModel(prepared.request)
            _ = prepared.authorization
            return response
        }

        let access = SecurityScopedModelAccess(url: modelDirectory)
        defer { access.release() }
        guard access.hasAccess,
              let authorization = access.makeTransferableAuthorization() else {
            throw TextEmbedderError.loadFailed(
                "the model-folder security scope could not be activated"
            )
        }
        return try await modelExecutionGateway.loadEmbeddingModel(
            LoadEmbeddingModelRequest(
                embeddingModelID: embeddingModelID,
                modelPath: path,
                displayName: model.displayName,
                revision: model.revision,
                expectedDimension: expectedDimension,
                modelBookmark: authorization.bookmark,
                managedRootPath: nil,
                modelDirectoryIdentity: authorization.directoryIdentity
            )
        )
    }

    private static func verifyManagedEmbeddingModel(_ model: DocumentEmbeddingModelRecord) throws {
        guard let path = model.localPath, !path.isEmpty else {
            throw ManagedModelIntegrityError.manifestMissing
        }
        guard ManagedModelStorage.isManagedEmbedding(path: path) else { return }
        let manifest = try ManagedModelStorage.loadVerifiedManifest(
            at: URL(fileURLWithPath: path, isDirectory: true)
        )
        guard manifest.repositoryID == model.repoID, manifest.revision == model.revision else {
            throw ManagedModelIntegrityError.manifestMismatch
        }
    }

    /// Kept for compatibility with older callers. Setup completion is now automatic.
    @discardableResult
    public func completeSetup() -> Bool {
        guard canCompleteSetup else {
            message = "Finish the remaining setup steps first."
            return false
        }
        syncCompletionStateIfNeeded()
        return isComplete
    }

    public func invalidateSetup(reason: String) {
        try? store.documentSettings.invalidateSetup(reason: reason)
        _ = try? store.auditEvents.recordEvent(
            eventType: "document_intelligence_setup_invalidated", actor: "system",
            summary: "Document Intelligence setup invalidated: \(reason)"
        )
        reloadSettings()
    }

    // MARK: - Helpers

    private func enqueueMattersMissingEmbeddings(modelID: String) {
        guard let reindexEnqueuer else { return }
        let matters = (try? store.matters.fetchMatters()) ?? []
        for matter in matters {
            let documents = (try? store.documentLibrary.fetchDocuments(matterID: matter.id)) ?? []
            let needsModel = documents.contains { document in
                let extractionDone = document.extractionStatus == DocumentExtractionStatus.extracted.rawValue
                    || document.extractionStatus == DocumentExtractionStatus.ocrComplete.rawValue
                    || document.extractionStatus == DocumentExtractionStatus.edited.rawValue
                guard extractionDone,
                      document.deletedAt == nil,
                      document.status != MatterDocumentStatus.failed.rawValue else { return false }
                return (try? store.documentIndex.hasCompleteEmbeddings(
                    documentID: document.id,
                    embeddingModelID: modelID
                )) != true
            }
            if needsModel { reindexEnqueuer(matter.id) }
        }
    }

    private func markConverterLineageStale(from priorVersion: String, to currentVersion: String) {
        let matters = (try? store.matters.fetchMatters()) ?? []
        for matter in matters {
            let documents = (try? store.documentLibrary.fetchDocuments(matterID: matter.id)) ?? []
            for document in documents {
                let extractionDone = document.extractionStatus == DocumentExtractionStatus.extracted.rawValue
                    || document.extractionStatus == DocumentExtractionStatus.ocrComplete.rawValue
                    || document.extractionStatus == DocumentExtractionStatus.edited.rawValue
                guard extractionDone,
                      document.status != MatterDocumentStatus.failed.rawValue,
                      document.deletedAt == nil else { continue }
                let documentVersion = DocumentToolchain.stampedVersion(from: document.extractionMethod)
                    ?? priorVersion
                guard documentVersion != currentVersion else { continue }
                try? store.documentLibrary.updateIndexStatus(documentID: document.id, indexStatus: .stale)
                _ = try? store.auditEvents.recordEvent(
                    matterID: matter.id,
                    eventType: "document_converter_lineage_stale",
                    actor: "system",
                    summary: "Converter toolchain changed from \(documentVersion) to \(currentVersion); document requires manual reprocessing.",
                    relatedTable: "matter_documents",
                    relatedID: document.id
                )
            }
        }
    }

    private func reloadSettings() {
        settings = (try? store.documentSettings.loadSettings()) ?? settings
    }

    private func reloadLocalState() {
        availableEmbeddingModels = (try? store.documentSettings.fetchEmbeddingModels()) ?? []
        selectedEmbeddingModel = (try? store.documentSettings.fetchSelectedEmbeddingModel())
        storageInitialized = storage.isInitialized()
        if let toolchainJSON = settings.converterCapabilityJSON,
           let data = toolchainJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(DocumentToolchainCapabilities.self, from: data) {
            toolchain = decoded
        }
        if let status = settings.notificationPermissionStatus {
            notificationStatus = DocumentNotificationAuthorizationStatus(rawValue: status) ?? notificationStatus
        }
        // Persisted "passed" test result plus a recorded test time means the
        // selected model has proven loadable.
        embeddingTestPassed = settings.embeddingModelLastTestedAt != nil
            && (selectedEmbeddingModel?.lastTestLoadResult == "passed")
        syncCompletionStateIfNeeded()
    }

    private func syncCompletionStateIfNeeded() {
        guard canCompleteSetup else { return }
        let shouldAudit = settings.setupCompletedAt == nil || settings.setupInvalidatedReason != nil
        guard shouldAudit else { return }
        settings = (try? store.documentSettings.updateSettings { settings in
            settings.setupCompletedAt = settings.setupCompletedAt ?? Date()
            settings.setupInvalidatedReason = nil
        }) ?? settings
        _ = try? store.auditEvents.recordEvent(
            eventType: "document_intelligence_setup_completed", actor: "system",
            summary: "Document Intelligence setup completed automatically"
        )
    }
}
