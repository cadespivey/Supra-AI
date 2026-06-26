import Foundation
import SupraDraftingCore

/// Recognizes a drafting request in a matter chat ("draft a notice of appearance",
/// "/draft notice", "prepare a demand letter") and maps it to a `DraftKindID`.
///
/// This is intentionally conservative: it only fires on an explicit drafting verb +
/// a recognized document kind, so ordinary questions ("what's a notice of
/// appearance?") don't trigger a file generation. Unrecognized kinds return nil so
/// the chat falls through to its normal answer path.
public enum DraftRequestParser {
    private static let draftingVerbs = ["draft", "prepare", "generate", "create", "write", "produce", "make"]

    public struct Match: Sendable, Equatable {
        public let kind: DraftKindID
        /// Whether the user used the explicit `/draft` slash form (high confidence).
        public let isExplicitCommand: Bool
    }

    public static func parse(_ text: String) -> Match? {
        let lowered = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lowered.isEmpty else { return nil }

        // Explicit slash command: "/draft notice", "/draft motion to dismiss".
        if lowered.hasPrefix("/draft") {
            let remainder = String(lowered.dropFirst("/draft".count)).trimmingCharacters(in: .whitespaces)
            if let kind = kind(in: remainder) ?? kind(in: lowered) {
                return Match(kind: kind, isExplicitCommand: true)
            }
            return nil
        }

        // Natural language: a drafting verb must appear before the document kind.
        guard let kind = kind(in: lowered) else { return nil }
        guard let verb = draftingVerbs.first(where: { lowered.contains($0) }) else { return nil }
        // The verb should come before the document name (so "I reviewed the notice and
        // want to draft a response" still reads as a draft request, but "what does the
        // notice of appearance say" — no verb — does not).
        guard let verbRange = lowered.range(of: verb) else { return nil }
        let afterVerb = String(lowered[verbRange.upperBound...])
        guard self.kind(in: afterVerb) != nil else { return nil }
        return Match(kind: kind, isExplicitCommand: false)
    }

    private static func kind(in text: String) -> DraftKindID? {
        // Order matters: check the most specific phrases first.
        if text.contains("notice of appearance") || text.contains("appearance") {
            return .noticeAppearance
        }
        if text.contains("motion to dismiss") || text.contains("mtd") {
            return .motionToDismiss
        }
        if text.contains("demand letter") || text.contains("demand") {
            return .letterDemand
        }
        return nil
    }
}
