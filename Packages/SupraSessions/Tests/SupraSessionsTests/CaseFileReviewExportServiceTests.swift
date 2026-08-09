import CryptoKit
import Foundation
import GRDB
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

@MainActor
final class CaseFileReviewExportServiceTests: XCTestCase {
    private enum InjectedFailure: Error {
        case stop
    }

    private static let expectedHeader = [
        "Row",
        "Finding",
        "Generated value",
        "Attorney value",
        "Current value",
        "Value state",
        "Review state",
        "Reviewed by",
        "Reviewed at (UTC)",
        "Support state",
        "Supporting source count",
        "Supporting sources",
        "Contrary source count",
        "Contrary sources",
        "Project",
        "Project status",
        "Project stale reason",
        "Matrix version",
        "Project ID",
        "Cell ID",
        "Source run ID",
        "Source output ID",
        "Source output version ID",
        "Project updated at (UTC)",
        "Exported at (UTC)",
    ]

    func testTRPEXPORT01WritesDeterministicAllRowSnapshotWithHostileCellsAndContraryOnlyWork() throws {
        // T-RP-EXPORT-01 expected RED: no CaseFileReviewExportService or atomic
        // Store snapshot API exists, so Review cannot render the approved
        // 25-column all-row CSV independently of Structured Output eligibility.
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let exportedAt = try instant("2026-08-09T18:45:00Z")
        let service = CaseFileReviewExportService(
            store: fixture.store,
            storage: fixture.storage
        )

        let url = try service.exportCSV(
            matterID: fixture.matterID,
            projectID: fixture.primary.id,
            actor: "Casey Finch",
            at: exportedAt
        )

        XCTAssertEqual(
            url.lastPathComponent,
            "Atlas-Amendment-Review-snapshot-v1-20260809T184500Z.csv"
        )
        XCTAssertEqual(
            url.deletingLastPathComponent().standardizedFileURL,
            fixture.storage.exportsDirectory(forMatterID: fixture.matterID).standardizedFileURL
        )
        let data = try Data(contentsOf: url)
        try assertProfessionalCSVBytes(data)
        try DocumentExportValidator.validate(data, as: .csv)
        let records = try parseCSV(data)
        XCTAssertEqual(records.first, Self.expectedHeader)
        XCTAssertEqual(records.count, 4, "one header plus all three persisted findings")
        XCTAssertTrue(records.dropFirst().allSatisfy { $0.count == Self.expectedHeader.count })

        let rows = records.dropFirst().map(rowDictionary)
        XCTAssertEqual(rows.compactMap { $0["Row"] }, ["1", "2", "3"])
        XCTAssertEqual(
            rows.compactMap { $0["Finding"] },
            [
                "'=HYPERLINK(\"https://evil.invalid\",\"row\")",
                "rent-escalation-cap",
                "contrary-only-deleted-source",
            ],
            "physical insertion order and the active UI filter must not influence snapshot order"
        )

        let hostile = rows[0]
        XCTAssertEqual(hostile["Generated value"], "'+SUM(1,1) · Résumé — 安全")
        XCTAssertEqual(hostile["Attorney value"], "")
        XCTAssertEqual(hostile["Current value"], "'+SUM(1,1) · Résumé — 安全")
        let hostileFinding: String = try XCTUnwrap(hostile["Finding"])
        let hostileGeneratedValue: String = try XCTUnwrap(hostile["Generated value"])
        XCTAssertFalse(hostileFinding.hasPrefix("="))
        XCTAssertFalse(hostileGeneratedValue.hasPrefix("+"))
        XCTAssertEqual(hostile["Value state"], "generated")
        XCTAssertEqual(hostile["Review state"], "reviewed")
        XCTAssertEqual(hostile["Reviewed by"], "Casey Finch")
        XCTAssertEqual(hostile["Reviewed at (UTC)"], "2026-08-09T18:41:12.000Z")
        XCTAssertEqual(hostile["Supporting source count"], "2")
        XCTAssertEqual(hostile["Contrary source count"], "0")
        XCTAssertEqual(
            hostile["Supporting sources"],
            "[E1] Résumé Lease.csv — p. 1 — available\r\n"
                + "ALPHA, \"quoted\"\r\nline\r\nend.\r\n\r\n"
                + "[E2] Résumé Lease.csv — p. 2 — available\r\nBETA-SUPPORT-2",
            "source details must follow evidence ordinal, not insertion or identifier order"
        )

        let edited = rows[1]
        XCTAssertEqual(edited["Generated value"], "3%")
        XCTAssertEqual(edited["Attorney value"], "'@cmd")
        XCTAssertEqual(edited["Current value"], "'@cmd")
        XCTAssertNotEqual(edited["Current value"], edited["Generated value"])
        let editedCurrentValue: String = try XCTUnwrap(edited["Current value"])
        XCTAssertFalse(editedCurrentValue.hasPrefix("@"))
        XCTAssertEqual(edited["Value state"], "edited")
        XCTAssertEqual(edited["Review state"], "needs_review")
        XCTAssertEqual(edited["Reviewed by"], "")
        XCTAssertEqual(edited["Reviewed at (UTC)"], "")
        XCTAssertEqual(edited["Support state"], "supported")
        XCTAssertEqual(edited["Supporting source count"], "1")
        XCTAssertEqual(edited["Contrary source count"], "1")
        XCTAssertEqual(
            edited["Supporting sources"],
            "[S977] Résumé Lease.csv — p. 3 — available\r\nSUPPORT-3%"
        )
        XCTAssertEqual(
            edited["Contrary sources"],
            "[C983] Résumé Lease.csv — p. 4 — available\r\nCONTRARY-2.5%"
        )
        let supportingSources: String = try XCTUnwrap(edited["Supporting sources"])
        let contrarySources: String = try XCTUnwrap(edited["Contrary sources"])
        XCTAssertFalse(
            supportingSources.contains("CONTRARY-2.5%"),
            "supporting and contrary evidence must stay in their exact output cells"
        )
        XCTAssertFalse(
            contrarySources.contains("SUPPORT-3%"),
            "contrary evidence must not inherit the supporting excerpt"
        )

        let contraryOnly = rows[2]
        XCTAssertEqual(contraryOnly["Generated value"], "'-12 months")
        XCTAssertEqual(contraryOnly["Current value"], "'-12 months")
        XCTAssertEqual(contraryOnly["Support state"], "stale")
        XCTAssertEqual(contraryOnly["Supporting source count"], "0")
        XCTAssertEqual(contraryOnly["Supporting sources"], "")
        XCTAssertEqual(contraryOnly["Contrary source count"], "1")
        XCTAssertEqual(
            contraryOnly["Contrary sources"],
            "[C999] Deleted Schedule.pdf — p. 9 — unavailable "
                + "(source_permanently_deleted)\r\n"
                + "FROZEN, \"contrary\"\r\nold\r\nline."
        )

        for row in rows {
            XCTAssertEqual(row["Project"], "Atlas Amendment Review")
            XCTAssertEqual(row["Project status"], "stale")
            XCTAssertEqual(row["Project stale reason"], "source_permanently_deleted")
            XCTAssertEqual(row["Matrix version"], "1")
            XCTAssertEqual(row["Project ID"], fixture.primary.id)
            XCTAssertEqual(row["Source run ID"], fixture.primary.sourceRunID)
            XCTAssertEqual(row["Source output ID"], fixture.primary.sourceOutputID)
            XCTAssertEqual(
                row["Source output version ID"],
                fixture.primary.sourceOutputVersionID
            )
            XCTAssertEqual(row["Project updated at (UTC)"], "2026-08-09T17:30:00.000Z")
            XCTAssertEqual(row["Exported at (UTC)"], "2026-08-09T18:45:00.000Z")
        }

        let exports = try fixture.store.documentSources.fetchExports(matterID: fixture.matterID)
        let export = try XCTUnwrap(exports.single)
        XCTAssertEqual(export.format, "review_csv")
        XCTAssertNil(export.structuredOutputID)
        XCTAssertNil(export.structuredOutputVersionID)
        XCTAssertEqual(
            export.managedRelativePath,
            "exports/\(fixture.matterID)/\(url.lastPathComponent)"
        )
        let audits = try fixture.store.auditEvents.fetchEvents(matterID: fixture.matterID)
            .filter { $0.eventType == "case_file_review_snapshot_exported" }
        let audit = try XCTUnwrap(audits.single)
        XCTAssertEqual(audit.actor, "Casey Finch")
        XCTAssertEqual(audit.relatedTable, CaseFileReviewProjectRecord.databaseTableName)
        XCTAssertEqual(audit.relatedID, fixture.primary.id)
        let metadata = try metadataObject(audit)
        XCTAssertEqual(metadata["artifact_sha256"] as? String, sha256(data))
        XCTAssertEqual(metadata["row_count"] as? Int, 3)
        XCTAssertEqual(
            metadata["snapshot_project_updated_at"] as? Double,
            fixture.primary.updatedAt.timeIntervalSince1970
        )
    }

