import Foundation
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

/// T-ART-03 — a Store-prepared general export intent survives interruption
/// between exact install and finalization. Relaunch authenticates the installed
/// format/bytes/digest, atomically creates the exact Saved Work version link and
/// export audit, and makes a second reconciliation an idempotent no-op.
///
/// Expected RED: the existing reconciliation owner accepts draft-only kinds.
/// A synthetic `structured_output_export` intent is moved to recovery-required
/// even when its exact validated bytes are installed, so no document-export link
/// or completion audit can be recovered on relaunch.
final class ArchitectureUXTArt03Tests: XCTestCase {
    func testInterruptedGeneralExportFinalizesExactlyOnceOnRelaunch() throws {
        let fixture = try ArchitectureUXArtifactFixture.make(
            testID: "T-ART-03",
            marker: 731
        )
        defer { fixture.removeTemporaryFiles() }
        let fileName = "T-ART-03-WIRE-731-artifact-713-collision-\(ArchitectureUXArtifactWire.collisionSuffix).md"
        let installedBytes = Data(
            "# T_ART_03_WIRE_731\n\nInstalled \(ArchitectureUXArtifactWire.digestMarker).".utf8
        )
        let seeded = try fixture.seedInterruptedGeneralExport(
            fileName: fileName,
            data: installedBytes
        )
        XCTAssertEqual(seeded.id, ArchitectureUXArtifactWire.intentID)
        XCTAssertFalse(seeded.fileName.contains(ArchitectureUXArtifactWire.forbiddenDefault))

        XCTAssertNoThrow(
            try fixture.store.draftArtifacts.auditEventPreview(intentID: seeded.id),
            "the shared intent owner must recognize the remaining general-export consumer"
        )
        let reconciler = DraftArtifactReconciliationService(
            store: fixture.store,
            storage: fixture.storage
        )
        let first = try reconciler.reconcilePendingIntents()
        XCTAssertEqual(first.finalizedCount, 1)
        XCTAssertEqual(first.abortedCount, 0)
        XCTAssertEqual(first.recoveryRequiredCount, 0)

        let intent = try XCTUnwrap(fixture.store.draftArtifacts.intent(id: seeded.id))
        XCTAssertEqual(intent.status, DraftArtifactIntentStatus.completed.rawValue)
        XCTAssertEqual(intent.outputByteSize, installedBytes.count)
        XCTAssertEqual(intent.outputSHA256, DocumentStorage.sha256Hex(of: installedBytes))

        let exports = try fixture.store.documentSources.fetchExports(
            structuredOutputID: fixture.output.id
        )
        XCTAssertEqual(exports.count, 1)
        let export = try XCTUnwrap(exports.first)
        XCTAssertEqual(export.structuredOutputID, fixture.output.id)
        XCTAssertEqual(export.structuredOutputVersionID, fixture.version.id)
        XCTAssertEqual(export.matterID, fixture.matter.id)
        XCTAssertEqual(export.format, DocumentExportFormat.markdown.rawValue)
        XCTAssertEqual(export.managedRelativePath, "exports/\(fixture.matter.id)/\(fileName)")
        XCTAssertEqual(try Data(contentsOf: fixture.publicURL(for: export)), installedBytes)
        XCTAssertEqual(try fixture.exportAudits().count, 1)
        XCTAssertTrue(
            try fixture.store.remediationRecovery.pendingItems().filter {
                $0.matterID == fixture.matter.id
            }.isEmpty
        )

        let columns = try fixture.exportColumns()
        XCTAssertTrue(columns.contains(ArchitectureUXArtifactWire.publicationIntentLinkColumn))
        if columns.contains(ArchitectureUXArtifactWire.publicationIntentLinkColumn) {
            XCTAssertEqual(try fixture.linkedIntentIDs(), [seeded.id])
        } else {
            XCTFail("T-ART-03 recovered export has no exact publication-intent link")
        }

        let second = try reconciler.reconcilePendingIntents()
        XCTAssertEqual(second, DraftArtifactReconciliationSummary())
        XCTAssertEqual(
            try fixture.store.documentSources.fetchExports(
                structuredOutputID: fixture.output.id
            ).count,
            1,
            "relaunch retry cannot duplicate the Saved Work artifact link"
        )
        XCTAssertEqual(try fixture.exportAudits().count, 1)
        XCTAssertEqual(
            try Data(contentsOf: fixture.publicURL(for: export)),
            installedBytes
        )
    }

    func testAlteredInterruptedFileIsPreservedAndCannotReconcileAsSuccess() throws {
        let fixture = try ArchitectureUXArtifactFixture.make(
            testID: "T-ART-03",
            marker: 743
        )
        defer { fixture.removeTemporaryFiles() }
        let fileName = "T-ART-03-WIRE-743-artifact-713-collision-\(ArchitectureUXArtifactWire.collisionSuffix).md"
        let intended = Data("# T_ART_03_INTENDED_743\n\n\(ArchitectureUXArtifactWire.digestMarker)".utf8)
        let seeded = try fixture.seedInterruptedGeneralExport(
            fileName: fileName,
            data: intended
        )
        XCTAssertNoThrow(try fixture.store.draftArtifacts.auditEventPreview(intentID: seeded.id))
        let publicURL = fixture.storage.exportsDirectory(forMatterID: fixture.matter.id)
            .appendingPathComponent(fileName)
        let replacement = Data("# T_ART_03_THIRD_PARTY_751\n\nPreserve exactly.".utf8)
        try replacement.write(to: publicURL, options: .atomic)

        let summary = try DraftArtifactReconciliationService(
            store: fixture.store,
            storage: fixture.storage
        ).reconcilePendingIntents()
        XCTAssertEqual(summary.finalizedCount, 0)
        XCTAssertEqual(summary.recoveryRequiredCount, 1)
        XCTAssertEqual(try Data(contentsOf: publicURL), replacement)
        XCTAssertEqual(
            try fixture.store.draftArtifacts.intent(id: seeded.id)?.status,
            DraftArtifactIntentStatus.recoveryRequired.rawValue
        )
        XCTAssertTrue(
            try fixture.store.documentSources.fetchExports(
                structuredOutputID: fixture.output.id
            ).isEmpty
        )
        XCTAssertTrue(try fixture.exportAudits().isEmpty)
        XCTAssertFalse(
            String(decoding: replacement, as: UTF8.self).contains(
                ArchitectureUXArtifactWire.forbiddenDefault
            )
        )
    }
}
