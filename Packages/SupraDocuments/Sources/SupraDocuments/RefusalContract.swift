import Foundation

/// The one place that decides whether generated text is a refusal.
///
/// Three ad-hoc matchers used to answer this question differently: an exact match
/// against the canonical sentence, and two copies of a four-phrase substring test
/// (`DocumentSupportVerifier.appearsToBeRefusal` and an inline block in
/// `CitationCoverage.check`). Because "refusal" suppresses citation warnings and the
/// review gate, a signal that disagrees with itself either strands the user on a false
/// refusal or lets an unreviewed answer through.
///
/// The substring form failed because it keyed on a bare "cannot answer", which is a
/// hedge, not a declination — "I cannot answer that with certainty, but the agreement
/// was terminated on March 3, 2024" asserts a fact and was being read as a refusal.
///
/// The contract here is shape-based instead: a refusal is a statement about the
/// SOURCES being inadequate, and text is a refusal only when *every* sentence in it is
/// such a statement. An assertion anywhere in the text disqualifies it, however the
/// text is phrased.
public enum RefusalContract {
    /// The exact reply the grounded-Q&A prompt instructs the model to produce when the
    /// sources do not support an answer.
    public static let canonicalReply = "The provided sources do not support an answer to this question."

    /// Whether the text is exactly the canonical reply, tolerant of surrounding quotes,
    /// whitespace, trailing punctuation, and case.
    ///
    /// Distinct from `isRefusal` on purpose: this is the "the model followed the
    /// instruction literally" signal, used to decide retrieval escalation. `isRefusal`
    /// is the broader semantic question of whether the text declines to answer.
    public static func isCanonicalReply(_ text: String) -> Bool {
        normalizedForExactMatch(text) == normalizedForExactMatch(canonicalReply)
    }

    /// Whether the text declines to answer and asserts nothing else.
    ///
    /// True only when the text contains at least one sentence and every sentence is a
    /// refusal sentence. A single substantive sentence makes the whole text an answer.
    public static func isRefusal(_ text: String) -> Bool {
        let sentences = sentenceLikeSpans(in: text)
        guard !sentences.isEmpty else { return false }
        return sentences.allSatisfy(isRefusalSentence)
    }

    /// Whether one sentence is a declination rather than an assertion.
    ///
    /// Recognizes the canonical reply, a statement that the sources do not
    /// support/contain/address the answer, and an inability statement that refers to
    /// the sources. The last clause is what keeps a bare "I cannot answer that, but X"
    /// out: an inability phrase alone is a hedge, and only becomes a refusal when it is
    /// about the source material.
    public static func isRefusalSentence(_ sentence: String) -> Bool {
        if isCanonicalReply(sentence) { return true }
        let normalized = normalizedForMatching(sentence)
        guard !normalized.isEmpty else { return false }
        if matches(normalized, sourceInadequacyPattern) { return true }
        return matches(normalized, inabilityPattern) && matches(normalized, sourceReferencePattern)
    }

    // MARK: - Patterns

    /// "the provided sources do not support/contain/address/mention…" and its
    /// singular/contracted variants.
    private static let sourceInadequacyPattern =
        #"\bsources?\b[^.]{0,60}?\b(?:do not|does not|dont|doesnt|cannot|can not|cant|fail to|fails to|lack|lacks)\b[^.]{0,40}?\b(?:support|contain|include|address|mention|provide|discuss|show|state|answer|indicate|specify)\b"#

    /// "I cannot answer", "I am unable to determine", "it is not possible to answer".
    private static let inabilityPattern =
        #"\b(?:cannot|can not|cant|could not|couldnt|unable to|not possible to|no basis to)\b[^.]{0,40}?\b(?:answer|determine|confirm|verify|establish|say|tell|conclude|identify)\b"#

    /// Any reference to the source material, which an inability statement needs before
    /// it counts as a declination rather than a hedge.
    private static let sourceReferencePattern =
        #"\b(?:sources?|documents?|records?|materials?|provided (?:text|material|information)|excerpts?)\b"#

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression]) != nil
    }

    // MARK: - Normalization

    private static func normalizedForExactMatch(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(".") { trimmed = String(trimmed.dropLast()) }
        return trimmed.lowercased()
    }

    /// Lowercased, apostrophes dropped so "don't" and "dont" match one pattern, and
    /// whitespace collapsed. Sentence punctuation is preserved because the patterns use
    /// `[^.]` to stay inside one clause.
    private static func normalizedForMatching(_ text: String) -> String {
        let lowered = text.lowercased()
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "'", with: "")
        return lowered
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Splits into sentence-like spans on terminal punctuation and newlines. Deliberately
    /// simple: the contract only needs to know whether some span asserts something, and a
    /// coarser split can only merge an assertion into a refusal span, which the
    /// `allSatisfy` test then rejects — the fail-closed direction.
    private static func sentenceLikeSpans(in text: String) -> [String] {
        text
            .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
