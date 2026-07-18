import Foundation
import GRDB
import SupraCore
@testable import SupraStore
import XCTest

final class VerificationDimensionsMigrationTests: XCTestCase {
    func testTMIG11V069LeavesLegacyDimensionsNotRunAndRequiresCompleteDimensionsForNewVerifiedWrites() throws {
        // T-MIG-11/T-DIM-02 expected RED: v069, the dimensions column/domain,
        // and the fail-closed repository argument do not exist.
        let migrator = SupraMigrator.makeMigrator()
        XCTAssertTrue(migrator.migrations.contains("v069_add_verification_dimensions"))
        let queue = try DatabaseQueue()
        try migrator.migrate(queue, upTo: "v068_add_document_classification_lineage")

        let matter = try MattersRepository(writer: queue).createMatter(name: "Synthetic v069 matter")
        let repository = StructuredOutputRepository(writer: queue)
        let output = try repository.createOutput(
            matterID: matter.id,
            title: "Synthetic legacy dimension output",
            outputType: .documentQA
        )
        let legacyID = "legacy-v068-dimension-version"
        let legacyDate = Date(timeIntervalSinceReferenceDate: 690)
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO structured_output_versions (
                    id, structured_output_id, version_index, content_markdown,
                    required_sections_json, present_sections_json, missing_sections_json,
                    verification_status, verification_version, verification_json,
                    assurance_state, created_at, updated_at
                ) VALUES (?, ?, 1, ?, '[]', '[]', '[]', ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    legacyID, output.id, "NONDEFAULT LEGACY CONTENT",
                    OutputVerificationStatus.allSupported.rawValue,
                    "legacy-support-v1", "[]",
                    OutputAssuranceState.propositionSupported.rawValue,
                    legacyDate, legacyDate,
                ]
            )
        }

        try migrator.migrate(queue)
        try queue.read { db in
            XCTAssertEqual(
                try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid").last,
                "v069_add_verification_dimensions"
            )
            XCTAssertTrue(try db.columns(in: "structured_output_versions").contains {
                $0.name == "verification_dimensions_json" && !$0.isNotNull
            })
        }

        let legacy = try XCTUnwrap(repository.fetchVersion(id: legacyID))
        XCTAssertEqual(legacy.contentMarkdown, "NONDEFAULT LEGACY CONTENT")
        XCTAssertEqual(legacy.verificationStatus, OutputVerificationStatus.allSupported.rawValue)
        XCTAssertNil(legacy.verificationDimensionsJSON)
        XCTAssertEqual(
            legacy.verificationDimensions.results.map(\.dimension),
            VerificationDimensionName.allCases
        )
        XCTAssertTrue(legacy.verificationDimensions.results.allSatisfy { $0.status == .notRun })

        let supported = try PropositionSupportResult(
            propositionID: "dimension-proposition",
            status: .supported,
            reasons: ["Synthetic source supports the proposition."],
            evidence: [SupportEvidence(
                sourceID: "synthetic/source",
                sourceLabel: "S-DIM",
                locator: "chars 17-49",
                retainedExcerpt: "NONDEFAULT DIMENSION EVIDENCE",
                verifierName: "SyntheticVerifier",
                verifierVersion: "synthetic-v69"
            )],
            timestamp: legacyDate
        )

        XCTAssertThrowsError(try repository.createVersion(
            structuredOutputID: output.id,
            contentMarkdown: "SHOULD NOT COMMIT WITHOUT DIMENSIONS",
            requiredSections: [],
            presentSections: [],
            missingSections: [],
            verificationStatus: .allSupported,
            verificationVersion: "document-support-v1",
            verificationResults: [supported],
            assuranceState: .propositionSupported,
            outputStatus: .complete
        )) { error in
            XCTAssertEqual(error as? StructuredOutputRepositoryError, .verificationDimensionsRequired)
        }
        XCTAssertEqual(try repository.fetchVersions(structuredOutputID: output.id).map(\.id), [legacyID])

        let complete = VerificationDimensions.complete(overrides: [
            .init(dimension: .propositionSupport, status: .satisfied, reason: "Supported"),
            .init(dimension: .citationResolution, status: .satisfied, reason: "Resolved"),
            .init(dimension: .criticalValueFidelity, status: .satisfied, reason: "Matched"),
            .init(dimension: .lowConfidenceHandling, status: .satisfied, reason: "Clear"),
        ])
        let inserted = try repository.createVersion(
            structuredOutputID: output.id,
            contentMarkdown: "NEW VERSION WITH COMPLETE DIMENSIONS",
            requiredSections: [],
            presentSections: [],
            missingSections: [],
            verificationStatus: .allSupported,
            verificationVersion: "document-support-v1",
            verificationResults: [supported],
            verificationDimensions: complete,
            assuranceState: .propositionSupported,
            outputStatus: .complete
        )
        XCTAssertNotNil(inserted.verificationDimensionsJSON)
        XCTAssertEqual(inserted.verificationDimensions, complete)
    }
}
