import CryptoKit
import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

final class ExhaustiveListTaskTests: XCTestCase {
    func testTENG09ListReconcilesDuplicatesConflictsContraryEvidenceAndNamedOmissions() async throws {
        // T-ENG-09 expected RED: exhaustive-list schema, reconciliation, metrics, and atomic output linkage are missing.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic exhaustive list")
        let fixture = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "invoice-ledger.txt",
            partTexts: ["MAP-A", "MAP-A-DUPLICATE", "MAP-B-ONE", "MAP-B-CONFLICT-X"]
        )

        let result = try await ExhaustiveListTask(store: store).run(
            request: ExhaustiveListRequest(
                runKey: "list-quality-run",
                matterID: matter.id,
                title: "Every invoice reference",
                query: "Extract every invoice reference.",
                characterBudget: 1,
                evaluationExpectedItemKeys: ["invoice-a", "invoice-b", "invoice-c"]
            )
        ) { input in
            let source = try XCTUnwrap(input.partition.sources.first)
            switch source.text {
            case "MAP-A":
                return try Self.response(input, items: [
                    .init(itemKey: "invoice-a", value: "$100", evidence: [.primary]),
                ])
            case "MAP-A-DUPLICATE":
                return try Self.response(input, items: [
                    .init(itemKey: "invoice-a", value: "$100", evidence: [.primary]),
                ])
            case "MAP-B-ONE":
                return try Self.response(input, items: [
                    .init(itemKey: "invoice-b", value: "$200", evidence: [.primary]),
                ])
            default:
                return try Self.response(input, items: [
                    .init(
                        itemKey: "invoice-b",
                        value: "$250",
                        evidence: [.primary],
                        contraryEvidence: [.primary]
                    ),
                    .init(itemKey: "invoice-x", value: "$999", evidence: [.primary]),
                ])
            }
        }

        XCTAssertEqual(Set(result.items.map(\.itemKey)), ["invoice-a", "invoice-b", "invoice-x"])
        let invoiceB = try XCTUnwrap(result.items.first { $0.itemKey == "invoice-b" })
        XCTAssertEqual(Set(invoiceB.values), ["$200", "$250"])
        XCTAssertEqual(invoiceB.contraryEvidence.count, 1)
        XCTAssertEqual(result.omissions.map(\.itemKey), ["invoice-c"])
        XCTAssertEqual(result.metrics.recall, 2.0 / 3.0, accuracy: 0.000_001)
        XCTAssertEqual(result.metrics.precision, 2.0 / 3.0, accuracy: 0.000_001)
        XCTAssertEqual(result.metrics.duplicateCount, 1)
        XCTAssertEqual(result.metrics.conflictCount, 1)
        XCTAssertEqual(result.run.assuranceState, OutputAssuranceState.corpusIncomplete.rawValue)

