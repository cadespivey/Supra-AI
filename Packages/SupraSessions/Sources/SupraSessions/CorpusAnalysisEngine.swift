import Foundation
import SupraCore
import SupraDocuments
import SupraStore

public struct CorpusAnalysisScope: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var documentIDs: [String]?

    public init(schemaVersion: Int = 1, documentIDs: [String]? = nil) {
        self.schemaVersion = schemaVersion
        self.documentIDs = documentIDs
    }

    public static let wholeMatter = CorpusAnalysisScope()

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case documentIDs = "document_ids"
    }
}

public struct CorpusAnalysisRequest: Sendable {
    public var runKey: String
    public var matterID: String
    public var taskKind: CorpusAnalysisTaskKind
    public var scope: CorpusAnalysisScope
    public var characterBudget: Int
    public var maximumRetryCount: Int
    public var modelLineageJSON: String?

    public init(
        runKey: String,
        matterID: String,
        taskKind: CorpusAnalysisTaskKind,
        scope: CorpusAnalysisScope = .wholeMatter,
        characterBudget: Int = 24_000,
        maximumRetryCount: Int = 2,
        modelLineageJSON: String? = nil
    ) {
        self.runKey = runKey
        self.matterID = matterID
        self.taskKind = taskKind
        self.scope = scope
        self.characterBudget = max(1, characterBudget)
        self.maximumRetryCount = max(0, maximumRetryCount)
        self.modelLineageJSON = modelLineageJSON
    }
}

public struct CorpusAnalysisEvidenceReference: Codable, Equatable, Hashable, Sendable {
    public var documentID: String
    public var revisionID: String
    public var locatorJSON: String

    public init(documentID: String, revisionID: String, locatorJSON: String) {
        self.documentID = documentID
        self.revisionID = revisionID
        self.locatorJSON = locatorJSON
    }

    private enum CodingKeys: String, CodingKey {
        case documentID = "document_id"
        case revisionID = "revision_id"
        case locatorJSON = "locator_json"
    }
}

public struct CorpusAnalysisFinding: Codable, Equatable, Sendable {
    public var id: String
    public var value: String
    public var evidence: [CorpusAnalysisEvidenceReference]
    public var contraryEvidence: [CorpusAnalysisEvidenceReference]

    public init(
        id: String,
        value: String,
        evidence: [CorpusAnalysisEvidenceReference],
        contraryEvidence: [CorpusAnalysisEvidenceReference] = []
    ) {
        self.id = id
        self.value = value
        self.evidence = evidence
        self.contraryEvidence = contraryEvidence
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case value
        case evidence
        case contraryEvidence = "contrary_evidence"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        value = try container.decode(String.self, forKey: .value)
        evidence = try container.decode([CorpusAnalysisEvidenceReference].self, forKey: .evidence)
        contraryEvidence = try container.decodeIfPresent(
            [CorpusAnalysisEvidenceReference].self,
            forKey: .contraryEvidence
        ) ?? []
    }
}

public struct CorpusAnalysisPartitionSource: Equatable, Sendable {
    public var documentID: String
    public var documentName: String
    public var partIndex: Int
    public var revisionID: String
    public var text: String
    public var locatorJSON: String
}

public struct CorpusAnalysisPartitionInput: Equatable, Sendable {
    public var partitionID: String
    public var partitionKey: String
    public var sources: [CorpusAnalysisPartitionSource]
    public var promptEnvelope: String
}

public struct CorpusAnalysisMapOutput: Equatable, Sendable {
    public var findings: [CorpusAnalysisFinding]

    public init(findings: [CorpusAnalysisFinding]) {
        self.findings = findings
    }
}

public struct CorpusAnalysisRunResult: Sendable {
    public var run: CorpusAnalysisRunRecord
    public var snapshot: CorpusAnalysisSnapshot
    public var coverage: CorpusAnalysisCoverage
    public var partitions: [CorpusAnalysisPartitionRecord]
    public var findings: [CorpusAnalysisFinding]
    public var assuranceReasons: [String]
}

public struct CorpusAnalysisJobPayload: Codable, Equatable, Sendable {
    public var runID: String

    public init(runID: String) { self.runID = runID }

