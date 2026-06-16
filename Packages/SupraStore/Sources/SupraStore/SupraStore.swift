import Foundation
import GRDB

public final class SupraStore: @unchecked Sendable {
    public let database: SupraDatabase
    public let appSettings: AppSettingsRepository
    public let models: ModelRepository
    public let chats: ChatRepository
    public let generation: GenerationRepository
    public let diagnostics: DiagnosticsRepository
    public let validation: ValidationRepository
    public let exportedReports: ExportedReportsRepository

    public init(database: SupraDatabase) {
        self.database = database
        self.appSettings = AppSettingsRepository(writer: database.writer)
        self.models = ModelRepository(writer: database.writer)
        self.chats = ChatRepository(writer: database.writer)
        self.generation = GenerationRepository(writer: database.writer)
        self.diagnostics = DiagnosticsRepository(writer: database.writer)
        self.validation = ValidationRepository(writer: database.writer)
        self.exportedReports = ExportedReportsRepository(writer: database.writer)
    }

    public convenience init(url: URL) throws {
        try self.init(database: SupraDatabase(url: url))
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
