import CryptoKit
import Foundation
import SupraCore
import SupraDocuments
import SupraStore

public struct ExhaustiveListRequest: Sendable {
    public var runKey: String
    public var matterID: String
    public var title: String
    public var query: String
    public var scope: CorpusAnalysisScope
    public var characterBudget: Int
    public var maximumRetryCount: Int
    /// Evaluation-only answer keys. They are never placed in a model prompt.
    public var evaluationExpectedItemKeys: [String]
    public var modelLineageJSON: String?

    public init(
        runKey: String,
        matterID: String,
        title: String,
        query: String,
        scope: CorpusAnalysisScope = .wholeMatter,
        characterBudget: Int = 24_000,
        maximumRetryCount: Int = 2,
        evaluationExpectedItemKeys: [String] = [],
        modelLineageJSON: String? = nil
    ) {
        self.runKey = runKey
        self.matterID = matterID
        self.title = title
        self.query = query
        self.scope = scope
        self.characterBudget = max(1, characterBudget)
        self.maximumRetryCount = max(0, maximumRetryCount)
        self.evaluationExpectedItemKeys = evaluationExpectedItemKeys
        self.modelLineageJSON = modelLineageJSON
    }
}

public struct ExhaustiveListGenerationInput: Sendable {
    public var partition: CorpusAnalysisPartitionInput
    public var prompt: String
}

public struct ExhaustiveListItem: Codable, Equatable, Sendable {
    public var itemKey: String
    public var values: [String]
    public var evidence: [CorpusAnalysisEvidenceReference]
    public var contraryEvidence: [CorpusAnalysisEvidenceReference]

    private enum CodingKeys: String, CodingKey {
        case itemKey = "item_key"
        case values
        case evidence
        case contraryEvidence = "contrary_evidence"
    }
}

public struct ExhaustiveListOmission: Codable, Equatable, Sendable {
    public var itemKey: String
    public var reason: String

    private enum CodingKeys: String, CodingKey {
        case itemKey = "item_key"
        case reason
    }
}

public struct ExhaustiveListMetrics: Codable, Equatable, Sendable {
    public var expectedCount: Int
    public var emittedCount: Int
    public var truePositiveCount: Int
    public var recall: Double
    public var precision: Double
    public var duplicateCount: Int
    public var conflictCount: Int
    public var unexpectedItemKeys: [String]

    private enum CodingKeys: String, CodingKey {
        case expectedCount = "expected_count"
        case emittedCount = "emitted_count"
        case truePositiveCount = "true_positive_count"
        case recall
        case precision
        case duplicateCount = "duplicate_count"
        case conflictCount = "conflict_count"
        case unexpectedItemKeys = "unexpected_item_keys"
    }
}

public struct ExhaustiveListResult: Sendable {
    public var run: CorpusAnalysisRunRecord
    public var coverage: CorpusAnalysisCoverage
    public var partitions: [CorpusAnalysisPartitionRecord]
    public var outputID: String
    public var version: StructuredOutputVersionRecord
    public var items: [ExhaustiveListItem]
    public var omissions: [ExhaustiveListOmission]
    public var metrics: ExhaustiveListMetrics
}

public struct CorpusNegativeDecision: Equatable, Sendable {
    public var allowed: Bool
    public var assuranceState: OutputAssuranceState
    public var reasons: [String]
}

public enum CorpusNegativeGate {
    public static func evaluate(
        run: CorpusAnalysisRunRecord,
        coverage: CorpusAnalysisCoverage,
        positiveFindingCount: Int
    ) -> CorpusNegativeDecision {
        var reasons: [String] = []
        if positiveFindingCount > 0 {
            reasons.append("The exhaustive run found \(positiveFindingCount) positive item(s).")
        }
        if run.assuranceState != OutputAssuranceState.corpusComplete.rawValue
            || coverage.pendingPartitionCount > 0
            || coverage.failedPartitionCount > 0
            || coverage.cancelledPartitionCount > 0
            || coverage.balanceErrorCount > 0 {
            reasons.append(
                "The corpus is incomplete: failed=\(coverage.failedPartitionCount), "
                    + "cancelled=\(coverage.cancelledPartitionCount), "
                    + "pending=\(coverage.pendingPartitionCount), "
                    + "balance_errors=\(coverage.balanceErrorCount)."
            )
        }
        if reasons.isEmpty {
            return CorpusNegativeDecision(allowed: true, assuranceState: .corpusComplete, reasons: [])
        }
        return CorpusNegativeDecision(
            allowed: false,
            assuranceState: .negativeBlocked,
            reasons: reasons
        )
    }
}

