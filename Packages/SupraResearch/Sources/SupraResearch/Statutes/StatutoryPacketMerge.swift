import Foundation

/// Builds the source-packet authority list for a statutory question: statutory provisions LEAD
/// (they're the primary law the user asked about, carrying their currency caveat), then the
/// top-ranked case law fills the remaining slots, capped to the packet size. Lives in
/// SupraResearch so it can use `RankedLegalAuthority`'s in-module initializer.
public enum StatutoryPacketMerge {
    /// Statutes lead the packet; the score is illustrative — the order is constructed here, not
    /// re-sorted downstream.
    static let statutoryLeadScore = 1_000

    public static func merge(
        statutoryProvisions: [StatutoryProvision],
        rankedCases: [RankedLegalAuthority],
        jurisdictionLabel: String?,
        cap: Int
    ) -> [RankedLegalAuthority] {
        guard cap > 0 else { return [] }
        guard !statutoryProvisions.isEmpty else { return Array(rankedCases.prefix(cap)) }

        // Reserve at most ~half the packet for statutes so case law isn't fully evicted.
        let statuteBudget = max(1, cap - cap / 2)
        let statRanked = statutoryProvisions.prefix(statuteBudget).map { provision in
            RankedLegalAuthority(
                authority: provision.asLegalAuthority(jurisdictionLabel: jurisdictionLabel),
                score: Self.statutoryLeadScore,
                reasons: ["statutory provision · \(provision.sourceName)\(provision.weightTier == .convenience ? " (unverified currency)" : "")"]
            )
        }
        let caseSlots = max(0, cap - statRanked.count)
        return Array(statRanked) + Array(rankedCases.prefix(caseSlots))
    }
}