    func testTRPEXPORT02WriterFailurePublishesNothingAndNeverRecordsCompletion() throws {
        // T-RP-EXPORT-02 expected RED: no Review snapshot service composes the
        // durable writer with a completion boundary, so a pre-install failure
        // cannot be proven to leave both the file and success metadata absent.
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let exportedAt = try instant("2026-08-09T18:45:00Z")
        var completionCount = 0
        let writer = DurableFileWriter { stage in
            if stage == .beforeInstall { throw InjectedFailure.stop }
        }
        let service = CaseFileReviewExportService(
            store: fixture.store,
            storage: fixture.storage,
            fileWriter: writer,
            completionRecorder: { _ in completionCount += 1 }
        )
        let destination = snapshotDestination(fixture: fixture, exportedAt: exportedAt)

        XCTAssertThrowsError(
            try service.exportCSV(
                matterID: fixture.matterID,
                projectID: fixture.primary.id,
                actor: "Writer failure actor",
                at: exportedAt
            )
        )

        XCTAssertEqual(completionCount, 0, "completion must not run before durable install")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(try fixture.store.documentSources.fetchExports(matterID: fixture.matterID).isEmpty)
        XCTAssertFalse(
            try fixture.store.auditEvents.fetchEvents(matterID: fixture.matterID).contains {
                $0.eventType == "case_file_review_snapshot_exported"
            }
        )
    }

