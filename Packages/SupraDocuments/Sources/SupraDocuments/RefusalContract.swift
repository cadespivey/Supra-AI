import Foundation

/// The whole-response classification of a grounded prose answer. Only `.refusal` — a
/// response whose EVERY sentence validates as a pure refusal statement — may suppress
/// citation checks. `.mixed` and `.empty` always fail closed to review; `.answer` gets
/// the full proposition/citation pipeline.
///
/// This is the typed replacement for the scattered "looks like a refusal" booleans the
/// Phase 3C review flagged: a signal that collapsed "declined to answer" and "answered
/// while disclaiming" into one value, letting an uncited assertion ship with review
/// suppressed.
public enum ResponseShape: String, Sendable, Equatable {
    /// Every sentence is a pure refusal statement; nothing is asserted.
    case refusal
    /// Substantive prose with no refusal statement.
    case answer
    /// Refusal language AND assertion content in one response — internally
    /// inconsistent; always requires review.
    case mixed
    /// No sentence content at all; never a refusal, never an answer.
    case empty
}

/// The one place that decides whether generated text is a refusal.
///
/// Three ad-hoc matchers used to answer this question differently: an exact match
/// against the canonical sentence, and two copies of a four-phrase substring test
/// (`DocumentSupportVerifier.appearsToBeRefusal` and an inline block in
/// `CitationCoverage.check`). Because "refusal" suppresses citation warnings and the
/// review gate, a signal that disagrees with itself either strands the user on a false
/// refusal or lets an unreviewed answer through.
///
/// The substring form failed twice, in the same direction:
/// - keying on a bare "cannot answer" read the hedge in "I cannot answer that with
///   certainty, but the agreement was terminated on March 3, 2024" as a refusal;
/// - matching the source-inadequacy pattern ANYWHERE in a sentence read the refusal
///   clause in "The provided sources do not support an answer, but the agreement was
///   terminated on March 3, 2024." as covering the whole sentence — suppressing
///   citation review of the uncited assertion it carried (Phase 3C review, finding #1).
///
/// The contract is therefore shape-based and fail-closed: a suppressing refusal is a
/// statement about the SOURCES being inadequate, validated against the WHOLE response
/// structure — every sentence must be a pure refusal statement (an anchored refusal
/// clause with no assertion payload and no continuation clause). Anything the grammar
/// does not affirmatively accept is an answer or a mixed response and flows to the
/// ordinary citation checks. There is deliberately no conjunction blacklist here:
/// unknown phrasings fall OUT of the refusal shape, never into it.
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

    /// Whole-response classification. `.refusal` requires every sentence to be a pure
    /// refusal statement; refusal language mixed with any assertion content is
    /// `.mixed`; no refusal language at all is `.answer`.
    public static func responseShape(of text: String) -> ResponseShape {
        let sentences = sentenceLikeSpans(in: text)
        guard !sentences.isEmpty else { return .empty }
        var pureCount = 0
        var refusalLikeCount = 0
        for sentence in sentences {
            if isRefusalSentence(sentence) {
                pureCount += 1
                refusalLikeCount += 1
            } else if isRefusalLike(sentence) {
                refusalLikeCount += 1
            }
        }
        if pureCount == sentences.count { return .refusal }
        if refusalLikeCount > 0 { return .mixed }
        return .answer
    }

    /// Whether the text declines to answer and asserts nothing else — exactly
    /// `responseShape(of:) == .refusal`, kept as a convenience so no caller can hold a
    /// refusal signal that disagrees with the typed shape.
    public static func isRefusal(_ text: String) -> Bool {
        responseShape(of: text) == .refusal
    }

    /// Whether one sentence is a pure declination — an anchored refusal statement and
    /// nothing else. Used by proposition extraction to skip ONLY sentences that assert
    /// nothing; a sentence that joins a refusal clause to further content fails this
    /// test and is extracted/verified like any other prose.
    ///
    /// Accepted shapes (validated structurally, in order):
    /// 1. The canonical reply.
    /// 2. A source-inadequacy statement ("the provided sources do not contain …"), or
    ///    an inability statement that references the source material ("I cannot
    ///    determine … from the provided sources"), where:
    ///    - the sentence carries NO assertion payload (digits, currency, @, quotes),
    ///    - the sentence carries NO clause-delimiting punctuation (, ; : parentheses
    ///      or dashes) — a continuation clause disqualifies the shape,
    ///    - at most 3 tokens precede the refusal clause (room for "Unfortunately the
    ///      provided …", not for a leading assertion), and
    ///    - the tail after the refusal verb parses as a short object (≤ 3 tokens)
    ///      optionally followed by a topic complement introduced by a whitelisted
    ///      marker ("about/regarding/whether/when/…"). The whitelist is an affirmative
    ///      grammar of the refusal shape: unknown connectives ("but", "because", …)
    ///      do not parse, so the sentence falls out of the refusal shape and into
    ///      review — the fail-closed direction.
    public static func isRefusalSentence(_ sentence: String) -> Bool {
        if isCanonicalReply(sentence) { return true }
        let normalized = normalizedForMatching(sentence)
        guard !normalized.isEmpty else { return false }
        guard !containsAssertionPayload(normalized) else { return false }
        guard !containsClauseDelimiter(normalized) else { return false }

        var corePatterns = [sourceInadequacyPattern]
        if matches(normalized, sourceReferencePattern) {
            corePatterns.append(inabilityPattern)
        }
        for pattern in corePatterns {
            for coreRange in matchRanges(of: pattern, in: normalized) {
                let prefixTokens = tokens(of: String(normalized[..<coreRange.lowerBound]))
                guard prefixTokens.count <= 3 else { continue }
                let tailTokens = tokens(of: String(normalized[coreRange.upperBound...]))
                if tailParsesAsRefusalObject(tailTokens) { return true }
            }
        }
        return false
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

    /// Whether a sentence carries refusal LANGUAGE at all (the loose test the old
    /// `isRefusalSentence` used). A sentence that is refusal-like but not a pure
    /// refusal sentence makes the whole response `.mixed`.
    private static func isRefusalLike(_ sentence: String) -> Bool {
        if isCanonicalReply(sentence) { return true }
        let normalized = normalizedForMatching(sentence)
        guard !normalized.isEmpty else { return false }
        if matches(normalized, sourceInadequacyPattern) { return true }
        return matches(normalized, inabilityPattern) && matches(normalized, sourceReferencePattern)
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression]) != nil
    }

    private static func matchRanges(of pattern: String, in text: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).compactMap { Range($0.range, in: text) }
    }

    // MARK: - Structural guards

    /// Material a refusal cannot carry: numbers (dates, amounts, section numbers,
    /// citation-label digits), currency, or addresses. A "refusal" carrying any of
    /// these is asserting something.
    private static func containsAssertionPayload(_ normalized: String) -> Bool {
        normalized.contains { $0.isNumber || "$€£@".contains($0) }
    }

    /// Clause-delimiting punctuation. A pure refusal statement is one clause; a comma,
    /// semicolon, colon, dash, parenthesis, or quotation mark signals structure this
    /// grammar does not validate, so the sentence fails closed to review. (Terminal
    /// periods never reach here: sentence splitting consumes them, and abbreviation
    /// periods inside a genuine refusal are rare enough that rejection is the
    /// conservative direction.)
    private static func containsClauseDelimiter(_ normalized: String) -> Bool {
        normalized.contains { ",;:()—–-\"“”".contains($0) }
    }

    /// The tail after the refusal verb: a short object (≤ 3 free tokens), optionally
    /// followed by a topic complement introduced by a whitelisted marker, or nothing.
    /// "an answer to this question" ⇒ object "an answer" + marker "to" + topic.
    /// "an answer but the buyer terminated …" ⇒ "but" is no marker ⇒ not a refusal.
    private static func tailParsesAsRefusalObject(_ tail: [String]) -> Bool {
        for objectLength in 0...min(3, tail.count) {
            if objectLength == tail.count { return true }
            if topicMarkers.contains(stripTerminalPunctuation(tail[objectLength])) { return true }
        }
        return false
    }

    /// Markers that introduce the QUESTION TOPIC a refusal may name ("… about the
    /// termination date", "… whether notice was given"). Deliberately a whitelist:
    /// coordinating or causal connectives ("but", "because", "as") are absent, so a
    /// continuation clause never parses as a topic.
    private static let topicMarkers: Set<String> = [
        "about", "regarding", "concerning", "to", "from", "whether",
        "when", "where", "who", "whom", "what", "which", "how", "why",
    ]

    private static func stripTerminalPunctuation(_ token: String) -> String {
        String(token.drop(while: { !$0.isLetter }).reversed().drop(while: { !$0.isLetter }).reversed())
    }

    private static func tokens(of text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
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
    /// `[^.]` to stay inside one clause and the structural guards inspect it.
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
    /// pure-sentence test then rejects — the fail-closed direction.
    private static func sentenceLikeSpans(in text: String) -> [String] {
        text
            .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
