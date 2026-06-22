import Foundation
import GRDB

public final class SupraStore: @unchecked Sendable {
    public let database: SupraDatabase
    public let appSettings: AppSettingsRepository
    public let models: ModelRepository
    public let chats: ChatRepository
    public let matters: MattersRepository
    public let generation: GenerationRepository
    public let diagnostics: DiagnosticsRepository
    public let validation: ValidationRepository
    public let exportedReports: ExportedReportsRepository
    public let networkRequests: NetworkRequestRepository
    public let research: ResearchRepository
    public let authorities: AuthorityRepository
    public let structuredOutputs: StructuredOutputRepository
    public let auditEvents: AuditEventRepository
    // Milestone 3: document intelligence repositories.
    public let documentSettings: DocumentSettingsRepository
    public let documentLibrary: DocumentLibraryRepository
    public let documentIndex: DocumentIndexRepository
    public let documentJobs: DocumentJobRepository
    public let documentSources: DocumentSourceRepository
    // Milestone 4: ScratchPad daily notes + billing.
    public let scratchPad: ScratchPadRepository
    public let billing: BillingRepository

    public init(database: SupraDatabase) {
        self.database = database
        self.appSettings = AppSettingsRepository(writer: database.writer)
        self.models = ModelRepository(writer: database.writer)
        self.chats = ChatRepository(writer: database.writer)
        self.matters = MattersRepository(writer: database.writer)
        self.generation = GenerationRepository(writer: database.writer)
        self.diagnostics = DiagnosticsRepository(writer: database.writer)
        self.validation = ValidationRepository(writer: database.writer)
        self.exportedReports = ExportedReportsRepository(writer: database.writer)
        self.networkRequests = NetworkRequestRepository(writer: database.writer)
        self.research = ResearchRepository(writer: database.writer)
        self.authorities = AuthorityRepository(writer: database.writer)
        self.structuredOutputs = StructuredOutputRepository(writer: database.writer)
        self.auditEvents = AuditEventRepository(writer: database.writer)
        self.documentSettings = DocumentSettingsRepository(writer: database.writer)
        self.documentLibrary = DocumentLibraryRepository(writer: database.writer)
        self.documentIndex = DocumentIndexRepository(writer: database.writer)
        self.documentJobs = DocumentJobRepository(writer: database.writer)
        self.documentSources = DocumentSourceRepository(writer: database.writer)
        self.scratchPad = ScratchPadRepository(writer: database.writer)
        self.billing = BillingRepository(writer: database.writer)
    }

    public convenience init(url: URL) throws {
        try self.init(database: SupraDatabase(url: url))
    }

    /// An in-memory store (nothing persists). Last-resort fallback so the app can
    /// still launch when no on-disk database can be opened.
    public static func inMemory() throws -> SupraStore {
        try SupraStore(database: .inMemory())
    }

    public static func openAppSupportStore(
        fileManager: FileManager = .default,
        bundleIdentifier: String = "ai.supra.SupraAI"
    ) throws -> SupraStore {
        try SupraStore(
            database: .openAppSupportDatabase(
                fileManager: fileManager,
                bundleIdentifier: bundleIdentifier
            )
        )
    }
}
