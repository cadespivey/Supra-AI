import Foundation
import SupraCore
@testable import SupraSessions
import SupraStore
import XCTest

@MainActor
final class DocumentClassificationV2Tests: XCTestCase {
    func testTCLS01TailSamplingCarriesLateCategorySentinelIntoClassification() async throws {
        // T-CLS-01 expected RED: classification still truncates to the first
        // 12,000 characters and exposes no structural sample provenance.
        let prefix = String(repeating: "P", count: 13_900)
        let sentinel = "TAIL_SENTINEL_FINANCIAL_RECORDS"
        let text = prefix + sentinel + String(repeating: "T", count: 1_900)
        let seeded = try seedDocument(text: text, name: "tail-sentinel.txt")
        let legacyPrefix = String(text.prefix(12_000))
        XCTAssertFalse(legacyPrefix.contains(sentinel))

        let runtime = StubRuntimeClient { request in
            let category = request.prompt.contains(sentinel)
                ? "financial_records"
                : "correspondence"
            let start = prefix.count
            let json = """
            {"primary_tag":"\(category)","confidence":0.94,
             "evidence_spans":[{"revision_id":"\(seeded.revision.id)","char_start":\(start),"char_end":\(start + sentinel.count),"excerpt":"\(sentinel)"}]}
            """
            return .events([
                .event(request, 1, .generationStarted),
                .event(request, 2, .token, token: json),
                .event(request, 3, .generationCompleted),
            ])
        }
        let service = makeService(store: seeded.store, runtime: runtime)
        let classifiedTail = await service.classifyDocument(
            seeded.document,
            modelID: ModelID(),
            modelLineage: Self.modelLineage,
            classificationKey: "tail-wire-attempt"
        )
        XCTAssertTrue(classifiedTail)

        let row = try XCTUnwrap(seeded.store.documentClassifications.fetchLatest(
            matterID: seeded.matter.id,
            documentID: seeded.document.id
        ))
        XCTAssertEqual(row.primaryCategory, DocumentCategory.financialRecords.rawValue)
        let samples = DocumentClassificationSampler.samples(
            revisions: [seeded.revision],
            characterBudget: 12_000
        )
        let tail = try XCTUnwrap(samples.first { $0.reason == "part_tail" })
        XCTAssertTrue(tail.text.contains(sentinel))
        XCTAssertEqual(tail.revisionID, seeded.revision.id)
        XCTAssertLessThanOrEqual(samples.reduce(0) { $0 + $1.text.count }, 12_000)
    }

    func testTCLS01SamplerIncludesRangeBoundHeadingWithinBudget() throws {
        let heading = "NONDEFAULT CLASSIFICATION HEADING"
        let headingStart = 420
        let text = String(repeating: "p", count: headingStart)
            + heading
            + String(repeating: "t", count: 600)
        let seeded = try seedDocument(text: text, name: "heading-sample.txt")
        let node = DocumentStructureNodeRecord(
            documentID: seeded.document.id,
            revisionID: seeded.revision.id,
            nodeKey: "heading/nondefault",
            ordinal: 17,
            kind: "heading",
            charStart: headingStart,
            charEnd: headingStart + heading.count
        )

        let samples = DocumentClassificationSampler.samples(
            revisions: [seeded.revision],
            structureNodes: [node],
            characterBudget: 180
        )
        let headingSample = try XCTUnwrap(samples.first { $0.reason == "heading" })
        XCTAssertEqual(headingSample.text, heading)
        XCTAssertEqual(headingSample.revisionID, seeded.revision.id)
        XCTAssertEqual(headingSample.charStart, headingStart)
        XCTAssertLessThanOrEqual(samples.reduce(0) { $0 + $1.text.count }, 180)
    }

