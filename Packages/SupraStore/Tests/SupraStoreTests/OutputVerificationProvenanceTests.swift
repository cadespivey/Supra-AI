import Foundation
import GRDB
import SupraCore
@testable import SupraStore
import XCTest

final class OutputVerificationProvenanceTests: XCTestCase {
    func testACRMigration001V054FixtureBackfillsProvenanceAndRequiresLegacyReview() throws {
        // Expected RED: v055 and its four verification columns do not exist before WP0-03.
        let queue = try DatabaseQueue()
        let migrator = SupraMigrator.makeMigrator()
        try migrator.migrate(queue, upTo: "v054_add_matter_pinned_at")

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO matters (id, name, created_at, updated_at)
                VALUES (?, ?, ?, ?)
                """,
                arguments: ["matter-legacy", "Synthetic Legacy Matter", now, now]
            )
            try db.execute(
                sql: """
                INSERT INTO structured_outputs
                    (id, matter_id, title, output_type, active_version_id, status, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "output-legacy", "matter-legacy", "Legacy synthesis", "rule_synthesis",
                    "version-legacy", StructuredOutputStatus.complete.rawValue, now, now,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO structured_output_versions
                    (id, structured_output_id, version_index, content_markdown,
                     required_sections_json, present_sections_json, missing_sections_json,
                     created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "version-legacy", "output-legacy", 1, "# Preserved legacy content",
                    "[]", "[]", "[]", now, now,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO document_source_sets
                    (id, matter_id, structured_output_version_id, status, mode, scope_json, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "sources-legacy", "matter-legacy", "version-legacy",
                    DocumentSourceSetStatus.attached.rawValue, DocumentSourceSetMode.autoSource.rawValue,
                    "{}", now,
                ]
            )
        }

        try migrator.migrate(queue)

        try queue.read { db in
            let columns = try db.columns(in: "structured_output_versions").map(\.name)
            XCTAssertTrue(columns.contains("verification_status"))
            XCTAssertTrue(columns.contains("verification_version"))
            XCTAssertTrue(columns.contains("verification_json"))
            XCTAssertTrue(columns.contains("verified_at"))

            let version = try XCTUnwrap(try StructuredOutputVersionRecord.fetchOne(db, key: "version-legacy"))
            XCTAssertEqual(version.contentMarkdown, "# Preserved legacy content")
            XCTAssertEqual(version.verificationStatus, OutputVerificationStatus.legacyUnverified.rawValue)
            XCTAssertNil(version.verificationVersion)
            XCTAssertNil(version.verificationJSON)
            XCTAssertNil(version.verifiedAt)

            let output = try XCTUnwrap(try StructuredOutputRecord.fetchOne(db, key: "output-legacy"))
            XCTAssertEqual(output.status, StructuredOutputStatus.needsReview.rawValue)
            XCTAssertEqual(output.activeVersionID, "version-legacy")
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT structured_output_version_id FROM document_source_sets WHERE id = ?",
                    arguments: ["sources-legacy"]
                ),
                "version-legacy"
            )
        }
    }

    func testACRMigration002FailedAtomicProvenanceWriteRollsBackVersionAndParentState() throws {
        // Expected RED: version/source/provenance/parent writes are not one repository transaction.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic Rollback Matter")
        let output = try store.structuredOutputs.createOutput(
            matterID: matter.id,
            title: "Rollback proof",
            outputType: .documentQA
        )

        XCTAssertThrowsError(
            try store.structuredOutputs.createVersion(
                structuredOutputID: output.id,
                contentMarkdown: "A supported proposition [S1].",
                requiredSections: [],
                presentSections: [],
                missingSections: [],
                verificationStatus: .allSupported,
                verificationVersion: "support-contract/1.0",
                verificationResults: [try supportedResult()],
                verifiedAt: Date(timeIntervalSince1970: 1_700_000_123),
                sourceSetID: "missing-source-set",
                outputStatus: .complete
            )
        ) { error in
            XCTAssertEqual(
                error as? StructuredOutputRepositoryError,
                .sourceSetUnavailable("missing-source-set")
            )
        }

        XCTAssertTrue(try store.structuredOutputs.fetchVersions(structuredOutputID: output.id).isEmpty)
        let storedOutput = try XCTUnwrap(try store.structuredOutputs.fetchOutputs(matterID: matter.id).single)
        XCTAssertNil(storedOutput.activeVersionID)
        XCTAssertEqual(storedOutput.status, StructuredOutputStatus.draft.rawValue)
    }

    func testACRMigration003VerifiedVersionRoundTripsAndCommitsSourceAndParentAtomically() throws {
        // Expected RED: records/repositories cannot persist or round-trip provenance before WP0-03.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic Provenance Matter")
        let output = try store.structuredOutputs.createOutput(
            matterID: matter.id,
            title: "Provenance round trip",
            outputType: .documentQA
        )
        let sourceSet = try store.documentSources.createSourceSet(
            matterID: matter.id,
            mode: .guided,
            retrievalQuery: "fictional payment date"
        )
        let verifiedAt = Date(timeIntervalSince1970: 1_700_000_123)
        let expectedResult = try supportedResult()

        let version = try store.structuredOutputs.createVersion(
            structuredOutputID: output.id,
            contentMarkdown: "Payment was due March 3, 2024 [S1].",
            requiredSections: [],
            presentSections: [],
            missingSections: [],
            verificationStatus: .allSupported,
            verificationVersion: "support-contract/1.0",
            verificationResults: [expectedResult],
            verifiedAt: verifiedAt,
            sourceSetID: sourceSet.id,
            outputStatus: .complete
        )

        let storedVersion = try XCTUnwrap(
            try store.structuredOutputs.fetchVersions(structuredOutputID: output.id).single
        )
        XCTAssertEqual(storedVersion.id, version.id)
        XCTAssertEqual(storedVersion.verificationStatus, OutputVerificationStatus.allSupported.rawValue)
        XCTAssertEqual(storedVersion.verificationVersion, "support-contract/1.0")
        XCTAssertEqual(storedVersion.verifiedAt, verifiedAt)
        let provenanceJSON = try XCTUnwrap(storedVersion.verificationJSON)
        XCTAssertEqual(
            try DateCoding.decoder.decode([PropositionSupportResult].self, from: Data(provenanceJSON.utf8)),
            [expectedResult]
        )

        let storedOutput = try XCTUnwrap(try store.structuredOutputs.fetchOutputs(matterID: matter.id).single)
        XCTAssertEqual(storedOutput.activeVersionID, version.id)
        XCTAssertEqual(storedOutput.status, StructuredOutputStatus.complete.rawValue)
        let attached = try XCTUnwrap(try store.documentSources.fetchSourceSet(id: sourceSet.id))
        XCTAssertEqual(attached.structuredOutputVersionID, version.id)
        XCTAssertEqual(attached.status, DocumentSourceSetStatus.attached.rawValue)
    }

    private func supportedResult() throws -> PropositionSupportResult {
        try PropositionSupportResult(
            propositionID: "proposition-001",
            status: .supported,
            reasons: ["direct_textual_support"],
            evidence: [
                SupportEvidence(
                    sourceID: "chunk-001",
                    sourceLabel: "S1",
                    locator: "Synthetic.pdf, page 1, paragraph 3",
                    retainedExcerpt: "Payment shall be due March 3, 2024.",
                    verifierName: "DocumentSupportVerifier",
                    verifierVersion: "support-contract/1.0"
                ),
            ],
            timestamp: Date(timeIntervalSince1970: 1_700_000_123)
        )
    }

    private func makeStore() throws -> SupraStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OutputVerificationProvenanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try SupraStore(url: directoryURL.appendingPathComponent("test.sqlite"))
    }
}

private extension Array {
    var single: Element? {
        count == 1 ? first : nil
    }
}
