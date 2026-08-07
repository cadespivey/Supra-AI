import Foundation
import GRDB
import SupraCore
@testable import SupraStore
import XCTest
final class PermanentSourceDeletionIntegrityTests: XCTestCase {
    func testTSTORE04PermanentDeletionAuditsAndInvalidatesDependentEvidenceAndOutput() throws {
        // T-STORE-04 expected RED: permanent document deletion nulls live source
        // identities but does not atomically append its base audit or revoke the
        // dependent output's publication-level assurance/export eligibility.
        let fixture = try makeFixture(caseName: "invalidate")
        try fixture.store.documentLibrary.softDeleteDocument(id: fixture.document.id)

        let result = try fixture.store.documentLibrary.permanentlyDeleteDocument(
            id: fixture.document.id)

        XCTAssertEqual(result.removedDocumentIDs, [fixture.document.id])
        XCTAssertNil(try fixture.store.documentLibrary.fetchDocument(id: fixture.document.id))
        let retainedSource = try XCTUnwrap(
            try fixture.store.documentSources.fetchSource(id: fixture.source.id)
        )
        XCTAssertNil(retainedSource.documentID)
        XCTAssertNil(retainedSource.chunkID)
        XCTAssertNil(retainedSource.revisionID)
        XCTAssertEqual(retainedSource.excerpt, fixture.source.excerpt)
        XCTAssertEqual(retainedSource.locatorJSON, fixture.source.locatorJSON)

        let invalidatedVersion = try XCTUnwrap(
            try fixture.store.structuredOutputs.fetchVersion(id: fixture.version.id)
        )
        XCTAssertEqual(invalidatedVersion.assuranceState, OutputAssuranceState.stale.rawValue)
        XCTAssertNotNil(invalidatedVersion.staleReason)
        XCTAssertFalse(invalidatedVersion.staleReason?.isEmpty ?? true)
        let invalidatedAssurance = invalidatedVersion.assuranceState.flatMap(
            OutputAssuranceState.init(rawValue:))
        XCTAssertNotNil(invalidatedAssurance)
        XCTAssertFalse(invalidatedAssurance.map(OutputAssurancePresentation.isExportEligible) ?? true)
        let invalidatedOutput = try XCTUnwrap(
            try fixture.store.structuredOutputs.fetchOutputs(matterID: fixture.matter.id)
                .first { $0.id == fixture.output.id }
        )
        XCTAssertEqual(invalidatedOutput.activeVersionID, fixture.version.id)
        XCTAssertEqual(invalidatedOutput.status, StructuredOutputStatus.needsReview.rawValue)
        let invalidatedRun = try XCTUnwrap(
            try fixture.store.corpusAnalysis.fetchRun(
                matterID: fixture.matter.id,
                id: fixture.corpusRun.id
            )
        )
        XCTAssertEqual(invalidatedRun.assuranceState, OutputAssuranceState.stale.rawValue)

        let snapshotOnlyRun = try XCTUnwrap(
            try fixture.store.corpusAnalysis.fetchRun(
                matterID: fixture.matter.id,
                id: fixture.snapshotOnlyRun.id
            )
        )
        XCTAssertEqual(snapshotOnlyRun.assuranceState, OutputAssuranceState.stale.rawValue)
        XCTAssertNil(
            snapshotOnlyRun.structuredOutputVersionID,
            "snapshot membership alone must be sufficient to invalidate a dependent run"
        )
        try assertUnrelatedGraphUnaffected(fixture)

        let deletionEvents = try fixture.store.auditEvents.fetchEvents(
            relatedTable: "matter_documents",
            relatedID: fixture.document.id,
            eventType: "document_permanently_deleted"
        )
        XCTAssertEqual(deletionEvents.count, 1)
        XCTAssertEqual(deletionEvents.first?.matterID, fixture.matter.id)
        XCTAssertFalse(deletionEvents.first?.actor.isEmpty ?? true)
        XCTAssertEqual(deletionEvents.first?.relatedID, fixture.document.id)
        XCTAssertFalse(deletionEvents.first?.summary.isEmpty ?? true)
        let metadata = try auditMetadata(try XCTUnwrap(deletionEvents.first))
        XCTAssertEqual(metadata["matter_id"] as? String, fixture.matter.id)
        XCTAssertEqual(metadata["document_id"] as? String, fixture.document.id)
        XCTAssertEqual(
            metadata["removed_document_ids"] as? [String],
            [fixture.document.id]
        )
        XCTAssertEqual(
            metadata["invalidated_output_version_ids"] as? [String],
            [fixture.version.id]
        )
        XCTAssertEqual(
            Set(metadata["invalidated_corpus_run_ids"] as? [String] ?? []),
            Set([fixture.corpusRun.id, fixture.snapshotOnlyRun.id])
        )
    }

