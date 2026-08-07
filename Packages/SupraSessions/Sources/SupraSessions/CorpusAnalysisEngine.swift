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
    /// Exact evidence text returned by the mapper. The host resolves and
    /// normalizes this against the presented slice before persistence.
    public var quote: String?
    /// Slice-relative Character offsets. These never describe UTF-8 or UTF-16
    /// units and are converted to an absolute document locator by the host.
    public var charStart: Int?
    public var charEnd: Int?

    public init(
        documentID: String,
        revisionID: String,
        locatorJSON: String,
        quote: String? = nil,
        charStart: Int? = nil,
        charEnd: Int? = nil
    ) {
        self.documentID = documentID
        self.revisionID = revisionID
        self.locatorJSON = locatorJSON
        self.quote = quote
        self.charStart = charStart
        self.charEnd = charEnd
    }

    private enum CodingKeys: String, CodingKey {
        case documentID = "document_id"
        case revisionID = "revision_id"
        case locatorJSON = "locator_json"
        case quote
        case charStart = "char_start"
        case charEnd = "char_end"
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
        guard request.taskKind != .exhaustiveList else {
            throw CorpusAnalysisPreparationError.preparedRunMismatch(
                "prepared exhaustive-list request"
            )
        }
        return try await execute(
            request: request,
            preparedRunID: nil,
            expectedRequestDigest: nil,
            mapper: mapper
        )
    }

    func runPrepared(
        request: CorpusAnalysisRequest,
        runID: String,
        requestDigest: String,
        mapper: @escaping Mapper
    ) async throws -> CorpusAnalysisRunResult {
        try await execute(
            request: request,
            preparedRunID: runID,
            expectedRequestDigest: requestDigest,
            mapper: mapper
        )
    }

    private func execute(
        request: CorpusAnalysisRequest,
        preparedRunID: String?,
        expectedRequestDigest: String?,
        mapper: @escaping Mapper
    ) async throws -> CorpusAnalysisRunResult {
        let scopeJSON = try canonicalJSON(request.scope)
        let exactStrategy = "exact_revision_slice:characters=\(request.characterBudget)"
        let legacyStrategy = "part_range:characters=\(request.characterBudget)"
        let snapshot: CorpusAnalysisSnapshot
        let run: CorpusAnalysisRunRecord
        if let preparedRunID {
            guard let existing = try store.corpusAnalysis.fetchRun(
                matterID: request.matterID,
                id: preparedRunID
            ) else {
                throw CorpusAnalysisPreparationError.preparedRunMismatch("run identity")
            }
            guard existing.runKey == request.runKey,
                  existing.taskKind == request.taskKind.rawValue,
                  existing.scopeJSON == scopeJSON,
                  existing.partitionStrategy == exactStrategy,
                  existing.partitionStrategyVersion == 2,
                  existing.modelLineageJSON == request.modelLineageJSON,
                  existing.requestSchemaVersion == 2,
                  existing.requestDigest == expectedRequestDigest else {
                throw CorpusAnalysisPreparationError.preparedRunMismatch("frozen request")
            }
            snapshot = try decodeSnapshot(existing)
            if existing.status == CorpusAnalysisRunStatus.persisted.rawValue {
                return try persistedResult(existing)
            }
            if existing.status == CorpusAnalysisRunStatus.planning.rawValue {
                run = try store.corpusAnalysis.updateStatus(
                    matterID: request.matterID,
                    runID: existing.id,
                    to: .running
                )
            } else {
                run = try store.corpusAnalysis.prepareForResume(
                    matterID: request.matterID,
                    runID: existing.id,
                    maximumRetryCount: request.maximumRetryCount
                )
            }
        } else if let existing = try store.corpusAnalysis.fetchRun(
            matterID: request.matterID,
            runKey: request.runKey
        ) {
            guard existing.requestSchemaVersion != 2 else {
                throw CorpusAnalysisPreparationError.preparedRunMismatch(
                    "version 2 request digest"
                )
            }
            let exactStrategyMatches = existing.partitionStrategy == exactStrategy
                && existing.partitionStrategyVersion == 2
            let legacyStrategyMatches = existing.partitionStrategy == legacyStrategy
                && existing.partitionStrategyVersion == 1
            guard existing.taskKind == request.taskKind.rawValue,
                  existing.scopeJSON == scopeJSON,
                  (exactStrategyMatches || legacyStrategyMatches),
                  existing.modelLineageJSON == request.modelLineageJSON else {
                throw CorpusAnalysisEngineError.runKeyCollision(request.runKey)
            }
            if existing.status == CorpusAnalysisRunStatus.persisted.rawValue {
                return try persistedResult(existing)
            }
            snapshot = try decodeSnapshot(existing)
            run = try store.corpusAnalysis.prepareForResume(
                matterID: request.matterID,
                runID: existing.id,
                maximumRetryCount: request.maximumRetryCount
            )
        } else {
            let runID = UUID().uuidString
            let plan = try CorpusAnalysisExactPlanner(store: store).plan(
                request: request,
                runID: runID
            )
            let proposed = CorpusAnalysisRunRecord(
                id: runID,
                runKey: request.runKey,
                matterID: request.matterID,
                taskKind: request.taskKind.rawValue,
                scopeJSON: scopeJSON,
                corpusSnapshotJSON: try canonicalJSON(plan.snapshot),
                partitionStrategy: exactStrategy,
                partitionStrategyVersion: 2,
                modelLineageJSON: request.modelLineageJSON,
                status: CorpusAnalysisRunStatus.planning.rawValue
            )
            let prepared = try store.corpusAnalysis.createOrFetchPreparedRun(
                run: proposed,
                partitions: plan.partitions,
                slices: plan.slices
            )
            snapshot = plan.snapshot
            if prepared.status == CorpusAnalysisRunStatus.persisted.rawValue {
                return try persistedResult(prepared)
            }
            run = try store.corpusAnalysis.updateStatus(
                matterID: request.matterID,
                runID: prepared.id,
                to: .running
            )
        }

        do {
            let documents = try store.documentLibrary.fetchDocuments(matterID: request.matterID)
            let nameByID = try frozenDocumentNames(snapshot)
            let partitions = try store.corpusAnalysis.fetchPartitions(
                matterID: request.matterID,
                runID: run.id
            )
            let slicesByPartitionID = Dictionary(
                grouping: try store.corpusAnalysis.fetchSlices(
                    matterID: request.matterID,
                    runID: run.id
                ),
                by: \.partitionID
            )
            let requiresExactSlices = run.partitionStrategyVersion == 2
                && run.partitionStrategy.hasPrefix("exact_revision_slice")
            if requiresExactSlices {
                guard !partitions.isEmpty,
                      partitions.allSatisfy({ !(slicesByPartitionID[$0.id] ?? []).isEmpty }) else {
                    throw CorpusAnalysisEngineError.invalidPersistedJSON("exact slice ledger")
                }
            }
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
                        let input = try partitionInput(
                            attempt,
                            slices: slicesByPartitionID[attempt.id] ?? [],
                            requiresExactSlices: requiresExactSlices,
                            documentNames: nameByID
                        )
                        let output = try validated(
                            try await mapper(input),
                            against: input
                        )
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
            let excludedNames = snapshot.members
                .filter { $0.disposition == .excluded }
                .map(\.displayName)
                .sorted()
            let unfinishedImportStates: Set<String> = [
                DocumentImportSourceState.selected.rawValue,
                DocumentImportSourceState.discovered.rawValue,
                DocumentImportSourceState.validated.rawValue,
                DocumentImportSourceState.copying.rawValue,
                DocumentImportSourceState.interrupted.rawValue,
            ]
            let unfinishedImportMembers = snapshot.members.filter { member in
                member.disposition == .excluded
                    && member.documentID == nil
                    && member.indexState.map(unfinishedImportStates.contains) == true
            }
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
            let staleReasons = try stalenessReasons(
                snapshot: snapshot,
                request: request
            )
            let versionRelationReasons: [String]
            if DocumentRelationDownstreamPolicy.requiresReviewedRelations(for: request.taskKind) {
                let inScopeDocumentIDs = Set(snapshot.members.compactMap(\.documentID))
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
            } else if !unfinishedImportMembers.isEmpty {
                assurance = .corpusIncomplete
                reasons = unfinishedImportMembers.map { member in
                    let state = member.indexState ?? "not ready"
                    let detail = member.reason.flatMap { reason in
                        reason == state ? nil : " (\(reason))"
                    } ?? ""
                    return "Unfinished import \(member.displayName): \(state)\(detail)."
                }.sorted()
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
                snapshot: snapshot,
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

    private func partitionInput(
        _ partition: CorpusAnalysisPartitionRecord,
        slices: [CorpusAnalysisPartitionSliceRecord],
        requiresExactSlices: Bool,
        documentNames: [String: String]
    ) throws -> CorpusAnalysisPartitionInput {
        let sources: [CorpusAnalysisPartitionSource]
        if slices.isEmpty {
            guard !requiresExactSlices else {
                throw CorpusAnalysisEngineError.invalidPersistedJSON("exact slice ledger")
            }
            sources = try legacyPartitionSources(
                partition,
                documentNames: documentNames
            )
        } else {
            sources = try slices.sorted {
                if $0.ordinal != $1.ordinal { return $0.ordinal < $1.ordinal }
                return $0.id < $1.id
            }.map { slice in
                guard let revision = try store.documentRevisions.fetchRevision(id: slice.revisionID),
                      revision.documentID == slice.documentID,
                      revision.partIndex == slice.partIndex,
                      slice.charStart >= 0,
                      slice.charEnd > slice.charStart,
                      slice.charEnd <= revision.text.count,
                      slice.revisionCharCount == revision.text.count else {
                    throw CorpusAnalysisEngineError.revisionUnavailable(slice.revisionID)
                }
                let lower = revision.text.index(
                    revision.text.startIndex,
                    offsetBy: slice.charStart
                )
                let upper = revision.text.index(
                    revision.text.startIndex,
                    offsetBy: slice.charEnd
                )
                let text = String(revision.text[lower..<upper])
                guard CorpusAnalysisRequestDigest.sha256(Data(text.utf8)) == slice.textSHA256 else {
                    throw CorpusAnalysisEngineError.invalidPersistedJSON("slice text hash")
                }
                return CorpusAnalysisPartitionSource(
                    documentID: slice.documentID,
                    documentName: documentNames[slice.documentID] ?? "Document",
                    partIndex: slice.partIndex,
                    revisionID: slice.revisionID,
                    text: text,
                    locatorJSON: slice.locatorJSON
                )
            }
        }
        let groundingSources = sources.enumerated().map { index, source in
            let locator = source.locatorJSON.data(using: .utf8).flatMap {
                try? JSONDecoder().decode(DocumentSourceLocator.self, from: $0)
            }
            return GroundingSource(
                sourceID: "\(source.revisionID)#slice:\(index)",
                label: "E\(index + 1)",
                documentName: source.documentName,
                locatorDisplay: locator?.displayString ?? "source range",
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

    private func frozenDocumentNames(
        _ snapshot: CorpusAnalysisSnapshot
    ) throws -> [String: String] {
        var names: [String: String] = [:]
        for member in snapshot.members {
            guard let documentID = member.documentID else { continue }
            if let existing = names[documentID], existing != member.displayName {
                throw CorpusAnalysisEngineError.invalidPersistedJSON(
                    "snapshot document name identity"
                )
            }
            names[documentID] = member.displayName
        }
        return names
    }

    private func legacyPartitionSources(
        _ partition: CorpusAnalysisPartitionRecord,
        documentNames: [String: String]
    ) throws -> [CorpusAnalysisPartitionSource] {
        guard let data = partition.inputRevisionIDsJSON.data(using: .utf8),
              let revisionIDs = try? JSONDecoder().decode([String].self, from: data) else {
            throw CorpusAnalysisEngineError.invalidPersistedJSON("input revisions")
        }
        return try revisionIDs.map { revisionID in
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
    }

    private func validated(
        _ output: CorpusAnalysisMapOutput,
        against input: CorpusAnalysisPartitionInput
    ) throws -> CorpusAnalysisMapOutput {
        var findingIDs = Set<String>()
        let findings = try output.findings.map { finding -> CorpusAnalysisFinding in
            guard !finding.id.isEmpty,
                  findingIDs.insert(finding.id).inserted,
                  !(finding.evidence + finding.contraryEvidence).isEmpty else {
                throw CorpusAnalysisEngineError.invalidFindingEvidence(finding.id)
            }
            return CorpusAnalysisFinding(
                id: finding.id,
                value: finding.value,
                evidence: try finding.evidence.map {
                    try normalizedEvidence($0, findingID: finding.id, input: input)
                },
                contraryEvidence: try finding.contraryEvidence.map {
                    try normalizedEvidence($0, findingID: finding.id, input: input)
                }
            )
        }
        return CorpusAnalysisMapOutput(findings: findings)
    }

    private func normalizedEvidence(
        _ evidence: CorpusAnalysisEvidenceReference,
        findingID: String,
        input: CorpusAnalysisPartitionInput
    ) throws -> CorpusAnalysisEvidenceReference {
        let matchingSources = input.sources.filter { source in
            source.revisionID == evidence.revisionID
                && source.documentID == evidence.documentID
                && source.locatorJSON == evidence.locatorJSON
        }
        guard matchingSources.count == 1, let source = matchingSources.first else {
            throw CorpusAnalysisEngineError.invalidFindingEvidence(findingID)
        }

        let relativeRange: Range<Int>
        let resolvedQuote: String
        switch (evidence.charStart, evidence.charEnd, evidence.quote) {
        case let (start?, end?, quote):
            guard start >= 0, end > start, end <= source.text.count else {
                throw CorpusAnalysisEngineError.invalidFindingEvidence(findingID)
            }
            relativeRange = start..<end
            resolvedQuote = Self.substring(source.text, range: relativeRange)
            if let quote {
                guard !quote.isEmpty, quote == resolvedQuote else {
                    throw CorpusAnalysisEngineError.invalidFindingEvidence(findingID)
                }
            }
        case (nil, nil, let quote?):
            guard !quote.isEmpty,
                  let uniqueRange = Self.uniqueCharacterRange(of: quote, in: source.text) else {
                throw CorpusAnalysisEngineError.invalidFindingEvidence(findingID)
            }
            relativeRange = uniqueRange
            resolvedQuote = quote
        case (nil, nil, nil):
            // Compatibility for the original exact-slice schema: identifying a
            // single presented slice implies its full text. New prompts ask for
            // an exact quote or span, and the normalized checkpoint always stores
            // both after this boundary.
            relativeRange = 0..<source.text.count
            resolvedQuote = source.text
        default:
            throw CorpusAnalysisEngineError.invalidFindingEvidence(findingID)
        }

        return CorpusAnalysisEvidenceReference(
            documentID: evidence.documentID,
            revisionID: evidence.revisionID,
            locatorJSON: evidence.locatorJSON,
            quote: resolvedQuote,
            charStart: relativeRange.lowerBound,
            charEnd: relativeRange.upperBound
        )
    }

    private static func uniqueCharacterRange(
        of needle: String,
        in haystack: String
    ) -> Range<Int>? {
        var match: Range<String.Index>?
        var searchStart = haystack.startIndex
        while searchStart <= haystack.endIndex,
              let found = haystack.range(
                  of: needle,
                  range: searchStart..<haystack.endIndex
              ) {
            if match != nil { return nil }
            match = found
            guard found.lowerBound < haystack.endIndex else { break }
            searchStart = haystack.index(after: found.lowerBound)
        }
        guard let match else { return nil }
        return Range(
            uncheckedBounds: (
                lower: haystack.distance(from: haystack.startIndex, to: match.lowerBound),
                upper: haystack.distance(from: haystack.startIndex, to: match.upperBound)
            )
        )
    }

    private static func substring(_ value: String, range: Range<Int>) -> String {
        let lower = value.index(value.startIndex, offsetBy: range.lowerBound)
        let upper = value.index(value.startIndex, offsetBy: range.upperBound)
        return String(value[lower..<upper])
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

    private func stalenessReasons(
        snapshot: CorpusAnalysisSnapshot,
        request: CorpusAnalysisRequest
    ) throws -> [String] {
        var reasons: [String] = []
        let currentSnapshot = try CorpusAnalysisExactPlanner(store: store)
            .currentSnapshot(request: request)
        let frozenByKey = try snapshotMembersByKey(snapshot.members)
        let currentByKey = try snapshotMembersByKey(currentSnapshot.members)

        for memberKey in Set(frozenByKey.keys).subtracting(currentByKey.keys).sorted() {
            reasons.append("Snapshot member \(memberKey) is no longer in the analyzed scope.")
        }
        for memberKey in Set(currentByKey.keys).subtracting(frozenByKey.keys).sorted() {
            reasons.append("Snapshot member \(memberKey) entered the analyzed scope after it was frozen.")
        }
        for memberKey in Set(frozenByKey.keys).intersection(currentByKey.keys).sorted() {
            guard let frozen = frozenByKey[memberKey], let current = currentByKey[memberKey] else {
                continue
            }
            if frozen.documentID != current.documentID
                || frozen.revisionIDs != current.revisionIDs
                || frozen.indexState != current.indexState
                || frozen.disposition != current.disposition
                || frozen.reason != current.reason {
                reasons.append("Snapshot member \(memberKey) changed eligibility or revision lineage after it was frozen.")
            }
        }
        return reasons
    }

    private func snapshotMembersByKey(
        _ members: [CorpusAnalysisSnapshotMember]
    ) throws -> [String: CorpusAnalysisSnapshotMember] {
        var result: [String: CorpusAnalysisSnapshotMember] = [:]
        for member in members {
            guard result.updateValue(member, forKey: member.memberKey) == nil else {
                throw CorpusAnalysisEngineError.invalidPersistedJSON("snapshot member identity")
            }
        }
        return result
    }

    private func persistedResult(_ run: CorpusAnalysisRunRecord) throws -> CorpusAnalysisRunResult {
        let snapshot = try decodeSnapshot(run)
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

    private func decodeSnapshot(_ run: CorpusAnalysisRunRecord) throws -> CorpusAnalysisSnapshot {
        guard let data = run.corpusSnapshotJSON.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(CorpusAnalysisSnapshot.self, from: data) else {
            throw CorpusAnalysisEngineError.invalidPersistedJSON("snapshot")
        }
        return snapshot
    }

    private func canonicalJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
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