    func testTRPEXPORT03CompletionFailurePreservesBaseCanaryAndRemovesOnlyUniqueInstall() throws {
        // T-RP-EXPORT-03 hardening RED: the replacement writer installs over
        // the occupied base name before completion, then restores those bytes;
        // a Review snapshot must instead publish create-only at a unique path
        // and compensate only that newly installed artifact.
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let exportedAt = try instant("2026-08-09T18:45:00Z")
        let baseDestination = snapshotDestination(fixture: fixture, exportedAt: exportedAt)
        try FileManager.default.createDirectory(
            at: baseDestination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let canary = Data("PRIOR-REVIEW-SNAPSHOT-CANARY-947".utf8)
        try canary.write(to: baseDestination)
        var completionCount = 0
        var installedData: Data?
        var installedURL: URL?
        var baseDataDuringCompletion: Data?
        var capturedCompletion: CaseFileReviewExportService.Completion?
        let service = CaseFileReviewExportService(
            store: fixture.store,
            storage: fixture.storage,
            completionRecorder: { completion in
                completionCount += 1
                capturedCompletion = completion
                let candidate = fixture.storage.url(
                    forManagedRelativePath: completion.managedRelativePath
                )
                installedURL = candidate
                installedData = try Data(contentsOf: candidate)
                baseDataDuringCompletion = try Data(contentsOf: baseDestination)
                throw InjectedFailure.stop
            }
        )

        XCTAssertThrowsError(
            try service.exportCSV(
                matterID: fixture.matterID,
                projectID: fixture.primary.id,
                actor: "Completion failure actor",
                at: exportedAt
            )
        )

        XCTAssertEqual(completionCount, 1, "the throwing completion seam must be observed")
        let uniqueDestination: URL = try XCTUnwrap(installedURL)
        XCTAssertNotEqual(
            uniqueDestination.standardizedFileURL,
            baseDestination.standardizedFileURL,
            "an occupied base name must never be replaced, even transiently"
        )
        XCTAssertEqual(
            baseDataDuringCompletion,
            canary,
            "completion must observe the preexisting base artifact untouched"
        )
        let installedBytes: Data = try XCTUnwrap(installedData)
        XCTAssertNotEqual(installedBytes, canary, "completion must observe the newly installed CSV")
        let completion: CaseFileReviewExportService.Completion = try XCTUnwrap(capturedCompletion)
        XCTAssertFalse(completion.exportID.isEmpty)
        XCTAssertEqual(completion.matterID, fixture.matterID)
        XCTAssertEqual(completion.projectID, fixture.primary.id)
        XCTAssertEqual(
            completion.managedRelativePath,
            "exports/\(fixture.matterID)/\(uniqueDestination.lastPathComponent)"
        )
        XCTAssertEqual(completion.artifactSHA256, sha256(installedBytes))
        XCTAssertEqual(completion.snapshotProjectUpdatedAt, fixture.primary.updatedAt)
        XCTAssertEqual(completion.rowCount, 3)
        XCTAssertEqual(completion.actor, "Completion failure actor")
        XCTAssertEqual(completion.exportedAt, exportedAt)
        XCTAssertEqual(try Data(contentsOf: baseDestination), canary)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: uniqueDestination.path),
            "failed completion must remove only its unique create-only install"
        )
        XCTAssertTrue(try fixture.store.documentSources.fetchExports(matterID: fixture.matterID).isEmpty)
        XCTAssertFalse(
            try fixture.store.auditEvents.fetchEvents(matterID: fixture.matterID).contains {
                $0.eventType == "case_file_review_snapshot_exported"
            }
        )
    }

    func testTRPEXPORT04ControllerDelegatesTheSelectedProjectWithLocalProfileIdentity() throws {
        // T-RP-EXPORT-04 expected RED: CaseFileReviewController has no selected-
        // project export delegation, so Review UI state cannot choose the exact
        // durable project while keeping serialization out of the view.
        let fixture = try makeFixture(includeNewerWrongProject: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let wrong = try XCTUnwrap(fixture.wrong)
        var profile = AssistantProfile()
        profile.fullName = "  Casey Finch  \n"
        try fixture.store.appSettings.setSetting(AssistantProfile.profileKey, value: profile)
        let exportService = CaseFileReviewExportService(
            store: fixture.store,
            storage: fixture.storage
        )
        let controller = CaseFileReviewController(
            matterID: fixture.matterID,
            store: fixture.store,
            previewStorage: fixture.storage,
            exportService: exportService
        )
        controller.load()
        XCTAssertEqual(controller.selectedProjectID, wrong.id, "newest project is initially selected")
        controller.selectProject(fixture.primary.id)
        XCTAssertEqual(controller.selectedProjectID, fixture.primary.id)

        let url = try controller.exportSelectedProjectCSV()

        XCTAssertTrue(url.lastPathComponent.hasPrefix("Atlas-Amendment-Review-snapshot-v1-"))
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".csv"))
        let records = try parseCSV(Data(contentsOf: url))
        let rows = records.dropFirst().map(rowDictionary)
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0["Project ID"] == fixture.primary.id })
        XCTAssertFalse(rows.contains { $0["Project ID"] == wrong.id })
        XCTAssertFalse(rows.contains { $0["Finding"] == wrong.findings.first })
        let audit = try XCTUnwrap(
            fixture.store.auditEvents.fetchEvents(matterID: fixture.matterID)
                .first { $0.eventType == "case_file_review_snapshot_exported" }
        )
        XCTAssertEqual(audit.actor, "Casey Finch")
        XCTAssertEqual(audit.relatedID, fixture.primary.id)
    }

    func testTRPEXPORT05SameSecondPublishesTwoCreateOnlyArtifactsWithValidReceipts() throws {
        // T-RP-EXPORT-05 expected RED: the current deterministic destination is
        // replacement-based, so a second export with the same project and
        // second reuses one path instead of retaining two exact artifacts.
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let filenameSecond = try instant("2026-08-09T18:45:00Z")
        let firstExportedAt = filenameSecond.addingTimeInterval(0.1)
        let secondExportedAt = filenameSecond.addingTimeInterval(0.9)
        let service = CaseFileReviewExportService(
            store: fixture.store,
            storage: fixture.storage
        )

        let firstURL = try service.exportCSV(
            matterID: fixture.matterID,
            projectID: fixture.primary.id,
            actor: "First collision actor",
            at: firstExportedAt
        )
        let firstBytes = try Data(contentsOf: firstURL)
        let secondURL = try service.exportCSV(
            matterID: fixture.matterID,
            projectID: fixture.primary.id,
            actor: "Second collision actor",
            at: secondExportedAt
        )
        let secondBytes = try Data(contentsOf: secondURL)

        XCTAssertNotEqual(
            firstURL.standardizedFileURL,
            secondURL.standardizedFileURL,
            "same-second exports must resolve a collision without replacing the first artifact"
        )
        XCTAssertEqual(try Data(contentsOf: firstURL), firstBytes)
        XCTAssertEqual(try Data(contentsOf: secondURL), secondBytes)
        XCTAssertNotEqual(
            firstBytes,
            secondBytes,
            "fractional export instants in the same filename second must retain distinct receipts"
        )
        try DocumentExportValidator.validate(firstBytes, as: .csv)
        try DocumentExportValidator.validate(secondBytes, as: .csv)

        let expectedPaths = [firstURL, secondURL].map {
            "exports/\(fixture.matterID)/\($0.lastPathComponent)"
        }
        let exports = try fixture.store.documentSources.fetchExports(
            matterID: fixture.matterID
        ).filter { $0.format == "review_csv" }
        XCTAssertEqual(exports.count, 2)
        XCTAssertEqual(Set(exports.map(\.managedRelativePath)), Set(expectedPaths))

        let receipts = try fixture.store.auditEvents.fetchEvents(matterID: fixture.matterID)
            .filter { $0.eventType == "case_file_review_snapshot_exported" }
            .map(metadataObject)
        XCTAssertEqual(receipts.count, 2)
        for (url, bytes) in [(firstURL, firstBytes), (secondURL, secondBytes)] {
            let path = "exports/\(fixture.matterID)/\(url.lastPathComponent)"
            let receipt = try XCTUnwrap(
                receipts.filter { $0["managed_relative_path"] as? String == path }.single
            )
            XCTAssertEqual(receipt["artifact_sha256"] as? String, sha256(bytes))
            XCTAssertEqual(receipt["row_count"] as? Int, 3)
        }
    }

    func testTRPEXPORT06SymlinkedExportsParentFailsClosedBeforePublication() throws {
        // T-RP-EXPORT-06 expected RED: the current pathname-based directory and
        // replacement writer follow an `exports` symlink, allowing the CSV and
        // its success callback to escape the configured managed-storage root.
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let exportedAt = try instant("2026-08-09T18:45:00Z")
        let outside = fixture.root.appendingPathComponent(
            "outside-review-export-target-631",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: fixture.storage.root,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.storage.exportsDirectory,
            withDestinationURL: outside
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: fixture.storage.exportsDirectory.path
            ),
            outside.path
        )
        var completionCount = 0
        let service = CaseFileReviewExportService(
            store: fixture.store,
            storage: fixture.storage,
            completionRecorder: { _ in completionCount += 1 }
        )

        XCTAssertThrowsError(
            try service.exportCSV(
                matterID: fixture.matterID,
                projectID: fixture.primary.id,
                actor: "Symlink rejection actor",
                at: exportedAt
            )
        )

        XCTAssertEqual(completionCount, 0)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: outside,
                includingPropertiesForKeys: nil
            ).isEmpty,
            "a symlinked managed parent must not receive CSV or temporary bytes"
        )
        XCTAssertTrue(try fixture.store.documentSources.fetchExports(matterID: fixture.matterID).isEmpty)
        XCTAssertFalse(
            try fixture.store.auditEvents.fetchEvents(matterID: fixture.matterID).contains {
                $0.eventType == "case_file_review_snapshot_exported"
            }
        )
    }

    func testTRPEXPORT07CompletionCompensationPreservesConcurrentPathReplacement() throws {
        // T-RP-EXPORT-07 expected RED: compensation currently removes whatever
        // occupies the destination pathname after completion fails, even when
        // a concurrent writer has replaced the installed snapshot inode.
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let exportedAt = try instant("2026-08-09T18:45:00Z")
        let replacement = Data("CONCURRENT-REVIEW-REPLACEMENT-719".utf8)
        let identityProbe = DurableFileWriter()
        var completionCount = 0
        var replacementURL: URL?
        var installedIdentity: DurableFileWriter.InstalledFileIdentity?
        var replacementIdentity: DurableFileWriter.InstalledFileIdentity?
        let service = CaseFileReviewExportService(
            store: fixture.store,
            storage: fixture.storage,
            completionRecorder: { completion in
                completionCount += 1
                let url = fixture.storage.url(
                    forManagedRelativePath: completion.managedRelativePath
                )
                replacementURL = url
                installedIdentity = try identityProbe.installedFileIdentity(at: url)
                try FileManager.default.removeItem(at: url)
                try replacement.write(to: url)
                replacementIdentity = try identityProbe.installedFileIdentity(at: url)
                throw InjectedFailure.stop
            }
        )

        XCTAssertThrowsError(
            try service.exportCSV(
                matterID: fixture.matterID,
                projectID: fixture.primary.id,
                actor: "Concurrent replacement actor",
                at: exportedAt
            )
        ) { error in
            guard case CaseFileReviewExportService.ExportError.partialFailure = error else {
                return XCTFail("a changed destination must surface partial failure, got \(error)")
            }
        }

        XCTAssertEqual(completionCount, 1, "the pathname replacement seam must execute")
        let original: DurableFileWriter.InstalledFileIdentity = try XCTUnwrap(installedIdentity)
        let concurrent: DurableFileWriter.InstalledFileIdentity = try XCTUnwrap(replacementIdentity)
        XCTAssertNotEqual(original, concurrent, "the canary must occupy a distinct inode")
        let url: URL = try XCTUnwrap(replacementURL)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "compensation must not unlink a concurrent replacement"
        )
        XCTAssertEqual(try? Data(contentsOf: url), replacement)
        XCTAssertTrue(try fixture.store.documentSources.fetchExports(matterID: fixture.matterID).isEmpty)
        XCTAssertFalse(
            try fixture.store.auditEvents.fetchEvents(matterID: fixture.matterID).contains {
                $0.eventType == "case_file_review_snapshot_exported"
            }
        )
    }

    // MARK: - Fixture

    private func makeFixture(includeNewerWrongProject: Bool = false) throws -> ExportFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CaseFileReviewExport-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SupraStore(url: root.appendingPathComponent("review.sqlite"))
        let storage = DocumentStorage(root: root.appendingPathComponent("managed", isDirectory: true))
        let matter = try store.matters.createMatter(name: "Synthetic Atlas Export Matter")
        let backing = try makeEvidenceBacking(store: store, matterID: matter.id)
        let primaryUpdatedAt = try instant("2026-08-09T17:30:00Z")
        let primary = try seedProject(
            store: store,
            matterID: matter.id,
            marker: "atlas",
            title: "Atlas Amendment Review",
            updatedAt: primaryUpdatedAt,
            backing: backing,
            isPrimary: true
        )
        let wrong: SeededProject?
        if includeNewerWrongProject {
            wrong = try seedProject(
                store: store,
                matterID: matter.id,
                marker: "wrong",
                title: "Wrong Newer Project",
                updatedAt: try instant("2026-08-09T17:31:00Z"),
                backing: backing,
                isPrimary: false
            )
        } else {
            wrong = nil
        }
        return ExportFixture(
            root: root,
            store: store,
            storage: storage,
            matterID: matter.id,
            primary: primary,
            wrong: wrong
        )
    }

    private func makeEvidenceBacking(
        store: SupraStore,
        matterID: String
    ) throws -> EvidenceBacking {
        let text = "Synthetic E1 E2 S977 C983 evidence backing only."
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            sha256: String(repeating: "e", count: 64),
            byteSize: text.utf8.count,
            originalExtension: "pdf",
            managedRelativePath: "blobs/synthetic-review-export.pdf"
        )).blob
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matterID,
            blobID: blob.id,
            displayName: "Résumé Lease.csv",
            status: MatterDocumentStatus.ready.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue,
            indexStatus: DocumentIndexStatus.textIndexed.rawValue
        ))
        let part = DocumentPagePartRecord(
            id: "review-export-part",
            documentID: document.id,
            partIndex: 0,
            sourceKind: DocumentSourceKind.pdfPage.rawValue,
            pageIndex: 0,
            pageLabel: "1",
            normalizedText: text,
            charCount: text.count
        )
        let revision = DocumentPartRevisionRecord(
            id: "review-export-revision",
            documentID: document.id,
            partIndex: 0,
            derivationKey: "synthetic-review-export",
            origin: "synthetic_test",
            method: "plain-text",
            text: text,
            charCount: text.count
        )
        let selection = DocumentPartSelectionRecord(
            id: "review-export-selection",
            documentID: document.id,
            partIndex: 0,
            selectedRevisionID: revision.id,
            selectionKey: "synthetic-review-export",
            selectedBy: "test",
            decisionJSON: #"{"rule":"fixture"}"#
        )
        try store.documentRevisions.replacePartsAndPersistLineage(
            documentID: document.id,
            parts: [part],
            revisions: [revision],
            selections: [selection]
        )
        let sourceSet = try store.documentSources.createSourceSet(
            matterID: matterID,
            mode: .exhaustive,
            retrievalQuery: "Synthetic Review export sources"
        )
        let sources = [
            SourceFixture(id: "review-export-source-e1", label: "E1", page: "1", excerpt: "ALPHA, \"quoted\"\rline\nend."),
            SourceFixture(id: "review-export-source-e2", label: "E2", page: "2", excerpt: "BETA-SUPPORT-2"),
            SourceFixture(id: "review-export-source-s977", label: "S977", page: "3", excerpt: "SUPPORT-3%"),
            SourceFixture(id: "review-export-source-c983", label: "C983", page: "4", excerpt: "CONTRARY-2.5%"),
        ]
        try store.database.writer.write { db in
            for (rank, source) in sources.enumerated() {
                try DocumentOutputSourceRecord(
                    id: source.id,
                    sourceSetID: sourceSet.id,
                    documentID: document.id,
                    revisionID: revision.id,
                    citationLabel: source.label,
                    locatorJSON: locator(page: source.page),
                    excerpt: source.excerpt,
                    rank: rank
                ).insert(db)
            }
        }
        return EvidenceBacking(
            documentID: document.id,
            revisionID: revision.id,
            documentName: document.displayName,
            sources: Dictionary(uniqueKeysWithValues: sources.map { ($0.label, $0) })
        )
    }

    private func seedProject(
        store: SupraStore,
        matterID: String,
        marker: String,
        title: String,
        updatedAt: Date,
        backing: EvidenceBacking,
        isPrimary: Bool
    ) throws -> SeededProject {
        let projectID = "review-project-\(marker)"
        let tableID = "review-table-\(marker)"
        let sourceRunID = "review-run-\(marker)"
        let sourceOutputID = "review-output-\(marker)"
        let sourceOutputVersionID = "review-version-\(marker)"
        let findings = isPrimary
            ? [
                "=HYPERLINK(\"https://evil.invalid\",\"row\")",
                "rent-escalation-cap",
                "contrary-only-deleted-source",
            ]
            : [
                "wrong-project-finding-1",
                "wrong-project-finding-2",
                "wrong-project-finding-3",
            ]
        let generatedValues = isPrimary
            ? [["+SUM(1,1)", "Résumé — 安全"], ["3%"], ["-12 months"]]
            : [["WRONG-GENERATED-1"], ["WRONG-GENERATED-2"], ["WRONG-GENERATED-3"]]
        let attorneyValues: [String?] = isPrimary ? [nil, "@cmd", nil] : [nil, nil, nil]
        let valueStates = isPrimary ? ["generated", "edited", "generated"] : ["generated", "generated", "generated"]
        let reviewStates = isPrimary ? ["reviewed", "needs_review", "needs_review"] : ["needs_review", "needs_review", "needs_review"]
        let supportStates = isPrimary ? ["supported", "supported", "stale"] : ["supported", "supported", "supported"]
        let reviewedAt = try instant("2026-08-09T18:41:12Z")
        let createdAt = updatedAt.addingTimeInterval(-300)

        try store.database.writer.write { db in
            try CaseFileReviewProjectRecord(
                id: projectID,
                matterID: matterID,
                title: title,
                status: isPrimary ? "stale" : "active",
                staleReason: isPrimary ? "source_permanently_deleted" : nil,
                sourceRunID: sourceRunID,
                sourceOutputID: sourceOutputID,
                sourceOutputVersionID: sourceOutputVersionID,
                sourceRequestDigest: String(repeating: isPrimary ? "a" : "b", count: 64),
                frozenScopeJSON: #"{"schema_version":2}"#,
                frozenCorpusSnapshotJSON: #"{"schema_version":1,"members":[]}"#,
                frozenReconciliationJSON: #"{"schema_version":1,"items":[]}"#,
                createdAt: createdAt,
                updatedAt: updatedAt
            ).insert(db)
            try CaseFileReviewTableRecord(
                id: tableID,
                projectID: projectID,
                title: "Review Matrix",
                versionIndex: 1,
                createdAt: createdAt,
                updatedAt: updatedAt
            ).insert(db)
            let columnSpecs = [
                ("finding", "Finding"),
                ("generated_value", "Generated value"),
                ("sources", "Sources"),
                ("review", "Review"),
            ]
            for (ordinal, spec) in columnSpecs.enumerated() {
                try CaseFileReviewColumnRecord(
                    id: "review-column-\(marker)-\(spec.0)",
                    tableID: tableID,
                    columnKey: spec.0,
                    title: spec.1,
                    ordinal: ordinal,
                    createdAt: createdAt
                ).insert(db)
            }

            // Insert rows and their dependent values in reverse physical order;
            // the snapshot contract must restore persisted ordinal order.
            for ordinal in findings.indices.reversed() {
                let rowID = "review-row-\(marker)-\(ordinal)"
                let cellID = "review-cell-\(marker)-\(ordinal)"
                let generationID = "review-generation-\(marker)-\(ordinal)"
                try CaseFileReviewRowRecord(
                    id: rowID,
                    tableID: tableID,
                    rowKey: findings[ordinal],
                    ordinal: ordinal,
                    createdAt: createdAt
                ).insert(db)
                try CaseFileReviewCellRecord(
                    id: cellID,
                    tableID: tableID,
                    rowID: rowID,
                    columnID: "review-column-\(marker)-generated_value",
                    currentGenerationID: generationID,
                    attorneyValue: attorneyValues[ordinal],
                    reviewState: reviewStates[ordinal],
                    valueState: valueStates[ordinal],
                    supportState: supportStates[ordinal],
                    reviewedBy: reviewStates[ordinal] == "reviewed" ? "Casey Finch" : nil,
                    reviewedAt: reviewStates[ordinal] == "reviewed" ? reviewedAt : nil,
                    createdAt: createdAt,
                    updatedAt: updatedAt
                ).insert(db)
                try CaseFileReviewCellGenerationRecord(
                    id: generationID,
                    cellID: cellID,
                    sourceRunID: sourceRunID,
                    generatedValuesJSON: try canonicalJSON(generatedValues[ordinal]),
                    createdAt: createdAt
                ).insert(db)
            }

            if isPrimary {
                // E2 is inserted before E1 to prove ordinal-owned ordering.
                try evidenceEdge(
                    id: "edge-\(marker)-e2",
                    generationID: "review-generation-\(marker)-0",
                    kind: "supporting",
                    ordinal: 1,
                    source: try XCTUnwrap(backing.sources["E2"]),
                    backing: backing,
                    timestamp: updatedAt
                ).insert(db)
                try evidenceEdge(
                    id: "edge-\(marker)-e1",
                    generationID: "review-generation-\(marker)-0",
                    kind: "supporting",
                    ordinal: 0,
                    source: try XCTUnwrap(backing.sources["E1"]),
                    backing: backing,
                    timestamp: updatedAt
                ).insert(db)
                try evidenceEdge(
                    id: "edge-\(marker)-s977",
                    generationID: "review-generation-\(marker)-1",
                    kind: "supporting",
                    ordinal: 0,
                    source: try XCTUnwrap(backing.sources["S977"]),
                    backing: backing,
                    timestamp: updatedAt
                ).insert(db)
                try evidenceEdge(
                    id: "edge-\(marker)-c983",
                    generationID: "review-generation-\(marker)-1",
                    kind: "contrary",
                    ordinal: 0,
                    source: try XCTUnwrap(backing.sources["C983"]),
                    backing: backing,
                    timestamp: updatedAt
                ).insert(db)
                let frozenExcerpt = "FROZEN, \"contrary\"\rold\nline."
                try CaseFileReviewEvidenceEdgeRecord(
                    id: "edge-\(marker)-c999",
                    generationID: "review-generation-\(marker)-2",
                    kind: "contrary",
                    ordinal: 0,
                    frozenOutputSourceID: "deleted-output-source-\(marker)",
                    frozenDocumentID: "deleted-document-\(marker)",
                    frozenRevisionID: "deleted-revision-\(marker)",
                    frozenDocumentName: "Deleted Schedule.pdf",
                    citationLabel: "C999",
                    charStart: nil,
                    charEnd: nil,
                    locatorJSON: locator(page: "9"),
                    excerpt: frozenExcerpt,
                    excerptSHA256: sha256(frozenExcerpt),
                    liveOutputSourceID: nil,
                    liveDocumentID: nil,
                    liveRevisionID: nil,
                    availability: "unavailable",
                    unavailableReason: "source_permanently_deleted",
                    createdAt: createdAt,
                    updatedAt: updatedAt
                ).insert(db)
            }

            try db.execute(
                sql: "UPDATE case_file_review_projects SET active_table_id = ? WHERE id = ?",
                arguments: [tableID, projectID]
            )
        }
        return SeededProject(
            id: projectID,
            title: title,
            sourceRunID: sourceRunID,
            sourceOutputID: sourceOutputID,
            sourceOutputVersionID: sourceOutputVersionID,
            updatedAt: updatedAt,
            findings: findings
        )
    }

    private func evidenceEdge(
        id: String,
        generationID: String,
        kind: String,
        ordinal: Int,
        source: SourceFixture,
        backing: EvidenceBacking,
        timestamp: Date
    ) -> CaseFileReviewEvidenceEdgeRecord {
        CaseFileReviewEvidenceEdgeRecord(
            id: id,
            generationID: generationID,
            kind: kind,
            ordinal: ordinal,
            frozenOutputSourceID: source.id,
            frozenDocumentID: backing.documentID,
            frozenRevisionID: backing.revisionID,
            frozenDocumentName: backing.documentName,
            citationLabel: source.label,
            charStart: nil,
            charEnd: nil,
            locatorJSON: locator(page: source.page),
            excerpt: source.excerpt,
            excerptSHA256: sha256(source.excerpt),
            liveOutputSourceID: source.id,
            liveDocumentID: backing.documentID,
            liveRevisionID: backing.revisionID,
            availability: "available",
            unavailableReason: nil,
            createdAt: timestamp,
            updatedAt: timestamp
        )
    }

    // MARK: - Assertions and parsing

    private func snapshotDestination(fixture: ExportFixture, exportedAt: Date) -> URL {
        fixture.storage.exportsDirectory(forMatterID: fixture.matterID)
            .appendingPathComponent(
                "Atlas-Amendment-Review-snapshot-v1-\(filenameStamp(exportedAt)).csv"
            )
    }

    private func assertProfessionalCSVBytes(
        _ data: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let bytes = Array(data)
        XCTAssertGreaterThan(bytes.count, 5, file: file, line: line)
        XCTAssertEqual(Array(bytes.prefix(3)), [0xEF, 0xBB, 0xBF], file: file, line: line)
        XCTAssertEqual(Array(bytes.suffix(2)), [0x0D, 0x0A], file: file, line: line)
        for (index, byte) in bytes.enumerated() where byte == 0x0A {
            XCTAssertGreaterThan(index, 0, file: file, line: line)
            XCTAssertEqual(bytes[index - 1], 0x0D, "bare LF at byte \(index)", file: file, line: line)
        }
        for (index, byte) in bytes.enumerated() where byte == 0x0D {
            XCTAssertLessThan(index + 1, bytes.count, file: file, line: line)
            XCTAssertEqual(bytes[index + 1], 0x0A, "bare CR at byte \(index)", file: file, line: line)
        }
        XCTAssertNotNil(String(data: Data(bytes.dropFirst(3)), encoding: .utf8), file: file, line: line)
    }

    private func parseCSV(_ data: Data) throws -> [[String]] {
        let bytes = Array(data)
        guard bytes.starts(with: [0xEF, 0xBB, 0xBF]) else {
            throw CSVFixtureError.missingBOM
        }
        guard let text = String(data: Data(bytes.dropFirst(3)), encoding: .utf8) else {
            throw CSVFixtureError.invalidUTF8
        }
        let scalars = Array(text.unicodeScalars)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var closedQuote = false
        var index = 0

        func finishField() {
            row.append(field)
            field = ""
            closedQuote = false
        }
        func finishRow() {
            finishField()
            rows.append(row)
            row = []
        }

        while index < scalars.count {
            let scalar = scalars[index]
            let next = index + 1 < scalars.count ? scalars[index + 1] : nil
            if quoted {
                if scalar.value == 0x22 {
                    if next?.value == 0x22 {
                        field.unicodeScalars.append(scalar)
                        index += 2
                        continue
                    }
                    quoted = false
                    closedQuote = true
                } else {
                    field.unicodeScalars.append(scalar)
                }
            } else if closedQuote {
                if scalar.value == 0x2C {
                    finishField()
                } else if scalar.value == 0x0D, next?.value == 0x0A {
                    finishRow()
                    index += 2
                    continue
                } else {
                    throw CSVFixtureError.invalidCharacterAfterQuote
                }
            } else if scalar.value == 0x22 {
                if !field.isEmpty { throw CSVFixtureError.strayQuote }
                quoted = true
            } else if scalar.value == 0x2C {
                finishField()
            } else if scalar.value == 0x0D, next?.value == 0x0A {
                finishRow()
                index += 2
                continue
            } else if scalar.value == 0x0A || scalar.value == 0x0D {
                throw CSVFixtureError.bareNewline
            } else {
                field.unicodeScalars.append(scalar)
            }
            index += 1
        }
        if quoted { throw CSVFixtureError.unterminatedQuote }
        if !row.isEmpty || !field.isEmpty || closedQuote {
            finishRow()
        }
        return rows
    }

    private func rowDictionary(_ values: [String]) -> [String: String] {
        Dictionary(zip(Self.expectedHeader, values), uniquingKeysWith: { first, _ in first })
    }

    private func metadataObject(_ audit: AuditEventRecord) throws -> [String: Any] {
        let json = try XCTUnwrap(audit.metadataJSON)
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }

    private func instant(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }

    private func filenameStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    private func locator(page: String) -> String {
        DocumentSourceLocator(
            sourceKind: .pdfPage,
            pageIndex: max((Int(page) ?? 1) - 1, 0),
            pageLabel: page
        ).encodedJSON()
    }

    private func canonicalJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func sha256(_ value: String) -> String {
        sha256(Data(value.utf8))
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct ExportFixture {
    let root: URL
    let store: SupraStore
    let storage: DocumentStorage
    let matterID: String
    let primary: SeededProject
    let wrong: SeededProject?
}

private struct SeededProject {
    let id: String
    let title: String
    let sourceRunID: String
    let sourceOutputID: String
    let sourceOutputVersionID: String
    let updatedAt: Date
    let findings: [String]
}

private struct EvidenceBacking {
    let documentID: String
    let revisionID: String
    let documentName: String
    let sources: [String: SourceFixture]
}

private struct SourceFixture {
    let id: String
    let label: String
    let page: String
    let excerpt: String
}

private enum CSVFixtureError: Error {
    case missingBOM
    case invalidUTF8
    case invalidCharacterAfterQuote
    case strayQuote
    case bareNewline
    case unterminatedQuote
}

private extension Collection {
    var single: Element? { count == 1 ? first : nil }
}
