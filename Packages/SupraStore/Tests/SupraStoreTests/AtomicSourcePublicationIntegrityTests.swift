import Foundation
import SupraCore
@testable import SupraStore
import XCTest

final class AtomicSourcePublicationIntegrityTests: XCTestCase {
    func testTSTORE03AtomicPublisherRejectsCrossMatterDocumentLikeOrdinarySourceWrite() throws {
        // T-STORE-03 expected RED: the ordinary source path rejects this
        // cross-matter document, but the atomic publisher inserts it directly.
        let fixture = try makeFixture(caseName: "cross-matter")
        let invalid = DocumentOutputSourceRecord(
            id: "t-store-03-cross-matter-source",
            sourceSetID: "replaced-by-test",
            documentID: fixture.otherMatterDocument.id,
            chunkID: fixture.otherMatterChunk.id,
            revisionID: fixture.otherMatterRevision.id,
            citationLabel: "S97",
            locatorJSON: #"{"source_kind":"text","part_index":19,"char_start":137,"char_end":311}"#,
            excerpt: "Synthetic cross-matter value 97 must not be published.",
            rank: 17,
            warningsJSON: #"["synthetic_cross_matter_probe"]"#,
            createdAt: Date(timeIntervalSince1970: 1_790_003_097)
        )

        try assertAtomicPublisherRejects(
            invalid,
            expectedError: .sourceMatterMismatch(fixture.otherMatterDocument.id),
            caseName: "cross-matter",
            fixture: fixture
        )
    }

    func testTSTORE03AtomicPublisherRejectsWrongRevisionLikeOrdinarySourceWrite() throws {
        // T-STORE-03 expected RED: the ordinary source path rejects a revision
        // owned by another document, while the atomic publisher bypasses that
        // revision/document integrity check.
        let fixture = try makeFixture(caseName: "wrong-revision")
        let invalid = DocumentOutputSourceRecord(
            id: "t-store-03-wrong-revision-source",
            sourceSetID: "replaced-by-test",
            documentID: fixture.primaryDocument.id,
            chunkID: fixture.primaryChunk.id,
            revisionID: fixture.siblingRevision.id,
            citationLabel: "S83",
            locatorJSON: #"{"source_kind":"text","part_index":11,"char_start":83,"char_end":197}"#,
            excerpt: "Synthetic wrong-revision value 83 must not be published.",
            rank: 23,
            warningsJSON: #"["synthetic_revision_scope_probe"]"#,
            createdAt: Date(timeIntervalSince1970: 1_790_003_083)
        )

        try assertAtomicPublisherRejects(
            invalid,
            expectedError: .revisionScopeMismatch(fixture.siblingRevision.id),
            caseName: "wrong-revision",
            fixture: fixture
        )
    }

    func testTSTORE03AtomicPublisherRejectsWrongChunkLikeOrdinarySourceWrite() throws {
        // T-STORE-03 expected RED: the ordinary source path rejects a chunk
        // owned by another document, while the atomic publisher bypasses that
        // chunk/document integrity check.
        let fixture = try makeFixture(caseName: "wrong-chunk")
        let invalid = DocumentOutputSourceRecord(
            id: "t-store-03-wrong-chunk-source",
            sourceSetID: "replaced-by-test",
            documentID: fixture.primaryDocument.id,
            chunkID: fixture.siblingChunk.id,
            revisionID: fixture.primaryRevision.id,
            citationLabel: "S71",
            locatorJSON: #"{"source_kind":"text","part_index":7,"char_start":71,"char_end":173}"#,
            excerpt: "Synthetic wrong-chunk value 71 must not be published.",
            rank: 29,
            warningsJSON: #"["synthetic_chunk_scope_probe"]"#,
            createdAt: Date(timeIntervalSince1970: 1_790_003_071)
        )

        try assertAtomicPublisherRejects(
            invalid,
            expectedError: .chunkScopeMismatch(fixture.siblingChunk.id),
            caseName: "wrong-chunk",
            fixture: fixture
        )
    }

    private func assertAtomicPublisherRejects(
        _ invalidSource: DocumentOutputSourceRecord,
        expectedError: DocumentSourceRepositoryError,
        caseName: String,
        fixture: PublicationFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let ordinarySet = try fixture.store.documentSources.createSourceSet(
            matterID: fixture.outputMatter.id,
            mode: .guided,
            scopeJSON: #"{"document_ids":["ordinary-integrity-probe"],"schema_version":7}"#,
            retrievalQuery: "ordinary source validator \(caseName) 97",
            retrievalDepth: "deep"
        )
        var ordinarySource = invalidSource
        ordinarySource.id = "ordinary-\(caseName)-source"
        ordinarySource.sourceSetID = ordinarySet.id
        XCTAssertThrowsError(
            try fixture.store.documentSources.addOutputSource(ordinarySource),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? DocumentSourceRepositoryError, expectedError, file: file, line: line)
        }
        XCTAssertTrue(
            try fixture.store.documentSources.fetchSources(sourceSetID: ordinarySet.id).isEmpty,
            "the ordinary validator must remain the reference fail-closed behavior",
            file: file,
            line: line
        )