/// First task-specific consumer of the generic coverage ledger. The generator
/// returns raw model text so this layer, not a permissive model adapter, owns the
/// strict schema boundary and response-digest failure record.
public final class ExhaustiveListTask: @unchecked Sendable {
    public typealias Generator = @Sendable (ExhaustiveListGenerationInput) async throws -> String

    public static let schemaVersion = 1
    public static let verificationVersion = "exhaustive-list-v1"
    public static let promptBuilderVersion = "exhaustive-list-v1"

    private let store: SupraStore

    public init(store: SupraStore) {
        self.store = store
    }

    public func run(
        request: ExhaustiveListRequest,
        generator: @escaping Generator
    ) async throws -> ExhaustiveListResult {
        guard let resolvedModelLineage = DocumentGenerationModelLineage.decode(
            json: request.modelLineageJSON
        ) else {
            throw DocumentGenerationLineageError.stableModelIdentityUnavailable
        }
        let promptCollector = PromptCollector()
        let engineResult = try await CorpusAnalysisEngine(store: store).run(
            request: CorpusAnalysisRequest(
                runKey: request.runKey,
                matterID: request.matterID,
                taskKind: .exhaustiveList,
                scope: request.scope,
                characterBudget: request.characterBudget,
                maximumRetryCount: request.maximumRetryCount,
                modelLineageJSON: request.modelLineageJSON
            )
        ) { partition in
            let prompt = Self.prompt(query: request.query, partition: partition)
            promptCollector.append(prompt)
            let raw = try await generator(ExhaustiveListGenerationInput(
                partition: partition,
                prompt: prompt
            ))
            return try Self.decodeMapResponse(raw)
        }

        let reconciliation = Self.reconcile(
            findings: engineResult.findings,
            expectedKeys: request.evaluationExpectedItemKeys
        )
        var taskRun = engineResult.run
        if taskRun.assuranceState == OutputAssuranceState.corpusComplete.rawValue,
           !reconciliation.omissions.isEmpty {
            taskRun = try store.corpusAnalysis.finalizeRun(
                matterID: request.matterID,
                runID: taskRun.id,
                assuranceState: .corpusIncomplete,
                assuranceReasons: [
                    "Evaluation keys identify omitted items: "
                        + reconciliation.omissions.map(\.itemKey).joined(separator: ", ") + ".",
                ],
                exclusionsDisclosed: true
            )
        }
        let disclosures = try failedPartitionDisclosures(
            partitions: engineResult.partitions,
            snapshot: engineResult.snapshot
        )
        let reconciliationRecord = ExhaustiveListReconciliationRecord(
            items: reconciliation.items,
            omissions: reconciliation.omissions,
            metrics: reconciliation.metrics,
            failedPartitions: disclosures,
            excludedMembers: engineResult.snapshot.members
                .filter { $0.disposition == .excluded }
                .map { .init(name: $0.displayName, reason: $0.reason ?? "excluded") }
        )
        var run = try store.corpusAnalysis.saveReconciliation(
            matterID: request.matterID,
            runID: taskRun.id,
            reconciliationJSON: try Self.canonicalJSON(reconciliationRecord),
            validationResultsJSON: try Self.canonicalJSON(ExhaustiveListValidationRecord(
                schemaInvalidPartitionCount: engineResult.partitions.count {
                    $0.dispositionReason == "schema_invalid"
                },
                metrics: reconciliation.metrics
            ))
        )

        if let attachedVersionID = run.structuredOutputVersionID,
           let version = try store.structuredOutputs.fetchVersion(id: attachedVersionID),
           let output = try store.structuredOutputs.fetchOutputs(matterID: request.matterID)
            .first(where: { $0.id == version.structuredOutputID }) {
            return ExhaustiveListResult(
                run: run,
                coverage: engineResult.coverage,
                partitions: engineResult.partitions,
                outputID: output.id,
                version: version,
                items: reconciliation.items,
                omissions: reconciliation.omissions,
                metrics: reconciliation.metrics
            )
        }

        let material = try evidenceMaterial(for: reconciliation.items)
        let needsReview = taskRun.assuranceState != OutputAssuranceState.corpusComplete.rawValue
            || reconciliation.items.isEmpty
            || !reconciliation.omissions.isEmpty
            || !reconciliation.metrics.unexpectedItemKeys.isEmpty
            || reconciliation.metrics.conflictCount > 0
            || reconciliation.items.contains { !$0.contraryEvidence.isEmpty }
        let verificationStatus: OutputVerificationStatus = needsReview ? .needsReview : .allSupported
        let outputStatus: StructuredOutputStatus = needsReview ? .needsReview : .complete
        let markdown = Self.markdown(
            title: request.title,
            assuranceState: OutputAssuranceState(rawValue: taskRun.assuranceState ?? "") ?? .corpusIncomplete,
            coverage: engineResult.coverage,
            reconciliation: reconciliationRecord,
            labels: material.labelByEvidence
        )
        let outputID = UUID().uuidString
        let packingReport = DocumentSourceLineageBuilder.report(
            summary: nil,
            candidates: material.sources.enumerated().map { index, source in
                let label = material.labelByEvidence[source.reference] ?? "E\(index + 1)"
                return .init(
                    sourceID: Self.evidenceSourceID(matterID: request.matterID, reference: source.reference),
                    label: label,
                    rank: index + 1,
                    originalText: source.excerpt,
                    packedText: source.excerpt
                )
            }
        )
        let lineage = try DocumentSourceLineageBuilder.make(
            store: store,
            matterID: request.matterID,
            scope: RetrievalScope(documentIDs: request.scope.documentIDs),
            configuration: DocumentRetrievalConfiguration(
                mode: DocumentSourceSetMode.exhaustive.rawValue,
                candidateLimit: engineResult.coverage.eligibleMemberCount,
                packedLimit: material.sources.count,
                characterBudget: request.characterBudget
            ),
            packingReport: packingReport
        )
        let sourceSet = DocumentSourceSetRecord(
            matterID: request.matterID,
            mode: DocumentSourceSetMode.exhaustive.rawValue,
            scopeJSON: try Self.canonicalJSON(request.scope),
            retrievalQuery: request.query,
            packingReportJSON: lineage.packingReportJSON,
            embeddingModelID: lineage.embeddingModelID,
            embeddingModelRevision: lineage.embeddingModelRevision,
            chunkerVersion: lineage.chunkerVersion,
            retrievalConfigJSON: lineage.retrievalConfigJSON,
            corpusSnapshotHash: lineage.corpusSnapshotHash
        )
        let outputSources = material.sources.enumerated().map { index, source in
            DocumentOutputSourceRecord(
                sourceSetID: sourceSet.id,
                documentID: source.reference.documentID,
                revisionID: source.reference.revisionID,
                citationLabel: material.labelByEvidence[source.reference] ?? "E\(index + 1)",
                locatorJSON: source.reference.locatorJSON,
                excerpt: source.excerpt,
                rank: index + 1
            )
        }
        let generation = try store.generation.createDocumentGenerationSession(
                    modelRepository: resolvedModelLineage.modelRepository,
                    modelRevision: resolvedModelLineage.modelRevision,
                    promptBuilderVersion: Self.promptBuilderVersion,
                    prompt: promptCollector.joined(or: request.query),
                    optionsJSON: try Self.canonicalJSON(GenerationAuditOptions(
                        characterBudget: request.characterBudget,
                        maximumRetryCount: request.maximumRetryCount,
                        taskKind: CorpusAnalysisTaskKind.exhaustiveList.rawValue
                    ))
                )
        let verificationResults = try supportResults(
            items: reconciliation.items,
            material: material
        )
        let version = try store.structuredOutputs.createVersionWithSourceSetAtomically(
            structuredOutputID: outputID,
            newOutput: StructuredOutputRecord(
                id: outputID,
                matterID: request.matterID,
                title: request.title,
                outputType: StructuredOutputType.documentExhaustiveList.rawValue,
                status: StructuredOutputStatus.draft.rawValue
            ),
            sourceSet: sourceSet,
            outputSources: outputSources,
            contentMarkdown: markdown,
            verificationStatus: verificationStatus,
            verificationVersion: Self.verificationVersion,
            verificationResults: verificationResults,
            verificationDimensions: VerificationDimensionsMapper.dimensions(
                verificationResults: verificationResults
            ),
            outputStatus: outputStatus,
            corpusAnalysisRunID: run.id,
            generationSessionID: generation.id,
            promptBuilderVersion: Self.promptBuilderVersion
        )
        run = try store.corpusAnalysis.fetchRun(matterID: request.matterID, id: run.id) ?? run
        return ExhaustiveListResult(
            run: run,
            coverage: engineResult.coverage,
            partitions: engineResult.partitions,
            outputID: outputID,
            version: version,
            items: reconciliation.items,
            omissions: reconciliation.omissions,
            metrics: reconciliation.metrics
        )
    }

