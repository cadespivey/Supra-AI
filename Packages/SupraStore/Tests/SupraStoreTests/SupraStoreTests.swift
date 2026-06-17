import Foundation
import GRDB
import SupraCore
@testable import SupraStore
import XCTest

final class SupraStoreTests: XCTestCase {
    func testMigrationsCreateAllTables() throws {
        let store = try makeStore()

        let tableNames = try store.database.writer.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                ORDER BY name
                """
            )
        }

        XCTAssertTrue(tableNames.contains("app_settings"))
        XCTAssertTrue(tableNames.contains("models"))
        XCTAssertTrue(tableNames.contains("runtime_profiles"))
        XCTAssertTrue(tableNames.contains("chats"))
        XCTAssertTrue(tableNames.contains("messages"))
        XCTAssertTrue(tableNames.contains("generation_sessions"))
        XCTAssertTrue(tableNames.contains("message_variants"))
        XCTAssertTrue(tableNames.contains("diagnostic_events"))
        XCTAssertTrue(tableNames.contains("model_validation_runs"))
        XCTAssertTrue(tableNames.contains("model_validation_tests"))
        XCTAssertTrue(tableNames.contains("exported_reports"))
        XCTAssertTrue(tableNames.contains("matters"))
        XCTAssertTrue(tableNames.contains("network_requests"))
        XCTAssertTrue(tableNames.contains("research_sessions"))
        XCTAssertTrue(tableNames.contains("research_queries"))
        XCTAssertTrue(tableNames.contains("research_results"))
        XCTAssertTrue(tableNames.contains("authorities"))
        XCTAssertTrue(tableNames.contains("structured_outputs"))
        XCTAssertTrue(tableNames.contains("structured_output_versions"))
        XCTAssertTrue(tableNames.contains("audit_events"))
    }

    func testMatterChatsAreScopedSeparatelyFromGlobalChats() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme v. Roe")

        _ = try store.chats.createGlobalChat(title: "Global")
        let matterChat = try store.chats.createMatterChat(matterID: matter.id, title: "Issue 1")

        let globalChats = try store.chats.fetchGlobalChats()
        let matterChats = try store.chats.fetchMatterChats(matterID: matter.id)

        XCTAssertEqual(globalChats.count, 1)
        XCTAssertEqual(globalChats.first?.title, "Global")
        XCTAssertEqual(matterChats.count, 1)
        XCTAssertEqual(matterChats.first?.id, matterChat.id)
        XCTAssertEqual(matterChats.first?.matterID, matter.id)
        XCTAssertEqual(try store.matters.fetchMatters().count, 1)
    }

    func testMatterMetadataRoundTrips() throws {
        let store = try makeStore()

        let matter = try store.matters.createMatter(
            name: "  Acme v. Roe  ",
            jurisdiction: "  Delaware  ",
            partyPerspective: .plaintiff,
            court: "Chancery",
            docketNumber: "2026-001"
        )

        XCTAssertEqual(matter.name, "Acme v. Roe")
        XCTAssertEqual(matter.jurisdiction, "Delaware")
        XCTAssertEqual(matter.partyPerspective, PartyPerspective.plaintiff.rawValue)
        XCTAssertEqual(matter.court, "Chancery")
        XCTAssertEqual(matter.docketNumber, "2026-001")
    }

    func testMilestone2ResearchAuthorityOutputAuditAndNetworkRoundTrip() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(
            name: "Acme v. Roe",
            jurisdiction: "Delaware",
            partyPerspective: .plaintiff
        )

        let session = try store.research.createSession(
            matterID: matter.id,
            title: "Standing research",
            issueText: "What standard governs standing?",
            jurisdiction: matter.jurisdiction,
            preferredCourts: ["delch"],
            status: .planned
        )
        let query = try store.research.createQuery(
            researchSessionID: session.id,
            queryText: "standing shareholder derivative",
            queryIndex: 0,
            status: .approved
        )
        let result = try store.research.insertResult(
            ResearchResultRecord(
                researchQueryID: query.id,
                courtlistenerID: "123",
                clusterID: "456",
                caseName: "Acme Corp. v. Roe",
                citationJSON: #"["1 A.3d 100"]"#,
                preferredCitation: "1 A.3d 100",
                court: "Del.",
                reviewState: ResearchResultReviewState.saved.rawValue,
                rawResultJSON: #"{"caseName":"Acme Corp. v. Roe"}"#
            )
        )
        let authority = try store.authorities.insertAuthority(
            AuthorityRecord(
                matterID: matter.id,
                researchSessionID: session.id,
                researchResultID: result.id,
                courtlistenerID: result.courtlistenerID,
                clusterID: result.clusterID,
                caseName: result.caseName,
                citationJSON: result.citationJSON,
                preferredCitation: result.preferredCitation,
                court: result.court,
                reviewState: ResearchResultReviewState.saved.rawValue,
                useStatus: AuthorityUseStatus.retrievedFromCourtListener.rawValue,
                rawMetadataJSON: result.rawResultJSON
            )
        )
        let output = try store.structuredOutputs.createOutput(
            matterID: matter.id,
            title: "Rule synthesis",
            outputType: .ruleSynthesis,
            researchSessionID: session.id
        )
        let version = try store.structuredOutputs.createVersion(
            structuredOutputID: output.id,
            versionIndex: 1,
            contentMarkdown: "# Rule Synthesis",
            requiredSections: ["# Rule Synthesis"],
            presentSections: ["# Rule Synthesis"],
            missingSections: []
        )
        let networkRequest = try store.networkRequests.createRequest(
            domain: "www.courtlistener.com",
            method: "GET",
            endpoint: "/api/rest/v4/search/",
            approved: true,
            relatedResearchSessionID: session.id
        )
        try store.networkRequests.finishRequest(id: networkRequest.id, statusCode: 200)
        _ = try store.auditEvents.recordEvent(
            matterID: matter.id,
            eventType: "authority_saved",
            actor: "user",
            summary: "Saved authority",
            relatedTable: "authorities",
            relatedID: authority.id
        )

        XCTAssertEqual(try store.research.fetchSessions(matterID: matter.id).single?.id, session.id)
        XCTAssertEqual(try store.research.fetchQueries(sessionID: session.id).single?.id, query.id)
        XCTAssertEqual(try store.research.fetchResults(queryID: query.id).single?.id, result.id)
        XCTAssertEqual(try store.authorities.fetchAuthorities(matterID: matter.id).single?.id, authority.id)
        XCTAssertEqual(try store.structuredOutputs.fetchOutputs(matterID: matter.id).single?.id, output.id)
        XCTAssertEqual(try store.structuredOutputs.fetchVersions(structuredOutputID: output.id).single?.id, version.id)
        XCTAssertEqual(try store.networkRequests.fetchRecent(limit: 1).single?.statusCode, 200)
        XCTAssertEqual(try store.auditEvents.fetchEvents(matterID: matter.id).single?.eventType, "authority_saved")
    }

    func testSettingsRoundTripCodableValues() throws {
        let store = try makeStore()

        try store.appSettings.setSetting("generation.default", value: GenerationOptions(preset: .drafting))
        let options = try store.appSettings.getSetting("generation.default", as: GenerationOptions.self)

        XCTAssertEqual(options?.preset, .drafting)
    }

    func testModelActivationAndValidationStatus() throws {
        let store = try makeStore()
        let first = ModelRecord(id: "model-a", displayName: "A", path: "/tmp/a")
        let second = ModelRecord(id: "model-b", displayName: "B", path: "/tmp/b")

        try store.models.upsertModel(first)
        try store.models.upsertModel(second)
        try store.models.setActiveModel(id: second.id)
        try store.models.updateValidationStatus(modelID: second.id, status: ValidationRunStatus.passed.rawValue, date: Date())

        let models = try store.models.fetchModels()
        XCTAssertEqual(models.first?.id, second.id)
        XCTAssertEqual(try store.models.fetchModel(id: second.id)?.validationStatus, ValidationRunStatus.passed.rawValue)
        XCTAssertEqual(try store.models.fetchModel(id: first.id)?.isActive, false)
    }

    func testChatVariantTokenPersistenceAndCancellation() throws {
        let store = try makeStore()
        let chat = try store.chats.createGlobalChat(title: "Global")
        _ = try store.chats.appendUserMessage(chatID: chat.id, content: "Hello")
        let assistant = try store.chats.createAssistantMessageShell(chatID: chat.id)
        let variant = try store.chats.createVariant(messageID: assistant.id, generationSessionID: nil)

        try store.chats.appendToken(to: variant.id, token: "Hel")
        try store.chats.appendToken(to: variant.id, token: "lo")
        try store.chats.markVariantCancelled(variant.id)

        let variants = try store.chats.fetchVariants(messageID: assistant.id)
        XCTAssertEqual(variants.single?.content, "Hello")
        XCTAssertEqual(variants.single?.status, MessageStatus.cancelled.rawValue)

        let messages = try store.chats.fetchMessages(chatID: chat.id)
        let storedAssistant = try XCTUnwrap(messages.first { $0.id == assistant.id })
        XCTAssertEqual(storedAssistant.content, "Hello")
        XCTAssertEqual(storedAssistant.status, MessageStatus.cancelled.rawValue)
    }

    func testGenerationDiagnosticsValidationAndReportRepositories() throws {
        let store = try makeStore()
        let model = ModelRecord(id: "model", displayName: "Model", path: "/tmp/model")
        try store.models.upsertModel(model)

        let chat = try store.chats.createGlobalChat(title: "Global")
        let assistant = try store.chats.createAssistantMessageShell(chatID: chat.id)
        let generation = try store.generation.createGenerationSession(
            chatID: chat.id,
            messageID: assistant.id,
            modelID: model.id,
            prompt: "Draft",
            options: GenerationOptions()
        )
        try store.generation.markFirstToken(generationID: generation.id)
        try store.generation.completeGeneration(
            generationID: generation.id,
            metrics: StoredRuntimeMetrics(generatedTokenCount: 12)
        )

        let storedGeneration = try store.generation.fetchGenerationSession(generationID: generation.id)
        XCTAssertEqual(storedGeneration?.status, MessageStatus.completed.rawValue)
        XCTAssertEqual(storedGeneration?.generatedTokenCount, 12)

        try store.diagnostics.recordDiagnosticEvent(
            DiagnosticEventRecord(severity: "info", message: "Runtime ready")
        )
        XCTAssertEqual(try store.diagnostics.fetchRecentDiagnostics(limit: 10).count, 1)

        let run = try store.validation.createValidationRun(
            modelID: model.id,
            suiteID: "suite",
            suiteVersion: 1
        )
        _ = try store.validation.appendValidationTest(
            runID: run.id,
            testID: "basic",
            name: "Basic",
            status: .passed,
            outputExcerpt: "ok"
        )
        try store.validation.completeValidationRun(runID: run.id, status: .passed)

        XCTAssertEqual(try store.validation.fetchValidationRuns(modelID: model.id).single?.status, ValidationRunStatus.passed.rawValue)
        XCTAssertEqual(try store.validation.fetchValidationTests(runID: run.id).single?.status, ValidationTestStatus.passed.rawValue)

        try store.exportedReports.recordExportedReport(
            ExportedReportRecord(validationRunID: run.id, format: "markdown", fileURL: "/tmp/report.md")
        )
        XCTAssertEqual(try store.exportedReports.fetchExportedReports(validationRunID: run.id).single?.format, "markdown")
    }

    func testMarkUnfinishedRunsCancelledReconcilesOnlyStrandedRuns() throws {
        let store = try makeStore()
        let model = ModelRecord(id: "m", displayName: "M", path: "/tmp/m")
        try store.models.upsertModel(model)

        // A finished run (completed_at set) must be left untouched.
        let finished = try store.validation.createValidationRun(modelID: model.id, suiteID: "s", suiteVersion: 1)
        try store.validation.completeValidationRun(runID: finished.id, status: .passed)

        // A stranded run: seeded partial with completed_at NULL, never completed.
        let stranded = try store.validation.createValidationRun(modelID: model.id, suiteID: "s", suiteVersion: 1)

        try store.validation.markUnfinishedRunsCancelled()

        let runs = try store.validation.fetchValidationRuns(modelID: model.id)
        let finishedRow = try XCTUnwrap(runs.first { $0.id == finished.id })
        let strandedRow = try XCTUnwrap(runs.first { $0.id == stranded.id })

        XCTAssertEqual(finishedRow.status, ValidationRunStatus.passed.rawValue)
        XCTAssertEqual(strandedRow.status, ValidationRunStatus.cancelled.rawValue)
        XCTAssertNotNil(strandedRow.completedAt)
    }

    private func makeStore() throws -> SupraStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SupraStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try SupraStore(url: directoryURL.appendingPathComponent("test.sqlite"))
    }
}

private extension Array {
    var single: Element? {
        count == 1 ? first : nil
    }
}
