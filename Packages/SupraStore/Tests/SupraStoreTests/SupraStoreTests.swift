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

    func testFetchClientUsageAggregatesLiveMatters() throws {
        let store = try makeStore()

        _ = try store.matters.createMatter(name: "A1", clientNames: "Fritz Martin Cabinetry LLC", clientID: "100")
        _ = try store.matters.createMatter(name: "A2", clientNames: "Fritz Martin Cabinetry LLC", clientID: "100")
        _ = try store.matters.createMatter(name: "B1", clientNames: "Fritz Martin Cabinetry", clientID: "100")
        _ = try store.matters.createMatter(name: "C1", clientNames: "VyStar Credit Union")
        let deleted = try store.matters.createMatter(name: "D1", clientNames: "Gone Co.", clientID: "999")
        try store.matters.softDeleteMatter(id: deleted.id)
        _ = try store.matters.createMatter(name: "E1")

        let rows = try store.matters.fetchClientUsage()

        // One row per (number, spelling) pair; deleted and clientless matters skipped.
        XCTAssertEqual(rows.count, 3)
        let dominant = rows.first { $0.clientID == "100" && $0.clientNames == "Fritz Martin Cabinetry LLC" }
        XCTAssertEqual(dominant?.matterCount, 2)
        XCTAssertEqual(rows.first { $0.clientID == "100" && $0.clientNames == "Fritz Martin Cabinetry" }?.matterCount, 1)
        XCTAssertEqual(rows.first { $0.clientID == nil }?.clientNames, "VyStar Credit Union")
        XCTAssertFalse(rows.contains { $0.clientID == "999" })
    }

    func testFetchPracticeAreaUsageAggregatesLiveMatters() throws {
        let store = try makeStore()

        _ = try store.matters.createMatter(name: "A", practiceArea: "Commercial Litigation")
        _ = try store.matters.createMatter(name: "B", practiceArea: "Commercial Litigation")
        _ = try store.matters.createMatter(name: "C", practiceArea: "Real Estate")
        _ = try store.matters.createMatter(name: "D")
        let deleted = try store.matters.createMatter(name: "E", practiceArea: "Tax")
        try store.matters.softDeleteMatter(id: deleted.id)

        let rows = try store.matters.fetchPracticeAreaUsage()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first { $0.name == "Commercial Litigation" }?.matterCount, 2)
        XCTAssertEqual(rows.first { $0.name == "Real Estate" }?.matterCount, 1)
    }

    func testRestoreMatterClearsManualSortOrder() throws {
        let store = try makeStore()
        let a = try store.matters.createMatter(name: "A")
        let b = try store.matters.createMatter(name: "B")
        try store.matters.updateMatterSortOrder(orderedIDs: [a.id, b.id])

        try store.matters.softDeleteMatter(id: a.id)
        try store.matters.updateMatterSortOrder(orderedIDs: [b.id])
        try store.matters.restoreMatter(id: a.id)

        // The manual list was reindexed while A was deleted; its stale index
        // must not collide, so restore clears it (never-placed → joins the end).
        let restored = try store.matters.fetchMatter(id: a.id)
        XCTAssertNil(restored?.sortOrder)
        XCTAssertEqual(try store.matters.fetchMatter(id: b.id)?.sortOrder, 0)
    }

    func testFindFolderMatchesCaseInsensitivelyWithinParent() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "M")
        let research = try store.documentLibrary.createFolder(matterID: matter.id, name: "Research")
        let nested = try store.documentLibrary.createFolder(matterID: matter.id, name: "research", parentFolderID: research.id)

        XCTAssertEqual(try store.documentLibrary.findFolder(matterID: matter.id, parentFolderID: nil, name: "RESEARCH")?.id, research.id)
        XCTAssertEqual(try store.documentLibrary.findFolder(matterID: matter.id, parentFolderID: research.id, name: "Research")?.id, nested.id)
        XCTAssertNil(try store.documentLibrary.findFolder(matterID: matter.id, parentFolderID: nil, name: "Pleadings"))

        // Trashed folders are not reuse candidates.
        try store.documentLibrary.softDeleteFolder(id: research.id)
        XCTAssertNil(try store.documentLibrary.findFolder(matterID: matter.id, parentFolderID: nil, name: "Research"))
    }

    func testEnsureFolderReusesUnicodeCaseVariantsAndLegacyDuplicatesDeterministically() throws {
        // Expected RED: `ensureFolder` does not exist yet; the old SQL `NOCASE`
        // lookup also treats accented case variants as different folders.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "M")
        let resume = try store.documentLibrary.createFolder(matterID: matter.id, name: "RÉSUMÉ")

        let unicodeReuse = try store.documentLibrary.ensureFolder(
            matterID: matter.id,
            name: "résumé"
        )
        XCTAssertEqual(unicodeReuse.id, resume.id)

        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        try store.database.writer.write { db in
            try DocumentFolderRecord(
                id: "legacy-folder-a",
                matterID: matter.id,
                name: "Research",
                createdAt: createdAt,
                updatedAt: createdAt
            ).insert(db)
            try DocumentFolderRecord(
                id: "legacy-folder-b",
                matterID: matter.id,
                name: "RESEARCH",
                createdAt: createdAt,
                updatedAt: createdAt
            ).insert(db)
        }

        let first = try store.documentLibrary.ensureFolder(matterID: matter.id, name: "research")
        let second = try store.documentLibrary.ensureFolder(matterID: matter.id, name: "Research")
        XCTAssertEqual(first.id, "legacy-folder-a")
        XCTAssertEqual(second.id, first.id)
    }

    func testEnsureFolderDoesNotReviveOrReuseTrashedFolder() throws {
        // Expected RED: `ensureFolder` does not exist yet. Its identity contract
        // must be scoped to live siblings so creating after deletion stays visible.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "M")
        let trashed = try store.documentLibrary.createFolder(matterID: matter.id, name: "Pleadings")
        try store.documentLibrary.softDeleteFolder(id: trashed.id)

        let replacement = try store.documentLibrary.ensureFolder(matterID: matter.id, name: "PLEADINGS")

        XCTAssertNotEqual(replacement.id, trashed.id)
        XCTAssertEqual(
            try store.documentLibrary.fetchFolders(matterID: matter.id).map(\.id),
            [replacement.id]
        )
    }

    func testMatterChatsAreScopedSeparatelyFromGlobalChats() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")

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

    func testSoftDeleteChatHidesItButPreservesMessagesAndReportsMissing() throws {
        let store = try makeStore()
        let chat = try store.chats.createGlobalChat(title: "Global")
        _ = try store.chats.appendUserMessage(chatID: chat.id, content: "Preserve me")

        XCTAssertTrue(try store.chats.softDeleteChat(id: chat.id))
        XCTAssertFalse(try store.chats.softDeleteChat(id: chat.id))      // already gone
        XCTAssertFalse(try store.chats.softDeleteChat(id: "no-such-chat"))

        XCTAssertTrue(try store.chats.fetchGlobalChats().isEmpty)
        XCTAssertEqual(try store.chats.fetchMessages(chatID: chat.id).single?.content, "Preserve me")
    }

    func testMessageCitationsRoundTripAndReplace() throws {
        let store = try makeStore()
        let chat = try store.chats.createGlobalChat(title: "Global")
        let assistant = try store.chats.createAssistantMessageShell(chatID: chat.id)

        let initial = [
            MessageCitationRecord(messageID: assistant.id, label: "A1", kind: "authority", url: "https://courtlistener.com/x", displayName: "Foo v. Bar", rank: 0),
            MessageCitationRecord(messageID: assistant.id, label: "S1", kind: "source", documentID: "doc-1", locatorJSON: "{}", displayName: "agreement.pdf", rank: 1)
        ]
        try store.chats.replaceCitations(messageID: assistant.id, initial)

        let fetched = try store.chats.fetchCitations(messageID: assistant.id)
        XCTAssertEqual(fetched.map(\.label), ["A1", "S1"])  // ordered by rank
        XCTAssertEqual(fetched.first?.url, "https://courtlistener.com/x")
        XCTAssertEqual(fetched.last?.documentID, "doc-1")

        // Replace is delete-then-insert: no orphan rows from the prior set.
        try store.chats.replaceCitations(messageID: assistant.id, [
            MessageCitationRecord(messageID: assistant.id, label: "A1", kind: "authority", url: "https://courtlistener.com/y", rank: 0)
        ])
        let replaced = try store.chats.fetchCitations(messageID: assistant.id)
        XCTAssertEqual(replaced.map(\.label), ["A1"])
        XCTAssertEqual(replaced.first?.url, "https://courtlistener.com/y")
    }

    func testMoveGlobalChatToMatterRetainsConversationAndValidatesTargets() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let chat = try store.chats.createGlobalChat(title: "Global issue")
        _ = try store.chats.appendUserMessage(chatID: chat.id, content: "Move this")

        // A missing matter or missing chat returns nil and changes nothing.
        XCTAssertNil(try store.chats.moveChatToMatter(id: chat.id, matterID: "no-such-matter"))
        XCTAssertNil(try store.chats.moveChatToMatter(id: "no-such-chat", matterID: matter.id))
        XCTAssertEqual(try store.chats.fetchGlobalChats().map(\.id), [chat.id])

        let moved = try XCTUnwrap(store.chats.moveChatToMatter(id: chat.id, matterID: matter.id))
        XCTAssertEqual(moved.scope, "matter")
        XCTAssertEqual(moved.matterID, matter.id)
        XCTAssertTrue(try store.chats.fetchGlobalChats().isEmpty)
        XCTAssertEqual(try store.chats.fetchMatterChats(matterID: matter.id).map(\.id), [chat.id])
        XCTAssertEqual(try store.chats.fetchMessages(chatID: chat.id).single?.content, "Move this")
    }

    func testRenameChatUpdatesTitle() throws {
        let store = try makeStore()
        let chat = try store.chats.createGlobalChat(title: "New Chat")
        try store.chats.renameChat(id: chat.id, title: "Negligence research")
        XCTAssertEqual(try store.chats.fetchGlobalChats().single?.title, "Negligence research")
    }

    func testMatterMetadataRoundTrips() throws {
        let store = try makeStore()

        let matter = try store.matters.createMatter(
            name: "  McKernon Motors v. Liberty Rail  ",
            jurisdiction: "  Delaware  ",
            partyPerspective: .plaintiff,
            court: "Chancery",
            docketNumber: "2026-001",
            clientNames: #"MCKERNON MOTORS, INC.; O'Neil & Sons / María-José"#,
            matterDescription: #"Post-closing indemnity dispute re: § 2.4(a), escrow #A-17 & "side letter""#,
            internalMatterID: #"LIT-2026/MCKERNON#001-A&B"#
        )

        XCTAssertEqual(matter.name, "McKernon Motors v. Liberty Rail")
        XCTAssertEqual(matter.jurisdiction, "Delaware")
        XCTAssertEqual(matter.partyPerspective, PartyPerspective.plaintiff.rawValue)
        XCTAssertEqual(matter.court, "Chancery")
        XCTAssertEqual(matter.docketNumber, "2026-001")
        XCTAssertEqual(matter.clientNames, #"MCKERNON MOTORS, INC.; O'Neil & Sons / María-José"#)
        XCTAssertEqual(matter.matterDescription, #"Post-closing indemnity dispute re: § 2.4(a), escrow #A-17 & "side letter""#)
        XCTAssertEqual(matter.internalMatterID, #"LIT-2026/MCKERNON#001-A&B"#)
    }

    func testMilestone2ResearchAuthorityOutputAuditAndNetworkRoundTrip() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(
            name: "McKernon Motors v. Liberty Rail",
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
                caseName: "McKernon Motors v. Liberty Rail",
                citationJSON: #"["1 A.3d 100"]"#,
                preferredCitation: "1 A.3d 100",
                court: "Del.",
                reviewState: ResearchResultReviewState.saved.rawValue,
                rawResultJSON: #"{"caseName":"McKernon Motors v. Liberty Rail"}"#
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

    func testCountAuthoritiesAndOpinionTextPersistence() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        XCTAssertEqual(try store.authorities.countAuthorities(matterID: matter.id), 0)

        let session = try store.research.createSession(matterID: matter.id, title: "S", issueText: "I", jurisdiction: "FL", status: .approved)
        let query = try store.research.createQuery(researchSessionID: session.id, queryText: "q", queryIndex: 0, status: .approved)
        let result = try store.research.insertResult(ResearchResultRecord(researchQueryID: query.id, caseName: "Roe"))
        let authority = try store.authorities.insertAuthority(AuthorityRecord(
            matterID: matter.id, researchSessionID: session.id, researchResultID: result.id, caseName: "Roe"
        ))
        XCTAssertEqual(try store.authorities.countAuthorities(matterID: matter.id), 1)
        XCTAssertNil(try store.authorities.fetchAuthorities(matterID: matter.id).first?.opinionText)

        try store.authorities.updateOpinionText(authorityID: authority.id, text: "The opinion body.")
        XCTAssertEqual(try store.authorities.fetchAuthorities(matterID: matter.id).first?.opinionText, "The opinion body.")

        // Soft-deleted authorities leave the count (the local-first gate).
        _ = try store.authorities.softDeleteAuthority(id: authority.id)
        XCTAssertEqual(try store.authorities.countAuthorities(matterID: matter.id), 0)
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

    func testFetchGenerationSessionsCanReturnBeyondRecoveryWindow() throws {
        let store = try makeStore()
        let chat = try store.chats.createGlobalChat(title: "Global")

        for index in 0..<125 {
            let assistant = try store.chats.createAssistantMessageShell(chatID: chat.id)
            _ = try store.generation.createGenerationSession(
                chatID: chat.id,
                messageID: assistant.id,
                prompt: "Prompt \(index)",
                options: GenerationOptions()
            )
        }

        XCTAssertEqual(try store.generation.fetchGenerationSessions(chatID: chat.id, limit: 100).count, 100)
        XCTAssertEqual(try store.generation.fetchGenerationSessions(chatID: chat.id).count, 125)
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

    func testSoftDeleteMatterCascadesToChildFolders() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors")
        _ = try store.documentLibrary.createFolder(matterID: matter.id, name: "Contracts")
        _ = try store.documentLibrary.createFolder(matterID: matter.id, name: "Notes")
        XCTAssertEqual(try store.documentLibrary.fetchFolders(matterID: matter.id).count, 2)

        try store.matters.softDeleteMatter(id: matter.id)

        XCTAssertEqual(try store.matters.fetchMatters().count, 0, "matter is soft-deleted")
        XCTAssertEqual(
            try store.documentLibrary.fetchFolders(matterID: matter.id).count, 0,
            "child folders are cascade-soft-deleted with the matter"
        )
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