        let persistedRun = try XCTUnwrap(store.corpusAnalysis.fetchRun(matterID: matter.id, id: result.run.id))
        XCTAssertEqual(persistedRun.structuredOutputVersionID, result.version.id)
        let output = try XCTUnwrap(store.structuredOutputs.fetchOutputs(matterID: matter.id).first)
        XCTAssertEqual(output.id, result.outputID)
        XCTAssertEqual(output.outputType, StructuredOutputType.documentExhaustiveList.rawValue)
        XCTAssertEqual(output.status, StructuredOutputStatus.needsReview.rawValue)
        XCTAssertEqual(output.activeVersionID, result.version.id)
        let sourceSet = try XCTUnwrap(store.documentSources.fetchSourceSet(
            structuredOutputVersionID: result.version.id
        ))
        XCTAssertEqual(sourceSet.status, DocumentSourceSetStatus.attached.rawValue)
        XCTAssertNotNil(sourceSet.embeddingModelID, "T-LIN-01: engine source sets stamp embedding lineage")
        XCTAssertNotNil(sourceSet.embeddingModelRevision)
        XCTAssertNotNil(sourceSet.chunkerVersion)
        XCTAssertNotNil(sourceSet.retrievalConfigJSON)
        XCTAssertNotNil(sourceSet.corpusSnapshotHash)
        XCTAssertNotNil(sourceSet.packingReportJSON)
        let outputSources = try store.documentSources.fetchSources(sourceSetID: sourceSet.id)
        XCTAssertEqual(Set(outputSources.compactMap(\.revisionID)), Set(fixture.revisionIDs))
        XCTAssertTrue(result.version.contentMarkdown.contains("invoice-c"))
        XCTAssertTrue(try XCTUnwrap(persistedRun.reconciliationJSON).contains("invoice-c"))
    }

    func testTENG10FailedPartitionPersistsIncompleteOutputWithNamedDocumentAndReason() async throws {
        // T-ENG-10 expected RED: failed partitions cannot yet produce an attached, explicitly incomplete list output.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic incomplete list")
        _ = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "partial-invoices.txt",
            partTexts: ["MAP-GOOD", "MAP-FAIL"]
        )

        let result = try await ExhaustiveListTask(store: store).run(
            request: ExhaustiveListRequest(
                runKey: "list-incomplete-run",
                matterID: matter.id,
                title: "Incomplete invoice list",
                query: "Extract every invoice.",
                characterBudget: 1,
                evaluationExpectedItemKeys: ["invoice-good", "invoice-missing"]
            )
        ) { input in
            if input.partition.sources.first?.text == "MAP-FAIL" {
                throw CorpusAnalysisMapFailure.permanent("synthetic forced map failure")
            }
            return try Self.response(input, items: [
                .init(itemKey: "invoice-good", value: "$100", evidence: [.primary]),
            ])
        }

        XCTAssertEqual(result.run.status, CorpusAnalysisRunStatus.persisted.rawValue)
        XCTAssertEqual(result.run.assuranceState, OutputAssuranceState.corpusIncomplete.rawValue)
        XCTAssertEqual(result.coverage.failedPartitionCount, 1)
        XCTAssertEqual(result.coverage.pendingPartitionCount, 0)
        XCTAssertEqual(result.omissions.map(\.itemKey), ["invoice-missing"])
        XCTAssertEqual(result.version.verificationStatus, OutputVerificationStatus.needsReview.rawValue)
        XCTAssertTrue(result.version.contentMarkdown.contains("Assurance: corpus_incomplete"))
        XCTAssertFalse(result.version.contentMarkdown.contains("Assurance: corpus_complete"))
        XCTAssertTrue(result.version.contentMarkdown.contains("partial-invoices.txt"))
        XCTAssertTrue(result.version.contentMarkdown.contains("synthetic forced map failure"))
        let output = try XCTUnwrap(store.structuredOutputs.fetchOutputs(matterID: matter.id).first)
        XCTAssertEqual(output.status, StructuredOutputStatus.needsReview.rawValue)
        XCTAssertEqual(
            try store.corpusAnalysis.fetchRun(matterID: matter.id, id: result.run.id)?.structuredOutputVersionID,
            result.version.id
        )
    }

    func testTENG11SchemaInvalidMapFailsPartitionAndPersistsOnlyResponseDigest() async throws {
        // T-ENG-11 expected RED: the typed engine mapper cannot receive or fail closed on malformed raw model output.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic malformed list")
        _ = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "malformed-list.txt",
            partTexts: ["MAP-MALFORMED"]
        )
        let malformed = #"{"schema_version":1,"items":[{"item_key":7,"value":"bad"}]}"#
        let expectedDigest = SHA256.hash(data: Data(malformed.utf8)).map { String(format: "%02x", $0) }.joined()

        let result = try await ExhaustiveListTask(store: store).run(
            request: ExhaustiveListRequest(
                runKey: "list-schema-run",
                matterID: matter.id,
                title: "Malformed list",
                query: "Extract every reference.",
                characterBudget: 1
            )
        ) { _ in malformed }

        let partition = try XCTUnwrap(result.partitions.first)
        XCTAssertEqual(partition.disposition, CorpusAnalysisPartitionDisposition.failed.rawValue)
        XCTAssertEqual(partition.dispositionReason, "schema_invalid")
        XCTAssertTrue(try XCTUnwrap(partition.errorSummary).contains(expectedDigest))
        XCTAssertTrue(partition.attemptHistoryJSON.contains(expectedDigest))
        XCTAssertEqual(result.run.assuranceState, OutputAssuranceState.corpusIncomplete.rawValue)
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertFalse(result.version.contentMarkdown.contains(malformed))
        XCTAssertFalse(try XCTUnwrap(result.run.reconciliationJSON).contains(malformed))
        XCTAssertTrue(result.version.contentMarkdown.contains(expectedDigest))
    }

    func testTENG12NegativeConclusionIsBlockedUnlessCoverageIsCompleteAndNoPositiveExists() async throws {
        // T-ENG-12 expected RED: no negative-conclusion gate maps inadequate coverage to negative_blocked.
        let incompleteStore = try makeStore()
        let incompleteMatter = try incompleteStore.matters.createMatter(name: "Synthetic blocked negative")
        _ = try insertDocument(
            store: incompleteStore,
            matterID: incompleteMatter.id,
            name: "blocked-negative.txt",
            partTexts: ["MAP-FAIL"]
        )
        let incomplete = try await ExhaustiveListTask(store: incompleteStore).run(
            request: ExhaustiveListRequest(
                runKey: "negative-blocked-run",
                matterID: incompleteMatter.id,
                title: "Blocked negative",
                query: "Find any termination reference.",
                characterBudget: 1
            )
        ) { _ in throw CorpusAnalysisMapFailure.permanent("synthetic negative probe failure") }
        let blocked = CorpusNegativeGate.evaluate(
            run: incomplete.run,
            coverage: incomplete.coverage,
            positiveFindingCount: incomplete.items.count
        )
        XCTAssertFalse(blocked.allowed)
        XCTAssertEqual(blocked.assuranceState, .negativeBlocked)
        XCTAssertTrue(blocked.reasons.contains { $0.contains("failed") || $0.contains("incomplete") })

        let completeStore = try makeStore()
        let completeMatter = try completeStore.matters.createMatter(name: "Synthetic allowed negative")
        _ = try insertDocument(
            store: completeStore,
            matterID: completeMatter.id,
            name: "allowed-negative.txt",
            partTexts: ["MAP-NONE"]
        )
        let complete = try await ExhaustiveListTask(store: completeStore).run(
            request: ExhaustiveListRequest(
                runKey: "negative-allowed-run",
                matterID: completeMatter.id,
                title: "Allowed negative",
                query: "Find any termination reference.",
                characterBudget: 1
            )
        ) { input in try Self.response(input, items: []) }
        let allowed = CorpusNegativeGate.evaluate(
            run: complete.run,
            coverage: complete.coverage,
            positiveFindingCount: complete.items.count
        )
        XCTAssertTrue(allowed.allowed)
        XCTAssertEqual(allowed.assuranceState, .corpusComplete)
        XCTAssertTrue(allowed.reasons.isEmpty)
    }

    private func makeStore() throws -> SupraStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExhaustiveListTask-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SupraStore(url: directory.appendingPathComponent("test.sqlite"))
    }

    private func insertDocument(
        store: SupraStore,
        matterID: String,
        name: String,
        partTexts: [String]
    ) throws -> ListFixtureDocument {
        let key = "\(name.replacingOccurrences(of: ".", with: "-"))-\(UUID().uuidString)"
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            sha256: "list-\(key)",
            byteSize: partTexts.reduce(0) { $0 + $1.utf8.count },
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
        let parts = partTexts.enumerated().map { index, text in
            DocumentPagePartRecord(
                id: "\(key)-part-\(index)",
                documentID: document.id,
                partIndex: index,
                sourceKind: DocumentSourceKind.text.rawValue,
                normalizedText: text,
                charCount: text.count
            )
        }
        let revisions = partTexts.enumerated().map { index, text in
            DocumentPartRevisionRecord(
                id: "\(key)-revision-\(index)",
                documentID: document.id,
                partIndex: index,
                derivationKey: "fixture-\(index)",
                origin: "synthetic_test",
                method: "plain-text",
                text: text,
                charCount: text.count
            )
        }
        let selections = revisions.map { revision in
            DocumentPartSelectionRecord(
                id: "\(key)-selection-\(revision.partIndex)",
                documentID: document.id,
                partIndex: revision.partIndex,
                selectedRevisionID: revision.id,
                selectionKey: "fixture-\(revision.partIndex)",
                selectedBy: "test",
                decisionJSON: #"{"rule":"fixture"}"#
            )
        }
        _ = try store.documentRevisions.replacePartsAndPersistLineage(
            documentID: document.id,
            parts: parts,
            revisions: revisions,
            selections: selections
        )
        return ListFixtureDocument(documentID: document.id, revisionIDs: revisions.map(\.id))
    }

    private static func response(
        _ input: ExhaustiveListGenerationInput,
        items: [SyntheticListItem]
    ) throws -> String {
        let source = try XCTUnwrap(input.partition.sources.first)
        let evidence = CorpusAnalysisEvidenceReference(
            documentID: source.documentID,
            revisionID: source.revisionID,
            locatorJSON: source.locatorJSON
        )
        let payload = SyntheticListResponse(items: items.map { item in
            SyntheticListMapItem(
                itemKey: item.itemKey,
                value: item.value,
                evidence: item.evidence.map { _ in evidence },
                contraryEvidence: item.contraryEvidence.map { _ in evidence }
            )
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }
}

private struct ListFixtureDocument {
    var documentID: String
    var revisionIDs: [String]
}

private enum SyntheticEvidenceToken {
    case primary
}

private struct SyntheticListItem {
    var itemKey: String
    var value: String
    var evidence: [SyntheticEvidenceToken]
    var contraryEvidence: [SyntheticEvidenceToken] = []
}

private struct SyntheticListResponse: Encodable {
    var schemaVersion = 1
    var items: [SyntheticListMapItem]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case items
    }
}

private struct SyntheticListMapItem: Encodable {
    var itemKey: String
    var value: String
    var evidence: [CorpusAnalysisEvidenceReference]
    var contraryEvidence: [CorpusAnalysisEvidenceReference]

    private enum CodingKeys: String, CodingKey {
        case itemKey = "item_key"
        case value
        case evidence
        case contraryEvidence = "contrary_evidence"
    }
}
