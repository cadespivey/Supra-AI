import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

final class DocumentExportTests: XCTestCase {
    private enum InjectedFailure: Error { case stop }
    private static let exactModelLineageJSON = #"{"artifact_fingerprint_sha256":"7777777777777777777777777777777777777777777777777777777777777777","content_binding_algorithm":"supra-release-model-sha256-v1","content_binding_schema_version":1,"model_repository":"synthetic/exact-export-runtime","model_revision":"0123456789abcdef0123456789abcdef01234567"}"#

    func testExportWritesFileRecordsAndAudits() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")

        // A saved Q&A output with a version + an attached source set.
        let output = try store.structuredOutputs.createOutput(matterID: matter.id, title: "Q&A: payment", outputType: .documentQA, status: .complete)
        let version = try createExportableVersion(
            store: store,
            structuredOutputID: output.id, versionIndex: 1,
            contentMarkdown: "Payment was due March 3, 2024 [S1]."
        )
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(sha256: "a", byteSize: 1, originalExtension: "pdf", managedRelativePath: "blobs/a.pdf")).blob
        let doc = try store.documentLibrary.insertDocument(MatterDocumentRecord(matterID: matter.id, blobID: blob.id, displayName: "agreement.pdf"))
        let sourceSet = try store.documentSources.createSourceSet(matterID: matter.id, mode: .autoSource, retrievalQuery: "payment")
        try store.documentSources.addOutputSource(DocumentOutputSourceRecord(
            sourceSetID: sourceSet.id, documentID: doc.id, chunkID: nil, citationLabel: "S1",
            locatorJSON: DocumentSourceLocator(sourceKind: .pdfPage, pageIndex: 2, pageLabel: "3").encodedJSON(),
            excerpt: "Payment due March 3, 2024.", rank: 0
        ))
        try store.documentSources.attachSourceSet(id: sourceSet.id, structuredOutputVersionID: version.id)

        let storage = DocumentStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent("ExportSvc-\(UUID().uuidString)"))
        let service = DocumentExportService(store: store, storage: storage)

        for format in DocumentExportFormat.allCases {
            let url = try service.export(matterID: matter.id, structuredOutputID: output.id, format: format)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing \(format.rawValue)")
        }

        // Markdown contains the answer + appendix reference (no raw documents).
        let mdURL = try service.export(matterID: matter.id, structuredOutputID: output.id, format: .markdown)
        let md = try String(contentsOf: mdURL, encoding: .utf8)
        XCTAssertTrue(md.contains("Payment was due March 3, 2024 [S1]."))
        XCTAssertTrue(md.contains("agreement.pdf"))
        XCTAssertTrue(md.contains("p. 3"))
        XCTAssertTrue(md.contains("Assurance: Supported by selected sources — not exhaustive"))

        // Export records persisted, and a single matter export audit exists.
        let exports = try store.documentSources.fetchExports(structuredOutputID: output.id)
        XCTAssertGreaterThanOrEqual(exports.count, DocumentExportFormat.allCases.count)
        let exportAudits = try store.auditEvents.fetchEvents(matterID: matter.id)
            .filter { $0.eventType == "export_completed" }
        XCTAssertGreaterThanOrEqual(exportAudits.count, DocumentExportFormat.allCases.count)
    }

    func testSelectedSupportedHistoryExportsWhenActiveSuccessorNeedsReview() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Selected Version Export")
        let output = try store.structuredOutputs.createOutput(
            matterID: matter.id,
            title: "Selected payment answer",
            outputType: .documentQA,
            status: .complete
        )
        let supported = try createExportableVersion(
            store: store,
            structuredOutputID: output.id,
            versionIndex: 1,
            contentMarkdown: "Payment was due March 3, 2024 [S1]."
        )
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            sha256: "selected-version-export",
            byteSize: 31,
            originalExtension: "txt",
            managedRelativePath: "blobs/selected-version-export.txt"
        )).blob
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matter.id,
            blobID: blob.id,
            displayName: "selected-payment.txt"
        ))
        let sourceSet = try store.documentSources.createSourceSet(
            matterID: matter.id,
            mode: .autoSource
        )
        try store.documentSources.addOutputSource(DocumentOutputSourceRecord(
            sourceSetID: sourceSet.id,
            documentID: document.id,
            citationLabel: "S1",
            locatorJSON: DocumentSourceLocator(
                sourceKind: .text,
                charStart: 0,
                charEnd: 31
            ).encodedJSON(),
            excerpt: "Payment was due March 3, 2024.",
            rank: 0
        ))
        try store.documentSources.attachSourceSet(
            id: sourceSet.id,
            structuredOutputVersionID: supported.id
        )
        let blockedActive = try store.structuredOutputs.createVersion(
            structuredOutputID: output.id,
            versionIndex: 2,
            contentMarkdown: "Unsupported successor.",
            requiredSections: [],
            presentSections: [],
            missingSections: [],
            parentVersionID: supported.id,
            verificationStatus: .legacyUnverified,
            assuranceState: .supportNeedsReview,
            outputStatus: .needsReview
        )
        XCTAssertEqual(
            try store.structuredOutputs.fetchOutputs(matterID: matter.id).first?.activeVersionID,
            blockedActive.id
        )

        let storage = DocumentStorage(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("SelectedVersionExport-\(UUID().uuidString)")
        )
        let url = try DocumentExportService(store: store, storage: storage).export(
            matterID: matter.id,
            structuredOutputID: output.id,
            structuredOutputVersionID: supported.id,
            format: .markdown
        )
        let markdown = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(url.lastPathComponent.contains("-v1-"))
        XCTAssertTrue(markdown.contains("Payment was due March 3, 2024 [S1]."))
        XCTAssertFalse(markdown.contains("Unsupported successor."))
    }

    func testExportDoesNotDuplicateEmbeddedAppendix() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        // Saved version markdown already embeds a "## Sources" appendix, exactly as
        // the Q&A/chronology controllers persist it.
        let output = try store.structuredOutputs.createOutput(matterID: matter.id, title: "Q&A", outputType: .documentQA, status: .complete)
        let version = try createExportableVersion(
            store: store,
            structuredOutputID: output.id, versionIndex: 1,
            contentMarkdown: "Answer body [S1].\n\n## Sources\n- **[S1]** agreement.pdf — p. 3"
        )
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(sha256: "a", byteSize: 1, originalExtension: "pdf", managedRelativePath: "blobs/a.pdf")).blob
        let doc = try store.documentLibrary.insertDocument(MatterDocumentRecord(matterID: matter.id, blobID: blob.id, displayName: "agreement.pdf"))
        let sourceSet = try store.documentSources.createSourceSet(matterID: matter.id, mode: .autoSource)
        try store.documentSources.addOutputSource(DocumentOutputSourceRecord(sourceSetID: sourceSet.id, documentID: doc.id, citationLabel: "S1", locatorJSON: DocumentSourceLocator(sourceKind: .pdfPage, pageIndex: 2).encodedJSON(), excerpt: "x", rank: 0))
        try store.documentSources.attachSourceSet(id: sourceSet.id, structuredOutputVersionID: version.id)

        let storage = DocumentStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let url = try DocumentExportService(store: store, storage: storage).export(matterID: matter.id, structuredOutputID: output.id, format: .markdown)
        let md = try String(contentsOf: url, encoding: .utf8)
        let appendixCount = md.components(separatedBy: "## Sources").count - 1
        XCTAssertEqual(appendixCount, 1, "exactly one Sources appendix expected, found \(appendixCount)")
        XCTAssertTrue(md.contains("Answer body [S1]."))
    }

    // ACR-EXPORT-007: an exporter failure must not overwrite a prior artifact
    // or create either half of the success metadata pair.
    func testFailedInstallPreservesCanaryAndWritesNoExportOrAuditRecord() throws {
        let fixture = try makeFixture()
        let directory = fixture.storage.exportsDirectory(forMatterID: fixture.matterID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("Q-A-v1.md")
        let canary = Data("prior-reviewed-export".utf8)
        try canary.write(to: destination)
        let writer = DurableFileWriter { stage in
            if stage == .beforeInstall { throw InjectedFailure.stop }
        }
        let service = DocumentExportService(store: fixture.store, storage: fixture.storage, fileWriter: writer)

        XCTAssertThrowsError(
            try service.export(matterID: fixture.matterID, structuredOutputID: fixture.outputID, format: .markdown)
        )
        XCTAssertEqual(try Data(contentsOf: destination), canary)
        XCTAssertTrue(try fixture.store.documentSources.fetchExports(structuredOutputID: fixture.outputID).isEmpty)
        XCTAssertFalse(try fixture.store.auditEvents.fetchEvents(matterID: fixture.matterID).contains { $0.eventType == "export_completed" })
    }

    // ACR-EXPORT-008: the DB/audit completion transaction starts only after a
    // parseable file is installed. A transaction failure compensates back to the
    // prior destination rather than returning an unrecorded new export.
    func testCompletionFailureRestoresCanaryAfterValidatedInstall() throws {
        let fixture = try makeFixture()
        let directory = fixture.storage.exportsDirectory(forMatterID: fixture.matterID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("Q-A-v1.md")
        let canary = Data("prior-reviewed-export".utf8)
        try canary.write(to: destination)
        var recorderObservedInstalledFile = false
        let service = DocumentExportService(
            store: fixture.store,
            storage: fixture.storage,
            completionRecorder: { _, _ in
                recorderObservedInstalledFile = FileManager.default.fileExists(atPath: destination.path)
                    && (try? DocumentExportValidator.validate(destination, as: .markdown)) != nil
                throw InjectedFailure.stop
            }
        )

        XCTAssertThrowsError(
            try service.export(matterID: fixture.matterID, structuredOutputID: fixture.outputID, format: .markdown)
        )
        XCTAssertTrue(recorderObservedInstalledFile)
        XCTAssertEqual(try Data(contentsOf: destination), canary)
        XCTAssertTrue(try fixture.store.documentSources.fetchExports(structuredOutputID: fixture.outputID).isEmpty)
        XCTAssertFalse(try fixture.store.auditEvents.fetchEvents(matterID: fixture.matterID).contains { $0.eventType == "export_completed" })
    }

    func testTUX01ServiceRejectsVerificationOnlyExportWhenAssuranceIsNotEligible() throws {
        // T-UX-01 expected RED: the controller hides export, but the service
        // accepts a direct legacy/review-state export and can bypass assurance.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic export assurance")
        let output = try store.structuredOutputs.createOutput(
            matterID: matter.id,
            title: "Blocked assurance",
            outputType: .documentQA,
            status: .needsReview
        )
        _ = try store.structuredOutputs.createVersion(
            structuredOutputID: output.id,
            contentMarkdown: "UNEXPORTABLE NONDEFAULT CONTENT",
            requiredSections: [],
            presentSections: [],
            missingSections: []
        )

        XCTAssertThrowsError(
            try DocumentExportService(store: store).export(
                matterID: matter.id,
                structuredOutputID: output.id,
                format: .markdown
            )
        ) { error in
            guard case DocumentExportService.ExportError.assuranceBlocked = error else {
                return XCTFail("expected assuranceBlocked, got \(error)")
            }
        }
        XCTAssertTrue(try store.documentSources.fetchExports(structuredOutputID: output.id).isEmpty)
    }

    func testTEXACTEXPORT01CorpusCompleteExhaustiveVersionRequiresMatchingPersistedV2ExactRun() throws {
        // T-EXACT-EXPORT-01 expected RED: DocumentExportService trusts an active
        // all_supported/corpus_complete exhaustive-list version without resolving
        // exactly one linked persisted v2 exact-slice run, so the poison legacy
        // planning link below still produces an export file and success metadata.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic exact export proof")
        let title = "Unproven exhaustive marker 734"
        let output = try store.structuredOutputs.createOutput(
            matterID: matter.id,
            title: title,
            outputType: .documentExhaustiveList,
            status: .complete
        )
        let version = try createExportableVersion(
            store: store,
            structuredOutputID: output.id,
            versionIndex: 1,
            contentMarkdown: "UNPROVEN-EXHAUSTIVE-CONTENT-734-MUST-NOT-EXPORT",
            assuranceState: .corpusComplete
        )
        let poisonRun = CorpusAnalysisRunRecord(
            runKey: "legacy-planning-export-poison-734",
            matterID: matter.id,
            taskKind: CorpusAnalysisTaskKind.exhaustiveList.rawValue,
            scopeJSON: #"{"schema_version":1,"document_ids":null}"#,
            corpusSnapshotJSON: #"{"schema_version":1,"members":[]}"#,
            partitionStrategy: "part_range:characters=734",
            partitionStrategyVersion: 1,
            status: CorpusAnalysisRunStatus.planning.rawValue,
            structuredOutputVersionID: version.id
        )
        _ = try store.corpusAnalysis.createOrFetchRun(poisonRun)
        let persistedPoison = try XCTUnwrap(
            store.corpusAnalysis.fetchRun(matterID: matter.id, runKey: poisonRun.runKey)
        )
        let activeOutput = try XCTUnwrap(
            store.structuredOutputs.fetchOutputs(matterID: matter.id).first { $0.id == output.id }
        )
        XCTAssertEqual(activeOutput.activeVersionID, version.id)
        XCTAssertEqual(version.verificationStatus, OutputVerificationStatus.allSupported.rawValue)
        XCTAssertEqual(version.assuranceState, OutputAssuranceState.corpusComplete.rawValue)
        XCTAssertEqual(persistedPoison.structuredOutputVersionID, version.id)
        XCTAssertEqual(persistedPoison.status, CorpusAnalysisRunStatus.planning.rawValue)
        XCTAssertNotEqual(persistedPoison.status, CorpusAnalysisRunStatus.persisted.rawValue)
        XCTAssertNotEqual(persistedPoison.requestSchemaVersion, 2)
        XCTAssertNotEqual(persistedPoison.partitionStrategyVersion, 2)

        let storage = DocumentStorage(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("ExactExportProof-\(UUID().uuidString)")
        )
        let destination = storage.exportsDirectory(forMatterID: matter.id)
            .appendingPathComponent("Unproven-exhaustive-marker-734-v1.md")

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertThrowsError(
            try DocumentExportService(store: store, storage: storage).export(
                matterID: matter.id,
                structuredOutputID: output.id,
                format: .markdown
            )
        ) { error in
            guard case DocumentExportService.ExportError.assuranceBlocked = error else {
                return XCTFail("expected assuranceBlocked for missing exact corpus proof, got \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path),
            "the unproven nondefault exhaustive artifact must not be written"
        )
        XCTAssertTrue(try store.documentSources.fetchExports(structuredOutputID: output.id).isEmpty)
        XCTAssertFalse(
            try store.auditEvents.fetchEvents(matterID: matter.id).contains {
                $0.eventType == "export_completed" && $0.relatedID == output.id
            }
        )
    }

    func testTEXACTEXPORT02NilActiveVersionFailsClosedInsteadOfFallingBackToLatest() throws {
        // T-EXACT-EXPORT-02 expected RED: DocumentExportService falls back to the
        // newest version when active_version_id is nil, writes its nondefault
        // content, and records a successful export instead of throwing noActiveVersion.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic nil active export")
        let title = "Nil active marker 862"
        let output = try store.structuredOutputs.createOutput(
            matterID: matter.id,
            title: title,
            outputType: .documentQA,
            status: .complete
        )
        let inactiveVersion = try createExportableVersion(
            store: store,
            structuredOutputID: output.id,
            versionIndex: 1,
            contentMarkdown: "LATEST-INACTIVE-CONTENT-862-MUST-NOT-EXPORT",
            makeActive: false
        )
        let persistedOutput = try XCTUnwrap(
            store.structuredOutputs.fetchOutputs(matterID: matter.id).first { $0.id == output.id }
        )
        XCTAssertNil(persistedOutput.activeVersionID)
        XCTAssertEqual(inactiveVersion.verificationStatus, OutputVerificationStatus.allSupported.rawValue)
        XCTAssertEqual(inactiveVersion.assuranceState, OutputAssuranceState.propositionSupported.rawValue)

        let storage = DocumentStorage(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("NilActiveExport-\(UUID().uuidString)")
        )
        let destination = storage.exportsDirectory(forMatterID: matter.id)
            .appendingPathComponent("Nil-active-marker-862-v1.md")

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertThrowsError(
            try DocumentExportService(store: store, storage: storage).export(
                matterID: matter.id,
                structuredOutputID: output.id,
                format: .markdown
            )
        ) { error in
            guard case DocumentExportService.ExportError.noActiveVersion = error else {
                return XCTFail("expected noActiveVersion, got \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path),
            "the inactive nondefault artifact must not be written"
        )
        XCTAssertTrue(try store.documentSources.fetchExports(structuredOutputID: output.id).isEmpty)
        XCTAssertFalse(
            try store.auditEvents.fetchEvents(matterID: matter.id).contains {
                $0.eventType == "export_completed" && $0.relatedID == output.id
            }
        )
    }

    func testTEXACTEXPORT03RevokedProofAtCompletionRestoresCanaryAndWritesNoSuccessRows() async throws {
        // T-EXACT-EXPORT-03 expected RED: exact-proof authorization occurs before
        // rendering, but the export/audit transaction does not revalidate it. A
        // proof revoked after install can therefore leave a successful export row.
        let fixture = try await makeExactExportFixture(marker: 947)
        let canary = Data("PRIOR-EXACT-EXPORT-CANARY-947".utf8)
        try FileManager.default.createDirectory(
            at: fixture.destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try canary.write(to: fixture.destination)
        var recorderSawInstalledFile = false
        let service = DocumentExportService(
            store: fixture.store,
            storage: fixture.storage,
            completionRecorder: { export, audit in
                recorderSawInstalledFile = (try? DocumentExportValidator.validate(
                    fixture.destination,
                    as: .markdown
                )) != nil
                _ = try fixture.store.corpusAnalysis.cancelRun(
                    matterID: fixture.matterID,
                    runID: fixture.runID
                )
                try fixture.store.documentSources.recordExportCompletion(
                    export,
                    auditEvent: audit
                )
            }
        )

        XCTAssertThrowsError(
            try service.export(
                matterID: fixture.matterID,
                structuredOutputID: fixture.outputID,
                format: .markdown
            )
        ) { error in
            guard case DocumentExportService.ExportError.completionRecordingFailed = error else {
                return XCTFail("expected completionRecordingFailed after proof revocation, got \(error)")
            }
        }
        XCTAssertTrue(recorderSawInstalledFile)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), canary)
        XCTAssertTrue(
            try fixture.store.documentSources.fetchExports(
                structuredOutputID: fixture.outputID
            ).isEmpty
        )
        XCTAssertFalse(
            try fixture.store.auditEvents.fetchEvents(matterID: fixture.matterID).contains {
                $0.eventType == "export_completed" && $0.relatedID == fixture.outputID
            }
        )
    }

    func testTEXACTEXPORT04ActiveVersionSwitchAtCompletionRestoresCanaryAndWritesNoSuccessRows() async throws {
        // T-EXACT-EXPORT-04 expected RED: the completion transaction does not
        // require the exported version to remain the output's active version.
        let fixture = try await makeExactExportFixture(marker: 953)
        let weakVersion = try fixture.store.structuredOutputs.createVersion(
            structuredOutputID: fixture.outputID,
            contentMarkdown: "WEAK-INACTIVE-VERSION-953",
            requiredSections: [],
            presentSections: [],
            missingSections: [],
            assuranceState: .supportNeedsReview,
            outputStatus: .needsReview,
            makeActive: false
        )
        let canary = Data("PRIOR-ACTIVE-VERSION-CANARY-953".utf8)
        try FileManager.default.createDirectory(
            at: fixture.destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try canary.write(to: fixture.destination)
        var recorderSawInstalledFile = false
        let service = DocumentExportService(
            store: fixture.store,
            storage: fixture.storage,
            completionRecorder: { export, audit in
                recorderSawInstalledFile = (try? DocumentExportValidator.validate(
                    fixture.destination,
                    as: .markdown
                )) != nil
                try fixture.store.database.writer.write { db in
                    try db.execute(
                        sql: "UPDATE structured_outputs SET active_version_id = ? WHERE id = ?",
                        arguments: [weakVersion.id, fixture.outputID]
                    )
                }
                try fixture.store.documentSources.recordExportCompletion(
                    export,
                    auditEvent: audit
                )
            }
        )

        XCTAssertThrowsError(
            try service.export(
                matterID: fixture.matterID,
                structuredOutputID: fixture.outputID,
                format: .markdown
            )
        ) { error in
            guard case DocumentExportService.ExportError.completionRecordingFailed = error else {
                return XCTFail("expected completionRecordingFailed after active-version switch, got \(error)")
            }
        }
        XCTAssertTrue(recorderSawInstalledFile)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), canary)
        XCTAssertTrue(
            try fixture.store.documentSources.fetchExports(
                structuredOutputID: fixture.outputID
            ).isEmpty
        )
        XCTAssertFalse(
            try fixture.store.auditEvents.fetchEvents(matterID: fixture.matterID).contains {
                $0.eventType == "export_completed" && $0.relatedID == fixture.outputID
            }
        )
    }

    private func makeFixture() throws -> (store: SupraStore, storage: DocumentStorage, matterID: String, outputID: String) {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let output = try store.structuredOutputs.createOutput(
            matterID: matter.id,
            title: "Q&A",
            outputType: .documentQA,
            status: .complete
        )
        _ = try createExportableVersion(
            store: store,
            structuredOutputID: output.id,
            versionIndex: 1,
            contentMarkdown: "Grounded answer."
        )
        let storage = DocumentStorage(
            root: FileManager.default.temporaryDirectory.appendingPathComponent("ExportFixture-\(UUID().uuidString)")
        )
        return (store, storage, matter.id, output.id)
    }

    private func makeExactExportFixture(marker: Int) async throws -> (
        store: SupraStore,
        storage: DocumentStorage,
        matterID: String,
        outputID: String,
        runID: String,
        destination: URL
    ) {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic exact export race \(marker)")
        let value = "EXACT-EXPORT-SUPPORTED-VALUE-\(marker)"
        _ = try insertExactTextDocument(
            store: store,
            matterID: matter.id,
            name: "exact-export-\(marker).txt",
            text: value
        )
        let title = "Revocable Exact Export \(marker)"
        let result = try await ExhaustiveListTask(store: store).run(
            request: ExhaustiveListRequest(
                runKey: "exact-export-race-run-\(marker)",
                matterID: matter.id,
                title: title,
                query: "Extract the exact supported value.",
                characterBudget: 1_907,
                modelLineageJSON: Self.exactModelLineageJSON
            )
        ) { input in
            let source = try XCTUnwrap(input.partition.sources.first)
            let payload: [String: Any] = [
                "schema_version": 1,
                "items": [[
                    "item_key": "exact-export-value-\(marker)",
                    "value": value,
                    "evidence": [[
                        "document_id": source.documentID,
                        "revision_id": source.revisionID,
                        "locator_json": source.locatorJSON,
                        "quote": value,
                        "char_start": 0,
                        "char_end": value.count,
                    ]],
                    "contrary_evidence": [],
                ]],
            ]
            let data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            return String(decoding: data, as: UTF8.self)
        }
        XCTAssertEqual(result.run.assuranceState, OutputAssuranceState.corpusComplete.rawValue)
        XCTAssertEqual(result.version.verificationStatus, OutputVerificationStatus.allSupported.rawValue)
        XCTAssertEqual(result.version.assuranceState, OutputAssuranceState.corpusComplete.rawValue)
        let storage = DocumentStorage(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("ExactExportRace-\(marker)-\(UUID().uuidString)")
        )
        let destination = storage.exportsDirectory(forMatterID: matter.id)
            .appendingPathComponent("Revocable-Exact-Export-\(marker)-v1.md")
        return (store, storage, matter.id, result.outputID, result.run.id, destination)
    }

    private func insertExactTextDocument(
        store: SupraStore,
        matterID: String,
        name: String,
        text: String
    ) throws -> String {
        let key = "exact-export-\(UUID().uuidString)"
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            sha256: key,
            byteSize: text.utf8.count,
            originalExtension: "txt",
            managedRelativePath: "blobs/\(key).txt"
        )).blob
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matterID,
            blobID: blob.id,
            displayName: name,
            status: MatterDocumentStatus.ready.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue,
            indexStatus: DocumentIndexStatus.textIndexed.rawValue
        ))
        let part = DocumentPagePartRecord(
            id: "\(key)-part",
            documentID: document.id,
            partIndex: 0,
            sourceKind: DocumentSourceKind.text.rawValue,
            normalizedText: text,
            charCount: text.count
        )
        let revision = DocumentPartRevisionRecord(
            id: "\(key)-revision",
            documentID: document.id,
            partIndex: 0,
            derivationKey: "exact-export-fixture",
            origin: "synthetic_test",
            method: "plain-text",
            text: text,
            charCount: text.count
        )
        _ = try store.documentRevisions.replacePartsAndPersistLineage(
            documentID: document.id,
            parts: [part],
            revisions: [revision],
            selections: [DocumentPartSelectionRecord(
                id: "\(key)-selection",
                documentID: document.id,
                partIndex: 0,
                selectedRevisionID: revision.id,
                selectionKey: "exact-export-fixture",
                selectedBy: "test",
                decisionJSON: #"{"rule":"fixture"}"#
            )]
        )
        return document.id
    }

    private func createExportableVersion(
        store: SupraStore,
        structuredOutputID: String,
        versionIndex: Int,
        contentMarkdown: String,
        assuranceState: OutputAssuranceState = .propositionSupported,
        makeActive: Bool = true
    ) throws -> StructuredOutputVersionRecord {
        let support = try PropositionSupportResult(
            propositionID: "export-proposition",
            status: .supported,
            reasons: [],
            evidence: [SupportEvidence(
                sourceID: "export-source",
                sourceLabel: "S1",
                locator: "synthetic:export",
                retainedExcerpt: "Grounded export evidence.",
                verifierName: "DocumentExportTests",
                verifierVersion: "tux01"
            )],
            timestamp: Date(timeIntervalSinceReferenceDate: 69)
        )
        return try store.structuredOutputs.createVersion(
            structuredOutputID: structuredOutputID,
            versionIndex: versionIndex,
            contentMarkdown: contentMarkdown,
            requiredSections: [],
            presentSections: [],
            missingSections: [],
            verificationStatus: .allSupported,
            verificationVersion: "tux01",
            verificationResults: [support],
            verificationDimensions: VerificationDimensionsMapper.dimensions(
                verificationResults: [support]
            ),
            assuranceState: assuranceState,
            outputStatus: .complete,
            makeActive: makeActive
        )
    }

    private func makeStore() throws -> SupraStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try SupraStore(url: directoryURL.appendingPathComponent("test.sqlite"))
    }
}