    func testTSTORE04InjectedBaseAuditFailureRollsBackEntirePermanentDeletion() throws {
        // T-STORE-04 expected RED: the repository has no in-transaction base
        // audit insert, so this injected audit failure never fires and the
        // destructive document/revision/chunk/FTS mutation commits instead.
        let fixture = try makeFixture(caseName: "audit-rollback")
        try fixture.store.documentLibrary.softDeleteDocument(id: fixture.document.id)
        let deletedAt = try XCTUnwrap(
            try fixture.store.documentLibrary.fetchDocument(id: fixture.document.id)?.deletedAt
        )
        try fixture.store.database.writer.write { db in
            try db.execute(
                sql: """
                    CREATE TRIGGER t_store_04_reject_delete_audit
                    BEFORE INSERT ON audit_events
                    WHEN NEW.event_type = 'document_permanently_deleted'
                    BEGIN
                        SELECT RAISE(ABORT, 'synthetic T-STORE-04 base-audit failure');
                    END
                    """)
        }
        XCTAssertEqual(try ftsRowCount(fixture), 1)

        XCTAssertThrowsError(
            try fixture.store.documentLibrary.permanentlyDeleteDocument(id: fixture.document.id)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("synthetic T-STORE-04 base-audit failure"))
        }

        let preservedDocument = try fixture.store.documentLibrary.fetchDocument(id: fixture.document.id)
        XCTAssertNotNil(preservedDocument)
        XCTAssertEqual(preservedDocument?.deletedAt, deletedAt)
        XCTAssertNotNil(try fixture.store.documentLibrary.fetchBlob(id: fixture.blob.id))
        XCTAssertNotNil(try fixture.store.documentRevisions.fetchRevision(id: fixture.revision.id))
        XCTAssertNotNil(try fixture.store.documentIndex.fetchChunk(id: fixture.chunk.id))
        XCTAssertEqual(try ftsRowCount(fixture), 1)

