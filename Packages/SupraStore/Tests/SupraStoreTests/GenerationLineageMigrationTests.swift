import Foundation
import GRDB
import SupraCore
@testable import SupraStore
import XCTest

final class GenerationLineageMigrationTests: XCTestCase {
    func testTMIG09V067BackfillsOnlyRunLinkedAssuranceAndKeepsDocumentSessionsChatOptional() throws {
        // T-MIG-09 expected RED: v067 is not registered; output versions have no
        // prompt/assurance/stale columns and generation sessions are chat-only.
        let migrator = SupraMigrator.makeMigrator()
        XCTAssertTrue(migrator.migrations.contains("v067_add_output_generation_lineage"))
        let queue = try DatabaseQueue()
        try migrator.migrate(queue, upTo: "v066_add_document_source_lineage")

        let matters = MattersRepository(writer: queue)
        let chats = ChatRepository(writer: queue)
        let outputs = StructuredOutputRepository(writer: queue)
        let generation = GenerationRepository(writer: queue)
        let matter = try matters.createMatter(name: "Synthetic v067 lineage matter")
        let chat = try chats.createMatterChat(matterID: matter.id, title: "Legacy chat lineage")
        let message = try chats.createAssistantMessageShell(chatID: chat.id)
        let legacySession = try generation.createGenerationSession(
            chatID: chat.id,
            messageID: message.id,
            modelID: "runtime-uuid-only",
            prompt: "legacy prompt bytes",
            options: GenerationOptions(temperature: 0.37, maxOutputTokens: 77)
        )
        let linkedOutput = try outputs.createOutput(
            matterID: matter.id,
            title: "Run-linked output",
            outputType: .documentExhaustiveList,
            status: .needsReview
        )
        let linkedVersion = try outputs.createVersion(
            structuredOutputID: linkedOutput.id,
            contentMarkdown: "RUN-LINKED-CONTENT",
            requiredSections: [],
            presentSections: [],
            missingSections: [],
            generationSessionID: legacySession.id,
            makeActive: true
        )
        let unrelatedOutput = try outputs.createOutput(
            matterID: matter.id,
            title: "Unrelated historical output",
            outputType: .documentQA,
            status: .needsReview
        )
        let unrelatedVersion = try outputs.createVersion(
            structuredOutputID: unrelatedOutput.id,
            contentMarkdown: "UNRELATED-HISTORICAL-CONTENT",
            requiredSections: [],
            presentSections: [],
            missingSections: [],
            makeActive: true
        )
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO corpus_analysis_runs (
                    id, run_key, matter_id, task_kind, scope_json,
                    corpus_snapshot_json, partition_strategy,
                    partition_strategy_version, status, assurance_state,
                    structured_output_version_id, created_at, completed_at
                ) VALUES (
                    'run-v067-linked', 'run-key-v067-linked', ?, 'exhaustive_list', '{}',
                    '{"schema_version":1,"members":[]}', 'synthetic', 1,
                    'persisted', 'corpus_complete', ?, ?, ?
                )
                """,
                arguments: [matter.id, linkedVersion.id, Date(), Date()]
            )
        }

        try migrator.migrate(queue)
        try queue.read { db in
            XCTAssertEqual(try appliedMigrations(db).last, "v067_add_output_generation_lineage")
            XCTAssertEqual(Set(try db.columns(in: "structured_output_versions").map(\.name)), Set([
                "id", "structured_output_id", "version_index", "parent_version_id",
                "content_markdown", "required_sections_json", "present_sections_json",
                "missing_sections_json", "repair_reason", "generation_session_id",
                "verification_status", "verification_version", "verification_json",
                "verified_at", "prompt_builder_version", "assurance_state", "stale_reason",
                "created_at", "updated_at",
            ]))
            let generationColumns = Dictionary(
                uniqueKeysWithValues: try db.columns(in: "generation_sessions").map { ($0.name, $0) }
            )
            XCTAssertEqual(Set(generationColumns.keys), Set([
                "id", "chat_id", "message_id", "variant_id", "model_id",
                "model_repository", "model_revision", "prompt_builder_version",
                "prompt", "system_prompt", "options_json", "status", "started_at",
                "first_token_at", "completed_at", "load_time_ms", "first_token_latency_ms",
                "tokens_per_second", "cancellation_latency_ms", "peak_memory_mb",
                "generated_token_count", "error_summary", "interruption_reason",
                "diagnostic_event_id", "created_at", "updated_at",
            ]))
            XCTAssertFalse(try XCTUnwrap(generationColumns["chat_id"]).isNotNull)
            XCTAssertFalse(try XCTUnwrap(generationColumns["message_id"]).isNotNull)
        }

        let migratedLinked = try XCTUnwrap(outputs.fetchVersion(id: linkedVersion.id))
        let migratedUnrelated = try XCTUnwrap(outputs.fetchVersion(id: unrelatedVersion.id))
        XCTAssertEqual(migratedLinked.contentMarkdown, "RUN-LINKED-CONTENT")
        XCTAssertEqual(migratedLinked.assuranceState, OutputAssuranceState.corpusComplete.rawValue)
        XCTAssertNil(migratedLinked.promptBuilderVersion)
        XCTAssertNil(migratedLinked.staleReason)
        XCTAssertEqual(migratedUnrelated.contentMarkdown, "UNRELATED-HISTORICAL-CONTENT")
        XCTAssertNil(migratedUnrelated.assuranceState)
        XCTAssertNil(migratedUnrelated.promptBuilderVersion)
        XCTAssertNil(migratedUnrelated.staleReason)

        let preservedSession = try XCTUnwrap(generation.fetchGenerationSession(generationID: legacySession.id))
        XCTAssertEqual(preservedSession.chatID, chat.id)
        XCTAssertEqual(preservedSession.messageID, message.id)
        XCTAssertNil(preservedSession.modelRepository)
        XCTAssertNil(preservedSession.modelRevision)
        XCTAssertNil(preservedSession.promptBuilderVersion)

        let documentSession = try generation.createDocumentGenerationSession(
            modelID: "transient-runtime-uuid",
            modelRepository: "synthetic/runtime-model",
            modelRevision: "revision-nondefault-067",
            promptBuilderVersion: "document-prompt-v67",
            prompt: "DOCUMENT-PROMPT-NONDEFAULT",
            systemPrompt: "DOCUMENT-SYSTEM-NONDEFAULT",
            options: GenerationOptions(temperature: 0.43, maxOutputTokens: 319)
        )
        XCTAssertNil(documentSession.chatID)
        XCTAssertNil(documentSession.messageID)
        XCTAssertEqual(documentSession.modelRepository, "synthetic/runtime-model")
        XCTAssertEqual(documentSession.modelRevision, "revision-nondefault-067")
        XCTAssertEqual(documentSession.promptBuilderVersion, "document-prompt-v67")
        XCTAssertTrue(documentSession.optionsJSON.contains("319"))

        XCTAssertThrowsError(try generation.createDocumentGenerationSession(
            modelID: "transient-runtime-uuid",
            modelRepository: "",
            modelRevision: "",
            promptBuilderVersion: "document-prompt-v67",
            prompt: "UUID-ONLY-MUST-BE-REJECTED",
            options: GenerationOptions()
        ))
    }

    private func appliedMigrations(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
    }
}
