import Foundation
import SupraCore
import SupraDocuments
import SupraStore

/// The complete controller-domain input required to publish one grounded chat
/// answer. This remains content-bearing only in memory; the Store receipt is
/// content-free and owns the terminal transaction.
struct GroundedChatTerminalPublicationRequest: Sendable {
    var matterID: String
    var question: String
    var answerText: String
    var terminalContent: String
    var context: GroundedChatContext
    var verification: DocumentSupportReport?
    var chatID: String
    var assistant: MessageRecord
    var variant: MessageVariantRecord
    var session: GenerationSessionRecord
    var metrics: StoredRuntimeMetrics
}

struct GroundedChatTerminalPublicationResult: Sendable {
    var receipt: GroundedChatTerminalPublicationReceipt
    var citations: [MessageCitation]
}

/// Forms the complete source-bearing aggregate in memory and crosses the Store's
/// single all-or-nothing publication boundary. UI/controller code must not
/// reconstruct any subset of this command independently.
struct GroundedChatTerminalPublicationUseCase: Sendable {
    private let store: SupraStore

    init(store: SupraStore) {
        self.store = store
    }

    func publish(
        _ request: GroundedChatTerminalPublicationRequest,
        cancellationCheck: @Sendable () -> Bool = { false }
    ) throws -> GroundedChatTerminalPublicationResult {
        let context = request.context
        guard !request.matterID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !context.sources.isEmpty,
              let packingReport = context.sourceSetPackingReport,
              let scope = context.sourceScope,
              let configuration = context.retrievalConfiguration else {
            throw GroundedChatTerminalPublicationError.invalidCommand(
                "grounded context lineage"
            )
        }
        let lineage = try DocumentSourceLineageBuilder.make(
            store: store,
            matterID: request.matterID,
            scope: scope,
            configuration: configuration,
            packingReport: packingReport
        )
        // GRDB's database date encoding retains millisecond precision. Canonicalize
        // before hashing so the command and its persisted reconstruction are exact.
        let publicationDate = Date(
            timeIntervalSinceReferenceDate: floor(
                request.assistant.createdAt.timeIntervalSinceReferenceDate * 1_000
            ) / 1_000
        )
        let sourceSet = DocumentSourceSetRecord(
            id: "grounded-chat-source-set:\(request.assistant.id)",
            matterID: request.matterID,
            mode: DocumentSourceSetMode.autoSource.rawValue,
            scopeJSON: try Self.canonicalJSON(scope),
            retrievalQuery: request.question,
            retrievalDepth: context.depth.rawValue,
            packingReportJSON: lineage.packingReportJSON,
            embeddingModelID: lineage.embeddingModelID,
            embeddingModelRevision: lineage.embeddingModelRevision,
            chunkerVersion: lineage.chunkerVersion,
            retrievalConfigJSON: lineage.retrievalConfigJSON,
            corpusSnapshotHash: lineage.corpusSnapshotHash,
            messageID: request.assistant.id,
            createdAt: publicationDate
        )
        var rows = context.sources.enumerated().map { index, source in
            DocumentOutputSourceRecord(
                id: "grounded-chat-source:\(request.assistant.id):\(index)",
                sourceSetID: sourceSet.id,
                documentID: source.documentID,
                chunkID: source.chunkID,
                revisionID: source.revisionID,
                citationLabel: source.label,
                locatorJSON: source.locator.encodedJSON(),
                excerpt: source.excerpt,
                rank: index,
                createdAt: publicationDate
            )
        }

        // The verifier reasons over retrieval identities (matter/chunk); terminal
        // evidence is rebound to the exact output-source rows the receipt owns.
        let rowByLabel = Dictionary(
            rows.map { ($0.citationLabel, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let normalizedResults = try (request.verification?.results ?? []).map { result in
            let evidence = try result.evidence.map { item -> SupportEvidence in
                guard let row = rowByLabel[item.sourceLabel],
                      context.sources.contains(where: {
                          $0.label == item.sourceLabel && $0.sourceID == item.sourceID
                      }) else {
                    throw GroundedChatTerminalPublicationError.invalidCommand(
                        "verification evidence"
                    )
                }
                return SupportEvidence(
                    sourceID: row.id,
                    sourceLabel: row.citationLabel,
                    locator: row.locatorJSON,
                    retainedExcerpt: item.retainedExcerpt,
                    verifierName: item.verifierName,
                    verifierVersion: item.verifierVersion
                )
            }
            return try PropositionSupportResult(
                propositionID: result.propositionID,
                status: result.status,
                reasons: result.reasons,
                evidence: evidence,
                timestamp: result.timestamp
            )
        }
        let verificationJSON = try Self.canonicalDateJSON(normalizedResults)
        for index in rows.indices {
            rows[index].warningsJSON = verificationJSON
        }

        let answerLabels = Self.citationLabels(in: request.answerText)
        let terminalLabels = Self.citationLabels(in: request.terminalContent)
        guard terminalLabels.allSatisfy({ rowByLabel[$0] != nil }) else {
            throw GroundedChatTerminalPublicationError.invalidCommand(
                "terminal citation labels"
            )
        }
        let citationRecords = rows.compactMap { row -> MessageCitationRecord? in
            guard terminalLabels.contains(row.citationLabel),
                  let source = context.sources.first(where: {
                      $0.label == row.citationLabel
                  }) else { return nil }
            return MessageCitationRecord(
                id: "grounded-chat-citation:\(request.assistant.id):\(row.rank)",
                messageID: request.assistant.id,
                label: row.citationLabel,
                kind: MessageCitation.Kind.source.rawValue,
                documentID: row.documentID,
                locatorJSON: row.locatorJSON,
                displayName: source.documentName,
                matchText: row.excerpt,
                rank: row.rank,
                createdAt: publicationDate
            )
        }

        let usedLabels = request.verification?.usedLabels ?? rows.compactMap {
            answerLabels.contains($0.citationLabel) ? $0.citationLabel : nil
        }
        let unresolvedLabels = request.verification?.unresolvedLabels ?? usedLabels.filter {
            rowByLabel[$0] == nil
        }
        let mappedDimensions = VerificationDimensionsMapper.dimensions(
            verificationResults: normalizedResults,
            usedLabels: usedLabels,
            unresolvedLabels: unresolvedLabels,
            warnings: request.verification?.warnings
                ?? ["Grounded verification did not complete."]
        )
        let exactDimensions = try VerificationDimensions(
            schemaVersion: mappedDimensions.schemaVersion,
            results: mappedDimensions.results.map { result in
                let exactEvidence = try result.evidence.map {
                    item -> VerificationDimensionEvidence in
                    guard let row = rowByLabel[item.sourceLabel ?? ""],
                          row.id == item.sourceID else {
                        throw GroundedChatTerminalPublicationError.invalidCommand(
                            "verification dimension evidence"
                        )
                    }
                    return VerificationDimensionEvidence(
                        sourceID: row.id,
                        sourceLabel: row.citationLabel,
                        locator: row.locatorJSON,
                        excerpt: row.excerpt
                    )
                }
                let evidence = Array(Set(exactEvidence)).sorted {
                    ($0.sourceLabel ?? "", $0.sourceID)
                        < ($1.sourceLabel ?? "", $1.sourceID)
                }
                if result.dimension == .criticalValueFidelity,
                   result.status == .notRun {
                    return VerificationDimensionResult(
                        dimension: result.dimension,
                        status: .failed,
                        reason: "Critical-value fidelity was not established.",
                        evidence: evidence
                    )
                }
                return VerificationDimensionResult(
                    dimension: result.dimension,
                    status: result.status,
                    reason: result.reason,
                    evidence: evidence
                )
            }
        )
        let assurance = Self.groundedAssurance(
            depth: context.depth,
            verificationStatus: request.verification?.verificationStatus
        )
        let authorizationEvidence = try Self.canonicalJSON([
            "basis": "local_matter_documents",
            "policy_version": "grounded-chat-terminal-v1",
            "scope": "matter_chat",
        ])
        let auditMetadata = try Self.canonicalJSON([
            "schema_version": "1",
            "retrieval_depth": context.depth.rawValue,
            "source_count": String(rows.count),
            "citation_count": String(citationRecords.count),
        ])
        let audit = AuditEventRecord(
            id: "grounded-chat-audit:\(request.assistant.id)",
            matterID: request.matterID,
            timestamp: publicationDate,
            eventType: "grounded_chat_terminal_published",
            actor: "local_grounded_chat_controller",
            summary: "Published a grounded matter-chat terminal aggregate.",
            relatedTable: "messages",
            relatedID: request.assistant.id,
            metadataJSON: auditMetadata
        )
        let command = GroundedChatTerminalPublicationCommand(
            idempotencyKey: "grounded-chat-terminal-v1:\(request.assistant.id):\(request.variant.id):\(request.session.id)",
            matterID: request.matterID,
            chatID: request.chatID,
            messageID: request.assistant.id,
            variantID: request.variant.id,
            generationSessionID: request.session.id,
            terminalContent: request.terminalContent,
            runtimeMetrics: request.metrics,
            sourceSet: sourceSet,
            orderedSources: rows,
            citations: citationRecords,
            verificationDimensions: exactDimensions,
            assuranceState: assurance,
            authorizationEvidenceJSON: authorizationEvidence,
            auditEvent: audit
        )
        let receipt = try store.groundedChatPublications.finalize(
            command,
            cancellationCheck: cancellationCheck
        )
        return GroundedChatTerminalPublicationResult(
            receipt: receipt,
            citations: citationRecords.map(MessageCitation.init)
        )
    }

    private static func groundedAssurance(
        depth: RetrievalDepth,
        verificationStatus: OutputVerificationStatus?
    ) -> OutputAssuranceState {
        if depth == .fast { return .preliminary }
        return verificationStatus == .allSupported
            ? .propositionSupported
            : .supportNeedsReview
    }

    private static func canonicalJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func canonicalDateJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = DateCoding.encoder
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func citationLabels(in text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(
            pattern: #"\[([AS]\d{1,3})\]"#
        ) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var labels: Set<String> = []
        for match in regex.matches(in: text, range: range) {
            if let labelRange = Range(match.range(at: 1), in: text) {
                labels.insert(String(text[labelRange]))
            }
        }
        return labels
    }
}