    private enum CodingKeys: String, CodingKey { case runID = "run_id" }
}

public enum CorpusAnalysisEngineError: Error, LocalizedError, Equatable, Sendable {
    case runKeyCollision(String)
    case invalidPersistedJSON(String)
    case revisionUnavailable(String)
    case invalidFindingEvidence(String)

    public var errorDescription: String? {
        switch self {
        case .runKeyCollision(let key): "Corpus run key \(key) was reused with different inputs."
        case .invalidPersistedJSON(let field): "Corpus analysis persisted invalid \(field) JSON."
        case .revisionUnavailable(let id): "Frozen revision \(id) is unavailable."
        case .invalidFindingEvidence(let id): "Finding \(id) cites evidence outside its frozen partition."
        }
    }
}

/// Mapper failures are permanent unless explicitly classified transient. This
/// keeps malformed output/evidence from being retried as if it were transport
/// instability while giving model/runtime callers a bounded retry seam.
public enum CorpusAnalysisMapFailure: Error, LocalizedError, Equatable, Sendable {
    case transient(String)
    case permanent(String)
    case schemaInvalid(responseDigest: String, summary: String)

    public var isTransient: Bool {
        if case .transient = self { return true }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .transient(let summary), .permanent(let summary): summary
        case .schemaInvalid(let digest, let summary):
            "\(summary); response_sha256=\(digest)"
        }
    }

    public var dispositionReason: String? {
        if case .schemaInvalid = self { return "schema_invalid" }
        return nil
    }
}

/// Frozen-snapshot exhaustive orchestration. Unlike ordinary retrieval, this
/// maps every planned revision range and therefore has no top-k/per-document
/// retrieval cap. Partition checkpoints support cancellation, relaunch resume,
/// orphan-attempt recovery, and explicitly bounded transient retries.
public final class CorpusAnalysisEngine: @unchecked Sendable {
    public typealias Mapper = @Sendable (CorpusAnalysisPartitionInput) async throws -> CorpusAnalysisMapOutput

    private let store: SupraStore

    public init(store: SupraStore) {
        self.store = store
    }

