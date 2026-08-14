import Foundation
import GRDB
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

/// T-ART-01 — Saved Work export must publish a new, identity-owned artifact on
/// every explicit export, including two calls racing in the same second. The
/// immutable work-product version, Store intent, installed bytes/digest, export
/// link, and normative audit must stay coherent through Open and Export New
/// Version.
///
/// Expected RED: `DocumentExportService` currently derives one replace-in-place
/// path from title/version, creates no general publication intent, and records
/// multiple export rows for that one path. Concurrent calls overwrite the
/// preexisting canary, return the same URL, and have no intent/digest link.
final class ArchitectureUXTArt01Tests: XCTestCase {
    func testSameSecondConcurrentExportsAreCreateOnlyUniqueAndVersionExact() async throws {
        let fixture = try ArchitectureUXArtifactFixture.make(
            testID: "T-ART-01",
            marker: 731
        )
        defer { fixture.removeTemporaryFiles() }
        let legacyOverwriteURL = fixture.legacyReplaceInPlaceURL()
        try FileManager.default.createDirectory(
            at: legacyOverwriteURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let priorArtifact = Data("T_ART_01_PRIOR_ARTIFACT_713".utf8)
        try priorArtifact.write(to: legacyOverwriteURL, options: .withoutOverwriting)

        let firstPublisher = DocumentExportService(
            store: fixture.store,
            storage: fixture.storage
        )
        let secondPublisher = DocumentExportService(
            store: fixture.store,
            storage: fixture.storage
        )
        async let firstURL = firstPublisher.export(
            matterID: fixture.matter.id,
            structuredOutputID: fixture.output.id,
            format: .markdown
        )
        async let secondURL = secondPublisher.export(
            matterID: fixture.matter.id,
            structuredOutputID: fixture.output.id,
            format: .markdown
        )
        let (resolvedFirstURL, resolvedSecondURL) = try await (firstURL, secondURL)
        let concurrentURLs = [resolvedFirstURL, resolvedSecondURL]

        XCTAssertEqual(
            try Data(contentsOf: legacyOverwriteURL),
            priorArtifact,
            "create-only publication must not replace the exact preexisting v7 path"
        )
        XCTAssertEqual(
            Set(concurrentURLs.map { $0.standardizedFileURL.path }).count,
            2,
            "two same-second publishers must own two distinct final identities"
        )
        XCTAssertTrue(concurrentURLs.allSatisfy { $0 != legacyOverwriteURL })
        XCTAssertTrue(concurrentURLs.allSatisfy {
            !$0.path.contains(ArchitectureUXArtifactWire.forbiddenDefault)
        })
        for url in concurrentURLs {
            let bytes = try Data(contentsOf: url)
            XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("T-ART-01_SAVED_WORK_731"))
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(
                ArchitectureUXArtifactWire.forbiddenDefault
            ))
            try DocumentExportValidator.validate(bytes, as: .markdown)
        }

        let nextVersion = try fixture.appendExportableVersion(marker: 739)
        let nextURL = try DocumentExportService(
            store: fixture.store,
            storage: fixture.storage
        ).export(
            matterID: fixture.matter.id,
            structuredOutputID: fixture.output.id,
            format: .markdown
        )
        XCTAssertFalse(concurrentURLs.contains(nextURL))
        XCTAssertTrue(
            String(decoding: try Data(contentsOf: nextURL), as: UTF8.self)
                .contains("T_ART_01_RESAVED_VERSION_739")
        )
        for url in concurrentURLs {
            let reopened = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            XCTAssertTrue(reopened.contains("T-ART-01_SAVED_WORK_731"))
            XCTAssertFalse(reopened.contains("T_ART_01_RESAVED_VERSION_739"))
        }

        let exports = try fixture.store.documentSources.fetchExports(
            structuredOutputID: fixture.output.id
        )
        XCTAssertEqual(exports.count, 3)
        XCTAssertEqual(Set(exports.map(\.managedRelativePath)).count, 3)
        XCTAssertEqual(
            exports.filter { $0.structuredOutputVersionID == fixture.version.id }.count,
            2
        )
        XCTAssertEqual(
            exports.filter { $0.structuredOutputVersionID == nextVersion.id }.count,
            1
        )
        XCTAssertEqual(try fixture.exportAudits().count, 3)

        let intents = try fixture.completedGeneralIntents()
        XCTAssertEqual(intents.count, 3)
        XCTAssertTrue(intents.allSatisfy {
            $0.status == DraftArtifactIntentStatus.completed.rawValue
        })
        XCTAssertEqual(Set(intents.map(\.fileName)).count, 3)
        for intent in intents {
            let url = fixture.storage.exportsDirectory(forMatterID: fixture.matter.id)
                .appendingPathComponent(intent.fileName)
            let bytes = try Data(contentsOf: url)
            XCTAssertEqual(bytes.count, intent.outputByteSize)
            XCTAssertEqual(DocumentStorage.sha256Hex(of: bytes), intent.outputSHA256)
            XCTAssertFalse(intent.auditMetadataJSON.contains(
                ArchitectureUXArtifactWire.forbiddenDefault
            ))
        }

        let columns = try fixture.exportColumns()
        XCTAssertTrue(
            columns.contains(ArchitectureUXArtifactWire.publicationIntentLinkColumn),
            "each durable export row must link the exact Store-owned publication intent"
        )
        if columns.contains(ArchitectureUXArtifactWire.publicationIntentLinkColumn) {
            XCTAssertEqual(
                Set(try fixture.linkedIntentIDs()),
                Set(intents.map(\.id))
            )
        } else {
            XCTFail("T-ART-01 observed no publication_intent_id link on document_exports")
        }
    }

    func testNoSuccessURLBeforeValidatedIntentLinkAndAuditReadBack() throws {
        let fixture = try ArchitectureUXArtifactFixture.make(
            testID: "T-ART-01",
            marker: 743
        )
        defer { fixture.removeTemporaryFiles() }
        var returnedURL: URL?
        let publisher = DocumentExportService(
            store: fixture.store,
            storage: fixture.storage,
            completionRecorder: { _, _ in
                // Simulates a nominally successful callback that committed
                // neither half of the normative Store aggregate.
            }
        )

        XCTAssertThrowsError(
            try {
                returnedURL = try publisher.export(
                    matterID: fixture.matter.id,
                    structuredOutputID: fixture.output.id,
                    format: .markdown
                )
            }(),
            "a callback return is not authoritative publication success"
        )
        XCTAssertNil(returnedURL)
        XCTAssertTrue(
            try fixture.store.documentSources.fetchExports(
                structuredOutputID: fixture.output.id
            ).isEmpty
        )
        XCTAssertTrue(try fixture.exportAudits().isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.legacyReplaceInPlaceURL().path),
            "an unlinked file cannot be exposed as a successful saved-work export"
        )
        XCTAssertFalse(
            try fixture.completedGeneralIntents().contains {
                $0.status == DraftArtifactIntentStatus.completed.rawValue
            }
        )
    }
}
