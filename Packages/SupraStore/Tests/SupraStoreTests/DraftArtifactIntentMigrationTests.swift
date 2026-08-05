import GRDB
@testable import SupraStore
import XCTest

final class DraftArtifactIntentMigrationTests: XCTestCase {
    // T-DAI-01 RED: a public artifact needs a durable Store-owned intent before
    // publication so relaunch can finish or surface the interrupted operation.
    func testTDAI01V071CreatesDurableContentFreeArtifactIntentLedger() throws {
        let migrator = SupraMigrator.makeMigrator()
        XCTAssertTrue(migrator.migrations.contains("v071_create_draft_artifact_intents"))

        let queue = try DatabaseQueue()
        try migrator.migrate(queue)

        try queue.read { db in
            XCTAssertEqual(
                Set(try db.columns(in: "draft_artifact_intents").map(\.name)),
                Set([
                    "id", "matter_id", "artifact_kind", "format", "file_name",
                    "output_sha256", "output_byte_size", "audit_metadata_json",
                    "audit_metadata_sha256",
                    "motion_snapshot_request_json", "motion_snapshot_sha256",
                    "status", "created_at", "updated_at", "terminal_at",
                ])
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT \"unique\" FROM pragma_index_list('draft_artifact_intents') WHERE name = 'idx_draft_artifact_intents_matter_file'"
                ),
                1
            )
        }
    }

    #if DEBUG
    func testTDAI05DebugResetDropsAndRecreatesArtifactIntentLedger() throws {
        let database = try SupraDatabase.inMemory()
        let store = SupraStore(database: database)
        let matter = try store.matters.createMatter(name: "Reset artifact matter")
        _ = try store.draftArtifacts.prepareGenericIntent(
            matterID: matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Before-reset.md",
            output: Data("# Before reset\n".utf8),
            id: "before-debug-reset"
        )

        try database.resetForDebug()

        try database.writer.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM draft_artifact_intents"),
                0
            )
        }
        let after = try store.matters.createMatter(name: "Reusable reset matter")
        let intent = try store.draftArtifacts.prepareGenericIntent(
            matterID: after.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "After-reset.md",
            output: Data("# After reset\n".utf8),
            id: "after-debug-reset"
        )
        XCTAssertEqual(intent.status, DraftArtifactIntentStatus.prepared.rawValue)
    }
    #endif
}
