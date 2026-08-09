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
        let inspection = try store.corpusAnalysis.inspectCurrentScope(
            matterID: request.matterID,
            documentIDs: request.scope.documentIDs
        )
        let members = inspection.snapshot.members
        let sources = inspection.sources

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
        try store.corpusAnalysis.inspectCurrentScope(
            matterID: request.matterID,
            documentIDs: request.scope.documentIDs
        ).snapshot
    }

    private func exactSlices(
        source: CorpusAnalysisScopeSource,
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

    private func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
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
