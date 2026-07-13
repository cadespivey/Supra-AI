import Foundation

/// The only permitted proposition-level support decisions. Unknown, incomplete,
/// or ambiguous source material is `unverifiable`, never `supported`.
public enum PropositionSupportStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case supported
    case unsupported
    case unverifiable
}

/// Aggregate verification state persisted with a structured-output version.
public enum OutputVerificationStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case legacyUnverified = "legacy_unverified"
    case allSupported = "all_supported"
    case needsReview = "needs_review"
}

/// A material proposition extracted from generated output. Offsets use the
/// caller's chosen string coordinate system and are half-open (`lower..<upper`).
public struct CitedProposition: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let text: String
    public let citationLabels: [String]
    public let outputRange: Range<Int>

    public init(
        id: String,
        text: String,
        citationLabels: [String],
        outputRange: Range<Int>
    ) {
        self.id = id
        self.text = text
        self.citationLabels = citationLabels
        self.outputRange = outputRange
    }
}

/// Exact source material retained for a support decision. Validation happens at
/// `PropositionSupportResult` construction so unsupported/unverifiable results
/// may still retain partial evidence for diagnosis.
public struct SupportEvidence: Codable, Equatable, Hashable, Sendable {
    public let sourceID: String
    public let sourceLabel: String
    public let locator: String
    public let retainedExcerpt: String
    public let verifierName: String
    public let verifierVersion: String

    public init(
        sourceID: String,
        sourceLabel: String,
        locator: String,
        retainedExcerpt: String,
        verifierName: String,
        verifierVersion: String
    ) {
        self.sourceID = sourceID
        self.sourceLabel = sourceLabel
        self.locator = locator
        self.retainedExcerpt = retainedExcerpt
        self.verifierName = verifierName
        self.verifierVersion = verifierVersion
    }

    fileprivate var isComplete: Bool {
        [sourceID, sourceLabel, locator, retainedExcerpt, verifierName, verifierVersion]
            .allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

public enum PropositionSupportContractError: Error, Equatable, Sendable {
    case supportedResultRequiresEvidence
    case supportedEvidenceIncomplete(index: Int)
}

/// A fail-closed support result. Both direct construction and JSON decoding use
/// the same invariant checks, so malformed persisted JSON cannot synthesize a
/// clean decision without complete retained evidence.
public struct PropositionSupportResult: Codable, Equatable, Hashable, Sendable {
    public let propositionID: String
    public let status: PropositionSupportStatus
    public let reasons: [String]
    public let evidence: [SupportEvidence]
    public let timestamp: Date

    public init(
        propositionID: String,
        status: PropositionSupportStatus,
        reasons: [String],
        evidence: [SupportEvidence],
        timestamp: Date
    ) throws {
        if status == .supported {
            guard !evidence.isEmpty else {
                throw PropositionSupportContractError.supportedResultRequiresEvidence
            }
            if let index = evidence.firstIndex(where: { !$0.isComplete }) {
                throw PropositionSupportContractError.supportedEvidenceIncomplete(index: index)
            }
        }

        self.propositionID = propositionID
        self.status = status
        self.reasons = reasons
        self.evidence = evidence
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case propositionID
        case status
        case reasons
        case evidence
        case timestamp
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let propositionID = try container.decode(String.self, forKey: .propositionID)
        let status = try container.decode(PropositionSupportStatus.self, forKey: .status)
        let reasons = try container.decode([String].self, forKey: .reasons)
        let evidence = try container.decode([SupportEvidence].self, forKey: .evidence)
        let timestamp = try container.decode(Date.self, forKey: .timestamp)

        do {
            try self.init(
                propositionID: propositionID,
                status: status,
                reasons: reasons,
                evidence: evidence,
                timestamp: timestamp
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid proposition support result: \(error)"
                )
            )
        }
    }
}