        let outputID = "t-store-03-output-\(caseName)"
        let sourceSetID = "t-store-03-source-set-\(caseName)"
        let atomicSet = DocumentSourceSetRecord(
            id: sourceSetID,
            matterID: fixture.outputMatter.id,
            status: DocumentSourceSetStatus.pending.rawValue,
            mode: DocumentSourceSetMode.guided.rawValue,
            scopeJSON: #"{"document_ids":["atomic-integrity-probe"],"schema_version":7}"#,
            retrievalQuery: "atomic source validator \(caseName) 97",
            retrievalDepth: "deep",
            packingReportJSON: #"{"packed_source_count":1,"probe":97}"#,
            embeddingModelID: "synthetic/embed-97",
            embeddingModelRevision: "revision-atomic-7",
            chunkerVersion: 7,
            retrievalConfigJSON: #"{"rrf_k":83,"candidate_limit":97}"#,
            corpusSnapshotHash: String(repeating: "9", count: 64),
            createdAt: Date(timeIntervalSince1970: 1_790_003_097)
        )
        var atomicSource = invalidSource
        atomicSource.sourceSetID = sourceSetID
        let newOutput = StructuredOutputRecord(
            id: outputID,
            matterID: fixture.outputMatter.id,
            title: "Atomic source integrity \(caseName) 97",
            outputType: StructuredOutputType.documentQA.rawValue,
            status: StructuredOutputStatus.draft.rawValue,
            createdAt: Date(timeIntervalSince1970: 1_790_003_097),
            updatedAt: Date(timeIntervalSince1970: 1_790_003_097)
        )

        XCTAssertThrowsError(
            try fixture.store.structuredOutputs.createVersionWithSourceSetAtomically(
                structuredOutputID: outputID,
                newOutput: newOutput,
                sourceSet: atomicSet,
                outputSources: [atomicSource],
                contentMarkdown: "Synthetic publication \(caseName) value 97 [\(atomicSource.citationLabel)].",
                verificationStatus: .allSupported,
                verificationVersion: "atomic-source-integrity/7",
                verificationResults: [try supportedResult(for: atomicSource)],
                verificationDimensions: supportedDimensions(),
                outputStatus: .complete,
                promptBuilderVersion: "case-file-review-prompt/7",
                assuranceState: .propositionSupported
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? DocumentSourceRepositoryError,
                expectedError,
                "the atomic and ordinary source paths must return the same scoped integrity error",
                file: file,
                line: line
            )
        }

