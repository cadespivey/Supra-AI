import Foundation
import GRDB
import SupraCore
@testable import SupraStore
import XCTest

/// Milestone 3 (Document Intelligence) schema and repository tests (WO 32).
final class Milestone3SchemaTests: XCTestCase {

    func testMigrationsCreateAllMilestone3Tables() throws {
        let store = try makeStore()
        let tableNames = try store.database.writer.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT name FROM sqlite_master
                WHERE type IN ('table') AND name NOT LIKE 'sqlite_%'
                ORDER BY name
                """
            )
        }

        // Existing v001-v021 tables remain intact.
        XCTAssertTrue(tableNames.contains("matters"))
        XCTAssertTrue(tableNames.contains("structured_output_versions"))
        XCTAssertTrue(tableNames.contains("audit_events"))

        // Milestone 3 tables.
        for table in [
            "document_intelligence_settings",
            "document_blobs",
            "document_folders",
            "matter_documents",
            "document_tags",
            "document_tag_assignments",
            "document_pages_parts",
            "document_chunks",
            "document_chunk_fts",
            "document_embedding_models",
            "document_chunk_embeddings",
            "document_import_batches",
            "document_processing_jobs",
            "document_source_sets",
            "document_output_sources",
            "document_exports"
        ] {
            XCTAssertTrue(tableNames.contains(table), "missing table \(table)")
        }
    }

    func testBlobDedupCreatesOneBlobWithMultipleDocumentInstances() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let folderA = try store.documentLibrary.createFolder(matterID: matter.id, name: "Contracts")
        let folderB = try store.documentLibrary.createFolder(matterID: matter.id, name: "Duplicates")

        let first = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(sha256: "abc123", byteSize: 10, originalExtension: "pdf", managedRelativePath: "blobs/ab/abc123.pdf")
        )
        let second = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(sha256: "abc123", byteSize: 10, originalExtension: "pdf", managedRelativePath: "blobs/ab/abc123.pdf")
        )
        XCTAssertFalse(first.reused)
        XCTAssertTrue(second.reused)
        XCTAssertEqual(first.blob.id, second.blob.id)

        _ = try store.documentLibrary.insertDocument(
            MatterDocumentRecord(matterID: matter.id, blobID: first.blob.id, folderID: folderA.id, displayName: "service-agreement.pdf")
        )
        _ = try store.documentLibrary.insertDocument(
            MatterDocumentRecord(matterID: matter.id, blobID: first.blob.id, folderID: folderB.id, displayName: "service-agreement-copy.pdf")
        )

        XCTAssertEqual(try store.documentLibrary.referenceCount(blobID: first.blob.id), 2)
        XCTAssertEqual(try store.documentLibrary.fetchDocuments(matterID: matter.id).count, 2)
    }

    func testFolderSoftDeleteCascadesAndRestores() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let parent = try store.documentLibrary.createFolder(matterID: matter.id, name: "Contracts")
        let child = try store.documentLibrary.createFolder(matterID: matter.id, name: "Amendments", parentFolderID: parent.id)
        let blob = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(sha256: "s1", byteSize: 1, originalExtension: "pdf", managedRelativePath: "blobs/s1.pdf")
        ).blob
        let doc = try store.documentLibrary.insertDocument(
            MatterDocumentRecord(matterID: matter.id, blobID: blob.id, folderID: child.id, displayName: "amendment.pdf", status: MatterDocumentStatus.ready.rawValue)
        )

        try store.documentLibrary.softDeleteFolder(id: parent.id)

        XCTAssertEqual(try store.documentLibrary.fetchFolders(matterID: matter.id).count, 0)
        XCTAssertEqual(try store.documentLibrary.fetchDocuments(matterID: matter.id).count, 0)
        let deletedDoc = try XCTUnwrap(try store.documentLibrary.fetchDocument(id: doc.id))
        XCTAssertNotNil(deletedDoc.deletedAt)
        XCTAssertEqual(deletedDoc.status, MatterDocumentStatus.deleted.rawValue)

        try store.documentLibrary.restoreFolder(id: parent.id)
        XCTAssertEqual(try store.documentLibrary.fetchFolders(matterID: matter.id).count, 2)
        XCTAssertEqual(try store.documentLibrary.fetchDocuments(matterID: matter.id).count, 1)
    }

    func testParentRestorePreservesIndependentlyDeletedChildFolder() throws {
        // Expected RED: deleting the parent overwrites the child's earlier
        // deletion timestamp, so restoring the parent also restores the child.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let parent = try store.documentLibrary.createFolder(matterID: matter.id, name: "Discovery")
        let child = try store.documentLibrary.createFolder(
            matterID: matter.id,
            name: "Depositions",
            parentFolderID: parent.id
        )
        let blob = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(
                sha256: "independent-child-delete",
                byteSize: 1,
                originalExtension: "txt",
                managedRelativePath: "blobs/independent-child-delete.txt"
            )
        ).blob
        let document = try store.documentLibrary.insertDocument(
            MatterDocumentRecord(
                matterID: matter.id,
                blobID: blob.id,
                folderID: child.id,
                displayName: "deposition.txt"
            )
        )

        try store.documentLibrary.softDeleteFolder(id: child.id)
        // Pin a clearly distinct timestamp into the fixture so this test proves
        // delete-batch ownership rather than depending on wall-clock precision.
        let childDeletion = Date(timeIntervalSince1970: 1_700_000_000)
        try store.database.writer.write { db in
            try db.execute(
                sql: "UPDATE document_folders SET deleted_at = ? WHERE id = ?",
                arguments: [childDeletion, child.id]
            )
            try db.execute(
                sql: "UPDATE matter_documents SET deleted_at = ? WHERE id = ?",
                arguments: [childDeletion, document.id]
            )
        }

        try store.documentLibrary.softDeleteFolder(id: parent.id)
        try store.documentLibrary.restoreFolder(id: parent.id)

        let allFolders = try store.documentLibrary.fetchFolders(matterID: matter.id, includeDeleted: true)
        let restoredParent = try XCTUnwrap(allFolders.first { $0.id == parent.id })
        let independentlyDeletedChild = try XCTUnwrap(allFolders.first { $0.id == child.id })
        XCTAssertNil(restoredParent.deletedAt)
        XCTAssertEqual(
            independentlyDeletedChild.deletedAt,
            childDeletion,
            "restoring a parent must not revive a child folder deleted in an earlier operation"
        )
        XCTAssertEqual(
            try XCTUnwrap(store.documentLibrary.fetchDocument(id: document.id)).deletedAt,
            childDeletion,
            "documents owned by the independently deleted child must remain in trash"
        )
    }

    func testDocumentMoveCopyAndPermanentDelete() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let folderA = try store.documentLibrary.createFolder(matterID: matter.id, name: "A")
        let folderB = try store.documentLibrary.createFolder(matterID: matter.id, name: "B")
        let blob = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(sha256: "s2", byteSize: 1, originalExtension: "pdf", managedRelativePath: "blobs/s2.pdf")
        ).blob
        let doc = try store.documentLibrary.insertDocument(
            MatterDocumentRecord(matterID: matter.id, blobID: blob.id, folderID: folderA.id, displayName: "doc.pdf")
        )

        try store.documentLibrary.moveDocument(id: doc.id, toFolderID: folderB.id)
        XCTAssertEqual(try store.documentLibrary.fetchDocument(id: doc.id)?.folderID, folderB.id)

        let copy = try store.documentLibrary.copyDocument(id: doc.id, toFolderID: folderA.id)
        XCTAssertNotEqual(copy.id, doc.id)
        XCTAssertEqual(copy.blobID, blob.id)
        XCTAssertEqual(try store.documentLibrary.referenceCount(blobID: blob.id), 2)

        // Deleting one instance keeps the blob (still referenced by the copy).
        let firstDelete = try store.documentLibrary.permanentlyDeleteDocument(id: doc.id)
        XCTAssertTrue(firstDelete.removedBlobPaths.isEmpty)
        XCTAssertNotNil(try store.documentLibrary.fetchBlob(id: blob.id))

        // Deleting the last instance removes the now-unreferenced blob.
        let secondDelete = try store.documentLibrary.permanentlyDeleteDocument(id: copy.id)
        XCTAssertEqual(secondDelete.removedBlobPaths, ["blobs/s2.pdf"])
        XCTAssertNil(try store.documentLibrary.fetchBlob(id: blob.id))
    }

    func testTagsCreateAssignAndFetch() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let blob = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(sha256: "s3", byteSize: 1, originalExtension: "txt", managedRelativePath: "blobs/s3.txt")
        ).blob
        let doc = try store.documentLibrary.insertDocument(
            MatterDocumentRecord(matterID: matter.id, blobID: blob.id, displayName: "note.txt")
        )
        let tag = try store.documentLibrary.createTag(matterID: matter.id, name: "Key Evidence")
        try store.documentLibrary.assignTag(tagID: tag.id, documentID: doc.id)
        try store.documentLibrary.assignTag(tagID: tag.id, documentID: doc.id) // idempotent

        XCTAssertEqual(try store.documentLibrary.fetchTags(documentID: doc.id).count, 1)
        try store.documentLibrary.unassignTag(tagID: tag.id, documentID: doc.id)
        XCTAssertEqual(try store.documentLibrary.fetchTags(documentID: doc.id).count, 0)
    }

    func testChunkReplacementUpdatesFTSAndCascadesEmbeddings() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let blob = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(sha256: "s4", byteSize: 1, originalExtension: "pdf", managedRelativePath: "blobs/s4.pdf")
        ).blob
        let doc = try store.documentLibrary.insertDocument(
            MatterDocumentRecord(matterID: matter.id, blobID: blob.id, displayName: "agreement.pdf")
        )

        let chunk = DocumentChunkRecord(
            documentID: doc.id,
            chunkIndex: 0,
            sourceKind: DocumentSourceKind.pdfPage.rawValue,
            normalizedText: "The indemnification clause survives termination."
        )
        try store.documentIndex.replaceChunks(documentID: doc.id, chunks: [chunk])

        // Embedding attached to that chunk.
        try store.documentIndex.upsertEmbedding(
            DocumentChunkEmbeddingRecord(
                chunkID: chunk.id,
                documentID: doc.id,
                embeddingModelID: "embed-model",
                modelDisplayName: "Test Embedder",
                dimension: 3,
                vector: floatBlob([1, 0, 0])
            )
        )

        let hits = try store.documentIndex.searchChunks(matterID: matter.id, query: "indemnification")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.id, chunk.id)
        XCTAssertEqual(try store.documentIndex.fetchEmbeddings(documentID: doc.id, embeddingModelID: "embed-model").count, 1)

        // Re-chunking replaces chunks, FTS rows, and cascade-deletes embeddings.
        let newChunk = DocumentChunkRecord(
            documentID: doc.id,
            chunkIndex: 0,
            sourceKind: DocumentSourceKind.pdfPage.rawValue,
            normalizedText: "Confidentiality obligations remain in effect."
        )
        try store.documentIndex.replaceChunks(documentID: doc.id, chunks: [newChunk])

        XCTAssertEqual(try store.documentIndex.searchChunks(matterID: matter.id, query: "indemnification").count, 0)
        XCTAssertEqual(try store.documentIndex.searchChunks(matterID: matter.id, query: "confidentiality").count, 1)
        XCTAssertEqual(try store.documentIndex.fetchEmbeddings(documentID: doc.id, embeddingModelID: "embed-model").count, 0)
    }

    func testPermanentDeleteRemovesFTSRows() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let blob = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(sha256: "fts", byteSize: 1, originalExtension: "txt", managedRelativePath: "blobs/fts.txt")
        ).blob
        let doc = try store.documentLibrary.insertDocument(
            MatterDocumentRecord(matterID: matter.id, blobID: blob.id, displayName: "leaky.txt")
        )
        try store.documentIndex.replaceChunks(documentID: doc.id, chunks: [
            DocumentChunkRecord(documentID: doc.id, chunkIndex: 0, sourceKind: DocumentSourceKind.text.rawValue, normalizedText: "unique indemnification term")
        ])
        func ftsRows() throws -> Int {
            try store.database.writer.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM document_chunk_fts WHERE document_id = ?", arguments: [doc.id]) ?? -1
            }
        }
        XCTAssertEqual(try ftsRows(), 1)
        _ = try store.documentLibrary.permanentlyDeleteDocument(id: doc.id)
        XCTAssertEqual(try ftsRows(), 0, "FTS rows must be removed on permanent delete")
    }

    func testPermanentDeleteOfParentPurgesAttachmentSubtreeWithoutLeaks() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        // Parent email + child attachment, each with its own distinct blob.
        let parentBlob = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(sha256: "email", byteSize: 1, originalExtension: "eml", managedRelativePath: "blobs/email.eml")
        ).blob
        let childBlob = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(sha256: "attach", byteSize: 1, originalExtension: "pdf", managedRelativePath: "blobs/attach.pdf")
        ).blob
        let parent = try store.documentLibrary.insertDocument(
            MatterDocumentRecord(matterID: matter.id, blobID: parentBlob.id, displayName: "message.eml")
        )
        let child = try store.documentLibrary.insertDocument(
            MatterDocumentRecord(matterID: matter.id, blobID: childBlob.id, parentDocumentID: parent.id, displayName: "attachment.pdf")
        )
        try store.documentIndex.replaceChunks(documentID: child.id, chunks: [
            DocumentChunkRecord(documentID: child.id, chunkIndex: 0, sourceKind: DocumentSourceKind.pdfPage.rawValue, normalizedText: "attachment body text")
        ])

        func count(_ sql: String, _ args: StatementArguments) throws -> Int {
            try store.database.writer.read { db in try Int.fetchOne(db, sql: sql, arguments: args) ?? -1 }
        }
        XCTAssertEqual(try count("SELECT COUNT(*) FROM document_chunk_fts WHERE document_id = ?", [child.id]), 1)

        let result = try store.documentLibrary.permanentlyDeleteDocument(id: parent.id)

        XCTAssertEqual(try count("SELECT COUNT(*) FROM matter_documents WHERE id = ?", [child.id]), 0, "child attachment row must be purged")
        XCTAssertEqual(try count("SELECT COUNT(*) FROM document_chunk_fts WHERE document_id = ?", [child.id]), 0, "child FTS rows must not leak")
        XCTAssertEqual(try count("SELECT COUNT(*) FROM document_blobs WHERE id = ?", [childBlob.id]), 0, "child blob row must not leak")
        XCTAssertEqual(try count("SELECT COUNT(*) FROM document_blobs WHERE id = ?", [parentBlob.id]), 0, "parent blob row must not leak")
        XCTAssertEqual(Set(result.removedBlobPaths), Set(["blobs/email.eml", "blobs/attach.pdf"]), "both freed blob files must be returned for deletion")
    }

    func testDateFilteredScopeRetainsDocumentsWithNoKnownDate() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let blob = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(sha256: "undated", byteSize: 1, originalExtension: "txt", managedRelativePath: "blobs/undated.txt")
        ).blob
        let undated = try store.documentLibrary.insertDocument(
            MatterDocumentRecord(matterID: matter.id, blobID: blob.id, displayName: "undated.txt", metadataCreatedAt: nil)
        )

        let resolved = try store.documentLibrary.resolveScopeDocumentIDs(
            matterID: matter.id,
            dateStart: Date(timeIntervalSince1970: 1_600_000_000),
            dateEnd: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertTrue(resolved.contains(undated.id), "a document with no extracted date must not be silently dropped by a date filter")
    }

    func testFolderScopeIncludesSubfolderDocuments() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let discovery = try store.documentLibrary.createFolder(matterID: matter.id, name: "Discovery")
        let depositions = try store.documentLibrary.createFolder(matterID: matter.id, name: "Depositions", parentFolderID: discovery.id)
        let other = try store.documentLibrary.createFolder(matterID: matter.id, name: "Pleadings")

        func insert(_ name: String, folderID: String?) throws -> MatterDocumentRecord {
            let blob = try store.documentLibrary.upsertBlob(
                DocumentBlobRecord(sha256: name, byteSize: 1, originalExtension: "txt", managedRelativePath: "blobs/\(name).txt")
            ).blob
            return try store.documentLibrary.insertDocument(
                MatterDocumentRecord(matterID: matter.id, blobID: blob.id, folderID: folderID, displayName: name)
            )
        }
        let inParent = try insert("rfp.txt", folderID: discovery.id)
        let inChild = try insert("calloway-depo.txt", folderID: depositions.id)
        let elsewhere = try insert("answer.txt", folderID: other.id)

        // Scoping to the parent folder covers its subfolders' documents too —
        // with nested folders, "Discovery" must include Discovery/Depositions.
        let resolved = try store.documentLibrary.resolveScopeDocumentIDs(matterID: matter.id, folderIDs: [discovery.id])
        XCTAssertTrue(resolved.contains(inParent.id))
        XCTAssertTrue(resolved.contains(inChild.id), "subfolder documents must be inside the parent folder's scope")
        XCTAssertFalse(resolved.contains(elsewhere.id))
    }

    func testFolderScopeExcludesRestoredDocumentUnderTrashedDescendant() throws {
        // Expected RED: scope expansion currently traverses deleted folders, so
        // a separately restored document under a trashed child leaks into the
        // live parent's legal-retrieval scope.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let discovery = try store.documentLibrary.createFolder(matterID: matter.id, name: "Discovery")
        let depositions = try store.documentLibrary.createFolder(
            matterID: matter.id,
            name: "Depositions",
            parentFolderID: discovery.id
        )
        let blob = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(
                sha256: "restored-hidden-document",
                byteSize: 1,
                originalExtension: "txt",
                managedRelativePath: "blobs/restored-hidden-document.txt"
            )
        ).blob
        let restoredDocument = try store.documentLibrary.insertDocument(
            MatterDocumentRecord(
                matterID: matter.id,
                blobID: blob.id,
                folderID: depositions.id,
                displayName: "restored-deposition.txt"
            )
        )

        try store.documentLibrary.softDeleteFolder(id: depositions.id)
        try store.documentLibrary.restoreDocument(id: restoredDocument.id)

        let liveDocument = try XCTUnwrap(store.documentLibrary.fetchDocument(id: restoredDocument.id))
        XCTAssertNil(liveDocument.deletedAt, "the scoped document must be live for this fixture")
        XCTAssertFalse(
            try store.documentLibrary.fetchFolders(matterID: matter.id).contains { $0.id == depositions.id },
            "the descendant folder must still be in trash for this fixture"
        )
        let resolved = try store.documentLibrary.resolveScopeDocumentIDs(
            matterID: matter.id,
            folderIDs: [discovery.id]
        )
        XCTAssertFalse(
            resolved.contains(restoredDocument.id),
            "a live parent scope must not traverse a descendant folder that remains in trash"
        )
    }

    func testSearchExcludesSoftDeletedDocuments() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let blob = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(sha256: "s5", byteSize: 1, originalExtension: "txt", managedRelativePath: "blobs/s5.txt")
        ).blob
        let doc = try store.documentLibrary.insertDocument(
            MatterDocumentRecord(matterID: matter.id, blobID: blob.id, displayName: "witness.txt")
        )
        try store.documentIndex.replaceChunks(documentID: doc.id, chunks: [
            DocumentChunkRecord(documentID: doc.id, chunkIndex: 0, sourceKind: DocumentSourceKind.text.rawValue, normalizedText: "The deposition mentioned a wire transfer.")
        ])
        XCTAssertEqual(try store.documentIndex.searchChunks(matterID: matter.id, query: "deposition").count, 1)

        try store.documentLibrary.softDeleteDocument(id: doc.id)
        XCTAssertEqual(try store.documentIndex.searchChunks(matterID: matter.id, query: "deposition").count, 0)

        try store.documentLibrary.restoreDocument(id: doc.id)
        XCTAssertEqual(try store.documentIndex.searchChunks(matterID: matter.id, query: "deposition").count, 1)
    }

    func testEmbeddingModelSelectionAndSettings() throws {
        let store = try makeStore()
        _ = try store.documentSettings.loadSettings()

        let modelA = DocumentEmbeddingModelRecord(repoID: "org/embed-a", displayName: "Embed A", dimension: 384, runtimeFamily: "mlx")
        let modelB = DocumentEmbeddingModelRecord(repoID: "org/embed-b", displayName: "Embed B", dimension: 768, runtimeFamily: "mlx")
        try store.documentSettings.upsertEmbeddingModel(modelA)
        try store.documentSettings.upsertEmbeddingModel(modelB)
        try store.documentSettings.selectEmbeddingModel(id: modelB.id)

        XCTAssertEqual(try store.documentSettings.fetchSelectedEmbeddingModel()?.id, modelB.id)
        XCTAssertEqual(try store.documentSettings.loadSettings().selectedEmbeddingModelID, modelB.id)

        try store.documentSettings.updateSettings { $0.setupCompletedAt = Date() }
        XCTAssertNotNil(try store.documentSettings.loadSettings().setupCompletedAt)
        try store.documentSettings.invalidateSetup(reason: "embedding model changed")
        let invalidated = try store.documentSettings.loadSettings()
        XCTAssertNil(invalidated.setupCompletedAt)
        XCTAssertEqual(invalidated.setupInvalidatedReason, "embedding model changed")
    }

    func testJobQueueIsFIFOWithSingleActiveAndResumeReconciliation() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")

        let job1 = try store.documentJobs.enqueueJob(matterID: matter.id)
        let job2 = try store.documentJobs.enqueueJob(matterID: matter.id)
        XCTAssertEqual(job1.queuePosition, 0)
        XCTAssertEqual(job2.queuePosition, 1)

        // First activation promotes job1; second returns the same active job.
        let active = try store.documentJobs.activateNextJobIfIdle()
        XCTAssertEqual(active?.id, job1.id)
        XCTAssertEqual(try store.documentJobs.activateNextJobIfIdle()?.id, job1.id)
        XCTAssertEqual(try store.documentJobs.fetchQueuedJobs().map(\.id), [job2.id])

        // Simulate an interrupted active job at relaunch: it becomes paused.
        let reconciled = try store.documentJobs.reconcileInterruptedJobs()
        XCTAssertEqual(reconciled, [job1.id])
        XCTAssertNil(try store.documentJobs.fetchActiveJob())
        XCTAssertEqual(try store.documentJobs.fetchJob(id: job1.id)?.status, DocumentProcessingJobStatus.paused.rawValue)

        try store.documentJobs.completeJob(id: job1.id)
        XCTAssertEqual(try store.documentJobs.fetchJob(id: job1.id)?.status, DocumentProcessingJobStatus.complete.rawValue)
    }

    func testSourceSetsAttachToOutputVersionsAndExportsPersist() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let blob = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(sha256: "s6", byteSize: 1, originalExtension: "pdf", managedRelativePath: "blobs/s6.pdf")
        ).blob
        let doc = try store.documentLibrary.insertDocument(
            MatterDocumentRecord(matterID: matter.id, blobID: blob.id, displayName: "evidence.pdf")
        )
        let chunk = DocumentChunkRecord(documentID: doc.id, chunkIndex: 0, sourceKind: DocumentSourceKind.pdfPage.rawValue, normalizedText: "Payment due on March 3, 2024.")
        try store.documentIndex.replaceChunks(documentID: doc.id, chunks: [chunk])

        let output = try store.structuredOutputs.createOutput(matterID: matter.id, title: "Q&A: payment date", outputType: .documentQA)
        let version = try store.structuredOutputs.createVersion(
            structuredOutputID: output.id,
            versionIndex: 1,
            contentMarkdown: "Payment was due March 3, 2024 [S1].",
            requiredSections: [],
            presentSections: [],
            missingSections: []
        )

        let sourceSet = try store.documentSources.createSourceSet(matterID: matter.id, mode: .autoSource, retrievalQuery: "payment date")
        try store.documentSources.addOutputSource(
            DocumentOutputSourceRecord(
                sourceSetID: sourceSet.id,
                documentID: doc.id,
                chunkID: chunk.id,
                citationLabel: "S1",
                locatorJSON: #"{"source_kind":"pdf_page","page_index":0}"#,
                excerpt: "Payment due on March 3, 2024.",
                rank: 0
            )
        )
        try store.documentSources.attachSourceSet(id: sourceSet.id, structuredOutputVersionID: version.id)

        let attached = try XCTUnwrap(try store.documentSources.fetchSourceSet(structuredOutputVersionID: version.id))
        XCTAssertEqual(attached.id, sourceSet.id)
        XCTAssertEqual(attached.status, DocumentSourceSetStatus.attached.rawValue)
        let sources = try store.documentSources.fetchSources(structuredOutputVersionID: version.id)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?.citationLabel, "S1")

        let export = try store.documentSources.recordExport(
            DocumentExportRecord(structuredOutputID: output.id, structuredOutputVersionID: version.id, matterID: matter.id, format: "pdf", managedRelativePath: "exports/\(matter.id)/qa.pdf")
        )
        XCTAssertEqual(try store.documentSources.fetchExports(structuredOutputID: output.id).single?.id, export.id)
    }

    func testImportBatchProgressAndFinalReport() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let batch = try store.documentJobs.createBatch(matterID: matter.id, sourceRootDisplay: "Validation Matter")
        try store.documentJobs.updateBatchProgress(id: batch.id, discoveredCount: 10, importedCount: 8, failedCount: 1)
        try store.documentJobs.finalizeBatch(id: batch.id, status: .completeWithFailures, reportJSON: #"{"imported":8,"failed":1}"#)

        let stored = try XCTUnwrap(try store.documentJobs.fetchBatch(id: batch.id))
        XCTAssertEqual(stored.discoveredCount, 10)
        XCTAssertEqual(stored.importedCount, 8)
        XCTAssertEqual(stored.status, DocumentImportBatchStatus.completeWithFailures.rawValue)
        XCTAssertNotNil(stored.completedAt)
        XCTAssertEqual(stored.reportJSON, #"{"imported":8,"failed":1}"#)
    }

    // ACR-EXPORT-012: export metadata and its success audit are one database
    // transaction. If the audit insert fails, no orphan success row survives.
    func testExportCompletionRollsBackExportWhenAuditInsertFails() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Atomic export")
        let output = try store.structuredOutputs.createOutput(
            matterID: matter.id,
            title: "Q&A",
            outputType: .documentQA
        )
        let version = try store.structuredOutputs.createVersion(
            structuredOutputID: output.id,
            versionIndex: 1,
            contentMarkdown: "Answer.",
            requiredSections: [],
            presentSections: [],
            missingSections: []
        )
        let duplicateAuditID = "duplicate-audit"
        _ = try store.auditEvents.recordEvent(
            AuditEventRecord(id: duplicateAuditID, matterID: matter.id, eventType: "existing", actor: "system", summary: "Existing")
        )
        let export = DocumentExportRecord(
            structuredOutputID: output.id,
            structuredOutputVersionID: version.id,
            matterID: matter.id,
            format: "markdown",
            managedRelativePath: "exports/\(matter.id)/qa.md"
        )
        let conflictingAudit = AuditEventRecord(
            id: duplicateAuditID,
            matterID: matter.id,
            eventType: "export_completed",
            actor: "user",
            summary: "Exported Q&A"
        )

        XCTAssertThrowsError(
            try store.documentSources.recordExportCompletion(export, auditEvent: conflictingAudit)
        )
        XCTAssertTrue(try store.documentSources.fetchExports(structuredOutputID: output.id).isEmpty)
    }

    // MARK: - Helpers

    private func floatBlob(_ values: [Float]) -> Data {
        var data = Data(capacity: values.count * 4)
        for value in values {
            var little = value.bitPattern.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func makeStore() throws -> SupraStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SupraStoreM3Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try SupraStore(url: directoryURL.appendingPathComponent("test.sqlite"))
    }
}

private extension Array {
    var single: Element? {
        count == 1 ? first : nil
    }
}
