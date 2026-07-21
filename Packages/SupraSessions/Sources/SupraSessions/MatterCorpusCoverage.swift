import Foundation
import SupraCore
import SupraStore

/// How strongly the matter's own document corpus covers a question.
public enum CoverageStrength: String, Sendable, Equatable {
    /// Retrieval found nothing relevant in scope.
    case none
    /// A single, marginally-relevant passage.
    case weak
    /// Multiple relevant passages, or a high-similarity semantic match.
    case strong
}

/// The evidence-coverage signal for one question against one matter's corpus. This is the
/// input the routing decision consumes to answer "is this a question about the user's own
/// documents?" from what the corpus actually contains, rather than from keyword lists.
public struct CoverageSignal: Sendable, Equatable {
    public let strength: CoverageStrength
    public let matchedSourceCount: Int
    public let scopeFullyIndexed: Bool

    public init(strength: CoverageStrength, matchedSourceCount: Int, scopeFullyIndexed: Bool) {
        self.strength = strength
        self.matchedSourceCount = matchedSourceCount
        self.scopeFullyIndexed = scopeFullyIndexed
    }

    /// Whether the corpus has any relevant content for the question.
    public var hasCoverage: Bool { strength != .none }
}

/// Phase 2 (retrieve-before-route): assesses how well a matter's own corpus covers a question,
/// using the existing fast-tier hybrid retrieval — the cheap local probe that a coverage-first
/// router runs before deciding document-vs-legal. Pure with respect to routing (it changes no
/// behavior); it only reads the index.
public enum MatterCorpusCoverage {
    /// The retrieval reaches for this many candidates — small, since coverage only needs to
    /// know whether strong evidence exists, not to pack a full answer.
    static let probeLimit = 8

    public static func assess(
        matterID: String,
        question: String,
        store: SupraStore,
        embedder: (any TextEmbedder)? = nil
    ) async -> CoverageSignal {
        let retrieval = DocumentRetrievalService(store: store, embedder: embedder)
        guard let result = try? await retrieval.retrieve(
            matterID: matterID, query: question, scope: .wholeMatter, limit: probeLimit, depth: .fast
        ) else {
            return CoverageSignal(strength: .none, matchedSourceCount: 0, scopeFullyIndexed: false)
        }
        let sources = result.sources
        let hasHighSemantic = sources.contains { $0.semanticBucket == "high" }
        let strength: CoverageStrength
        if sources.isEmpty {
            strength = .none
        } else if hasHighSemantic || sources.count >= 2 {
            strength = .strong
        } else {
            strength = .weak
        }
        return CoverageSignal(
            strength: strength,
            matchedSourceCount: sources.count,
            scopeFullyIndexed: result.readiness.isFullyReady
        )
    }
}
