import Foundation

/// One advisory result from the narrow matter-chat quotation check. Its identity is
/// derived from the visible answer's matching order and source label, so SwiftUI can
/// preserve disclosure state across a reload of the same persisted message.
public struct MatterChatQuoteWarning: Identifiable, Sendable, Equatable {
    public let id: String
    public let message: String

    public init(id: String, message: String) {
        self.id = id
        self.message = message
    }
}

/// Checks explicit `[S#]`-labelled quotations against the retained excerpt packet.
/// This is deliberately advisory: it neither changes the answer nor performs any
/// persistence, citation, assurance, or publication operation.
public enum MatterChatQuoteChecker {
    public static let unmatchedMessage =
        "This quotation could not be matched in the retained source excerpt."
    public static let unresolvedSourceMessage =
        "This quotation's source label could not be resolved from the retained source excerpts."

    public static func warnings(
        in visibleAnswer: String,
        providedSources: [ProvidedDocumentSource]
    ) -> [MatterChatQuoteWarning] {
        let answer = replacingCodeBlocksWithBoundaries(in: visibleAnswer)
        guard let expression = try? NSRegularExpression(
            pattern: "(?s)(?:\"([^\"\u{FFFC}]+)\"|“([^”\u{FFFC}]+)”)[\\s]*\\[(S\\d+)\\](?![\\s]*\\[S\\d+\\])"
        ) else { return [] }

        let excerptsByLabel = Dictionary(
            providedSources.map { ($0.label, normalize($0.excerpt)) },
            uniquingKeysWith: { first, _ in first }
        )
        let range = NSRange(answer.startIndex..<answer.endIndex, in: answer)
        return expression.matches(in: answer, range: range).enumerated().compactMap { ordinal, match in
            guard let labelRange = Range(match.range(at: 3), in: answer) else { return nil }
            let label = String(answer[labelRange])
            let id = "quote-check-\(label)-\(ordinal + 1)"
            guard let excerpt = excerptsByLabel[label] else {
                return MatterChatQuoteWarning(id: id, message: unresolvedSourceMessage)
            }
            let quoteRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            guard let quote = Range(quoteRange, in: answer), excerpt.contains(normalize(String(answer[quote]))) else {
                return MatterChatQuoteWarning(id: id, message: unmatchedMessage)
            }
            return nil
        }
    }

    private static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Code is excluded from quote checking, but must leave a non-whitespace
    /// boundary behind: deleting it would turn fragments on either side into a
    /// synthetic quote/citation pair. Support the normal backtick/tilde fenced
    /// forms and Markdown's indented code block form.
    private static func replacingCodeBlocksWithBoundaries(in text: String) -> String {
        let boundary = "\u{FFFC}"
        var result: [String] = []
        var activeFence: (marker: Character, length: Int)?

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(line)
            if let fence = activeFence {
                result.append(boundary)
                if closesFence(line, marker: fence.marker, minimumLength: fence.length) {
                    activeFence = nil
                }
                continue
            }
            if let fence = openingFence(in: line) {
                result.append(boundary)
                activeFence = fence
            } else if isIndentedCodeLine(line) {
                result.append(boundary)
            } else {
                result.append(line)
            }
        }
        return result.joined(separator: "\n")
    }

    private static func openingFence(in line: String) -> (marker: Character, length: Int)? {
        let indentation = line.prefix { $0 == " " }
        guard indentation.count <= 3 else { return nil }
        let remainder = line.dropFirst(indentation.count)
        guard let marker = remainder.first, marker == "`" || marker == "~" else { return nil }
        let length = remainder.prefix { $0 == marker }.count
        return length >= 3 ? (marker, length) : nil
    }

    private static func closesFence(_ line: String, marker: Character, minimumLength: Int) -> Bool {
        let indentation = line.prefix { $0 == " " }
        guard indentation.count <= 3 else { return false }
        let remainder = line.dropFirst(indentation.count)
        let length = remainder.prefix { $0 == marker }.count
        guard length >= minimumLength else { return false }
        return remainder.dropFirst(length).allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func isIndentedCodeLine(_ line: String) -> Bool {
        line.hasPrefix("\t") || line.hasPrefix("    ")
    }
}
