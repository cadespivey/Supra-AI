import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

final class CorpusAnalysisEngineTests: XCTestCase {
    func testTENG01FrozenSnapshotIgnoresMidRunEditAndMarksResultStale() async throws {
        // T-ENG-01 expected RED: no frozen corpus snapshot or stale result contract exists.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic frozen corpus")
        let fixture = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "frozen.txt",
            status: .ready,
            extractionStatus: .extracted,
            indexStatus: .textIndexed,
            partTexts: ["ORIGINAL-FIRST", "ORIGINAL-SECOND"]
        )
        let probe = EngineProbe()
        let result = try await CorpusAnalysisEngine(store: store).run(
            request: CorpusAnalysisRequest(
                runKey: "freeze-run",
                matterID: matter.id,
                taskKind: .customExtraction,
                scope: CorpusAnalysisScope(documentIDs: [fixture.documentID]),
                characterBudget: 1
            )
        ) { input in
            await probe.record(input)
            if await probe.claimEdit() {
                _ = try store.documentRevisions.appendUserEdit(
                    documentID: fixture.documentID,
                    partID: fixture.partIDs[1],
                    text: "EDITED-SECOND",
                    author: "Synthetic tester",
                    reason: "T-ENG-01 mid-run edit"
                )
            }
            return CorpusAnalysisMapOutput(findings: input.sources.map { source in
                CorpusAnalysisFinding(
                    id: "finding-\(source.revisionID)",
                    value: source.text,
                    evidence: [CorpusAnalysisEvidenceReference(
                        documentID: source.documentID,
                        revisionID: source.revisionID,
                        locatorJSON: source.locatorJSON
                    )]
                )
            })
        }

