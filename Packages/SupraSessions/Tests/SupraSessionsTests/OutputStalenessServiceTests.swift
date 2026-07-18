import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

final class OutputStalenessServiceTests: XCTestCase {
    func testTLIN04RevisionTransitionStalesOnlyDependentVersionWithoutMutatingContent() throws {
        // T-LIN-04 expected RED: no OutputStalenessService or version assurance
        // columns exist, so a cited source edit leaves the saved output current.
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Synthetic revision staleness")
        let cited = try seedDocument(store: store, matterID: matter.id, name: "cited.txt")
        let unrelated = try seedDocument(store: store, matterID: matter.id, name: "unrelated.txt")
        let dependent = try seedOutput(
            store: store,
            matterID: matter.id,
            documentID: cited.document.id,
            revisionID: cited.revision.id,
            title: "Dependent output",
            embeddingModelID: "embed-A",
            embeddingRevision: "embed-A-r1",
            chunkerVersion: 1
        )
        let independent = try seedOutput(
            store: store,
            matterID: matter.id,
            documentID: unrelated.document.id,
            revisionID: unrelated.revision.id,
            title: "Independent output",
            embeddingModelID: "embed-B",
            embeddingRevision: "embed-B-r1",
            chunkerVersion: 2
        )
        let before = try XCTUnwrap(store.structuredOutputs.fetchVersion(id: dependent.id))
        let newRevision = try store.documentRevisions.appendRevision(DocumentPartRevisionRecord(
            documentID: cited.document.id,
            partIndex: 0,
            derivationKey: "user-edit-revision-b",
            origin: "user_edit",
            method: "manual",
            text: "REVISION-B-NONDEFAULT",
            charCount: 21,
            supersedesRevisionID: cited.revision.id
        ))

        let service = OutputStalenessService(store: store)
        XCTAssertEqual(try service.sourceRevisionChanged(
            matterID: matter.id,
            documentID: cited.document.id,
            fromRevisionID: cited.revision.id,
            toRevisionID: newRevision.id
        ), 1)

        let after = try XCTUnwrap(store.structuredOutputs.fetchVersion(id: dependent.id))
        let untouched = try XCTUnwrap(store.structuredOutputs.fetchVersion(id: independent.id))
        XCTAssertEqual(after.contentMarkdown, before.contentMarkdown)
        XCTAssertEqual(after.verificationJSON, before.verificationJSON)
        XCTAssertEqual(after.assuranceState, OutputAssuranceState.stale.rawValue)
        XCTAssertTrue(try XCTUnwrap(after.staleReason).contains(cited.document.id))
        XCTAssertTrue(try XCTUnwrap(after.staleReason).contains(cited.revision.id))
        XCTAssertTrue(try XCTUnwrap(after.staleReason).contains(newRevision.id))
        XCTAssertEqual(untouched.assuranceState, OutputAssuranceState.propositionSupported.rawValue)
        XCTAssertNil(untouched.staleReason)

        let firstUpdatedAt = after.updatedAt
        XCTAssertEqual(try service.sourceRevisionChanged(
            matterID: matter.id,
            documentID: cited.document.id,
            fromRevisionID: cited.revision.id,
            toRevisionID: newRevision.id
        ), 0)
        XCTAssertEqual(try store.structuredOutputs.fetchVersion(id: dependent.id)?.updatedAt, firstUpdatedAt)
    }