    func testTCLS02And03RowsAppendCompleteLineageAndResolveExactRepeatedEvidenceSpan() async throws {
        // T-CLS-02/T-CLS-03 expected RED: no versioned classification rows,
        // input checksums, stable model lineage, or revision-bound evidence exist.
        let phrase = "REPEATED-EVIDENCE"
        let unique = "UNIQUE-EVIDENCE"
        let text = "\(unique). \(phrase) first occurrence. " + String(repeating: "x", count: 80) + " \(phrase) SECOND occurrence."
        let secondStart = text.range(of: phrase, options: .backwards).map {
            text.distance(from: text.startIndex, to: $0.lowerBound)
        }!
        let seeded = try seedDocument(text: text, name: "repeated-evidence.txt")
        let response = """
        {"primary_tag":"evidence_and_exhibits","secondary_tags":["investigation_and_facts"],"confidence":0.88,
         "evidence_spans":[
           {"revision_id":"\(seeded.revision.id)","char_start":0,"char_end":\(unique.count),"excerpt":"\(unique)"},
           {"revision_id":"\(seeded.revision.id)","char_start":\(secondStart),"char_end":\(secondStart + phrase.count),"excerpt":"\(phrase)"}],
         "warnings":["NONDEFAULT-CLASSIFICATION-WARNING"]}
        """
        let runtime = scriptedRuntime(response)
        let service = makeService(store: seeded.store, runtime: runtime)
        let classifiedFirst = await service.classifyDocument(
            seeded.document,
            modelID: ModelID(),
            modelLineage: Self.modelLineage,
            classificationKey: "classification-attempt-A"
        )
        XCTAssertTrue(classifiedFirst)
        let classifiedSecond = await service.classifyDocument(
            try XCTUnwrap(seeded.store.documentLibrary.fetchDocument(id: seeded.document.id)),
            modelID: ModelID(),
            modelLineage: .init(
                modelRepository: "synthetic/classifier-B",
                modelRevision: "classifier-B-revision-9"
            ),
            classificationKey: "classification-attempt-B"
        )
        XCTAssertTrue(classifiedSecond)

        let history = try seeded.store.documentClassifications.fetchHistory(
            matterID: seeded.matter.id,
            documentID: seeded.document.id
        )
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.map(\.classificationKey), ["classification-attempt-A", "classification-attempt-B"])
        XCTAssertEqual(history[0].modelRepository, Self.modelLineage.modelRepository)
        XCTAssertEqual(history[0].modelRevision, Self.modelLineage.modelRevision)
        XCTAssertEqual(history[0].promptVersion, DocumentClassificationService.promptVersion)
        XCTAssertEqual(history[0].samplingStrategy, DocumentClassificationSampler.strategy)
        XCTAssertEqual(history[0].samplingVersion, DocumentClassificationSampler.version)
        XCTAssertEqual(history[0].calibrationVersion, DocumentClassificationService.calibrationVersion)
        XCTAssertEqual(history[0].inputChecksum.count, 64)
        XCTAssertEqual(try decode([String].self, from: history[0].inputRevisionIDsJSON), [seeded.revision.id])
        XCTAssertEqual(history[0].primaryCategory, DocumentCategory.evidenceAndExhibits.rawValue)
        XCTAssertEqual(try decode([String].self, from: history[0].secondaryCategoriesJSON), [DocumentCategory.investigationAndFacts.rawValue])
        XCTAssertEqual(try decode([String].self, from: history[0].warningsJSON), ["NONDEFAULT-CLASSIFICATION-WARNING"])
        let confidence = try decode(DocumentClassificationConfidence.self, from: history[0].confidenceJSON)
        XCTAssertEqual(confidence.rawConfidence, 0.88, accuracy: 0.0001)
        XCTAssertEqual(confidence.abstentionFloor, 0.5, accuracy: 0.0001)
        XCTAssertEqual(confidence.rawSuggestedPrimaryCategory, DocumentCategory.evidenceAndExhibits.rawValue)