        let observedInputs = await probe.inputs
        let observedTexts = observedInputs.flatMap(\.sources).map(\.text)
        XCTAssertEqual(observedTexts, ["ORIGINAL-FIRST", "ORIGINAL-SECOND"])
        XCTAssertFalse(observedTexts.contains("EDITED-SECOND"))
        XCTAssertEqual(result.snapshot.members.first?.revisionIDs, fixture.revisionIDs)
        XCTAssertEqual(result.run.status, CorpusAnalysisRunStatus.persisted.rawValue)
        XCTAssertEqual(result.run.assuranceState, OutputAssuranceState.stale.rawValue)
        XCTAssertTrue(result.assuranceReasons.contains { $0.contains(fixture.documentID) })
        let currentParts = try store.documentIndex.fetchParts(documentID: fixture.documentID)
        XCTAssertNotEqual(currentParts[1].currentRevisionID, fixture.revisionIDs[1])
    }

    func testTENG02SnapshotDisclosesFailedReviewAndExcludedHiddenMembers() async throws {
        // T-ENG-02 expected RED: failed/excluded members vanish from readiness denominators.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic disclosed corpus")
        let eligible = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "eligible.txt",
            status: .ready,
            extractionStatus: .extracted,
            indexStatus: .textIndexed,
            partTexts: ["ELIGIBLE-EVIDENCE"]
        )
        _ = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "failed-parser.txt",
            status: .failed,
            extractionStatus: .failed,
            indexStatus: .failed,
            partTexts: []
        )
        _ = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "review-required.txt",
            status: .needsReview,
            extractionStatus: .extracted,
            indexStatus: .textIndexed,
            partTexts: ["REVIEW-EVIDENCE"]
        )
        let batch = try store.documentJobs.createBatch(matterID: matter.id)
        _ = try store.documentJobs.recordDiscovered(
            batchID: batch.id,
            matterID: matter.id,
            sourceKey: "selection:hidden",
            sourceDisplayPath: ".synthetic-hidden",
            state: .excludedHidden
        )

        let result = try await CorpusAnalysisEngine(store: store).run(
            request: CorpusAnalysisRequest(
                runKey: "disclosure-run",
                matterID: matter.id,
                taskKind: .customExtraction,
                scope: .wholeMatter,
                characterBudget: 1
            )
        ) { input in
            CorpusAnalysisMapOutput(findings: input.sources.map { source in
                CorpusAnalysisFinding(
                    id: "finding-\(source.revisionID)",
                    value: source.text,
                    evidence: [.init(
                        documentID: source.documentID,
                        revisionID: source.revisionID,
                        locatorJSON: source.locatorJSON
                    )]
                )
            })
        }

        XCTAssertEqual(result.snapshot.members.count, 4)
        XCTAssertEqual(result.coverage.snapshotMemberCount, 4)
        XCTAssertEqual(result.coverage.eligibleMemberCount, 1)
        XCTAssertEqual(result.coverage.excludedMemberCount, 3)
        XCTAssertEqual(result.coverage.partitionCount, 1)
        XCTAssertEqual(result.findings.first?.evidence.first?.revisionID, eligible.revisionIDs[0])
        let reasonByName: [String: String?] = Dictionary(uniqueKeysWithValues: result.snapshot.members.map {
            ($0.displayName, $0.reason)
        })
        XCTAssertEqual(try XCTUnwrap(reasonByName["failed-parser.txt"] ?? nil), "extraction_failed")
        XCTAssertEqual(try XCTUnwrap(reasonByName["review-required.txt"] ?? nil), "review_required")
        XCTAssertEqual(try XCTUnwrap(reasonByName[".synthetic-hidden"] ?? nil), "excluded_hidden")
        XCTAssertEqual(result.run.assuranceState, OutputAssuranceState.corpusComplete.rawValue)
        XCTAssertTrue(result.coverage.excludedMembersDisclosed)
    }

    func testTENG05EngineMapsAllSixPartitionsWhileRetrievalRemainsCappedAtFour() async throws {
        // T-ENG-05 expected RED: no uncapped engine path exists; ordinary retrieval already caps per document.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic uncapped corpus")
        let texts = (1...6).map { "RESPONSIVE-\($0) planted corpus fact" }
        let fixture = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "six-partitions.txt",
            status: .indexing,
            extractionStatus: .extracted,
            indexStatus: .notIndexed,
            partTexts: texts
        )
        let indexedDocumentCount = try await DocumentIndexingService(store: store)
            .indexMatter(matterID: matter.id)
        XCTAssertEqual(indexedDocumentCount, 1)

        let retrieval = try await DocumentRetrievalService(store: store).retrieve(
            matterID: matter.id,
            query: "responsive planted corpus fact",
            scope: .wholeMatter,
            limit: 40,
            depth: .deep
        )
        XCTAssertLessThanOrEqual(retrieval.sources.count, 4)
        XCTAssertEqual(Set(retrieval.sources.map(\.documentID)), [fixture.documentID])

        let probe = EngineProbe()
        let result = try await CorpusAnalysisEngine(store: store).run(
            request: CorpusAnalysisRequest(
                runKey: "uncapped-run",
                matterID: matter.id,
                taskKind: .customExtraction,
                scope: CorpusAnalysisScope(documentIDs: [fixture.documentID]),
                characterBudget: 1
            )
        ) { input in
            await probe.record(input)
            return CorpusAnalysisMapOutput(findings: input.sources.map { source in
                CorpusAnalysisFinding(
                    id: "finding-\(source.revisionID)",
                    value: source.text,
                    evidence: [.init(
                        documentID: source.documentID,
                        revisionID: source.revisionID,
                        locatorJSON: source.locatorJSON
                    )]
                )
            })
        }

        XCTAssertEqual(result.partitions.count, 6)
        XCTAssertEqual(result.findings.count, 6)
        XCTAssertEqual(
            Set(result.findings.flatMap { $0.evidence }.map { $0.revisionID }),
            Set(fixture.revisionIDs)
        )
        XCTAssertTrue(result.partitions.allSatisfy {
            $0.disposition == CorpusAnalysisPartitionDisposition.succeeded.rawValue
        })
        let recordedInputs = await probe.inputs
        let prompts = recordedInputs.map { $0.promptEnvelope }
        XCTAssertEqual(prompts.count, 6)
        XCTAssertTrue(prompts.allSatisfy { $0.contains("BEGIN_UNTRUSTED_SOURCE_DATA") })
        XCTAssertTrue(prompts.allSatisfy { $0.contains("END_UNTRUSTED_SOURCE_DATA") })
    }

    private func makeStore() throws -> SupraStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CorpusAnalysisEngine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SupraStore(url: directory.appendingPathComponent("test.sqlite"))
    }

    private func insertDocument(
        store: SupraStore,
        matterID: String,
        name: String,
        status: MatterDocumentStatus,
        extractionStatus: DocumentExtractionStatus,
        indexStatus: DocumentIndexStatus,
        partTexts: [String]
    ) throws -> CorpusFixtureDocument {
        let key = name.replacingOccurrences(of: ".", with: "-")
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            sha256: "corpus-\(key)-\(UUID().uuidString)",
            byteSize: partTexts.reduce(0) { $0 + $1.utf8.count },
            originalExtension: "txt",
            managedRelativePath: "blobs/\(key).txt"
        )).blob
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matterID,
            blobID: blob.id,
            displayName: name,
            status: status.rawValue,
            extractionStatus: extractionStatus.rawValue,
            indexStatus: indexStatus.rawValue
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
        if !parts.isEmpty {
            _ = try store.documentRevisions.replacePartsAndPersistLineage(
                documentID: document.id,
                parts: parts,
                revisions: revisions,
                selections: selections
            )
        }
        return CorpusFixtureDocument(
            documentID: document.id,
            partIDs: parts.map(\.id),
            revisionIDs: revisions.map(\.id)
        )
    }
}

private struct CorpusFixtureDocument: Sendable {
    var documentID: String
    var partIDs: [String]
    var revisionIDs: [String]
}

private actor EngineProbe {
    private(set) var inputs: [CorpusAnalysisPartitionInput] = []
    private var editClaimed = false

    func record(_ input: CorpusAnalysisPartitionInput) {
        inputs.append(input)
    }

    func claimEdit() -> Bool {
        if editClaimed { return false }
        editClaimed = true
        return true
    }
}