    func testTLIN05EmbeddingAndChunkerChangesUseExactLineageJoins() throws {
        // T-LIN-05 expected RED: configuration changes cannot target versions by
        // the exact embedding revision or chunker version that produced them.
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Synthetic config staleness")
        let document = try seedDocument(store: store, matterID: matter.id, name: "config.txt")
        let modelA = try seedOutput(
            store: store,
            matterID: matter.id,
            documentID: document.document.id,
            revisionID: document.revision.id,
            title: "Model A output",
            embeddingModelID: "embed-A",
            embeddingRevision: "embed-A-r1",
            chunkerVersion: 1
        )
        let modelB = try seedOutput(
            store: store,
            matterID: matter.id,
            documentID: document.document.id,
            revisionID: document.revision.id,
            title: "Model B output",
            embeddingModelID: "embed-B",
            embeddingRevision: "embed-B-r7",
            chunkerVersion: 2
        )
        let service = OutputStalenessService(store: store)

        XCTAssertEqual(try service.embeddingModelRevisionChanged(
            matterID: matter.id,
            modelID: "embed-A",
            fromRevision: "embed-A-r1",
            toRevision: "embed-A-r2"
        ), 1)
        XCTAssertEqual(
            try store.structuredOutputs.fetchVersion(id: modelA.id)?.assuranceState,
            OutputAssuranceState.stale.rawValue
        )
        XCTAssertEqual(
            try store.structuredOutputs.fetchVersion(id: modelB.id)?.assuranceState,
            OutputAssuranceState.propositionSupported.rawValue
        )

        XCTAssertEqual(try service.chunkerVersionChanged(
            matterID: matter.id,
            fromVersion: 2,
            toVersion: 3
        ), 1)
        XCTAssertEqual(
            try store.structuredOutputs.fetchVersion(id: modelB.id)?.assuranceState,
            OutputAssuranceState.stale.rawValue
        )
        XCTAssertEqual(try service.chunkerVersionChanged(
            matterID: matter.id,
            fromVersion: 2,
            toVersion: 3
        ), 0)
    }

    func testTDIM08StaleAssuranceCannotBeResetAndReverificationAppendsNewVersion() throws {
        // T-DIM-08 expected RED: assurance is not version-persisted and stale has
        // no precedence rule requiring regeneration/reverification to append.
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Synthetic assurance history")
        let document = try seedDocument(store: store, matterID: matter.id, name: "history.txt")
        let old = try seedOutput(
            store: store,
            matterID: matter.id,
            documentID: document.document.id,
            revisionID: document.revision.id,
            title: "Corpus-complete output",
            embeddingModelID: "embed-history",
            embeddingRevision: "embed-history-r1",
            chunkerVersion: 2,
            assuranceState: .corpusComplete
        )
        let service = OutputStalenessService(store: store)
        XCTAssertEqual(try service.promptBuilderVersionChanged(
            matterID: matter.id,
            fromVersion: "document-prompt-v1",
            toVersion: "document-prompt-v2"
        ), 1)
        XCTAssertThrowsError(try store.structuredOutputs.updateAssuranceState(
            versionID: old.id,
            assuranceState: .corpusComplete
        )) { error in
            XCTAssertEqual(
                error as? StructuredOutputRepositoryError,
                .staleVersionRequiresNewVersion(old.id)
            )
        }

        let replacement = try store.structuredOutputs.createVersion(
            structuredOutputID: old.structuredOutputID,
            contentMarkdown: "REVERIFIED-CONTENT-NONDEFAULT",
            requiredSections: [],
            presentSections: [],
            missingSections: [],
            generationSessionID: old.generationSessionID,
            verificationStatus: .allSupported,
            verificationVersion: "support-v2",
            verificationResults: [try supportedResult()],
            promptBuilderVersion: "document-prompt-v2",
            assuranceState: .corpusComplete,
            outputStatus: .complete
        )
        let history = try store.structuredOutputs.fetchVersions(structuredOutputID: old.structuredOutputID)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(try store.structuredOutputs.fetchVersion(id: old.id)?.assuranceState, OutputAssuranceState.stale.rawValue)
        XCTAssertEqual(replacement.assuranceState, OutputAssuranceState.corpusComplete.rawValue)
        XCTAssertNil(replacement.staleReason)
        XCTAssertNotEqual(replacement.id, old.id)
    }