        let spans = try decode(
            [DocumentClassificationEvidenceSpan].self,
            from: history[0].evidenceSpansJSON
        )
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].excerpt, unique)
        XCTAssertEqual(spans[0].charStart, 0)
        for evidence in spans {
            let start = text.index(text.startIndex, offsetBy: evidence.charStart)
            let end = text.index(text.startIndex, offsetBy: evidence.charEnd)
            XCTAssertEqual(String(text[start..<end]), evidence.excerpt)
        }
        let span = spans[1]
        XCTAssertEqual(span.revisionID, seeded.revision.id)
        XCTAssertEqual(span.charStart, secondStart)
        XCTAssertEqual(span.charEnd, secondStart + phrase.count)
        XCTAssertEqual(span.excerpt, phrase)
        XCTAssertNotEqual(span.charStart, 0, "the repeated phrase must bind the planted second occurrence")
        XCTAssertEqual(history[0].inputChecksum, history[1].inputChecksum)
        XCTAssertNotEqual(history[0].id, history[1].id)
    }

    func testTCLS04LowConfidencePersistsExplicitAbstentionWithoutPrimaryCategory() async throws {
        // T-CLS-04 expected RED: sub-floor output is currently stored as a normal
        // primary category and there is no calibrated abstention record.
        let text = "LOW-CONFIDENCE-EVIDENCE appears in this synthetic document."
        let seeded = try seedDocument(text: text, name: "low-confidence.txt")
        let evidence = "LOW-CONFIDENCE-EVIDENCE"
        let response = """
        {"primary_tag":"contracts_and_agreements","confidence":0.42,
         "evidence_spans":[{"revision_id":"\(seeded.revision.id)","char_start":0,"char_end":\(evidence.count),"excerpt":"\(evidence)"}]}
        """
        let service = makeService(
            store: seeded.store,
            runtime: scriptedRuntime(response),
            abstentionFloor: 0.71
        )
        let classifiedLowConfidence = await service.classifyDocument(
            seeded.document,
            modelID: ModelID(),
            modelLineage: Self.modelLineage,
            classificationKey: "low-confidence-attempt"
        )
        XCTAssertTrue(classifiedLowConfidence)

        let row = try XCTUnwrap(seeded.store.documentClassifications.fetchLatest(
            matterID: seeded.matter.id,
            documentID: seeded.document.id
        ))
        XCTAssertTrue(row.abstained)
        XCTAssertNil(row.primaryCategory)
        XCTAssertTrue(try XCTUnwrap(row.abstentionReason).contains("0.71"))
        let confidence = try decode(
            DocumentClassificationConfidence.self,
            from: row.confidenceJSON
        )
        XCTAssertEqual(confidence.rawConfidence, 0.42, accuracy: 0.0001)
        XCTAssertEqual(confidence.abstentionFloor, 0.71, accuracy: 0.0001)
        XCTAssertEqual(confidence.rawSuggestedPrimaryCategory, DocumentCategory.contractsAndAgreements.rawValue)
        let legacy = try JSONDecoder().decode(
            DocumentClassification.self,
            from: Data(try XCTUnwrap(
                seeded.store.documentLibrary.fetchDocument(id: seeded.document.id)?.classificationMetadataJSON
            ).utf8)
        )
        XCTAssertTrue(legacy.abstained)
        XCTAssertEqual(legacy.primaryTag, "")
        XCTAssertNil(DocumentRetrievalService.contextMetadata(
            for: try XCTUnwrap(seeded.store.documentLibrary.fetchDocument(id: seeded.document.id))
        ))
    }

    func testTCLS03InvalidEvidenceSpanPersistsAbstentionWithoutInvalidLocator() async throws {
        // T-CLS-03 adversarial wire-proof: the category suggestion is strong, but
        // the claimed excerpt does not match the exact revision range.
        let text = "EXACT-VALID-EVIDENCE appears in this synthetic financial record."
        let seeded = try seedDocument(text: text, name: "invalid-evidence.txt")
        let response = """
        {"primary_tag":"financial_records","confidence":0.97,
         "evidence_spans":[{"revision_id":"\(seeded.revision.id)","char_start":0,"char_end":20,"excerpt":"DIFFERENT-FAKE-TEXT"}]}
        """
        let service = makeService(store: seeded.store, runtime: scriptedRuntime(response))
        let classified = await service.classifyDocument(
            seeded.document,
            modelID: ModelID(),
            modelLineage: Self.modelLineage,
            classificationKey: "invalid-evidence-attempt"
        )
        XCTAssertTrue(classified, "a calibrated safety abstention is a completed classifier attempt")

        let row = try XCTUnwrap(seeded.store.documentClassifications.fetchLatest(
            matterID: seeded.matter.id,
            documentID: seeded.document.id
        ))
        XCTAssertTrue(row.abstained)
        XCTAssertNil(row.primaryCategory)
        XCTAssertEqual(try decode([DocumentClassificationEvidenceSpan].self, from: row.evidenceSpansJSON), [])
        XCTAssertTrue(try XCTUnwrap(row.abstentionReason).contains("exact revision-bound evidence"))
    }

    func testTCLS05ClassificationNeverMutatesUserTags() async throws {
        // T-CLS-05 standing guard: classifier suggestions and user-created tags
        // are separate domains; classify/reclassify/abstain must never auto-tag.
        let text = "TAG-GUARD-EVIDENCE for a synthetic correspondence document."
        let seeded = try seedDocument(text: text, name: "tag-guard.txt")
        let tag = try seeded.store.documentLibrary.createTag(
            matterID: seeded.matter.id,
            name: "User-only tag",
            color: "#123456"
        )
        try seeded.store.documentLibrary.assignTag(tagID: tag.id, documentID: seeded.document.id)
        let response = """
        {"primary_tag":"correspondence","confidence":0.93,
         "evidence_spans":[{"revision_id":"\(seeded.revision.id)","char_start":0,"char_end":18,"excerpt":"TAG-GUARD-EVIDENCE"}]}
        """
        let service = makeService(store: seeded.store, runtime: scriptedRuntime(response))
        let classifiedClean = await service.classifyDocument(
            seeded.document,
            modelID: ModelID(),
            modelLineage: Self.modelLineage,
            classificationKey: "tag-guard-clean"
        )
        XCTAssertTrue(classifiedClean)
        XCTAssertEqual(try seeded.store.documentLibrary.fetchTags(documentID: seeded.document.id).map(\.id), [tag.id])

        let abstaining = makeService(
            store: seeded.store,
            runtime: scriptedRuntime(response.replacingOccurrences(of: "0.93", with: "0.31")),
            abstentionFloor: 0.67
        )
        let classifiedAbstention = await abstaining.classifyDocument(
            try XCTUnwrap(seeded.store.documentLibrary.fetchDocument(id: seeded.document.id)),
            modelID: ModelID(),
            modelLineage: Self.modelLineage,
            classificationKey: "tag-guard-abstain"
        )
        XCTAssertTrue(classifiedAbstention)
        let tags = try seeded.store.documentLibrary.fetchTags(documentID: seeded.document.id)
        XCTAssertEqual(tags.map(\.id), [tag.id])
        XCTAssertEqual(tags.map(\.name), ["User-only tag"])
        XCTAssertEqual(tags.map(\.color), ["#123456"])
    }

    private struct SeededDocument {
        var store: SupraStore
        var matter: MatterRecord
        var document: MatterDocumentRecord
        var revision: DocumentPartRevisionRecord
    }

    private func seedDocument(text: String, name: String) throws -> SeededDocument {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Synthetic classification v2")
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            sha256: "classification-\(UUID().uuidString)",
            byteSize: text.utf8.count,
            originalExtension: "txt",
            managedRelativePath: "classification/\(UUID().uuidString).txt"
        )).blob
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matter.id,
            blobID: blob.id,
            displayName: name,
            status: MatterDocumentStatus.ready.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue
        ))
        try store.documentIndex.replaceParts(documentID: document.id, parts: [
            DocumentPagePartRecord(
                documentID: document.id,
                partIndex: 0,
                sourceKind: "text",
                normalizedText: text,
                charCount: text.count
            ),
        ])
        let revision = try store.documentRevisions.appendRevision(DocumentPartRevisionRecord(
            documentID: document.id,
            partIndex: 0,
            derivationKey: "classification-\(document.id)",
            origin: "parser",
            method: "synthetic",
            text: text,
            charCount: text.count
        ))
        try store.documentIndex.replaceParts(documentID: document.id, parts: [
            DocumentPagePartRecord(
                documentID: document.id,
                partIndex: 0,
                sourceKind: "text",
                normalizedText: text,
                charCount: text.count,
                currentRevisionID: revision.id
            ),
        ])
        return SeededDocument(store: store, matter: matter, document: document, revision: revision)
    }

    private func makeService(
        store: SupraStore,
        runtime: StubRuntimeClient,
        abstentionFloor: Double = 0.5
    ) -> DocumentClassificationService {
        DocumentClassificationService(
            store: store,
            modelLibrary: ModelLibrary(store: store, runtimeClient: runtime),
            runtimeClient: runtime,
            abstentionFloor: abstentionFloor
        )
    }

    private func scriptedRuntime(_ response: String) -> StubRuntimeClient {
        StubRuntimeClient { request in
            .events([
                .event(request, 1, .generationStarted),
                .event(request, 2, .token, token: response),
                .event(request, 3, .generationCompleted),
            ])
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private static let modelLineage = DocumentGenerationModelLineage(
        modelRepository: "synthetic/classifier-A",
        modelRevision: "classifier-A-revision-7"
    )
}
