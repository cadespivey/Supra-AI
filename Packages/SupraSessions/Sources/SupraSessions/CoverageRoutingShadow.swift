import Foundation
import os

/// How the evidence-based corpus-coverage signal relates to the legacy keyword router's
/// decision for one matter-chat turn. Grades agreement and, on disagreement, the direction —
/// so shadow traffic reveals how often (and which way) coverage would change routing before it
/// becomes the primary discriminator.
public enum CoverageRoutingComparison: String, Sendable, Equatable {
    /// Keyword grounds and the corpus strongly covers the question — both answer from documents.
    case agreeGround
    /// Keyword does not ground and the corpus has no coverage — both skip the documents.
    case agreeSkip
    /// Keyword did NOT ground, but the corpus strongly covers the question — coverage would pull
    /// it into the documents (the missed-grounding case Phase 2 targets).
    case coverageWouldGround
    /// Keyword grounded, but the corpus has no coverage — coverage would send it to the legal
    /// route instead (keyword over-grounding).
    case coverageWouldSkip
    /// The corpus coverage is only weak, so neither the keyword nor the strong-evidence rule
    /// gives a confident routing signal — a marginal case worth watching.
    case marginal
}

/// Phase 2 (retrieve-before-route) SHADOW. Runs the evidence signal `MatterCorpusCoverage`
/// ALONGSIDE the keyword router (`MatterChatDocumentIntent`), grading where they diverge, and
/// logs the result as metadata only. It changes nothing user-visible — the keyword classifier
/// still decides — so real matters reveal how well coverage would route before it flips to
/// primary. Mirrors the Phase 0 attribution shadow (`GroundedAttributionAdapter`).
public enum CoverageRoutingShadow {
    private static let log = Logger(subsystem: "ai.supra.SupraAI", category: "reasoning.shadow")

    /// The app setting that turns the shadow probe on. Default OFF (absent → false): shadow adds
    /// a fast-tier retrieval per matter-chat turn, so it runs only when explicitly enabled. Public
    /// so the app's Diagnostics surface can flip it.
    public static let shadowEnabledKey = "reasoning.corpusCoverageShadow.enabled"

    /// The app setting that turns ADDITIVE coverage routing on. Default OFF. When on, a matter-chat
    /// question the keyword router leaves ungrounded (`.none`) but whose corpus coverage is STRONG
    /// is grounded as a whole-matter content question — coverage ADDS grounding the keyword lists
    /// miss. It never un-grounds a keyword-grounded question, so it cannot regress the keyword path.
    public static let additiveRoutingEnabledKey = "reasoning.additiveCoverageRouting.enabled"

    /// The candidate primary rule under test: coverage would ground iff its evidence is strong.
    /// `keywordGrounds` is the legacy decision (intent is `.content`/`.inventory`, not `.none`).
    static func compare(keywordGrounds: Bool, coverage: CoverageSignal) -> CoverageRoutingComparison {
        switch (keywordGrounds, coverage.strength) {
        case (_, .weak): return .marginal
        case (true, .strong): return .agreeGround
        case (false, .none): return .agreeSkip
        case (false, .strong): return .coverageWouldGround
        case (true, .none): return .coverageWouldSkip
        }
    }

    /// Logs the shadow comparison as metadata only (never the question or any source text), so a
    /// dev/pilot run reveals where evidence-based routing would diverge from the keyword router
    /// before Phase 2 flips the gate. A divergence (`coverageWouldGround`/`coverageWouldSkip`)
    /// is a `notice`; agreement and marginal cases are `debug`.
    static func logShadow(
        comparison: CoverageRoutingComparison,
        keywordGrounds: Bool,
        coverage: CoverageSignal
    ) {
        let diverges = comparison == .coverageWouldGround || comparison == .coverageWouldSkip
        if diverges {
            log.notice("shadow routing: comparison=\(comparison.rawValue, privacy: .public) keywordGrounds=\(keywordGrounds, privacy: .public) coverage=\(coverage.strength.rawValue, privacy: .public) matched=\(coverage.matchedSourceCount, privacy: .public) fullyIndexed=\(coverage.scopeFullyIndexed, privacy: .public)")
        } else {
            log.debug("shadow routing: comparison=\(comparison.rawValue, privacy: .public) coverage=\(coverage.strength.rawValue, privacy: .public)")
        }
    }
}
