import Foundation
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

/// T-ART-02 — compensation owns an exact installed identity, never a pathname.
/// If the public name is replaced after install, Supra preserves the replacement,
/// records recovery-required, and publishes no export/audit success. Managed-root
/// authority also rejects a symlink escape before any bytes or success rows exist.
///
/// Expected RED: general export snapshots only the old path bytes, installs with
/// replace semantics, and unconditionally removes a newly-created path after a
/// completion failure. A third-party atomic replacement is therefore deleted,
/// no recovery item exists, and a symlinked matter export directory is followed.
final class ArchitectureUXTArt02Tests: XCTestCase {
    private enum InjectedFailure: Error { case afterReplacement }

    func testThirdPartyReplacementIsPreservedAndDurablyRequiresRecovery() throws {
        let fixture = try ArchitectureUXArtifactFixture.make(
            testID: "T-ART-02",
            marker: 731
        )
        defer { fixture.removeTemporaryFiles() }
        let thirdPartyBytes = Data(
            "T_ART_02_THIRD_PARTY_REPLACEMENT_727 \(ArchitectureUXArtifactWire.digestMarker)".utf8
        )
        var installedURL: URL?
        var returnedURL: URL?
        let publisher = DocumentExportService(
            store: fixture.store,
            storage: fixture.storage,
            completionRecorder: { export, _ in
                let url = fixture.publicURL(for: export)
                try DocumentExportValidator.validate(url, as: .markdown)
                installedURL = url
                try thirdPartyBytes.write(to: url, options: .atomic)
                throw InjectedFailure.afterReplacement
            }
        )

        XCTAssertThrowsError(
            try {
                returnedURL = try publisher.export(
                    matterID: fixture.matter.id,
                    structuredOutputID: fixture.output.id,
                    format: .markdown
                )
            }()
        )
        XCTAssertNil(returnedURL)
        let replacementURL = try XCTUnwrap(installedURL)
        XCTAssertEqual(
            try? Data(contentsOf: replacementURL),
            thirdPartyBytes,
            "the exact third-party replacement must survive failed compensation"
        )
        XCTAssertFalse(
            String(decoding: thirdPartyBytes, as: UTF8.self).contains(
                ArchitectureUXArtifactWire.forbiddenDefault
            )
        )

        let recoveries = try fixture.store.remediationRecovery.pendingItems().filter {
            $0.matterID == fixture.matter.id
        }
        XCTAssertEqual(recoveries.count, 1)
        let recovery = try XCTUnwrap(recoveries.first)
        XCTAssertTrue(recovery.relatedTable.localizedCaseInsensitiveContains("artifact"))
        XCTAssertFalse(recovery.relatedID.isEmpty)
        XCTAssertNotEqual(recovery.relatedID, ArchitectureUXArtifactWire.forbiddenDefault)
        XCTAssertEqual(recovery.status, RemediationRecoveryStatus.pending.rawValue)

        XCTAssertTrue(
            try fixture.store.documentSources.fetchExports(
                structuredOutputID: fixture.output.id
            ).isEmpty
        )
        XCTAssertTrue(try fixture.exportAudits().isEmpty)
        XCTAssertFalse(
            try fixture.completedGeneralIntents().contains {
                $0.status == DraftArtifactIntentStatus.completed.rawValue
            }
        )
    }

    func testSymlinkedMatterDirectoryCannotEscapeManagedPublicationRoot() throws {
        let fixture = try ArchitectureUXArtifactFixture.make(
            testID: "T-ART-02",
            marker: 739
        )
        defer { fixture.removeTemporaryFiles() }
        let externalRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("T-ART-02-ESCAPE-739-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: externalRoot) }
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: fixture.storage.exportsDirectory,
            withIntermediateDirectories: true
        )
        let matterDirectory = fixture.storage.exportsDirectory(forMatterID: fixture.matter.id)
        try FileManager.default.createSymbolicLink(
            at: matterDirectory,
            withDestinationURL: externalRoot
        )

        XCTAssertThrowsError(
            try DocumentExportService(
                store: fixture.store,
                storage: fixture.storage
            ).export(
                matterID: fixture.matter.id,
                structuredOutputID: fixture.output.id,
                format: .markdown
            )
        )
        let escapedEntries = try FileManager.default.contentsOfDirectory(
            at: externalRoot,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(
            escapedEntries.isEmpty,
            "a symlink/root escape must be rejected before a temporary or final artifact is written"
        )
        XCTAssertTrue(
            try fixture.store.documentSources.fetchExports(
                structuredOutputID: fixture.output.id
            ).isEmpty
        )
        XCTAssertTrue(try fixture.exportAudits().isEmpty)
        XCTAssertFalse(
            escapedEntries.contains { $0.path.contains(ArchitectureUXArtifactWire.forbiddenDefault) }
        )
    }
}
