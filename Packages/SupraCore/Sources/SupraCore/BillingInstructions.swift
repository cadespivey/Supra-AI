import Foundation

// Milestone 4 Phase 7 — the billing instruction stack. The model's billing-draft
// prompt is grounded in a *merged* instruction context: the firm's global billing
// instructions, plus each matter's per-matter override text and any client billing
// guideline documents (extracted verbatim excerpts). This file is the single,
// deterministic place that composition happens, so the merge is unit-testable and
// the Phase-7 gate ("per-matter override + guideline reach the prompt") asserts a
// real string rather than prompt internals. See Docs/ScratchPad-SPEC.md §5.3, §9.

/// The resolved billing rules for one matter on a given day: which code set governs
/// it, the attorney's free-text override, and verbatim excerpts pulled from the
/// client's uploaded billing-guideline documents (already extracted to text).
public struct MatterBillingRules: Sendable, Equatable {
    public var matterID: String
    public var matterName: String
    public var clientName: String?
    public var codeSet: BillingCodeSet
    public var overrideInstructions: String?
    public var guidelineExcerpts: [String]

    public init(
        matterID: String,
        matterName: String,
        clientName: String? = nil,
        codeSet: BillingCodeSet = .none,
        overrideInstructions: String? = nil,
        guidelineExcerpts: [String] = []
    ) {
        self.matterID = matterID
        self.matterName = matterName
        self.clientName = clientName
        self.codeSet = codeSet
        self.overrideInstructions = overrideInstructions
        self.guidelineExcerpts = guidelineExcerpts
    }

    /// True when this matter carries any rules beyond its bare identity (an
    /// override or a guideline excerpt) — i.e. something the prompt must surface.
    public var hasControllingRules: Bool {
        let hasOverride = !(overrideInstructions ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasGuideline = guidelineExcerpts.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return hasOverride || hasGuideline
    }
}

/// Composes the merged billing instruction stack rendered into the draft prompt.
public enum BillingInstructions {
    /// The document-tag name that marks an uploaded client billing-guideline doc.
    public static let guidelineTagName = "billing guideline"

    /// Maximum characters of guideline text included per matter, so a long policy
    /// PDF can't blow the prompt budget. Excerpts are truncated, not dropped.
    public static let guidelineCharBudget = 1500

    /// Renders the full instruction stack: global instructions, the auto-coding
    /// directive, and each matter's controlling rules (override + guideline
    /// excerpts). This is the exact text the model receives for instructions.
    public static func composedStack(
        global: String,
        rules: [MatterBillingRules],
        autoCoding: Bool = true
    ) -> String {
        var sections: [String] = []

        let trimmedGlobal = global.trimmingCharacters(in: .whitespacesAndNewlines)
        sections.append("Global billing instructions:\n\(trimmedGlobal.isEmpty ? "(none)" : trimmedGlobal)")

        if !autoCoding {
            sections.append("UTBMS coding is OFF: leave taskCode and activityCode null — the attorney assigns codes manually after review.")
        }

        sections.append("Matters (copy the exact id into matterID, or null):\n" + matterRulesBlock(rules))

        return sections.joined(separator: "\n\n")
    }

    /// Renders just the per-matter block: one entry per matter with its code set and,
    /// indented beneath it, the matter's override and any client-guideline excerpts.
    public static func matterRulesBlock(_ rules: [MatterBillingRules]) -> String {
        guard !rules.isEmpty else {
            return "(no matters on file — use null and infer the client/matter in the narrative)"
        }
        return rules.map(matterEntry).joined(separator: "\n")
    }

    private static func matterEntry(_ rule: MatterBillingRules) -> String {
        var line = "- id=\(rule.matterID) | \(rule.matterName)"
        if let client = rule.clientName?.trimmingCharacters(in: .whitespacesAndNewlines), !client.isEmpty {
            line += " | client=\(client)"
        }
        line += " | codeSet=\(rule.codeSet.rawValue)"

        var detail: [String] = []
        if let override = rule.overrideInstructions?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            detail.append("    Override: \(override)")
        }
        let excerpts = rule.guidelineExcerpts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !excerpts.isEmpty {
            let merged = budgetedExcerpt(excerpts.joined(separator: "\n"))
            detail.append("    Client billing guidelines (follow verbatim):\n" + indent(merged, by: "      "))
        }
        return detail.isEmpty ? line : ([line] + detail).joined(separator: "\n")
    }

    /// Truncates guideline text to the per-matter budget at a whitespace boundary.
    public static func budgetedExcerpt(_ text: String) -> String {
        let collapsed = text.replacingOccurrences(of: "\r", with: " ")
        guard collapsed.count > guidelineCharBudget else { return collapsed }
        let clipped = String(collapsed.prefix(guidelineCharBudget))
        if let lastSpace = clipped.lastIndex(where: { $0 == " " || $0 == "\n" }) {
            return String(clipped[..<lastSpace]) + " …"
        }
        return clipped + " …"
    }

    private static func indent(_ text: String, by prefix: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { prefix + $0 }
            .joined(separator: "\n")
    }
}
