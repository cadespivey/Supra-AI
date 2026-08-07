import Foundation
import SupraCore
import SupraDocuments
import SupraStore

struct CorpusAnalysisPreparedPlan {
    var snapshot: CorpusAnalysisSnapshot
    var partitions: [CorpusAnalysisPartitionRecord]
    var slices: [CorpusAnalysisPartitionSliceRecord]
}

struct CorpusAnalysisExactPlanner {
    let store: SupraStore

    func plan(
        request: CorpusAnalysisRequest,
        runID: String
    ) throws -> CorpusAnalysisPreparedPlan {
        let corpus = try inspectCorpus(request: request)
        let members = corpus.members
        let sources = corpus.sources

        let sliceLimit = min(
            request.characterBudget,
            DocumentQAPromptBuilder.maxSourceTextChars
        )
        let seeds = sources.flatMap { exactSlices(source: $0, limit: sliceLimit) }
        guard !seeds.isEmpty else {
            throw CorpusAnalysisPreparationError.noEligibleSources
        }

        let batches = ChronologyBatchPlanner.plan(
            items: seeds.map {
                ChronologyBatchPlanner.Item(
                    documentKey: $0.documentID,
                    charCount: $0.charEnd - $0.charStart,
                    orderDate: $0.orderDate
                )
            },
            characterBudget: request.characterBudget
        )
        var partitions: [CorpusAnalysisPartitionRecord] = []
        var slices: [CorpusAnalysisPartitionSliceRecord] = []
        for (partitionOrdinal, batch) in batches.enumerated() {
            let partitionID = UUID().uuidString
            let batchSeeds = batch.sourceIndices.map { seeds[$0] }
            let descriptors = batchSeeds.map {
                "\($0.memberKey)#part:\($0.partIndex)#revision:\($0.revisionID)#chars:\($0.charStart)-\($0.charEnd)"
            }
            let revisionIDs = orderedUnique(batchSeeds.map(\.revisionID))
            partitions.append(CorpusAnalysisPartitionRecord(
                id: partitionID,
                runID: runID,
                partitionKey: String(format: "%06d|%@", partitionOrdinal, descriptors.joined(separator: "|")),
                inputRevisionIDsJSON: try CorpusAnalysisRequestDigest.canonicalJSON(revisionIDs)
            ))
            slices.append(contentsOf: batchSeeds.enumerated().map { ordinal, seed in
                CorpusAnalysisPartitionSliceRecord(
                    runID: runID,
                    partitionID: partitionID,
                    ordinal: ordinal,
                    memberKey: seed.memberKey,
                    documentID: seed.documentID,
                    partIndex: seed.partIndex,
                    revisionID: seed.revisionID,
                    charStart: seed.charStart,
                    charEnd: seed.charEnd,
                    revisionCharCount: seed.revisionCharCount,
                    textSHA256: seed.textSHA256,
                    locatorJSON: seed.locatorJSON
                )
            })
        }

        return CorpusAnalysisPreparedPlan(
            snapshot: CorpusAnalysisSnapshot(schemaVersion: 2, members: members),
            partitions: partitions,
            slices: slices
        )
    }

    /// Re-evaluates scope membership and eligibility using the same rules as
    /// preparation, without producing a second runnable ledger.
    func currentSnapshot(request: CorpusAnalysisRequest) throws -> CorpusAnalysisSnapshot {
        CorpusAnalysisSnapshot(
            schemaVersion: 2,
            members: try inspectCorpus(request: request).members
        )
    }

    private func inspectCorpus(request: CorpusAnalysisRequest) throws -> ExactCorpus {
        let requestedIDs = request.scope.documentIDs.map(Set.init)
        let documents = try store.documentLibrary.fetchDocuments(matterID: request.matterID)
            .filter { requestedIDs?.contains($0.id) ?? true }
            .sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                    || ($0.displayName == $1.displayName && $0.id < $1.id)
            }
        var members: [CorpusAnalysisSnapshotMember] = []
        var sources: [ExactRevisionSource] = []