        let preservedSource = try XCTUnwrap(
            try fixture.store.documentSources.fetchSource(id: fixture.source.id)
        )
        XCTAssertEqual(preservedSource.documentID, fixture.document.id)
        XCTAssertEqual(preservedSource.chunkID, fixture.chunk.id)
        XCTAssertEqual(preservedSource.revisionID, fixture.revision.id)
        XCTAssertEqual(preservedSource.excerpt, fixture.source.excerpt)
        let preservedVersion = try XCTUnwrap(
            try fixture.store.structuredOutputs.fetchVersion(id: fixture.version.id)
        )
        XCTAssertEqual(
            preservedVersion.assuranceState, OutputAssuranceState.propositionSupported.rawValue)
        XCTAssertNil(preservedVersion.staleReason)
        let preservedAssurance = try XCTUnwrap(
            preservedVersion.assuranceState.flatMap(OutputAssuranceState.init(rawValue:))
        )
        let preservedOutput = try XCTUnwrap(
            try fixture.store.structuredOutputs.fetchOutputs(matterID: fixture.matter.id)
                .first { $0.id == fixture.output.id }
        )
        XCTAssertEqual(preservedOutput.status, StructuredOutputStatus.complete.rawValue)
        let preservedRun = try XCTUnwrap(
            try fixture.store.corpusAnalysis.fetchRun(
                matterID: fixture.matter.id,
                id: fixture.corpusRun.id
            )
        )
        XCTAssertEqual(
            preservedRun.assuranceState,
            OutputAssuranceState.propositionSupported.rawValue
        )
        let preservedSnapshotOnlyRun = try XCTUnwrap(
            try fixture.store.corpusAnalysis.fetchRun(
                matterID: fixture.matter.id,
                id: fixture.snapshotOnlyRun.id
            )
        )
        XCTAssertEqual(
            preservedSnapshotOnlyRun.assuranceState,
            OutputAssuranceState.propositionSupported.rawValue
        )
        try assertUnrelatedGraphUnaffected(fixture)
        XCTAssertTrue(OutputAssurancePresentation.isExportEligible(preservedAssurance))
        XCTAssertTrue(
            try fixture.store.auditEvents.fetchEvents(
                relatedTable: "matter_documents",
                relatedID: fixture.document.id,
                eventType: "document_permanently_deleted"
            ).isEmpty
        )
    }

    func testTSTORE04GlobalMatterDeletionWritesSurvivingBaseAudit() throws {
        // T-STORE-04 expected RED: global matter deletion cascades the matter,
        // document, FTS, and output rows without creating the surviving base
        // audit required for parity with matter-local document deletion.
        let fixture = try makeFixture(caseName: "matter-audit")
        try fixture.store.matters.softDeleteMatter(
            id: fixture.matter.id,
            deletedAt: Date(timeIntervalSince1970: 1_790_004_701)
        )

        let removedBlobPaths = try fixture.store.matters.permanentlyDeleteMatter(id: fixture.matter.id)

        XCTAssertEqual(
            Set(removedBlobPaths),
            Set([fixture.blob.managedRelativePath, fixture.unrelated.blob.managedRelativePath])
        )
        XCTAssertNil(try matterRecord(fixture))
        XCTAssertNil(try fixture.store.documentLibrary.fetchDocument(id: fixture.document.id))
        XCTAssertEqual(try ftsRowCount(fixture), 0)
        XCTAssertNil(try outputRecord(fixture))
        let events = try fixture.store.auditEvents.fetchEvents(
            relatedTable: "matters",
            relatedID: fixture.matter.id,
            eventType: "matter_permanently_deleted"
        )
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(
            events.first?.matterID, "the surviving audit must not retain a dangling matter foreign key")
        XCTAssertEqual(events.first?.relatedTable, "matters")
        XCTAssertEqual(events.first?.relatedID, fixture.matter.id)
        XCTAssertFalse(events.first?.actor.isEmpty ?? true)
        XCTAssertFalse(events.first?.summary.isEmpty ?? true)
        let metadata = try auditMetadata(try XCTUnwrap(events.first))
        XCTAssertEqual(metadata["matter_id"] as? String, fixture.matter.id)
        XCTAssertEqual(metadata["matter_name"] as? String, fixture.matter.name)
        XCTAssertEqual(metadata["removed_document_count"] as? Int, 2)
        XCTAssertEqual(
            Set(metadata["removed_document_ids"] as? [String] ?? []),
            Set([fixture.document.id, fixture.unrelated.document.id])
        )
    }

    func testTSTORE04InjectedMatterAuditFailureRollsBackGlobalCascade() throws {
        // T-STORE-04 expected RED: the global repository does not insert its
        // base audit in the destructive transaction, so this injected failure
        // never fires and the matter/document/FTS/output cascade commits.
        let fixture = try makeFixture(caseName: "matter-audit-rollback")
        let deletedAt = Date(timeIntervalSince1970: 1_790_004_797)
        try fixture.store.matters.softDeleteMatter(id: fixture.matter.id, deletedAt: deletedAt)
        try fixture.store.database.writer.write { db in
            try db.execute(
                sql: """
                    CREATE TRIGGER t_store_04_reject_matter_delete_audit
                    BEFORE INSERT ON audit_events
                    WHEN NEW.event_type = 'matter_permanently_deleted'
                    BEGIN
                        SELECT RAISE(ABORT, 'synthetic T-STORE-04 matter base-audit failure');
                    END
                    """)
        }
        XCTAssertEqual(try ftsRowCount(fixture), 1)

        XCTAssertThrowsError(
            try fixture.store.matters.permanentlyDeleteMatter(id: fixture.matter.id)
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("synthetic T-STORE-04 matter base-audit failure"))
        }

        let preservedMatter = try matterRecord(fixture)
        XCTAssertNotNil(preservedMatter)
        XCTAssertEqual(preservedMatter?.deletedAt, deletedAt)
        let preservedDocument = try fixture.store.documentLibrary.fetchDocument(id: fixture.document.id)
        XCTAssertNotNil(preservedDocument)
        XCTAssertEqual(preservedDocument?.deletedAt, deletedAt)
        XCTAssertNotNil(try fixture.store.documentLibrary.fetchBlob(id: fixture.blob.id))
        XCTAssertNotNil(try fixture.store.documentRevisions.fetchRevision(id: fixture.revision.id))
        XCTAssertNotNil(try fixture.store.documentIndex.fetchChunk(id: fixture.chunk.id))
        XCTAssertEqual(try ftsRowCount(fixture), 1)
        let preservedOutput = try outputRecord(fixture)
        XCTAssertNotNil(preservedOutput)
        XCTAssertEqual(preservedOutput?.deletedAt, deletedAt)
        XCTAssertEqual(preservedOutput?.status, StructuredOutputStatus.complete.rawValue)
        XCTAssertNotNil(try fixture.store.structuredOutputs.fetchVersion(id: fixture.version.id))
        XCTAssertNotNil(
            try fixture.store.corpusAnalysis.fetchRun(
                matterID: fixture.matter.id,
                id: fixture.corpusRun.id
            )
        )
        let preservedSource = try fixture.store.documentSources.fetchSource(id: fixture.source.id)
        XCTAssertEqual(preservedSource?.documentID, fixture.document.id)
        XCTAssertEqual(preservedSource?.chunkID, fixture.chunk.id)
        XCTAssertEqual(preservedSource?.revisionID, fixture.revision.id)
        XCTAssertTrue(
            try fixture.store.auditEvents.fetchEvents(
                relatedTable: "matters",
                relatedID: fixture.matter.id,
                eventType: "matter_permanently_deleted"
            ).isEmpty
        )
    }

    private func makeFixture(caseName: String) throws -> DeletionFixture {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(
            name: "Synthetic permanent deletion \(caseName)",
            jurisdiction: "Maryland",
            partyPerspective: .defendant
        )
        let blob = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(
                id: "t-store-04-blob-\(caseName)",
                sha256: String(repeating: "7", count: 64),
                byteSize: 9_197,
                originalExtension: "txt",
                managedRelativePath: "blobs/t-store-04-\(caseName).txt",
                mimeType: "text/plain",
                integrityStatus: DocumentBlobIntegrityStatus.verified.rawValue,
                verifiedAt: Date(timeIntervalSince1970: 1_790_004_097)
            )
        ).blob
        let document = try store.documentLibrary.insertDocument(
            MatterDocumentRecord(
                id: "t-store-04-document-\(caseName)",
                matterID: matter.id,
                blobID: blob.id,
                displayName: "Synthetic-deletion-\(caseName)-97.txt",
                status: MatterDocumentStatus.ready.rawValue,
                extractionStatus: DocumentExtractionStatus.extracted.rawValue,
                indexStatus: DocumentIndexStatus.textIndexed.rawValue,
                sourceKind: DocumentSourceKind.text.rawValue,
                extractedTextChecksum: "t-store-04-checksum-97",
                pagePartCount: 14,
                importedAt: Date(timeIntervalSince1970: 1_790_004_097)
            ))
        let sourceExcerptMarker =
            "Synthetic retained source value 97 remains denormalized after deletion."
        let sourceExcerpt =
            sourceExcerptMarker
            + String(repeating: "e", count: 276 - sourceExcerptMarker.count)
        let revisionText =
            String(repeating: "p", count: 113)
            + sourceExcerpt
            + String(repeating: "s", count: 31)
        let revision = try store.documentRevisions.appendRevision(
            DocumentPartRevisionRecord(
                id: "t-store-04-revision-\(caseName)",
                documentID: document.id,
                partIndex: 13,
                derivationKey: "t-store-04-derivation-\(caseName)-7",
                origin: "parser",
                method: "synthetic_exact_text",
                text: revisionText,
                charCount: revisionText.count,
                toolchainVersion: "synthetic-parser/7",
                reason: "T-STORE-04 deletion dependency fixture",
                createdAt: Date(timeIntervalSince1970: 1_790_004_107)
            ))
        let chunk = DocumentChunkRecord(
            id: "t-store-04-chunk-\(caseName)",
            documentID: document.id,
            revisionID: revision.id,
            chunkerVersion: 7,
            chunkIndex: 13,
            sourceKind: DocumentSourceKind.text.rawValue,
            charStart: 113,
            charEnd: 389,
            normalizedText: sourceExcerpt,
            displayExcerpt: sourceExcerpt,
            tokenCount: 53,
            createdAt: Date(timeIntervalSince1970: 1_790_004_117),
            updatedAt: Date(timeIntervalSince1970: 1_790_004_117)
        )
        try store.documentIndex.replaceChunks(documentID: document.id, chunks: [chunk])
        let sourceSet = try store.documentSources.createSourceSet(
            matterID: matter.id,
            mode: .guided,
            scopeJSON: "{\"document_ids\":[\"\(document.id)\"],\"schema_version\":7}",
            retrievalQuery: "synthetic permanent deletion dependency 97",
            retrievalDepth: "deep",
            packingReportJSON: #"{"packed_source_count":1,"probe":97}"#,
            embeddingModelID: "synthetic/embed-97",
            embeddingModelRevision: "embedding-revision-7",
            chunkerVersion: 7,
            retrievalConfigJSON: #"{"rrf_k":83,"candidate_limit":97}"#,
            corpusSnapshotHash: String(repeating: "8", count: 64)
        )
        let source = DocumentOutputSourceRecord(
            id: "t-store-04-source-\(caseName)",
            sourceSetID: sourceSet.id,
            documentID: document.id,
            chunkID: chunk.id,
            revisionID: revision.id,
            citationLabel: "S97",
            locatorJSON: #"{"source_kind":"text","part_index":13,"char_start":113,"char_end":389}"#,
            excerpt: sourceExcerpt,
            rank: 17,
            warningsJSON: #"["synthetic_deletion_dependency"]"#,
            createdAt: Date(timeIntervalSince1970: 1_790_004_127)
        )
        try store.documentSources.addOutputSource(source)
        let output = try store.structuredOutputs.createOutput(
            matterID: matter.id,
            title: "Synthetic deletion dependency 97",
            outputType: .documentQA
        )
        let version = try store.structuredOutputs.createVersion(
            structuredOutputID: output.id,
            contentMarkdown: "Synthetic retained source value 97 [S97].",
            requiredSections: ["Finding 97"],
            presentSections: ["Finding 97"],
            missingSections: [],
            verificationStatus: .allSupported,
            verificationVersion: "source-deletion-integrity/7",
            verificationResults: [try supportedResult(source: source)],
            verificationDimensions: supportedDimensions(),
            verifiedAt: Date(timeIntervalSince1970: 1_790_004_137),
            sourceSetID: sourceSet.id,
            promptBuilderVersion: "case-file-review-prompt/7",
            assuranceState: .propositionSupported,
            outputStatus: .complete
        )
        let unrelated = try makeUnrelatedGraph(
            store: store,
            matter: matter,
            caseName: caseName
        )
        let corpusRun = CorpusAnalysisRunRecord(
            id: "t-store-04-run-\(caseName)",
            runKey: "t-store-04-run-key-\(caseName)",
            matterID: matter.id,
            taskKind: CorpusAnalysisTaskKind.customExtraction.rawValue,
            scopeJSON: "{\"document_ids\":[\"\(document.id)\"],\"schema_version\":7}",
            corpusSnapshotJSON:
                "{\"members\":[{\"member_key\":\"t-store-04-member-\(caseName)\",\"document_id\":\"\(document.id)\",\"display_name\":\"Synthetic deletion source\",\"revision_ids\":[\"\(revision.id)\"],\"index_state\":\"ready\",\"disposition\":\"eligible\"}],\"schema_version\":7}",
            partitionStrategy: "synthetic_source_dependency",
            partitionStrategyVersion: 1,
            modelLineageJSON:
                #"{"model_repository":"synthetic/delete-integrity","model_revision":"revision-7"}"#,
            status: CorpusAnalysisRunStatus.persisted.rawValue,
            coverageJSON: #"{"balance_error_count":0,"partition_count":1,"succeeded_partition_count":1}"#,
            reconciliationJSON: #"{"finding":"Synthetic retained source value 97","schema_version":7}"#,
            assuranceState: OutputAssuranceState.propositionSupported.rawValue,
            assuranceReasonsJSON: "[]",
            structuredOutputVersionID: version.id,
            createdAt: Date(timeIntervalSince1970: 1_790_004_147),
            completedAt: Date(timeIntervalSince1970: 1_790_004_157)
        )
        let snapshotOnlyRun = CorpusAnalysisRunRecord(
            id: "t-store-04-snapshot-only-run-\(caseName)",
            runKey: "t-store-04-snapshot-only-key-\(caseName)",
            matterID: matter.id,
            taskKind: CorpusAnalysisTaskKind.customExtraction.rawValue,
            scopeJSON: "{\"document_ids\":[\"\(document.id)\"],\"schema_version\":7}",
            corpusSnapshotJSON:
                "{\"members\":[{\"member_key\":\"t-store-04-snapshot-only-member-\(caseName)\",\"document_id\":\"\(document.id)\",\"display_name\":\"Synthetic snapshot-only dependency\",\"revision_ids\":[\"\(revision.id)\"],\"index_state\":\"ready\",\"disposition\":\"eligible\"}],\"schema_version\":7}",
            partitionStrategy: "synthetic_snapshot_only_dependency",
            partitionStrategyVersion: 1,
            modelLineageJSON:
                #"{"model_repository":"synthetic/delete-integrity","model_revision":"snapshot-only-11"}"#,
            status: CorpusAnalysisRunStatus.persisted.rawValue,
            coverageJSON: #"{"balance_error_count":0,"partition_count":1,"succeeded_partition_count":1}"#,
            reconciliationJSON: #"{"finding":"Synthetic snapshot-only value 113","schema_version":7}"#,
            assuranceState: OutputAssuranceState.propositionSupported.rawValue,
            assuranceReasonsJSON: "[]",
            createdAt: Date(timeIntervalSince1970: 1_790_004_167),
            completedAt: Date(timeIntervalSince1970: 1_790_004_177)
        )
        let unrelatedRun = CorpusAnalysisRunRecord(
            id: "t-store-04-unrelated-run-\(caseName)",
            runKey: "t-store-04-unrelated-key-\(caseName)",
            matterID: matter.id,
            taskKind: CorpusAnalysisTaskKind.customExtraction.rawValue,
            scopeJSON: "{\"document_ids\":[\"\(unrelated.document.id)\"],\"schema_version\":7}",
            corpusSnapshotJSON:
                "{\"members\":[{\"member_key\":\"t-store-04-unrelated-member-\(caseName)\",\"document_id\":\"\(unrelated.document.id)\",\"display_name\":\"Synthetic unrelated source\",\"revision_ids\":[\"\(unrelated.revision.id)\"],\"index_state\":\"ready\",\"disposition\":\"eligible\"}],\"schema_version\":7}",
            partitionStrategy: "synthetic_unrelated_dependency",
            partitionStrategyVersion: 1,
            modelLineageJSON:
                #"{"model_repository":"synthetic/delete-integrity","model_revision":"unrelated-13"}"#,
            status: CorpusAnalysisRunStatus.persisted.rawValue,
            coverageJSON: #"{"balance_error_count":0,"partition_count":1,"succeeded_partition_count":1}"#,
            reconciliationJSON: #"{"finding":"Synthetic unrelated value 127","schema_version":7}"#,
            assuranceState: OutputAssuranceState.propositionSupported.rawValue,
            assuranceReasonsJSON: "[]",
            structuredOutputVersionID: unrelated.version.id,
            createdAt: Date(timeIntervalSince1970: 1_790_004_187),
            completedAt: Date(timeIntervalSince1970: 1_790_004_197)
        )
        try store.database.writer.write { db in
            try corpusRun.insert(db)
            try snapshotOnlyRun.insert(db)
            try unrelatedRun.insert(db)
        }
        return DeletionFixture(
            store: store,
            matter: matter,
            blob: blob,
            document: document,
            revision: revision,
            chunk: chunk,
            source: source,
            output: output,
            version: version,
            corpusRun: corpusRun,
            snapshotOnlyRun: snapshotOnlyRun,
            unrelated: DeletionUnrelatedFixture(
                blob: unrelated.blob,
                document: unrelated.document,
                revision: unrelated.revision,
                chunk: unrelated.chunk,
                source: unrelated.source,
                output: unrelated.output,
                version: unrelated.version,
                corpusRun: unrelatedRun
            )
        )
    }

    private func makeUnrelatedGraph(
        store: SupraStore,
        matter: MatterRecord,
        caseName: String
    ) throws -> (
        blob: DocumentBlobRecord,
        document: MatterDocumentRecord,
        revision: DocumentPartRevisionRecord,
        chunk: DocumentChunkRecord,
        source: DocumentOutputSourceRecord,
        output: StructuredOutputRecord,
        version: StructuredOutputVersionRecord
    ) {
        let blob = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(
                id: "t-store-04-unrelated-blob-\(caseName)",
                sha256: String(repeating: "6", count: 64),
                byteSize: 8_813,
                originalExtension: "txt",
                managedRelativePath: "blobs/t-store-04-unrelated-\(caseName).txt",
                mimeType: "text/plain",
                integrityStatus: DocumentBlobIntegrityStatus.verified.rawValue,
                verifiedAt: Date(timeIntervalSince1970: 1_790_004_207)
            )
        ).blob
        let document = try store.documentLibrary.insertDocument(
            MatterDocumentRecord(
                id: "t-store-04-unrelated-document-\(caseName)",
                matterID: matter.id,
                blobID: blob.id,
                displayName: "Synthetic-unrelated-\(caseName)-127.txt",
                status: MatterDocumentStatus.ready.rawValue,
                extractionStatus: DocumentExtractionStatus.extracted.rawValue,
                indexStatus: DocumentIndexStatus.textIndexed.rawValue,
                sourceKind: DocumentSourceKind.text.rawValue,
                extractedTextChecksum: "t-store-04-unrelated-checksum-127",
                pagePartCount: 18,
                importedAt: Date(timeIntervalSince1970: 1_790_004_207)
            ))
        let excerptMarker = "Synthetic unrelated retained source value 127."
        let excerpt =
            excerptMarker
            + String(repeating: "u", count: 104 - excerptMarker.count)
        let text =
            String(repeating: "q", count: 47)
            + excerpt
            + String(repeating: "r", count: 37)
        let revision = try store.documentRevisions.appendRevision(
            DocumentPartRevisionRecord(
                id: "t-store-04-unrelated-revision-\(caseName)",
                documentID: document.id,
                partIndex: 17,
                derivationKey: "t-store-04-unrelated-derivation-\(caseName)-13",
                origin: "parser",
                method: "synthetic_exact_text",
                text: text,
                charCount: text.count,
                toolchainVersion: "synthetic-parser/13",
                reason: "T-STORE-04 same-matter negative control",
                createdAt: Date(timeIntervalSince1970: 1_790_004_217)
            ))
        let chunk = DocumentChunkRecord(
            id: "t-store-04-unrelated-chunk-\(caseName)",
            documentID: document.id,
            revisionID: revision.id,
            chunkerVersion: 7,
            chunkIndex: 17,
            sourceKind: DocumentSourceKind.text.rawValue,
            charStart: 47,
            charEnd: 151,
            normalizedText: excerpt,
            displayExcerpt: excerpt,
            tokenCount: 41,
            createdAt: Date(timeIntervalSince1970: 1_790_004_227),
            updatedAt: Date(timeIntervalSince1970: 1_790_004_227)
        )
        try store.documentIndex.replaceChunks(documentID: document.id, chunks: [chunk])
        let sourceSet = try store.documentSources.createSourceSet(
            matterID: matter.id,
            mode: .guided,
            scopeJSON: "{\"document_ids\":[\"\(document.id)\"],\"schema_version\":7}",
            retrievalQuery: "synthetic unrelated deletion control 127",
            retrievalDepth: "deep",
            packingReportJSON: #"{"packed_source_count":1,"probe":127}"#,
            embeddingModelID: "synthetic/embed-127",
            embeddingModelRevision: "embedding-revision-13",
            chunkerVersion: 7,
            retrievalConfigJSON: #"{"rrf_k":89,"candidate_limit":101}"#,
            corpusSnapshotHash: String(repeating: "5", count: 64)
        )
        let source = DocumentOutputSourceRecord(
            id: "t-store-04-unrelated-source-\(caseName)",
            sourceSetID: sourceSet.id,
            documentID: document.id,
            chunkID: chunk.id,
            revisionID: revision.id,
            citationLabel: "S127",
            locatorJSON: #"{"source_kind":"text","part_index":17,"char_start":47,"char_end":151}"#,
            excerpt: excerpt,
            rank: 19,
            warningsJSON: #"["synthetic_unrelated_control"]"#,
            createdAt: Date(timeIntervalSince1970: 1_790_004_237)
        )
        try store.documentSources.addOutputSource(source)
        let output = try store.structuredOutputs.createOutput(
            matterID: matter.id,
            title: "Synthetic unrelated deletion control 127",
            outputType: .documentQA
        )
        let version = try store.structuredOutputs.createVersion(
            structuredOutputID: output.id,
            contentMarkdown: "Synthetic unrelated retained source value 127 [S127].",
            requiredSections: ["Finding 127"],
            presentSections: ["Finding 127"],
            missingSections: [],
            verificationStatus: .allSupported,
            verificationVersion: "source-deletion-integrity/13",
            verificationResults: [try supportedResult(source: source)],
            verificationDimensions: supportedDimensions(),
            verifiedAt: Date(timeIntervalSince1970: 1_790_004_247),
            sourceSetID: sourceSet.id,
            promptBuilderVersion: "case-file-review-prompt/13",
            assuranceState: .propositionSupported,
            outputStatus: .complete
        )
        return (blob, document, revision, chunk, source, output, version)
    }

    private func assertUnrelatedGraphUnaffected(
        _ fixture: DeletionFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertNotNil(
            try fixture.store.documentLibrary.fetchDocument(id: fixture.unrelated.document.id),
            file: file,
            line: line
        )
        XCTAssertNotNil(
            try fixture.store.documentLibrary.fetchBlob(id: fixture.unrelated.blob.id),
            file: file,
            line: line
        )
        XCTAssertNotNil(
            try fixture.store.documentRevisions.fetchRevision(id: fixture.unrelated.revision.id),
            file: file,
            line: line
        )
        XCTAssertNotNil(
            try fixture.store.documentIndex.fetchChunk(id: fixture.unrelated.chunk.id),
            file: file,
            line: line
        )
        XCTAssertEqual(
            try ftsRowCount(fixture, documentID: fixture.unrelated.document.id),
            1,
            file: file,
            line: line
        )
        let source = try XCTUnwrap(
            try fixture.store.documentSources.fetchSource(id: fixture.unrelated.source.id),
            file: file,
            line: line
        )
        XCTAssertEqual(source.documentID, fixture.unrelated.document.id, file: file, line: line)
        XCTAssertEqual(source.chunkID, fixture.unrelated.chunk.id, file: file, line: line)
        XCTAssertEqual(source.revisionID, fixture.unrelated.revision.id, file: file, line: line)
        let version = try XCTUnwrap(
            try fixture.store.structuredOutputs.fetchVersion(id: fixture.unrelated.version.id),
            file: file,
            line: line
        )
        XCTAssertEqual(
            version.assuranceState,
            OutputAssuranceState.propositionSupported.rawValue,
            file: file,
            line: line
        )
        XCTAssertNil(version.staleReason, file: file, line: line)
        let output = try XCTUnwrap(
            try fixture.store.structuredOutputs.fetchOutputs(matterID: fixture.matter.id)
                .first { $0.id == fixture.unrelated.output.id },
            file: file,
            line: line
        )
        XCTAssertEqual(output.status, StructuredOutputStatus.complete.rawValue, file: file, line: line)
        let run = try XCTUnwrap(
            try fixture.store.corpusAnalysis.fetchRun(
                matterID: fixture.matter.id,
                id: fixture.unrelated.corpusRun.id
            ),
            file: file,
            line: line
        )
        XCTAssertEqual(
            run.assuranceState,
            OutputAssuranceState.propositionSupported.rawValue,
            file: file,
            line: line
        )
        XCTAssertEqual(
            run.structuredOutputVersionID,
            fixture.unrelated.version.id,
            "a linked but unrelated run must not be invalidated merely because it shares the matter",
            file: file,
            line: line
        )
    }

    private func auditMetadata(_ event: AuditEventRecord) throws -> [String: Any] {
        let metadataJSON = try XCTUnwrap(event.metadataJSON)
        let data = try XCTUnwrap(metadataJSON.data(using: .utf8))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func ftsRowCount(
        _ fixture: DeletionFixture,
        documentID: String? = nil
    ) throws -> Int {
        try fixture.store.database.writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM document_chunk_fts WHERE document_id = ?",
                arguments: [documentID ?? fixture.document.id]
            ) ?? -1
        }
    }

    private func matterRecord(_ fixture: DeletionFixture) throws -> MatterRecord? {
        try fixture.store.database.writer.read { db in
            try MatterRecord.fetchOne(db, key: fixture.matter.id)
        }
    }

    private func outputRecord(_ fixture: DeletionFixture) throws -> StructuredOutputRecord? {
        try fixture.store.database.writer.read { db in
            try StructuredOutputRecord.fetchOne(db, key: fixture.output.id)
        }
    }

    private func supportedResult(
        source: DocumentOutputSourceRecord
    ) throws -> PropositionSupportResult {
        try PropositionSupportResult(
            propositionID: "t-store-04-proposition-97",
            status: .supported,
            reasons: ["synthetic_exact_source_support"],
            evidence: [
                SupportEvidence(
                    sourceID: source.id,
                    sourceLabel: source.citationLabel,
                    locator: source.locatorJSON,
                    retainedExcerpt: source.excerpt,
                    verifierName: "PermanentSourceDeletionVerifier",
                    verifierVersion: "source-deletion-integrity/7"
                )
            ],
            timestamp: Date(timeIntervalSince1970: 1_790_004_137)
        )
    }

    private func supportedDimensions() -> VerificationDimensions {
        .complete(overrides: [
            .init(dimension: .propositionSupport, status: .satisfied),
            .init(dimension: .citationResolution, status: .satisfied),
            .init(dimension: .criticalValueFidelity, status: .satisfied),
            .init(dimension: .lowConfidenceHandling, status: .satisfied),
        ])
    }
}

private struct DeletionFixture {
    let store: SupraStore
    let matter: MatterRecord
    let blob: DocumentBlobRecord
    let document: MatterDocumentRecord
    let revision: DocumentPartRevisionRecord
    let chunk: DocumentChunkRecord
    let source: DocumentOutputSourceRecord
    let output: StructuredOutputRecord
    let version: StructuredOutputVersionRecord
    let corpusRun: CorpusAnalysisRunRecord
    let snapshotOnlyRun: CorpusAnalysisRunRecord
    let unrelated: DeletionUnrelatedFixture
}

private struct DeletionUnrelatedFixture {
    let blob: DocumentBlobRecord
    let document: MatterDocumentRecord
    let revision: DocumentPartRevisionRecord
    let chunk: DocumentChunkRecord
    let source: DocumentOutputSourceRecord
    let output: StructuredOutputRecord
    let version: StructuredOutputVersionRecord
    let corpusRun: CorpusAnalysisRunRecord
}