        XCTAssertNil(
            try fixture.store.structuredOutputs.fetchOutputs(matterID: fixture.outputMatter.id)
                .first { $0.id == outputID },
            "invalid provenance must roll back the new output",
            file: file,
            line: line
        )
        XCTAssertTrue(
            try fixture.store.structuredOutputs.fetchVersions(structuredOutputID: outputID).isEmpty,
            "invalid provenance must not leave an assurance-bearing version",
            file: file,
            line: line
        )
        XCTAssertNil(
            try fixture.store.documentSources.fetchSourceSet(id: sourceSetID),
            "invalid provenance must roll back the atomic source set",
            file: file,
            line: line
        )
        XCTAssertNil(
            try fixture.store.documentSources.fetchSource(id: atomicSource.id),
            "invalid provenance must roll back the atomic source row",
            file: file,
            line: line
        )
    }

    private func makeFixture(caseName: String) throws -> PublicationFixture {
        let store = try SupraStore.inMemory()
        let outputMatter = try store.matters.createMatter(
            name: "Synthetic output matter \(caseName)",
            jurisdiction: "Georgia",
            partyPerspective: .defendant
        )
        let otherMatter = try store.matters.createMatter(
            name: "Synthetic foreign matter \(caseName)",
            jurisdiction: "Oregon",
            partyPerspective: .plaintiff
        )
        let primary = try makeDocument(
            store: store,
            matterID: outputMatter.id,
            stem: "\(caseName)-primary",
            partIndex: 7,
            charStart: 71,
            charEnd: 173
        )
        let sibling = try makeDocument(
            store: store,
            matterID: outputMatter.id,
            stem: "\(caseName)-sibling",
            partIndex: 11,
            charStart: 83,
            charEnd: 197
        )
        let foreign = try makeDocument(
            store: store,
            matterID: otherMatter.id,
            stem: "\(caseName)-foreign",
            partIndex: 19,
            charStart: 137,
            charEnd: 311
        )
        return PublicationFixture(
            store: store,
            outputMatter: outputMatter,
            otherMatterDocument: foreign.document,
            otherMatterRevision: foreign.revision,
            otherMatterChunk: foreign.chunk,
            primaryDocument: primary.document,
            primaryRevision: primary.revision,
            primaryChunk: primary.chunk,
            siblingRevision: sibling.revision,
            siblingChunk: sibling.chunk
        )
    }

    private func makeDocument(
        store: SupraStore,
        matterID: String,
        stem: String,
        partIndex: Int,
        charStart: Int,
        charEnd: Int
    ) throws -> (
        document: MatterDocumentRecord,
        revision: DocumentPartRevisionRecord,
        chunk: DocumentChunkRecord
    ) {
        let text = "Synthetic exact evidence \(stem) value \(partIndex) with a distinct retained range."
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            id: "blob-\(stem)",
            sha256: String(repeating: String((partIndex % 9) + 1), count: 64),
            byteSize: 8_191 + partIndex,
            originalExtension: "txt",
            managedRelativePath: "blobs/\(stem).txt",
            mimeType: "text/plain",
            integrityStatus: DocumentBlobIntegrityStatus.verified.rawValue,
            verifiedAt: Date(timeIntervalSince1970: 1_790_001_000 + Double(partIndex))
        )).blob
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            id: "document-\(stem)",
            matterID: matterID,
            blobID: blob.id,
            displayName: "Synthetic-\(stem).txt",
            status: MatterDocumentStatus.ready.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue,
            indexStatus: DocumentIndexStatus.textIndexed.rawValue,
            sourceKind: DocumentSourceKind.text.rawValue,
            extractedTextChecksum: "checksum-\(stem)-97",
            pagePartCount: 1,
            importedAt: Date(timeIntervalSince1970: 1_790_001_000 + Double(partIndex))
        ))
        let revision = try store.documentRevisions.appendRevision(DocumentPartRevisionRecord(
            id: "revision-\(stem)",
            documentID: document.id,
            partIndex: partIndex,
            derivationKey: "derivation-\(stem)-7",
            origin: "parser",
            method: "synthetic_exact_text",
            text: text,
            charCount: 997 + partIndex,
            toolchainVersion: "synthetic-parser/7",
            reason: "T-STORE-03 exact source scope probe",
            createdAt: Date(timeIntervalSince1970: 1_790_002_000 + Double(partIndex))
        ))
        let chunk = DocumentChunkRecord(
            id: "chunk-\(stem)",
            documentID: document.id,
            revisionID: revision.id,
            chunkerVersion: 7,
            chunkIndex: partIndex,
            sourceKind: DocumentSourceKind.text.rawValue,
            charStart: charStart,
            charEnd: charEnd,
            normalizedText: text,
            displayExcerpt: text,
            tokenCount: 47 + partIndex,
            createdAt: Date(timeIntervalSince1970: 1_790_002_100 + Double(partIndex)),
            updatedAt: Date(timeIntervalSince1970: 1_790_002_100 + Double(partIndex))
        )
        try store.documentIndex.replaceChunks(documentID: document.id, chunks: [chunk])
        return (document, revision, chunk)
    }

    private func supportedResult(
        for source: DocumentOutputSourceRecord
    ) throws -> PropositionSupportResult {
        try PropositionSupportResult(
            propositionID: "atomic-proposition-\(source.citationLabel)",
            status: .supported,
            reasons: ["synthetic_atomic_source_probe"],
            evidence: [SupportEvidence(
                sourceID: source.id,
                sourceLabel: source.citationLabel,
                locator: "Synthetic locator \(source.locatorJSON)",
                retainedExcerpt: source.excerpt,
                verifierName: "AtomicSourceIntegrityVerifier",
                verifierVersion: "atomic-source-integrity/7"
            )],
            timestamp: Date(timeIntervalSince1970: 1_790_003_097)
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

private struct PublicationFixture {
    let store: SupraStore
    let outputMatter: MatterRecord
    let otherMatterDocument: MatterDocumentRecord
    let otherMatterRevision: DocumentPartRevisionRecord
    let otherMatterChunk: DocumentChunkRecord
    let primaryDocument: MatterDocumentRecord
    let primaryRevision: DocumentPartRevisionRecord
    let primaryChunk: DocumentChunkRecord
    let siblingRevision: DocumentPartRevisionRecord
    let siblingChunk: DocumentChunkRecord
}