    private static func evidenceSourceID(
        matterID: String,
        reference: CorpusAnalysisEvidenceReference
    ) -> String {
        [matterID, reference.documentID, reference.revisionID, reference.locatorJSON]
            .joined(separator: "/")
    }

    private static func prompt(
        query: String,
        partition: CorpusAnalysisPartitionInput
    ) -> String {
        """
        TASK: \(query)
        Return only strict JSON with this schema:
        {"schema_version":1,"items":[{"item_key":"stable-key","value":"literal value","evidence":[{"document_id":"...","revision_id":"...","locator_json":"..."}],"contrary_evidence":[]}]}
        Every emitted item requires at least one exact evidence reference from the source envelope.
        \(partition.promptEnvelope)
        """
    }

    private struct GenerationAuditOptions: Codable, Sendable {
        var characterBudget: Int
        var maximumRetryCount: Int
        var taskKind: String

        private enum CodingKeys: String, CodingKey {
            case characterBudget = "character_budget"
            case maximumRetryCount = "maximum_retry_count"
            case taskKind = "task_kind"
        }
    }

    private final class PromptCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var prompts: [String] = []

        func append(_ prompt: String) {
            lock.withLock { prompts.append(prompt) }
        }

        func joined(or fallback: String) -> String {
            lock.withLock {
                prompts.isEmpty
                    ? fallback
                    : prompts.joined(separator: "\n\n--- prompt boundary ---\n\n")
            }
        }
    }

    private static func decodeMapResponse(_ raw: String) throws -> CorpusAnalysisMapOutput {
        do {
            let response = try JSONDecoder().decode(
                ExhaustiveListMapResponse.self,
                from: Data(raw.utf8)
            )
            guard response.schemaVersion == schemaVersion else {
                throw ExhaustiveListSchemaError.invalidSchemaVersion
            }
            var keys = Set<String>()
            let findings = try response.items.map { item -> CorpusAnalysisFinding in
                let key = canonicalKey(item.itemKey)
                let value = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty, !value.isEmpty, !item.evidence.isEmpty else {
                    throw ExhaustiveListSchemaError.emptyRequiredField
                }
                guard keys.insert(key).inserted else {
                    throw ExhaustiveListSchemaError.duplicateItemKey
                }
                return CorpusAnalysisFinding(
                    id: key,
                    value: value,
                    evidence: item.evidence,
                    contraryEvidence: item.contraryEvidence
                )
            }
            return CorpusAnalysisMapOutput(findings: findings)
        } catch {
            let digest = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
            throw CorpusAnalysisMapFailure.schemaInvalid(
                responseDigest: digest,
                summary: "The exhaustive-list mapper response failed schema v1 validation"
            )
        }
    }

    private static func reconcile(
        findings: [CorpusAnalysisFinding],
        expectedKeys: [String]
    ) -> ExhaustiveListReconciliation {
        let grouped = Dictionary(grouping: findings, by: { canonicalKey($0.id) })
        var duplicateCount = 0
        let items = grouped.keys.sorted().map { key -> ExhaustiveListItem in
            let group = grouped[key, default: []]
            let values = Array(Set(group.map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) })).sorted()
            let valueGroups = Dictionary(grouping: group, by: { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) })
            duplicateCount += valueGroups.values.reduce(0) { $0 + max(0, $1.count - 1) }
            return ExhaustiveListItem(
                itemKey: key,
                values: values,
                evidence: Array(Set(group.flatMap(\.evidence))).sorted(by: evidenceLessThan),
                contraryEvidence: Array(Set(group.flatMap(\.contraryEvidence))).sorted(by: evidenceLessThan)
            )
        }
        let found = Set(items.map(\.itemKey))
        let expected = Set(expectedKeys.map(canonicalKey).filter { !$0.isEmpty })
        let evaluated = !expected.isEmpty
        let truePositives = found.intersection(expected)
        let omissions = evaluated
            ? expected.subtracting(found).sorted().map {
                ExhaustiveListOmission(
                    itemKey: $0,
                    reason: "not_emitted_by_any_successful_partition"
                )
            }
            : []
        let unexpected = evaluated ? found.subtracting(expected).sorted() : []
        return ExhaustiveListReconciliation(
            items: items,
            omissions: omissions,
            metrics: ExhaustiveListMetrics(
                expectedCount: expected.count,
                emittedCount: found.count,
                truePositiveCount: truePositives.count,
                recall: evaluated ? Double(truePositives.count) / Double(expected.count) : 1,
                precision: evaluated
                    ? (found.isEmpty ? 0 : Double(truePositives.count) / Double(found.count))
                    : 1,
                duplicateCount: duplicateCount,
                conflictCount: items.count { $0.values.count > 1 },
                unexpectedItemKeys: unexpected
            )
        )
    }

    private func failedPartitionDisclosures(
        partitions: [CorpusAnalysisPartitionRecord],
        snapshot: CorpusAnalysisSnapshot
    ) throws -> [ExhaustiveListFailedPartition] {
        let nameByRevision = Dictionary(uniqueKeysWithValues: snapshot.members.flatMap { member in
            member.revisionIDs.map { ($0, member.displayName) }
        })
        return try partitions.filter {
            $0.disposition == CorpusAnalysisPartitionDisposition.failed.rawValue
        }.map { partition in
            let revisionIDs = try JSONDecoder().decode(
                [String].self,
                from: Data(partition.inputRevisionIDsJSON.utf8)
            )
            let names = Array(Set(revisionIDs.compactMap { nameByRevision[$0] })).sorted()
            return ExhaustiveListFailedPartition(
                partitionKey: partition.partitionKey,
                documentNames: names,
                reason: partition.dispositionReason ?? "failed",
                errorSummary: partition.errorSummary ?? "No error summary was recorded."
            )
        }.sorted { $0.partitionKey < $1.partitionKey }
    }

    private func evidenceMaterial(for items: [ExhaustiveListItem]) throws -> ExhaustiveListEvidenceMaterial {
        let references = Array(Set(items.flatMap { $0.evidence + $0.contraryEvidence }))
            .sorted(by: Self.evidenceLessThan)
        var sources: [ExhaustiveListEvidenceSource] = []
        var labels: [CorpusAnalysisEvidenceReference: String] = [:]
        for (index, reference) in references.enumerated() {
            guard let revision = try store.documentRevisions.fetchRevision(id: reference.revisionID),
                  revision.documentID == reference.documentID else {
                throw CorpusAnalysisEngineError.revisionUnavailable(reference.revisionID)
            }
            labels[reference] = "E\(index + 1)"
            sources.append(ExhaustiveListEvidenceSource(
                reference: reference,
                excerpt: DocumentChunker.excerpt(revision.text)
            ))
        }
        return ExhaustiveListEvidenceMaterial(sources: sources, labelByEvidence: labels)
    }

    private func supportResults(
        items: [ExhaustiveListItem],
        material: ExhaustiveListEvidenceMaterial
    ) throws -> [PropositionSupportResult] {
        let excerptByReference = Dictionary(uniqueKeysWithValues: material.sources.map {
            ($0.reference, $0.excerpt)
        })
        return try items.map { item in
            try PropositionSupportResult(
                propositionID: item.itemKey,
                status: .supported,
                reasons: item.values.count > 1 ? ["Conflicting values require review."] : [],
                evidence: item.evidence.map { reference in
                    SupportEvidence(
                        sourceID: reference.revisionID,
                        sourceLabel: material.labelByEvidence[reference] ?? "Evidence",
                        locator: reference.locatorJSON,
                        retainedExcerpt: excerptByReference[reference] ?? "Evidence retained in source set.",
                        verifierName: "ExhaustiveListTask",
                        verifierVersion: Self.verificationVersion
                    )
                },
                timestamp: Date()
            )
        }
    }

    private static func markdown(
        title: String,
        assuranceState: OutputAssuranceState,
        coverage: CorpusAnalysisCoverage,
        reconciliation: ExhaustiveListReconciliationRecord,
        labels: [CorpusAnalysisEvidenceReference: String]
    ) -> String {
        var lines = [
            "# \(title)",
            "",
            "Assurance: \(assuranceState.rawValue)",
            "Coverage: \(coverage.succeededPartitionCount)/\(coverage.partitionCount) partitions succeeded; failed \(coverage.failedPartitionCount); cancelled \(coverage.cancelledPartitionCount); pending \(coverage.pendingPartitionCount).",
            "",
            "## Items",
        ]
        if reconciliation.items.isEmpty {
            lines.append("No validated items were emitted.")
        } else {
            for item in reconciliation.items {
                let citations = item.evidence.compactMap { labels[$0] }.map { "[\($0)]" }.joined(separator: " ")
                lines.append("- **\(item.itemKey)** — \(item.values.joined(separator: " | ")) \(citations)")
            }
        }
        lines += ["", "## Omissions"]
        lines += reconciliation.omissions.isEmpty
            ? ["None recorded against the evaluation key set."]
            : reconciliation.omissions.map { "- \($0.itemKey): \($0.reason)" }
        lines += ["", "## Conflicts and contrary evidence"]
        let conflictLines = reconciliation.items.compactMap { item -> String? in
            guard item.values.count > 1 || !item.contraryEvidence.isEmpty else { return nil }
            let contrary = item.contraryEvidence.compactMap { labels[$0] }.map { "[\($0)]" }.joined(separator: " ")
            return "- \(item.itemKey): values \(item.values.joined(separator: " | ")); contrary \(contrary.isEmpty ? "none" : contrary)"
        }
        lines += conflictLines.isEmpty ? ["None recorded."] : conflictLines
        lines += ["", "## Excluded corpus members"]
        lines += reconciliation.excludedMembers.isEmpty
            ? ["None."]
            : reconciliation.excludedMembers.map { "- \($0.name): \($0.reason)" }
        lines += ["", "## Failed partitions"]
        lines += reconciliation.failedPartitions.isEmpty
            ? ["None."]
            : reconciliation.failedPartitions.map {
                "- \($0.documentNames.isEmpty ? $0.partitionKey : $0.documentNames.joined(separator: ", ")): \($0.reason); \($0.errorSummary)"
            }
        return lines.joined(separator: "\n")
    }

    private static func canonicalKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func evidenceLessThan(
        _ lhs: CorpusAnalysisEvidenceReference,
        _ rhs: CorpusAnalysisEvidenceReference
    ) -> Bool {
        (lhs.documentID, lhs.revisionID, lhs.locatorJSON)
            < (rhs.documentID, rhs.revisionID, rhs.locatorJSON)
    }

    private static func canonicalJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

