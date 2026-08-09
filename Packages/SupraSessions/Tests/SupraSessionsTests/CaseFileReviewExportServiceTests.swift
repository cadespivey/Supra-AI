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

    private static let expectedMatrixHeader = [
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
        "Contrary source count",
        "Cell ID",
    ]

    private static let expectedSourcesHeader = [
        "Finding row",
        "Finding",
        "Relationship",
        "Source order",
        "Citation",
        "Document",
        "Locator",
        "Availability",
        "Unavailable reason",
        "Excerpt",
        "Frozen source ID",
        "Frozen document ID",
        "Frozen revision ID",
        "Cell ID",
    ]

    private static let expectedProjectFields = [
        "Snapshot schema version",
        "Project",
        "Project status",
        "Project stale reason",
        "Matrix version",
        "Finding count",
        "Reviewed findings",
        "Needs-review findings",
        "Edited findings",
        "Evidence-attention findings",
        "Supporting source count",
        "Contrary source count",
        "Scope",
        "Project ID",
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

    func testTRPEXPORT08WritesDeterministicThreeSheetXLSXAndReopensExactSnapshot() async throws {
        // T-RP-EXPORT-08 expected RED: Review export exposes CSV only, so no
        // relationship-keyed Matrix / Sources / Project workbook can preserve
        // the hostile, stale, contrary-only snapshot or record review_xlsx.
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let exportedAt = try instant("2026-08-09T18:45:00Z")
        let exportActor = "Morgan Vale XLSX 742"
        let snapshot = try fixture.store.caseFileReviews.fetchSnapshot(
            matterID: fixture.matterID,
            projectID: fixture.primary.id
        )
        let liveDocumentID = try XCTUnwrap(
            snapshot.rows.first?.evidence.first?.frozenDocumentID
        )
        let service = CaseFileReviewExportService(
            store: fixture.store,
            storage: fixture.storage
        )

        let firstURL: URL = try service.exportXLSX(
            matterID: fixture.matterID,
            projectID: fixture.primary.id,
            actor: exportActor,
            at: exportedAt
        )
        // ZIPFoundation defaults entry timestamps to the wall clock. Crossing
        // its timestamp granularity makes byte equality a real wire proof that
        // the renderer pins canonical package metadata independently of wall clock.
        try await Task.sleep(nanoseconds: 2_200_000_000)
        let secondURL: URL = try service.exportXLSX(
            matterID: fixture.matterID,
            projectID: fixture.primary.id,
            actor: exportActor,
            at: exportedAt
        )

        XCTAssertEqual(
            firstURL.lastPathComponent,
            "Atlas-Amendment-Review-snapshot-v1-20260809T184500Z.xlsx"
        )
        XCTAssertNotEqual(firstURL.standardizedFileURL, secondURL.standardizedFileURL)
        XCTAssertTrue(
            secondURL.lastPathComponent.hasPrefix(
                "Atlas-Amendment-Review-snapshot-v1-20260809T184500Z-"
            )
        )
        XCTAssertTrue(secondURL.lastPathComponent.hasSuffix(".xlsx"))
        let firstData = try Data(contentsOf: firstURL)
        let secondData = try Data(contentsOf: secondURL)
        XCTAssertEqual(
            firstData,
            secondData,
            "one immutable snapshot and export instant must produce byte-identical XLSX packages"
        )
        try DocumentExportValidator.validate(firstData, as: .xlsx)
        try DocumentExportValidator.validate(secondData, as: .xlsx)

        let workbook = try await SpreadsheetExtractor().extract(fileURL: firstURL)
        XCTAssertEqual(workbook.method, "xlsx")
        XCTAssertEqual(workbook.parts.count, 3)
        XCTAssertEqual(
            workbook.parts.map { $0.sheetName ?? "<missing>" },
            ["Matrix", "Sources", "Project"],
            "sheet identity must reopen through workbook relationships in fixed presentation order"
        )
        XCTAssertEqual(
            workbook.parts.map { $0.cellRange ?? "<missing>" },
            ["A1:M4", "A1:N6", "A1:B20"]
        )
        try assertSpreadsheetHeader(Self.expectedMatrixHeader, sheet: "Matrix", in: workbook)
        try assertSpreadsheetHeader(Self.expectedSourcesHeader, sheet: "Sources", in: workbook)
        try assertSpreadsheetHeader(["Field", "Value"], sheet: "Project", in: workbook)

        try assertSpreadsheetNumber(1, cell: "A2", sheet: "Matrix", in: workbook)
        try assertSpreadsheetNumber(2, cell: "A3", sheet: "Matrix", in: workbook)
        try assertSpreadsheetNumber(3, cell: "A4", sheet: "Matrix", in: workbook)
        try assertSpreadsheetText(
            "'=HYPERLINK(\"https://evil.invalid\",\"row\")",
            cell: "B2",
            sheet: "Matrix",
            in: workbook
        )
        try assertSpreadsheetText(
            "'+SUM(1,1) · Résumé — 安全",
            cell: "C2",
            sheet: "Matrix",
            in: workbook
        )
        assertSpreadsheetBlank(cell: "D2", sheet: "Matrix", in: workbook)
        try assertSpreadsheetText(
            "'+SUM(1,1) · Résumé — 安全",
            cell: "E2",
            sheet: "Matrix",
            in: workbook
        )
        try assertSpreadsheetText("generated", cell: "F2", sheet: "Matrix", in: workbook)
        try assertSpreadsheetText("'@cmd", cell: "D3", sheet: "Matrix", in: workbook)
        try assertSpreadsheetText("'@cmd", cell: "E3", sheet: "Matrix", in: workbook)
        try assertSpreadsheetText("rent-escalation-cap", cell: "B3", sheet: "Matrix", in: workbook)
        try assertSpreadsheetText("3%", cell: "C3", sheet: "Matrix", in: workbook)
        try assertSpreadsheetText("edited", cell: "F3", sheet: "Matrix", in: workbook)
        try assertSpreadsheetText("needs_review", cell: "G3", sheet: "Matrix", in: workbook)
        assertSpreadsheetBlank(cell: "H3", sheet: "Matrix", in: workbook)
        assertSpreadsheetBlank(cell: "I3", sheet: "Matrix", in: workbook)
        try assertSpreadsheetText("supported", cell: "J3", sheet: "Matrix", in: workbook)
        try assertSpreadsheetText("'-12 months", cell: "C4", sheet: "Matrix", in: workbook)
        assertSpreadsheetBlank(cell: "D4", sheet: "Matrix", in: workbook)
        try assertSpreadsheetText("'-12 months", cell: "E4", sheet: "Matrix", in: workbook)
        try assertSpreadsheetText(
            "contrary-only-deleted-source",
            cell: "B4",
            sheet: "Matrix",
            in: workbook
        )
        try assertSpreadsheetText("generated", cell: "F4", sheet: "Matrix", in: workbook)
        try assertSpreadsheetText("needs_review", cell: "G4", sheet: "Matrix", in: workbook)
        assertSpreadsheetBlank(cell: "H4", sheet: "Matrix", in: workbook)
        assertSpreadsheetBlank(cell: "I4", sheet: "Matrix", in: workbook)
        try assertSpreadsheetText("stale", cell: "J4", sheet: "Matrix", in: workbook)
        for (cell, unsafeDefault) in [
            ("B2", "=HYPERLINK(\"https://evil.invalid\",\"row\")"),
            ("C2", "+SUM(1,1) · Résumé — 安全"),
            ("D3", "@cmd"),
            ("C4", "-12 months"),
        ] {
            XCTAssertNotEqual(
                try spreadsheetText(cell: cell, sheet: "Matrix", in: workbook),
                unsafeDefault,
                "formula-neutralized Matrix cell \(cell) must not retain the active default"
            )
        }
        try assertSpreadsheetText("reviewed", cell: "G2", sheet: "Matrix", in: workbook)
        try assertSpreadsheetText("Casey Finch", cell: "H2", sheet: "Matrix", in: workbook)
        try assertSpreadsheetDate(
            46_243.778_611_111_11,
            cell: "I2",
            sheet: "Matrix",
            in: workbook
        )
        try assertSpreadsheetNumber(2, cell: "K2", sheet: "Matrix", in: workbook)
        try assertSpreadsheetNumber(0, cell: "L2", sheet: "Matrix", in: workbook)
        try assertSpreadsheetNumber(1, cell: "K3", sheet: "Matrix", in: workbook)
        try assertSpreadsheetNumber(1, cell: "L3", sheet: "Matrix", in: workbook)
        try assertSpreadsheetNumber(0, cell: "K4", sheet: "Matrix", in: workbook)
        try assertSpreadsheetNumber(1, cell: "L4", sheet: "Matrix", in: workbook)
        try assertSpreadsheetText(
            "review-cell-atlas-0",
            cell: "M2",
            sheet: "Matrix",
            in: workbook
        )
        try assertSpreadsheetText("review-cell-atlas-1", cell: "M3", sheet: "Matrix", in: workbook)
        try assertSpreadsheetText("review-cell-atlas-2", cell: "M4", sheet: "Matrix", in: workbook)

        let sourceRows: [[String]] = [
            ["1", "'=HYPERLINK(\"https://evil.invalid\",\"row\")", "supporting", "1", "E1", "Résumé Lease.csv", "p. 1", "available", "", "ALPHA, \"quoted\"\nline\nend.", "review-export-source-e1", liveDocumentID, "review-export-revision", "review-cell-atlas-0"],
            ["1", "'=HYPERLINK(\"https://evil.invalid\",\"row\")", "supporting", "2", "E2", "Résumé Lease.csv", "p. 2", "available", "", "BETA-SUPPORT-2", "review-export-source-e2", liveDocumentID, "review-export-revision", "review-cell-atlas-0"],
            ["2", "rent-escalation-cap", "supporting", "1", "S977", "Résumé Lease.csv", "p. 3", "available", "", "SUPPORT-3%", "review-export-source-s977", liveDocumentID, "review-export-revision", "review-cell-atlas-1"],
            ["2", "rent-escalation-cap", "contrary", "1", "C983", "Résumé Lease.csv", "p. 4", "available", "", "CONTRARY-2.5%", "review-export-source-c983", liveDocumentID, "review-export-revision", "review-cell-atlas-1"],
            ["3", "contrary-only-deleted-source", "contrary", "1", "C999", "Deleted Schedule.pdf", "p. 9", "unavailable", "source_permanently_deleted", "FROZEN, \"contrary\"\nold\nline.", "deleted-output-source-atlas", "deleted-document-atlas", "deleted-revision-atlas", "review-cell-atlas-2"],
        ]
        for (rowOffset, values) in sourceRows.enumerated() {
            let row = rowOffset + 2
            XCTAssertEqual(values.count, Self.expectedSourcesHeader.count)
            try assertSpreadsheetNumber(
                Double(try XCTUnwrap(Int(values[0]))),
                cell: "A\(row)",
                sheet: "Sources",
                in: workbook
            )
            try assertSpreadsheetNumber(
                Double(try XCTUnwrap(Int(values[3]))),
                cell: "D\(row)",
                sheet: "Sources",
                in: workbook
            )
            for columnIndex in values.indices where columnIndex != 0 && columnIndex != 3 {
                let reference = "\(spreadsheetColumnName(columnIndex))\(row)"
                if values[columnIndex].isEmpty {
                    assertSpreadsheetBlank(cell: reference, sheet: "Sources", in: workbook)
                    continue
                }
                let actual = try spreadsheetText(
                    cell: reference,
                    sheet: "Sources",
                    in: workbook
                )
                XCTAssertEqual(
                    normalizeWorkbookLineEndings(actual),
                    normalizeWorkbookLineEndings(values[columnIndex]),
                    "Sources row \(row) column \(Self.expectedSourcesHeader[columnIndex]) drifted"
                )
            }
        }
        let supportExcerpt = try spreadsheetText(cell: "J4", sheet: "Sources", in: workbook)
        let contraryExcerpt = try spreadsheetText(cell: "J5", sheet: "Sources", in: workbook)
        XCTAssertFalse(supportExcerpt.contains("CONTRARY-2.5%"))
        XCTAssertFalse(contraryExcerpt.contains("SUPPORT-3%"))

        for (offset, field) in Self.expectedProjectFields.enumerated() {
            try assertSpreadsheetText(
                field,
                cell: "A\(offset + 2)",
                sheet: "Project",
                in: workbook
            )
        }
        try assertSpreadsheetNumber(1, cell: "B2", sheet: "Project", in: workbook)
        try assertSpreadsheetText(
            "Atlas Amendment Review",
            cell: "B3",
            sheet: "Project",
            in: workbook
        )
        try assertSpreadsheetText("stale", cell: "B4", sheet: "Project", in: workbook)
        try assertSpreadsheetText(
            "source_permanently_deleted",
            cell: "B5",
            sheet: "Project",
            in: workbook
        )
        for (cell, value) in [
            ("B6", 1.0),
            ("B7", 3.0),
            ("B8", 1.0),
            ("B9", 2.0),
            ("B10", 1.0),
            ("B11", 2.0),
            ("B12", 3.0),
            ("B13", 2.0),
        ] {
            try assertSpreadsheetNumber(value, cell: cell, sheet: "Project", in: workbook)
        }
        try assertSpreadsheetText(
            "All saved findings (presentation filters ignored)",
            cell: "B14",
            sheet: "Project",
            in: workbook
        )
        try assertSpreadsheetText(fixture.primary.id, cell: "B15", sheet: "Project", in: workbook)
        try assertSpreadsheetText(
            fixture.primary.sourceRunID,
            cell: "B16",
            sheet: "Project",
            in: workbook
        )
        try assertSpreadsheetText(
            fixture.primary.sourceOutputID,
            cell: "B17",
            sheet: "Project",
            in: workbook
        )
        try assertSpreadsheetText(
            fixture.primary.sourceOutputVersionID,
            cell: "B18",
            sheet: "Project",
            in: workbook
        )
        try assertSpreadsheetDate(
            46_243.729_166_666_664,
            cell: "B19",
            sheet: "Project",
            in: workbook
        )
        try assertSpreadsheetDate(
            46_243.781_25,
            cell: "B20",
            sheet: "Project",
            in: workbook
        )

        var formulaCells: [String] = []
        for node in workbook.structure.nodes where node.kind == .cellRange {
            let payload = try spreadsheetPayload(node)
            guard payload["semanticKind"] as? String == "cell" else { continue }
            if payload["formula"] as? String != nil {
                formulaCells.append(payload["cellRef"] as? String ?? "<missing>")
            }
        }
        XCTAssertTrue(formulaCells.isEmpty, "Review XLSX must contain no formulas: \(formulaCells)")
        XCTAssertFalse(
            workbook.combinedText.contains(exportActor),
            "the completion actor is audit-only and must not become workbook content"
        )

        let exports = try fixture.store.documentSources.fetchExports(matterID: fixture.matterID)
        XCTAssertEqual(exports.count, 2)
        XCTAssertTrue(exports.allSatisfy { $0.format == "review_xlsx" })
        XCTAssertFalse(exports.contains { $0.format == "review_csv" })
        XCTAssertTrue(exports.allSatisfy { $0.structuredOutputID == nil })
        XCTAssertTrue(exports.allSatisfy { $0.structuredOutputVersionID == nil })
        XCTAssertEqual(
            Set(exports.map(\.managedRelativePath)),
            Set([firstURL, secondURL].map {
                "exports/\(fixture.matterID)/\($0.lastPathComponent)"
            })
        )
        XCTAssertTrue(
            try fixture.store.documentSources.fetchExports(
                structuredOutputID: fixture.primary.sourceOutputID
            ).isEmpty,
            "Review XLSX must not enter Structured Output export history"
        )
        let audits = try fixture.store.auditEvents.fetchEvents(matterID: fixture.matterID)
            .filter { $0.eventType == "case_file_review_snapshot_exported" }
        XCTAssertEqual(audits.count, 2)
        XCTAssertTrue(audits.allSatisfy { $0.actor == exportActor })
        XCTAssertTrue(audits.allSatisfy {
            $0.relatedTable == CaseFileReviewProjectRecord.databaseTableName
                && $0.relatedID == fixture.primary.id
        })
        var auditedPaths = Set<String>()
        for audit in audits {
            let metadata = try metadataObject(audit)
            XCTAssertEqual(metadata["format"] as? String, "review_xlsx")
            XCTAssertEqual(metadata["artifact_sha256"] as? String, sha256(firstData))
            XCTAssertEqual(metadata["row_count"] as? Int, 3)
            XCTAssertEqual(metadata["project_id"] as? String, fixture.primary.id)
            XCTAssertEqual(
                metadata["snapshot_project_updated_at"] as? Double,
                fixture.primary.updatedAt.timeIntervalSince1970
            )
            XCTAssertEqual(metadata["source_run_id"] as? String, fixture.primary.sourceRunID)
            XCTAssertEqual(metadata["source_output_id"] as? String, fixture.primary.sourceOutputID)
            XCTAssertEqual(
                metadata["source_output_version_id"] as? String,
                fixture.primary.sourceOutputVersionID
            )
            auditedPaths.insert(try XCTUnwrap(metadata["managed_relative_path"] as? String))
        }
        XCTAssertEqual(auditedPaths, Set(exports.map(\.managedRelativePath)))
    }

    func testTRPEXPORT09XLSXReusesCreateOnlyContainedIdentitySafePublication() throws {
        // T-RP-EXPORT-09 expected RED: there is no XLSX route through the
        // create-only writer, typed completion format, contained-parent guard,
        // or inode-and-byte-bound compensation already proven for CSV.
        try assertXLSXOccupiedBaseCompletionFailurePreservesCanary()
        try assertXLSXSymlinkedParentFailsClosed()
        try assertXLSXCompensationPreservesConcurrentReplacement()
    }

    func testTRPEXPORT10ControllerDelegatesSelectedProjectXLSXWithLocalProfileIdentity() async throws {
        // T-RP-EXPORT-10 expected RED: the controller exposes CSV only, so the
        // selected nondefault project and trimmed local profile cannot reach a
        // zero-argument XLSX snapshot without leaking the newer project.
        let fixture = try makeFixture(includeNewerWrongProject: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let wrong = try XCTUnwrap(fixture.wrong)
        let exportedAt = try instant("2026-08-09T18:45:00Z")
        var profile = AssistantProfile()
        profile.fullName = "  Avery Quinn  \n"
        try fixture.store.appSettings.setSetting(AssistantProfile.profileKey, value: profile)
        let controller = CaseFileReviewController(
            matterID: fixture.matterID,
            store: fixture.store,
            previewStorage: fixture.storage,
            exportService: CaseFileReviewExportService(
                store: fixture.store,
                storage: fixture.storage
            )
        )
        controller.load()
        XCTAssertEqual(controller.selectedProjectID, wrong.id)
        controller.selectProject(fixture.primary.id)
        XCTAssertEqual(controller.selectedProjectID, fixture.primary.id)

        let url: URL = try controller.exportSelectedProjectXLSX(at: exportedAt)

        XCTAssertEqual(
            url.lastPathComponent,
            "Atlas-Amendment-Review-snapshot-v1-20260809T184500Z.xlsx"
        )
        let workbook = try await SpreadsheetExtractor().extract(fileURL: url)
        XCTAssertEqual(workbook.parts.map { $0.sheetName ?? "<missing>" }, ["Matrix", "Sources", "Project"])
        try assertSpreadsheetText(fixture.primary.id, cell: "B15", sheet: "Project", in: workbook)
        try assertSpreadsheetText(
            fixture.primary.sourceRunID,
            cell: "B16",
            sheet: "Project",
            in: workbook
        )
        XCTAssertFalse(workbook.combinedText.contains(wrong.id))
        XCTAssertFalse(workbook.combinedText.contains(wrong.title))
        for finding in wrong.findings {
            XCTAssertFalse(
                workbook.combinedText.contains(finding),
                "selected-project XLSX leaked wrong-project finding \(finding)"
            )
        }
        XCTAssertFalse(
            workbook.combinedText.contains("Avery Quinn"),
            "the trimmed local-profile actor is audit-only, not workbook content"
        )
        let audit = try XCTUnwrap(
            fixture.store.auditEvents.fetchEvents(matterID: fixture.matterID)
                .first { $0.eventType == "case_file_review_snapshot_exported" }
        )
        XCTAssertEqual(audit.actor, "Avery Quinn")
        XCTAssertEqual(audit.relatedID, fixture.primary.id)
        XCTAssertEqual(try metadataObject(audit)["format"] as? String, "review_xlsx")
    }

    func testTRPEXPORT11XLSXLimitViolationPrecedesPublicationAndCompletion() throws {
        // T-RP-EXPORT-11 expected RED: XLSX validation counted raw graphemes
        // before formula neutralization, so an expanding saved value could
        // cross the spreadsheet limit and still reach file publication.
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let exportedAt = try instant("2026-08-09T18:45:00Z")
        let dangerous = "=" + String(repeating: "h", count: 32_766)
        XCTAssertEqual(dangerous.utf16.count, 32_767)
        XCTAssertEqual(CSVCellSanitizer.neutralize(dangerous).utf16.count, 32_768)
        _ = try fixture.store.caseFileReviews.editCellValue(
            matterID: fixture.matterID,
            projectID: fixture.primary.id,
            cellID: "review-cell-atlas-1",
            attorneyValue: dangerous,
            editedBy: "XLSX limit actor 811",
            editedAt: try instant("2026-08-09T18:44:00Z")
        )
        let exportsDirectory = fixture.storage.exportsDirectory
        let matterExportsDirectory = fixture.storage.exportsDirectory(
            forMatterID: fixture.matterID
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportsDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: matterExportsDirectory.path))
        var completionCount = 0
        let service = CaseFileReviewExportService(
            store: fixture.store,
            storage: fixture.storage,
            completionRecorder: { _ in completionCount += 1 }
        )

        XCTAssertThrowsError(
            try service.exportXLSX(
                matterID: fixture.matterID,
                projectID: fixture.primary.id,
                actor: "XLSX limit actor 811",
                at: exportedAt
            )
        ) { error in
            guard let renderError = error as? TabularXLSXRenderer.RenderError,
                  case let .invalidCellText(sheet, row, column) = renderError else {
                return XCTFail("expected a Matrix cell-limit rejection, got \(error)")
            }
            XCTAssertEqual(sheet, "Matrix")
            XCTAssertEqual(row, 3)
            XCTAssertEqual(column, 4)
        }

        XCTAssertEqual(completionCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportsDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: matterExportsDirectory.path))
        XCTAssertTrue(try fixture.store.documentSources.fetchExports(matterID: fixture.matterID).isEmpty)
        XCTAssertFalse(
            try fixture.store.auditEvents.fetchEvents(matterID: fixture.matterID).contains {
                $0.eventType == "case_file_review_snapshot_exported"
            }
        )
    }

    private func assertXLSXOccupiedBaseCompletionFailurePreservesCanary() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let exportedAt = try instant("2026-08-09T18:45:00Z")
        let baseDestination = snapshotXLSXDestination(
            fixture: fixture,
            exportedAt: exportedAt
        )
        try FileManager.default.createDirectory(
            at: baseDestination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let canary = Data("PRIOR-REVIEW-XLSX-CANARY-427".utf8)
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
                let data = try Data(contentsOf: candidate)
                installedData = data
                try DocumentExportValidator.validate(data, as: .xlsx)
                baseDataDuringCompletion = try Data(contentsOf: baseDestination)
                throw InjectedFailure.stop
            }
        )

        XCTAssertThrowsError(
            try service.exportXLSX(
                matterID: fixture.matterID,
                projectID: fixture.primary.id,
                actor: "XLSX completion failure actor",
                at: exportedAt
            )
        ) { error in
            guard case CaseFileReviewExportService.ExportError.completionRecordingFailed = error else {
                return XCTFail("expected compensated XLSX completion failure, got \(error)")
            }
        }

        XCTAssertEqual(completionCount, 1)
        let uniqueDestination = try XCTUnwrap(installedURL)
        XCTAssertNotEqual(uniqueDestination.standardizedFileURL, baseDestination.standardizedFileURL)
        XCTAssertEqual(baseDataDuringCompletion, canary)
        let installedBytes = try XCTUnwrap(installedData)
        XCTAssertNotEqual(installedBytes, canary)
        let completion = try XCTUnwrap(capturedCompletion)
        XCTAssertEqual(completion.format, CaseFileReviewSnapshotExportFormat.xlsx)
        XCTAssertEqual(completion.matterID, fixture.matterID)
        XCTAssertEqual(completion.projectID, fixture.primary.id)
        XCTAssertEqual(
            completion.managedRelativePath,
            "exports/\(fixture.matterID)/\(uniqueDestination.lastPathComponent)"
        )
        XCTAssertEqual(completion.artifactSHA256, sha256(installedBytes))
        XCTAssertEqual(completion.snapshotProjectUpdatedAt, fixture.primary.updatedAt)
        XCTAssertEqual(completion.rowCount, 3)
        XCTAssertEqual(completion.actor, "XLSX completion failure actor")
        XCTAssertEqual(completion.exportedAt, exportedAt)
        XCTAssertEqual(try Data(contentsOf: baseDestination), canary)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: uniqueDestination.path),
            "failed XLSX completion must remove only its unique owned install"
        )
        XCTAssertTrue(try fixture.store.documentSources.fetchExports(matterID: fixture.matterID).isEmpty)
        XCTAssertFalse(
            try fixture.store.auditEvents.fetchEvents(matterID: fixture.matterID).contains {
                $0.eventType == "case_file_review_snapshot_exported"
            }
        )
    }

    private func assertXLSXSymlinkedParentFailsClosed() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let exportedAt = try instant("2026-08-09T18:45:00Z")
        let outside = fixture.root.appendingPathComponent(
            "outside-review-xlsx-target-619",
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
        var completionCount = 0
        let service = CaseFileReviewExportService(
            store: fixture.store,
            storage: fixture.storage,
            completionRecorder: { _ in completionCount += 1 }
        )

        XCTAssertThrowsError(
            try service.exportXLSX(
                matterID: fixture.matterID,
                projectID: fixture.primary.id,
                actor: "XLSX symlink rejection actor",
                at: exportedAt
            )
        )

        XCTAssertEqual(completionCount, 0)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: outside,
                includingPropertiesForKeys: nil
            ).isEmpty,
            "a symlinked managed parent must receive no XLSX or temporary bytes"
        )
        XCTAssertTrue(try fixture.store.documentSources.fetchExports(matterID: fixture.matterID).isEmpty)
        XCTAssertFalse(
            try fixture.store.auditEvents.fetchEvents(matterID: fixture.matterID).contains {
                $0.eventType == "case_file_review_snapshot_exported"
            }
        )
    }

    private func assertXLSXCompensationPreservesConcurrentReplacement() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let exportedAt = try instant("2026-08-09T18:45:00Z")
        let replacement = Data("CONCURRENT-REVIEW-XLSX-REPLACEMENT-883".utf8)
        let identityProbe = DurableFileWriter()
        var completionCount = 0
        var replacementURL: URL?
        var installedIdentity: DurableFileWriter.InstalledFileIdentity?
        var replacementIdentity: DurableFileWriter.InstalledFileIdentity?
        var capturedCompletion: CaseFileReviewExportService.Completion?
        let service = CaseFileReviewExportService(
            store: fixture.store,
            storage: fixture.storage,
            completionRecorder: { completion in
                completionCount += 1
                capturedCompletion = completion
                let url = fixture.storage.url(
                    forManagedRelativePath: completion.managedRelativePath
                )
                replacementURL = url
                let installedData = try Data(contentsOf: url)
                try DocumentExportValidator.validate(installedData, as: .xlsx)
                installedIdentity = try identityProbe.installedFileIdentity(at: url)
                try FileManager.default.removeItem(at: url)
                try replacement.write(to: url)
                replacementIdentity = try identityProbe.installedFileIdentity(at: url)
                throw InjectedFailure.stop
            }
        )

        XCTAssertThrowsError(
            try service.exportXLSX(
                matterID: fixture.matterID,
                projectID: fixture.primary.id,
                actor: "XLSX concurrent replacement actor",
                at: exportedAt
            )
        ) { error in
            guard case CaseFileReviewExportService.ExportError.partialFailure = error else {
                return XCTFail("a changed XLSX destination must surface partial failure, got \(error)")
            }
        }

        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(
            try XCTUnwrap(capturedCompletion).format,
            CaseFileReviewSnapshotExportFormat.xlsx
        )
        let original = try XCTUnwrap(installedIdentity)
        let concurrent = try XCTUnwrap(replacementIdentity)
        XCTAssertNotEqual(original, concurrent)
        let url = try XCTUnwrap(replacementURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: url), replacement)
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

    private func snapshotXLSXDestination(fixture: ExportFixture, exportedAt: Date) -> URL {
        fixture.storage.exportsDirectory(forMatterID: fixture.matterID)
            .appendingPathComponent(
                "Atlas-Amendment-Review-snapshot-v1-\(filenameStamp(exportedAt)).xlsx"
            )
    }

    private func assertSpreadsheetHeader(
        _ expected: [String],
        sheet: String,
        in workbook: ExtractionResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for (index, value) in expected.enumerated() {
            try assertSpreadsheetText(
                value,
                cell: "\(spreadsheetColumnName(index))1",
                sheet: sheet,
                in: workbook,
                file: file,
                line: line
            )
        }
    }

    private func assertSpreadsheetText(
        _ expected: String,
        cell reference: String,
        sheet: String,
        in workbook: ExtractionResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let node = try spreadsheetCell(reference, sheet: sheet, in: workbook)
        let payload = try spreadsheetPayload(node)
        XCTAssertEqual(payload["cellType"] as? String, "string", file: file, line: line)
        XCTAssertNil(payload["formula"] as? String, file: file, line: line)
        XCTAssertEqual(
            try resolvedSpreadsheetText(node, in: workbook),
            expected,
            "unexpected value at \(sheet)!\(reference)",
            file: file,
            line: line
        )
    }

    private func spreadsheetText(
        cell reference: String,
        sheet: String,
        in workbook: ExtractionResult
    ) throws -> String {
        let node = try spreadsheetCell(reference, sheet: sheet, in: workbook)
        let payload = try spreadsheetPayload(node)
        XCTAssertEqual(payload["cellType"] as? String, "string")
        XCTAssertNil(payload["formula"] as? String)
        return try resolvedSpreadsheetText(node, in: workbook)
    }

    private func assertSpreadsheetBlank(
        cell reference: String,
        sheet: String,
        in workbook: ExtractionResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let hasExtractedValue = workbook.structure.nodes.contains { node in
            guard node.kind == .cellRange,
                  let payload = spreadsheetPayloadIfPresent(node) else { return false }
            return payload["semanticKind"] as? String == "cell"
                && payload["cellRef"] as? String == reference
                && payload["sheetName"] as? String == sheet
        }
        XCTAssertFalse(
            hasExtractedValue,
            "expected blank cell at \(sheet)!\(reference)",
            file: file,
            line: line
        )
    }

    private func assertSpreadsheetNumber(
        _ expected: Double,
        cell reference: String,
        sheet: String,
        in workbook: ExtractionResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let node = try spreadsheetCell(reference, sheet: sheet, in: workbook)
        let payload = try spreadsheetPayload(node)
        XCTAssertEqual(payload["cellType"] as? String, "number", file: file, line: line)
        XCTAssertNil(payload["formula"] as? String, file: file, line: line)
        let raw = try XCTUnwrap(
            (payload["rawValue"] as? String).flatMap(Double.init),
            "missing numeric value at \(sheet)!\(reference)",
            file: file,
            line: line
        )
        XCTAssertEqual(raw, expected, accuracy: 0.000_000_001, file: file, line: line)
    }

    private func assertSpreadsheetDate(
        _ expected: Double,
        cell reference: String,
        sheet: String,
        in workbook: ExtractionResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let node = try spreadsheetCell(reference, sheet: sheet, in: workbook)
        let payload = try spreadsheetPayload(node)
        XCTAssertEqual(payload["cellType"] as? String, "date_serial", file: file, line: line)
        XCTAssertNil(payload["formula"] as? String, file: file, line: line)
        XCTAssertGreaterThan(payload["numberFormatId"] as? Int ?? 0, 0, file: file, line: line)
        let raw = try XCTUnwrap(
            (payload["rawValue"] as? String).flatMap(Double.init),
            "missing date serial at \(sheet)!\(reference)",
            file: file,
            line: line
        )
        XCTAssertEqual(raw, expected, accuracy: 0.000_000_001, file: file, line: line)
    }

    private func spreadsheetCell(
        _ reference: String,
        sheet: String,
        in workbook: ExtractionResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ExtractedStructureNode {
        try XCTUnwrap(
            workbook.structure.nodes.first { node in
                guard node.kind == .cellRange,
                      let payload = spreadsheetPayloadIfPresent(node) else { return false }
                return payload["semanticKind"] as? String == "cell"
                    && payload["cellRef"] as? String == reference
                    && payload["sheetName"] as? String == sheet
            },
            "missing cell \(sheet)!\(reference)",
            file: file,
            line: line
        )
    }

    private func spreadsheetPayload(_ node: ExtractedStructureNode) throws -> [String: Any] {
        let json = try XCTUnwrap(node.payloadJSON, "spreadsheet node has no payload")
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try XCTUnwrap(object as? [String: Any], "spreadsheet payload is not an object")
    }

    private func spreadsheetPayloadIfPresent(_ node: ExtractedStructureNode) -> [String: Any]? {
        guard let json = node.payloadJSON,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else {
            return nil
        }
        return object as? [String: Any]
    }

    private func resolvedSpreadsheetText(
        _ node: ExtractedStructureNode,
        in workbook: ExtractionResult
    ) throws -> String {
        if let textContent = node.textContent { return textContent }
        let start = try XCTUnwrap(node.charStart)
        let end = try XCTUnwrap(node.charEnd)
        guard workbook.parts.indices.contains(node.partIndex),
              start >= 0,
              end >= start else {
            throw WorkbookFixtureError.invalidCellTextRange
        }
        let text = workbook.parts[node.partIndex].text
        guard end <= text.count else { throw WorkbookFixtureError.invalidCellTextRange }
        let lower = text.index(text.startIndex, offsetBy: start)
        let upper = text.index(text.startIndex, offsetBy: end)
        return String(text[lower..<upper])
    }

    private func spreadsheetColumnName(_ index: Int) -> String {
        var remaining = index
        var result = ""
        repeat {
            let scalar = UnicodeScalar(UInt8(65 + remaining % 26))
            result = String(Character(scalar)) + result
            remaining = remaining / 26 - 1
        } while remaining >= 0
        return result
    }

    private func normalizeWorkbookLineEndings(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
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

private enum WorkbookFixtureError: Error {
    case invalidCellTextRange
}

private extension Collection {
    var single: Element? { count == 1 ? first : nil }
}
