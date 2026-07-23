import Foundation

/// Render-time split of the out-of-band verification banners from persisted
/// assistant-message content, mirroring `ReasoningContent`'s reasoning/answer
/// split. Persistence keeps the full text — the versioned verification record,
/// the pinned security warnings, and the copy action all read the unsplit
/// content — while the chat surface renders the notice collapsed and subdued so
/// it cannot dwarf the answer it qualifies.
public enum SupportNoticeContent {
    /// The document-support banner's heading line, shared with every banner the
    /// controller appends (including the fallback "verification could not be
    /// completed" form) so the builders and this splitter cannot drift apart.
    public static let documentSupportHeading =
        "⚠️ **Document support check — verify before relying on this answer.**"

    /// The entity-grounding banner's heading prefix.
    public static let entityGroundingHeading =
        "⚠️ **Grounding check — not found in the cited documents.**"

    /// Splits `content` into the answer body and the trailing out-of-band notice
    /// block: everything from the first banner heading to the end (both banners
    /// when both were appended, order preserved). The presentation rule ("---")
    /// directly above the first heading belongs to the banner, not the answer,
    /// and is dropped; a rule anywhere else in the answer is content. Text
    /// without a banner heading is returned untouched.
    public static func split(_ content: String) -> (body: String, notice: String?) {
        let firstHeading = [documentSupportHeading, entityGroundingHeading]
            .compactMap { content.range(of: $0) }
            .min { $0.lowerBound < $1.lowerBound }
        guard let firstHeading else { return (content, nil) }

        var body = trimmingTrailingWhitespace(String(content[..<firstHeading.lowerBound]))
        if body.hasSuffix("\n---") {
            body = trimmingTrailingWhitespace(String(body.dropLast("\n---".count)))
        } else if body == "---" {
            body = ""
        }
        let notice = trimmingTrailingWhitespace(String(content[firstHeading.lowerBound...]))
        return (body, notice.isEmpty ? nil : notice)
    }

    private static func trimmingTrailingWhitespace(_ text: String) -> String {
        var text = text
        while let last = text.unicodeScalars.last,
              CharacterSet.whitespacesAndNewlines.contains(last) {
            text.unicodeScalars.removeLast()
        }
        return text
    }
}