private struct ExhaustiveListMapResponse: Decodable {
    var schemaVersion: Int
    var items: [ExhaustiveListMapItem]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case items
    }
}

private struct ExhaustiveListMapItem: Decodable {
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        itemKey = try container.decode(String.self, forKey: .itemKey)
        value = try container.decode(String.self, forKey: .value)
        evidence = try container.decode([CorpusAnalysisEvidenceReference].self, forKey: .evidence)
        contraryEvidence = try container.decodeIfPresent(
            [CorpusAnalysisEvidenceReference].self,
            forKey: .contraryEvidence
        ) ?? []
    }
}

private enum ExhaustiveListSchemaError: Error {
    case invalidSchemaVersion
    case emptyRequiredField
    case duplicateItemKey
}

private struct ExhaustiveListReconciliation {
    var items: [ExhaustiveListItem]
    var omissions: [ExhaustiveListOmission]
    var metrics: ExhaustiveListMetrics
}

private struct ExhaustiveListReconciliationRecord: Codable {
    var schemaVersion = 1
    var items: [ExhaustiveListItem]
    var omissions: [ExhaustiveListOmission]
    var metrics: ExhaustiveListMetrics
    var failedPartitions: [ExhaustiveListFailedPartition]
    var excludedMembers: [ExhaustiveListExcludedMember]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case items
        case omissions
        case metrics
        case failedPartitions = "failed_partitions"
        case excludedMembers = "excluded_members"
    }
}

private struct ExhaustiveListValidationRecord: Codable {
    var schemaVersion = 1
    var schemaInvalidPartitionCount: Int
    var metrics: ExhaustiveListMetrics

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case schemaInvalidPartitionCount = "schema_invalid_partition_count"
        case metrics
    }
}

private struct ExhaustiveListFailedPartition: Codable {
    var partitionKey: String
    var documentNames: [String]
    var reason: String
    var errorSummary: String

    private enum CodingKeys: String, CodingKey {
        case partitionKey = "partition_key"
        case documentNames = "document_names"
        case reason
        case errorSummary = "error_summary"
    }
}

private struct ExhaustiveListExcludedMember: Codable {
    var name: String
    var reason: String
}

private struct ExhaustiveListEvidenceSource {
    var reference: CorpusAnalysisEvidenceReference
    var excerpt: String
}

private struct ExhaustiveListEvidenceMaterial {
    var sources: [ExhaustiveListEvidenceSource]
    var labelByEvidence: [CorpusAnalysisEvidenceReference: String]
}