    public func run(
        request: CorpusAnalysisRequest,
        mapper: @escaping Mapper
    ) async throws -> CorpusAnalysisRunResult {
        let scopeJSON = try canonicalJSON(request.scope)
        let strategy = "part_range:characters=\(request.characterBudget)"
        let plan: CorpusAnalysisPlan
        let run: CorpusAnalysisRunRecord
        if let existing = try store.corpusAnalysis.fetchRun(
            matterID: request.matterID,
            runKey: request.runKey
        ) {
            guard existing.taskKind == request.taskKind.rawValue,
                  existing.scopeJSON == scopeJSON,
                  existing.partitionStrategy == strategy,
                  existing.partitionStrategyVersion == 1,
                  existing.modelLineageJSON == request.modelLineageJSON else {
                throw CorpusAnalysisEngineError.runKeyCollision(request.runKey)
            }
            if existing.status == CorpusAnalysisRunStatus.persisted.rawValue {
                return try persistedResult(existing)
            }
            guard let snapshotData = existing.corpusSnapshotJSON.data(using: .utf8),
                  let snapshot = try? JSONDecoder().decode(CorpusAnalysisSnapshot.self, from: snapshotData) else {
                throw CorpusAnalysisEngineError.invalidPersistedJSON("snapshot")
            }
            plan = CorpusAnalysisPlan(snapshot: snapshot, partitions: [])
            run = try store.corpusAnalysis.prepareForResume(
                matterID: request.matterID,
                runID: existing.id,
                maximumRetryCount: request.maximumRetryCount
            )
        } else {
            plan = try makePlan(request: request)
            let proposed = CorpusAnalysisRunRecord(
                runKey: request.runKey,
                matterID: request.matterID,
                taskKind: request.taskKind.rawValue,
                scopeJSON: scopeJSON,
                corpusSnapshotJSON: try canonicalJSON(plan.snapshot),
                partitionStrategy: strategy,
                partitionStrategyVersion: 1,
                modelLineageJSON: request.modelLineageJSON,
                status: CorpusAnalysisRunStatus.planning.rawValue
            )
            run = try store.corpusAnalysis.createOrFetchRun(proposed)
            try store.corpusAnalysis.createPartitions(
                matterID: request.matterID,
                runID: run.id,
                partitions: try plan.partitions.map { try $0.record(runID: run.id) }
            )
            _ = try store.corpusAnalysis.updateStatus(
                matterID: request.matterID,
                runID: run.id,
                to: .running
            )
        }

        do {
            let documents = try store.documentLibrary.fetchDocuments(matterID: request.matterID)
            let nameByID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0.displayName) })
            let partitions = try store.corpusAnalysis.fetchPartitions(
                matterID: request.matterID,
                runID: run.id
            )
            for partition in partitions where partition.disposition == CorpusAnalysisPartitionDisposition.pending.rawValue {
                try Task.checkCancellation()
                var partitionFinished = false
                while !partitionFinished {
                    let attempt = try store.corpusAnalysis.beginAttempt(
                        matterID: request.matterID,
                        runID: run.id,
                        partitionID: partition.id
                    )
                    do {
                        let input = try partitionInput(attempt, documentNames: nameByID)
                        let output = try await mapper(input)
                        try validate(output, against: input)
                        try store.corpusAnalysis.completeAttemptSucceeded(
                            matterID: request.matterID,
                            runID: run.id,
                            partitionID: partition.id,
                            findingsJSON: try canonicalJSON(output.findings)
                        )
                        partitionFinished = true
                    } catch is CancellationError {
                        try store.corpusAnalysis.completeAttemptCancelled(
                            matterID: request.matterID,
                            runID: run.id,
                            partitionID: partition.id
                        )
                        throw CancellationError()
                    } catch {
                        let classified = error as? CorpusAnalysisMapFailure
                        let shouldRetry = try store.corpusAnalysis.completeAttemptFailed(
                            matterID: request.matterID,
                            runID: run.id,
                            partitionID: partition.id,
                            retryable: classified?.isTransient == true,
                            errorSummary: error.localizedDescription,
                            maximumRetryCount: request.maximumRetryCount,
                            dispositionReason: classified?.dispositionReason
                        )
                        partitionFinished = !shouldRetry
                        if shouldRetry { try Task.checkCancellation() }
                    }
                }
            }

            _ = try store.corpusAnalysis.updateStatus(
                matterID: request.matterID,
                runID: run.id,
                to: .reconciling
            )
            let finishedPartitions = try store.corpusAnalysis.fetchPartitions(
                matterID: request.matterID,
                runID: run.id
            )
            let findings = try reconciledFindings(from: finishedPartitions)
            let excludedNames = plan.snapshot.members
                .filter { $0.disposition == .excluded }
                .map(\.displayName)
                .sorted()
            let reconciliation = CorpusAnalysisReconciliation(
                findings: findings,
                excludedMembers: excludedNames
            )
            _ = try store.corpusAnalysis.saveReconciliation(
                matterID: request.matterID,
                runID: run.id,
                reconciliationJSON: try canonicalJSON(reconciliation),
                validationResultsJSON: try canonicalJSON(CorpusAnalysisValidationResults(
                    validatedPartitionCount: finishedPartitions.count {
                        $0.disposition == CorpusAnalysisPartitionDisposition.succeeded.rawValue
                    },
                    failedPartitionCount: finishedPartitions.count {
                        $0.disposition == CorpusAnalysisPartitionDisposition.failed.rawValue
                    }
                ))
            )
            _ = try store.corpusAnalysis.updateStatus(
                matterID: request.matterID,
                runID: run.id,
                to: .verifying
            )
            let coverage = try store.corpusAnalysis.coverage(
                matterID: request.matterID,
                runID: run.id
            )
            let staleReasons = try stalenessReasons(snapshot: plan.snapshot)
            let versionRelationReasons: [String]
            if DocumentRelationDownstreamPolicy.requiresReviewedRelations(for: request.taskKind) {
                let inScopeDocumentIDs = Set(plan.snapshot.members.compactMap(\.documentID))
                versionRelationReasons = DocumentRelationDownstreamPolicy.unreviewedReasons(
                    relations: try store.documentRelations.fetchAll(matterID: request.matterID),
                    documents: documents,
                    inScopeDocumentIDs: inScopeDocumentIDs
                )
            } else {
                versionRelationReasons = []
            }
            let assurance: OutputAssuranceState
            let reasons: [String]
            if !staleReasons.isEmpty {
                assurance = .stale
                reasons = (staleReasons + versionRelationReasons).sorted()
            } else if !versionRelationReasons.isEmpty {
                assurance = request.taskKind == .negativeCheck ? .negativeBlocked : .corpusIncomplete
                reasons = versionRelationReasons
            } else if coverage.pendingPartitionCount == 0,
                      coverage.failedPartitionCount == 0,
                      coverage.cancelledPartitionCount == 0,
                      coverage.excludedPartitionCount == 0,
                      coverage.succeededPartitionCount == coverage.partitionCount,
                      coverage.balanceErrorCount == 0 {
                assurance = .corpusComplete
                reasons = excludedNames.isEmpty
                    ? []
                    : ["Excluded snapshot members were disclosed: \(excludedNames.joined(separator: ", "))."]
            } else {
                assurance = .corpusIncomplete
                reasons = ["The corpus ledger contains failed, cancelled, pending, excluded, or unbalanced partitions."]
            }
            let finalized = try store.corpusAnalysis.finalizeRun(
                matterID: request.matterID,
                runID: run.id,
                assuranceState: assurance,
                assuranceReasons: reasons,
                exclusionsDisclosed: true
            )
            return CorpusAnalysisRunResult(
                run: finalized,
                snapshot: plan.snapshot,
                coverage: try decodeCoverage(finalized),
                partitions: try store.corpusAnalysis.fetchPartitions(
                    matterID: request.matterID,
                    runID: run.id
                ),
                findings: findings,
                assuranceReasons: reasons
            )
        } catch is CancellationError {
            _ = try? store.corpusAnalysis.cancelRun(
                matterID: request.matterID,
                runID: run.id
            )
            throw CancellationError()
        } catch {
            _ = try? store.corpusAnalysis.updateStatus(
                matterID: request.matterID,
                runID: run.id,
                to: .failed
            )
            throw error
        }
    }

    private func makePlan(request: CorpusAnalysisRequest) throws -> CorpusAnalysisPlan {
        let requestedIDs = request.scope.documentIDs.map(Set.init)
        let documents = try store.documentLibrary.fetchDocuments(matterID: request.matterID)
            .filter { requestedIDs?.contains($0.id) ?? true }
            .sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                    || ($0.displayName == $1.displayName && $0.id < $1.id)
            }
        var members: [CorpusAnalysisSnapshotMember] = []
        var sources: [PlannedSource] = []
        for document in documents {
            let exclusionReason = exclusionReason(for: document)
            let parts = try store.documentIndex.fetchParts(documentID: document.id)
            let revisionIDs = parts.compactMap(\.currentRevisionID)
            if let exclusionReason {
                members.append(.init(
                    memberKey: "document:\(document.id)",
                    documentID: document.id,
                    displayName: document.displayName,
                    revisionIDs: revisionIDs,
                    indexState: document.indexStatus,
                    disposition: .excluded,
                    reason: exclusionReason
                ))
                continue
            }
            guard !parts.isEmpty, revisionIDs.count == parts.count else {
                members.append(.init(
                    memberKey: "document:\(document.id)",
                    documentID: document.id,
                    displayName: document.displayName,
                    revisionIDs: revisionIDs,
                    indexState: document.indexStatus,
                    disposition: .excluded,
                    reason: "no_selected_revision"
                ))
                continue
            }
            members.append(.init(
                memberKey: "document:\(document.id)",
                documentID: document.id,
                displayName: document.displayName,
                revisionIDs: revisionIDs,
                indexState: document.indexStatus,
                disposition: .eligible
            ))
            for (part, revisionID) in zip(parts, revisionIDs) {
                guard let revision = try store.documentRevisions.fetchRevision(id: revisionID) else {
                    throw CorpusAnalysisEngineError.revisionUnavailable(revisionID)
                }
                sources.append(PlannedSource(
                    documentID: document.id,
                    partIndex: part.partIndex,
                    revisionID: revision.id,
                    charCount: revision.charCount,
                    orderDate: document.metadataModifiedAt ?? document.metadataCreatedAt
                ))
            }
        }

        if requestedIDs == nil {
            let terminalExclusionStates: Set<DocumentImportSourceState> = [
                .rejected, .unsupportedByPolicy, .failed, .cancelled,
                .excludedHidden, .excludedByUser,
            ]
            for source in try store.documentJobs.fetchSources(matterID: request.matterID)
                where source.documentID == nil
                    && source.sourceState.map(terminalExclusionStates.contains) == true {
                members.append(.init(
                    memberKey: "import-source:\(source.id)",
                    displayName: source.sourceDisplayPath,
                    disposition: .excluded,
                    reason: source.reason ?? source.state
                ))
            }
        }
        members.sort { $0.memberKey < $1.memberKey }

        let items = sources.map {
            ChronologyBatchPlanner.Item(
                documentKey: $0.documentID,
                charCount: $0.charCount,
                orderDate: $0.orderDate
            )
        }
        let batches = ChronologyBatchPlanner.plan(
            items: items,
            characterBudget: request.characterBudget
        )
        let partitions = batches.enumerated().map { ordinal, batch in
            let batchSources = batch.sourceIndices.map { sources[$0] }
            let key = batchSources.map {
                "\($0.documentID)#part:\($0.partIndex)#revision:\($0.revisionID)"
            }.joined(separator: "|")
            return PlannedPartition(
                id: UUID().uuidString,
                key: String(format: "%06d|%@", ordinal, key),
                revisionIDs: batchSources.map(\.revisionID)
            )
        }
        return CorpusAnalysisPlan(
            snapshot: CorpusAnalysisSnapshot(members: members),
            partitions: partitions
        )
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

    private func partitionInput(
        _ partition: CorpusAnalysisPartitionRecord,
        documentNames: [String: String]
    ) throws -> CorpusAnalysisPartitionInput {
        guard let data = partition.inputRevisionIDsJSON.data(using: .utf8),
              let revisionIDs = try? JSONDecoder().decode([String].self, from: data) else {
            throw CorpusAnalysisEngineError.invalidPersistedJSON("input revisions")
        }
        let sources = try revisionIDs.map { revisionID -> CorpusAnalysisPartitionSource in
            guard let revision = try store.documentRevisions.fetchRevision(id: revisionID) else {
                throw CorpusAnalysisEngineError.revisionUnavailable(revisionID)
            }
            let locator = DocumentSourceLocator(
                sourceKind: .text,
                charStart: 0,
                charEnd: revision.text.count
            )
            return CorpusAnalysisPartitionSource(
                documentID: revision.documentID,
                documentName: documentNames[revision.documentID] ?? "Document",
                partIndex: revision.partIndex,
                revisionID: revision.id,
                text: revision.text,
                locatorJSON: locator.encodedJSON()
            )
        }
        let groundingSources = sources.enumerated().map { index, source in
            GroundingSource(
                sourceID: source.revisionID,
                label: "E\(index + 1)",
                documentName: source.documentName,
                locatorDisplay: "chars 0–\(source.text.count)",
                text: source.text,
                excerpt: DocumentChunker.excerpt(source.text)
            )
        }
        return CorpusAnalysisPartitionInput(
            partitionID: partition.id,
            partitionKey: partition.partitionKey,
            sources: sources,
            promptEnvelope: DocumentQAPromptBuilder.buildSourceDataBlock(sources: groundingSources)
        )
    }

    private func validate(
        _ output: CorpusAnalysisMapOutput,
        against input: CorpusAnalysisPartitionInput
    ) throws {
        let sourceByRevision = Dictionary(uniqueKeysWithValues: input.sources.map { ($0.revisionID, $0) })
        var findingIDs = Set<String>()
        for finding in output.findings {
            guard !finding.id.isEmpty,
                  findingIDs.insert(finding.id).inserted,
                  !(finding.evidence + finding.contraryEvidence).isEmpty,
                  (finding.evidence + finding.contraryEvidence).allSatisfy({ evidence in
                      guard let source = sourceByRevision[evidence.revisionID] else { return false }
                      return source.documentID == evidence.documentID
                          && source.locatorJSON == evidence.locatorJSON
                  }) else {
                throw CorpusAnalysisEngineError.invalidFindingEvidence(finding.id)
            }
        }
    }

    private func reconciledFindings(
        from partitions: [CorpusAnalysisPartitionRecord]
    ) throws -> [CorpusAnalysisFinding] {
        var reconciled: [CorpusAnalysisFinding] = []
        for partition in partitions where partition.disposition == CorpusAnalysisPartitionDisposition.succeeded.rawValue {
            guard let json = partition.findingsJSON,
                  let data = json.data(using: .utf8),
                  let decodedFindings = try? JSONDecoder().decode([CorpusAnalysisFinding].self, from: data) else {
                throw CorpusAnalysisEngineError.invalidPersistedJSON("findings")
            }
            for finding in decodedFindings {
                if !reconciled.contains(finding) {
                    reconciled.append(finding)
                }
            }
        }
        return reconciled.sorted {
            $0.id < $1.id || ($0.id == $1.id && $0.value < $1.value)
        }
    }

    private func stalenessReasons(snapshot: CorpusAnalysisSnapshot) throws -> [String] {
        var reasons: [String] = []
        for member in snapshot.members where member.disposition == .eligible {
            guard let documentID = member.documentID else { continue }
            let currentRevisionIDs = try store.documentIndex.fetchParts(documentID: documentID)
                .compactMap(\.currentRevisionID)
            if currentRevisionIDs != member.revisionIDs {
                reasons.append("Document \(documentID) changed after the corpus snapshot was frozen.")
            }
        }
        return reasons.sorted()
    }

    private func persistedResult(_ run: CorpusAnalysisRunRecord) throws -> CorpusAnalysisRunResult {
        guard let snapshotData = run.corpusSnapshotJSON.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(CorpusAnalysisSnapshot.self, from: snapshotData) else {
            throw CorpusAnalysisEngineError.invalidPersistedJSON("snapshot")
        }
        let partitions = try store.corpusAnalysis.fetchPartitions(matterID: run.matterID, runID: run.id)
        let findings = try reconciledFindings(from: partitions)
        let reasons: [String]
        if let json = run.assuranceReasonsJSON,
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            reasons = decoded
        } else {
            reasons = []
        }
        return CorpusAnalysisRunResult(
            run: run,
            snapshot: snapshot,
            coverage: try decodeCoverage(run),
            partitions: partitions,
            findings: findings,
            assuranceReasons: reasons
        )
    }

    private func decodeCoverage(_ run: CorpusAnalysisRunRecord) throws -> CorpusAnalysisCoverage {
        guard let json = run.coverageJSON,
              let data = json.data(using: .utf8),
              let coverage = try? JSONDecoder().decode(CorpusAnalysisCoverage.self, from: data) else {
            throw CorpusAnalysisEngineError.invalidPersistedJSON("coverage")
        }
        return coverage
    }

    private func canonicalJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

private struct PlannedSource {
    var documentID: String
    var partIndex: Int
    var revisionID: String
    var charCount: Int
    var orderDate: Date?
}

private struct PlannedPartition {
    var id: String
    var key: String
    var revisionIDs: [String]

    func record(runID: String) throws -> CorpusAnalysisPartitionRecord {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return CorpusAnalysisPartitionRecord(
            id: id,
            runID: runID,
            partitionKey: key,
            inputRevisionIDsJSON: String(decoding: try encoder.encode(revisionIDs), as: UTF8.self)
        )
    }
}

private struct CorpusAnalysisPlan {
    var snapshot: CorpusAnalysisSnapshot
    var partitions: [PlannedPartition]
}

private struct CorpusAnalysisReconciliation: Codable {
    var schemaVersion = 1
    var findings: [CorpusAnalysisFinding]
    var excludedMembers: [String]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case findings
        case excludedMembers = "excluded_members"
    }
}

private struct CorpusAnalysisValidationResults: Codable {
    var schemaVersion = 1
    var validatedPartitionCount: Int
    var failedPartitionCount: Int

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case validatedPartitionCount = "validated_partition_count"
        case failedPartitionCount = "failed_partition_count"
    }
}