    private func seedDocument(
        store: SupraStore,
        matterID: String,
        name: String
    ) throws -> (document: MatterDocumentRecord, revision: DocumentPartRevisionRecord) {
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            sha256: "sha-\(UUID().uuidString)",
            byteSize: 1,
            originalExtension: "txt",
            managedRelativePath: "blobs/\(UUID().uuidString).txt"
        )).blob
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matterID,
            blobID: blob.id,
            displayName: name
        ))
        try store.documentIndex.replaceParts(documentID: document.id, parts: [
            DocumentPagePartRecord(
                documentID: document.id,
                partIndex: 0,
                sourceKind: "text",
                normalizedText: "REVISION-A-NONDEFAULT",
                charCount: 21
            ),
        ])
        let revision = try store.documentRevisions.appendRevision(DocumentPartRevisionRecord(
            documentID: document.id,
            partIndex: 0,
            derivationKey: "revision-a-\(document.id)",
            origin: "parser",
            method: "synthetic",
            text: "REVISION-A-NONDEFAULT",
            charCount: 21
        ))
        return (document, revision)
    }

    private func seedOutput(
        store: SupraStore,
        matterID: String,
        documentID: String,
        revisionID: String,
        title: String,
        embeddingModelID: String,
        embeddingRevision: String,
        chunkerVersion: Int,
        assuranceState: OutputAssuranceState = .propositionSupported
    ) throws -> StructuredOutputVersionRecord {
        let output = try store.structuredOutputs.createOutput(
            matterID: matterID,
            title: title,
            outputType: .documentQA,
            status: .draft
        )
        let sourceSet = try store.documentSources.createSourceSet(
            matterID: matterID,
            mode: .autoSource,
            scopeJSON: #"{"document_ids":["nondefault"]}"#,
            retrievalQuery: "synthetic dependency query",
            packingReportJSON: #"{"schema_version":1}"#,
            embeddingModelID: embeddingModelID,
            embeddingModelRevision: embeddingRevision,
            chunkerVersion: chunkerVersion,
            retrievalConfigJSON: #"{"rrf_k":67}"#,
            corpusSnapshotHash: "snapshot-nondefault"
        )
        try store.documentSources.addOutputSource(DocumentOutputSourceRecord(
            sourceSetID: sourceSet.id,
            documentID: documentID,
            revisionID: revisionID,
            citationLabel: "S1",
            locatorJSON: #"{"source_kind":"text","char_start":0,"char_end":21}"#,
            excerpt: "REVISION-A-NONDEFAULT",
            rank: 1
        ))
        let generation = try store.generation.createDocumentGenerationSession(
            modelID: "runtime-uuid-nondefault",
            modelRepository: "synthetic/generation-model",
            modelRevision: "generation-revision-nondefault",
            promptBuilderVersion: "document-prompt-v1",
            prompt: "SYNTHETIC-GROUNDED-PROMPT",
            systemPrompt: "SYNTHETIC-GROUNDED-SYSTEM",
            options: GenerationOptions(temperature: 0.31, maxOutputTokens: 513)
        )
        return try store.structuredOutputs.createVersion(
            structuredOutputID: output.id,
            contentMarkdown: "PERSISTED-CONTENT-\(title)",
            requiredSections: [],
            presentSections: [],
            missingSections: [],
            generationSessionID: generation.id,
            verificationStatus: .allSupported,
            verificationVersion: "support-v1",
            verificationResults: [try supportedResult()],
            sourceSetID: sourceSet.id,
            promptBuilderVersion: "document-prompt-v1",
            assuranceState: assuranceState,
            outputStatus: .complete
        )
    }

    private func supportedResult() throws -> PropositionSupportResult {
        try PropositionSupportResult(
            propositionID: "synthetic-proposition",
            status: .supported,
            reasons: ["direct_textual_support"],
            evidence: [
                SupportEvidence(
                    sourceID: "synthetic-source",
                    sourceLabel: "S1",
                    locator: "Synthetic.txt, characters 0-21",
                    retainedExcerpt: "REVISION-A-NONDEFAULT",
                    verifierName: "SyntheticVerifier",
                    verifierVersion: "support-v1"
                ),
            ],
            timestamp: Date(timeIntervalSinceReferenceDate: 67)
        )
    }
}
