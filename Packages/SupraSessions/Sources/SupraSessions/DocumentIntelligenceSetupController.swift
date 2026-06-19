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
    @Published public private(set) var isBusy = false
    @Published public private(set) var message: String?
    /// Days before soft-deleted documents are auto-purged (0 disables). Plan §12.2.
    @Published public private(set) var autoPurgeDays: Int = DocumentMaintenance.defaultAutoPurgeDays

    private let store: SupraStore
    private let runtimeClient: any RuntimeClientProtocol
    private let notifier: any DocumentNotifying
    private let storage: DocumentStorage
    private let capabilitiesProvider: @Sendable () -> DocumentToolchainCapabilities

    public init(
        store: SupraStore,
        runtimeClient: any RuntimeClientProtocol,
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

    /// True when setup has been completed and not since invalidated. Import is
    /// blocked unless this is true.
    public var isComplete: Bool {
        settings.setupCompletedAt != nil && settings.setupInvalidatedReason == nil
    }

    public var isReadyForImport: Bool { isComplete }

    /// True when every setup step passes, so the user may mark setup complete.
    public var canCompleteSetup: Bool {
        chatModelLoaded
            && selectedEmbeddingModel != nil
            && embeddingTestPassed
            && (toolchain?.meetsMinimumForSetup ?? false)
            && storageInitialized
    }

    /// Human-readable list of steps still outstanding, for the Settings UI.
    public var outstandingSteps: [String] {
        var steps: [String] = []
        if !chatModelLoaded { steps.append("Load a runtime text model in the Models tab.") }
        if selectedEmbeddingModel == nil { steps.append("Download and select an embedding model.") }
        else if !embeddingTestPassed { steps.append("Test-load the selected embedding model.") }
        if !(toolchain?.meetsMinimumForSetup ?? false) { steps.append("Confirm the local extraction/OCR toolchain.") }
        if !storageInitialized { steps.append("Initialize document storage.") }
        if notificationStatus == .notDetermined { steps.append("Allow completion notifications (optional).") }
        return steps
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
        guard let status = try? await runtimeClient.runtimeStatus() else {
            chatModelLoaded = false
            return
        }
        chatModelLoaded = status.loadedModelID != nil
        if chatModelLoaded {
            settings = (try? store.documentSettings.updateSettings { settings in
                settings.selectedChatModelID = status.loadedModelID?.rawValue.uuidString
                settings.chatModelLastLoadedAt = Date()
            }) ?? settings
        }
    }

    /// Detects and persists the local extraction/OCR toolchain capabilities.
    @discardableResult
    public func refreshToolchain() -> DocumentToolchainCapabilities {
        let capabilities = capabilitiesProvider()
        toolchain = capabilities
        let json = try? JSONEncoder().encode(capabilities)
        settings = (try? store.documentSettings.updateSettings { settings in
            settings.converterToolchainVersion = capabilities.version
            settings.ocrAvailable = capabilities.ocr
            settings.ocrCheckedAt = Date()
            settings.converterCapabilityJSON = json.flatMap { String(data: $0, encoding: .utf8) }
        }) ?? settings
        return capabilities
    }

    public func refreshStorage() {
        storageInitialized = storage.isInitialized()
    }

    public func refreshNotificationStatus() async {
        notificationStatus = await notifier.authorizationStatus()
    }

    // MARK: - Actions

    /// Creates the managed storage layout and records initialization.
    public func initializeStorage() {
        do {
            try storage.initializeStorage()
            storageInitialized = true
            settings = (try? store.documentSettings.updateSettings { $0.storageInitializedAt = Date() }) ?? settings
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
        try? store.documentSettings.selectEmbeddingModel(id: id)
        try? store.documentSettings.invalidateSetup(reason: "embedding model changed")
        reloadSettings()
        reloadLocalState()
    }

    /// Loads the selected embedding model into the runtime to prove it can be
    /// initialized, checking the produced dimension (plan §2.1).
    public func testLoadEmbeddingModel() async {
        guard let model = selectedEmbeddingModel else {
            message = "Select an embedding model first."
            return
        }
        guard let path = model.localPath, !path.isEmpty else {
            message = "The selected embedding model is not downloaded."
            return
        }
        isBusy = true
        defer { isBusy = false }

        let bookmark = try? URL(fileURLWithPath: path, isDirectory: true).bookmarkData(options: [])
        let request = LoadEmbeddingModelRequest(
            embeddingModelID: DocumentEmbeddingModelID(UUID(uuidString: model.id) ?? UUID()),
            modelPath: path,
            displayName: model.displayName,
            revision: model.revision,
            expectedDimension: model.dimension,
            modelBookmark: bookmark
        )
        do {
            let response = try await runtimeClient.loadEmbeddingModel(request)
            switch response.state {
            case .loaded:
                embeddingTestPassed = true
                message = nil
                try? store.documentSettings.recordTestLoad(modelID: model.id, result: "passed")
                settings = (try? store.documentSettings.updateSettings { $0.embeddingModelLastTestedAt = Date() }) ?? settings
                _ = try? store.auditEvents.recordEvent(
                    eventType: "document_intelligence_setup_changed", actor: "user",
                    summary: "Embedding model \(model.displayName) test-loaded",
                    relatedTable: "document_embedding_models", relatedID: model.id
                )
            default:
                embeddingTestPassed = false
                let detail = response.error?.message ?? "The embedding model failed to load."
                message = detail
                try? store.documentSettings.recordTestLoad(modelID: model.id, result: "failed: \(detail)")
            }
        } catch {
            embeddingTestPassed = false
            message = error.localizedDescription
            try? store.documentSettings.recordTestLoad(modelID: model.id, result: "failed: \(error.localizedDescription)")
        }
        reloadLocalState()
    }

    /// Marks setup complete when every step passes, and audits it.
    @discardableResult
    public func completeSetup() -> Bool {
        guard canCompleteSetup else {
            message = "Finish the remaining setup steps first."
            return false
        }
        settings = (try? store.documentSettings.updateSettings { settings in
            settings.setupCompletedAt = Date()
            settings.setupInvalidatedReason = nil
        }) ?? settings
        _ = try? store.auditEvents.recordEvent(
            eventType: "document_intelligence_setup_completed", actor: "user",
            summary: "Document Intelligence setup completed"
        )
        return true
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
    }
}