        for document in documents {
            let parts = try store.documentIndex.fetchParts(documentID: document.id)
            let revisionIDs = parts.compactMap(\.currentRevisionID)
            let memberKey = "document:\(document.id)"
            if let reason = exclusionReason(for: document) {
                members.append(.init(
                    memberKey: memberKey,
                    documentID: document.id,
                    displayName: document.displayName,
                    revisionIDs: revisionIDs,
                    indexState: document.indexStatus,
                    disposition: .excluded,
                    reason: reason
                ))
                continue
            }
            guard !parts.isEmpty, revisionIDs.count == parts.count else {
                members.append(.init(
                    memberKey: memberKey,
                    documentID: document.id,
                    displayName: document.displayName,
                    revisionIDs: revisionIDs,
                    indexState: document.indexStatus,
                    disposition: .excluded,
                    reason: "no_selected_revision"
                ))
                continue
            }

            var selected: [(DocumentPagePartRecord, DocumentPartRevisionRecord)] = []
            var selectedRevisionUnavailable = false
            for (part, revisionID) in zip(parts, revisionIDs) {
                guard let revision = try store.documentRevisions.fetchRevision(id: revisionID),
                      revision.documentID == document.id,
                      revision.partIndex == part.partIndex else {
                    selectedRevisionUnavailable = true
                    break
                }
                selected.append((part, revision))
            }
            guard !selectedRevisionUnavailable else {
                members.append(.init(
                    memberKey: memberKey,
                    documentID: document.id,
                    displayName: document.displayName,
                    revisionIDs: revisionIDs,
                    indexState: document.indexStatus,
                    disposition: .excluded,
                    reason: "selected_revision_unavailable"
                ))
                continue
            }
            guard selected.allSatisfy({ !$0.1.text.isEmpty }) else {
                members.append(.init(
                    memberKey: memberKey,
                    documentID: document.id,
                    displayName: document.displayName,
                    revisionIDs: revisionIDs,
                    indexState: document.indexStatus,
                    disposition: .excluded,
                    reason: "empty_selected_revision"
                ))
                continue
            }

            members.append(.init(
                memberKey: memberKey,
                documentID: document.id,
                displayName: document.displayName,
                revisionIDs: revisionIDs,
                indexState: document.indexStatus,
                disposition: .eligible
            ))
            sources.append(contentsOf: selected.map { part, revision in
                ExactRevisionSource(
                    memberKey: memberKey,
                    documentID: document.id,
                    part: part,
                    revision: revision,
                    orderDate: document.metadataModifiedAt ?? document.metadataCreatedAt
                )
            })
        }

        if let requestedIDs {
            let resolvedIDs = Set(documents.map(\.id))
            for documentID in requestedIDs.subtracting(resolvedIDs).sorted() {
                members.append(.init(
                    memberKey: "document:\(documentID)",
                    documentID: documentID,
                    displayName: "Unavailable selected document \(documentID)",
                    revisionIDs: [],
                    indexState: "unavailable",
                    disposition: .excluded,
                    reason: "selected_document_unavailable"
                ))
            }
        }

        if requestedIDs == nil {
            for source in try store.documentJobs.fetchSources(matterID: request.matterID)
                where source.documentID == nil {
                members.append(.init(
                    memberKey: "import-source:\(source.id)",
                    displayName: source.sourceDisplayPath,
                    indexState: source.state,
                    disposition: .excluded,
                    reason: source.reason ?? source.state
                ))
            }
        }
        members.sort { $0.memberKey < $1.memberKey }
        return ExactCorpus(members: members, sources: sources)
    }

    private func exactSlices(
        source: ExactRevisionSource,
        limit: Int
    ) -> [ExactSliceSeed] {
        var result: [ExactSliceSeed] = []
        let text = source.revision.text
        let characterCount = text.count
        var start = 0
        var lower = text.startIndex
        while start < characterCount {
            let end = min(start + limit, characterCount)
            let upper = text.index(lower, offsetBy: end - start)
            let sliceText = String(text[lower..<upper])
            let locator = DocumentSourceLocator(
                sourceKind: DocumentSourceKind(rawValue: source.part.sourceKind) ?? .text,
                pageIndex: source.part.pageIndex,
                pageLabel: source.part.pageLabel,
                sheetName: source.part.sheetName,
                cellRange: source.part.cellRange,
                emailPartPath: source.part.emailPartPath,
                charStart: start,
                charEnd: end,
                boundingBoxesJSON: source.part.boundingBoxesJSON
            )
            result.append(ExactSliceSeed(
                memberKey: source.memberKey,
                documentID: source.documentID,
                partIndex: source.part.partIndex,
                revisionID: source.revision.id,
                charStart: start,
                charEnd: end,
                revisionCharCount: characterCount,
                textSHA256: CorpusAnalysisRequestDigest.sha256(Data(sliceText.utf8)),
                locatorJSON: locator.encodedJSON(),
                orderDate: source.orderDate
            ))
            start = end
            lower = upper
        }
        return result
    }

    private func exclusionReason(for document: MatterDocumentRecord) -> String? {
        if document.status == MatterDocumentStatus.failed.rawValue
            || document.extractionStatus == DocumentExtractionStatus.failed.rawValue {
            return "extraction_failed"
        }
        if document.status == MatterDocumentStatus.needsReview.rawValue { return "review_required" }
        let extractionComplete = document.extractionStatus == DocumentExtractionStatus.extracted.rawValue
            || document.extractionStatus == DocumentExtractionStatus.ocrComplete.rawValue
            || document.extractionStatus == DocumentExtractionStatus.edited.rawValue
        if !extractionComplete { return "extraction_not_ready" }
        let indexReady = document.indexStatus == DocumentIndexStatus.textIndexed.rawValue
            || document.indexStatus == DocumentIndexStatus.ready.rawValue
        return indexReady ? nil : "index_not_ready"
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

private struct ExactCorpus {
    var members: [CorpusAnalysisSnapshotMember]
    var sources: [ExactRevisionSource]
}

private struct ExactRevisionSource {
    var memberKey: String
    var documentID: String
    var part: DocumentPagePartRecord
    var revision: DocumentPartRevisionRecord
    var orderDate: Date?
}

private struct ExactSliceSeed {
    var memberKey: String
    var documentID: String
    var partIndex: Int
    var revisionID: String
    var charStart: Int
    var charEnd: Int
    var revisionCharCount: Int
    var textSHA256: String
    var locatorJSON: String
    var orderDate: Date?
}
