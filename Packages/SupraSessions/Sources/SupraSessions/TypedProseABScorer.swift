import Foundation
import SupraCore
import SupraDocuments

/// Which grounded-answer path produced an outcome.
public enum TypedProseArm: String, Sendable, Equatable, Codable {
    /// `TypedGroundedGenerator` → `AnswerDraftRenderer`.
    case typed
    /// The streamed prose path: `DocumentQAPromptBuilder` → normalize → reasoning-strip.
    case prose
}

/// The typed ground truth a correct answer must state (measurement qualification,
/// review finding #3). Fields are REQUESTED individually; correctness requires every
/// requested field to be affirmatively satisfied, and for value-typed fields (money,
/// date) the answer's affirmative values of that type must be exactly the expected
/// value — a contradiction or an unsupported additional value fails closed. A fixture
/// must explicitly enumerate incidental money/date values that a correct answer may
/// include even though the question did not request that type. Requested fields must
/// also co-occur in one affirmative sentence so the scorer cannot join unrelated
/// propositions into a synthetic answer.
///
/// `terms` is the honestly limited field: word-bounded, negation-guarded term
/// presence. It measures term recall for rule-style answers, not semantic
/// correctness — fixtures that only request terms are labeled by that limit.
///
/// Boolean/enumerated-outcome fields are deliberately absent until a fixture needs
/// them: unmeasured machinery is how the substring scorer happened.
public struct TypedProseExpectedAnswer: Sendable, Equatable, Codable {
    /// A calendar day, compared as a date — never as notation.
    public struct Day: Sendable, Equatable, Hashable, Codable {
        public let year: Int
        public let month: Int
        public let day: Int

        public init(year: Int, month: Int, day: Int) {
            self.year = year
            self.month = month
            self.day = day
        }
    }

    /// Expected amount in dollars, compared numerically ("$9,000", "9,000.00
    /// dollars", and "nine thousand dollars" are the same money).
    public var money: Decimal?
    public var date: Day?
    /// The entity a correct answer must attribute the fact to; all of its
    /// significant tokens must co-occur in one non-negated sentence.
    public var actor: String?
    /// Word-bounded terms that must each appear in a non-negated sentence.
    public var terms: [String]
    /// Evidence-backed incidental values permitted only when this type is not itself
    /// requested. Nil decodes old artifacts safely as an empty allowlist.
    public var allowedMoney: [Decimal]?
    public var allowedDates: [Day]?

    public init(
        money: Decimal? = nil,
        date: Day? = nil,
        actor: String? = nil,
        terms: [String] = [],
        allowedMoney: [Decimal]? = nil,
        allowedDates: [Day]? = nil
    ) {
        self.money = money
        self.date = date
        self.actor = actor
        self.terms = terms
        self.allowedMoney = allowedMoney
        self.allowedDates = allowedDates
    }

    /// Whether any field is requested at all — an empty expectation can never be
    /// satisfied (fail closed), only a refusal fixture carries none.
    public var requestsAnything: Bool {
        money != nil || date != nil || actor != nil || !terms.isEmpty
    }
}

/// One scored (fixture, arm) result. Everything needed to classify it, and nothing that
/// identifies a real matter — the pilot runs on authored fixtures only.
public struct TypedProseABOutcome: Sendable, Equatable, Codable {
    public let fixtureName: String
    public let arm: TypedProseArm
    public let answer: String
    /// `DocumentSupportReport.requiresReview` for this answer.
    public let requiresReview: Bool
    public let warnings: [String]
    /// True when the fixture's honest answer is a refusal.
    public let expectsRefusal: Bool
    /// The typed ground truth for an answerable fixture. Nil when `expectsRefusal`.
    public let expected: TypedProseExpectedAnswer?
    /// True when the path failed and degraded (typed fallback, or a failed generation).
    public let fellBack: Bool

    public init(
        fixtureName: String,
        arm: TypedProseArm,
        answer: String,
        requiresReview: Bool,
        warnings: [String],
        expectsRefusal: Bool,
        expected: TypedProseExpectedAnswer?,
        fellBack: Bool
    ) {
        self.fixtureName = fixtureName
        self.arm = arm
        self.answer = answer
        self.requiresReview = requiresReview
        self.warnings = warnings
        self.expectsRefusal = expectsRefusal
        self.expected = expected
        self.fellBack = fellBack
    }
}

/// The 2x2 cell an outcome falls into.
public enum TypedProseABCell: String, Sendable, Equatable, Codable {
    /// Correct answer, verifier flagged it — the noise this pilot measures.
    case falsePositive
    /// Wrong answer, verifier flagged it — the gate working.
    case truePositive
    /// Wrong answer, verifier stayed quiet — worse than noise.
    case missedError
    /// Correct answer, verifier stayed quiet.
    case trueNegative
}

/// Per-arm tally.
public struct TypedProseABReport: Sendable, Equatable, Codable {
    public let arm: TypedProseArm
    public let total: Int
    public let correct: Int
    public let falsePositives: Int
    public let truePositives: Int
    public let missedErrors: Int
    public let trueNegatives: Int
    public let fellBack: Int

    /// The headline: of the answers that were RIGHT, how many did the verifier flag anyway.
    ///
    /// Denominator is `correct`, not `total`, deliberately. Over all fixtures a path that answers
    /// badly would look quiet, since wrong answers draw true positives rather than false ones.
    public var falsePositiveRate: Double { correct == 0 ? 0 : Double(falsePositives) / Double(correct) }
    /// Of the answers that were WRONG, how many slipped past the verifier.
    public var missedErrorRate: Double {
        let wrong = truePositives + missedErrors
        return wrong == 0 ? 0 : Double(missedErrors) / Double(wrong)
    }
    public var correctRate: Double { total == 0 ? 0 : Double(correct) / Double(total) }
}

/// The persisted artifact of one A/B run: every raw outcome plus the per-arm reports.
/// Deliberately timestamp-free and Codable-stable, so a published measurement can be
/// independently RE-SCORED from its own artifact — decode `outcomes`, re-run
/// `TypedProseABScorer.report`, and compare against the recorded reports.
public struct TypedProseABRunRecord: Sendable, Equatable, Codable {
    /// v4: contrastive negation scope is limited to disjoint, bare typed values;
    /// comma-not adjuncts, hypotheticals, and repeated denied values fail closed.
    /// Decoding refuses any other schema — a recorded version that is never checked
    /// protects nothing, and re-scoring an old artifact under new semantics would
    /// silently change published numbers.
    public static let currentSchemaVersion = 4

    public let schemaVersion: Int
    public let outcomes: [TypedProseABOutcome]
    public let typed: TypedProseABReport
    public let prose: TypedProseABReport

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, outcomes, typed, prose
    }

    public init(
        schemaVersion: Int = TypedProseABRunRecord.currentSchemaVersion,
        outcomes: [TypedProseABOutcome],
        typed: TypedProseABReport,
        prose: TypedProseABReport
    ) {
        self.schemaVersion = schemaVersion
        self.outcomes = outcomes
        self.typed = typed
        self.prose = prose
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "artifact schema \(version) does not match scorer schema "
                    + "\(Self.currentSchemaVersion); the scoring semantics differ, so this artifact "
                    + "cannot be re-scored — regenerate it with the current build"
            )
        }
        self.schemaVersion = version
        self.outcomes = try container.decode([TypedProseABOutcome].self, forKey: .outcomes)
        self.typed = try container.decode(TypedProseABReport.self, forKey: .typed)
        self.prose = try container.decode(TypedProseABReport.self, forKey: .prose)
    }
}

/// Scores typed-vs-prose pilot outcomes.
///
/// Pure and model-free, so the arithmetic that decides the pilot is unit-tested independently of
/// any generation run. The measurement it protects is the distinction between the verifier being
/// NOISY (flagging correct answers) and the verifier WORKING (flagging wrong ones) — a raw
/// `requiresReview` rate conflates the two, and a divergence tally between the paths sees neither.
///
/// Correctness is decided from TYPED expected fields, never substring containment:
/// values are extracted from the answer (dates as dates, money as amounts), negated
/// sentences never satisfy a field, and for a requested value type the answer's
/// affirmative values must be exactly the expected value. Values of an unrequested
/// type must be in the fixture's explicit allowlist, and all requested fields must
/// bind in a single proposition. The old substring test survives only as the
/// `containsExpectedLiteral` diagnostic, which no correctness decision consumes.
public enum TypedProseABScorer {

    /// Whether the answer is the one the fixture calls for.
    ///
    /// A refusal is correct only on a not-answerable fixture. Refusing an answerable question is a
    /// WRONG answer — without that rule a model that refuses everything posts a perfect,
    /// unflagged scorecard.
    public static func isCorrect(_ outcome: TypedProseABOutcome) -> Bool {
        if outcome.fellBack { return false }
        let refused = RefusalContract.isRefusal(outcome.answer)
        if outcome.expectsRefusal { return refused }
        if refused { return false }
        guard let expected = outcome.expected, expected.requestsAnything else { return false }

        let sentences = classifiedSentences(in: outcome.answer)

        guard sentences.contains(where: { sentenceSatisfiesExpectedProposition($0, expected: expected) })
        else { return false }

        let statedMoney = affirmativeValues(of: sentences, extractor: moneyValues)
        if let money = expected.money {
            guard statedMoney == [money] else { return false }
        } else {
            guard statedMoney.isSubset(of: Set(expected.allowedMoney ?? [])) else { return false }
        }
        let statedDates = affirmativeValues(of: sentences, extractor: dateValues)
        if let day = expected.date {
            guard statedDates == [day] else { return false }
        } else {
            guard statedDates.isSubset(of: Set(expected.allowedDates ?? [])) else { return false }
        }
        return true
    }

    /// The OLD substring test, retained strictly as a diagnostic under an honest
    /// name. It accepts negated mentions and rejects paraphrases, so it must never be
    /// consumed as correctness — `isCorrect` does not call it.
    public static func containsExpectedLiteral(_ answer: String, literal: String?) -> Bool {
        guard let literal, !literal.isEmpty else { return false }
        return answer.localizedCaseInsensitiveContains(literal)
    }

    public static func classify(_ outcome: TypedProseABOutcome) -> TypedProseABCell {
        switch (isCorrect(outcome), outcome.requiresReview) {
        case (true, true): return .falsePositive
        case (false, true): return .truePositive
        case (false, false): return .missedError
        case (true, false): return .trueNegative
        }
    }

    /// Folds outcomes for ONE arm into a report. Outcomes from other arms are filtered out — the
    /// comparison is paired per fixture, so a mixed report would be meaningless.
    public static func report(outcomes: [TypedProseABOutcome], arm: TypedProseArm) -> TypedProseABReport {
        let mine = outcomes.filter { $0.arm == arm }
        var falsePositives = 0, truePositives = 0, missedErrors = 0, trueNegatives = 0
        for outcome in mine {
            switch classify(outcome) {
            case .falsePositive: falsePositives += 1
            case .truePositive: truePositives += 1
            case .missedError: missedErrors += 1
            case .trueNegative: trueNegatives += 1
            }
        }
        return TypedProseABReport(
            arm: arm,
            total: mine.count,
            correct: falsePositives + trueNegatives,
            falsePositives: falsePositives,
            truePositives: truePositives,
            missedErrors: missedErrors,
            trueNegatives: trueNegatives,
            fellBack: mine.filter(\.fellBack).count
        )
    }

    // MARK: - Sentence structure

    private struct ClassifiedSentence {
        let text: String
        let negated: Bool
    }

    /// Splits the answer into negation-scoped spans (citation labels stripped first
    /// so `[S1]` digits are not values; periods between digits masked so `$9,000.00`
    /// does not end a sentence). A value found in a negated span is neither credit
    /// nor contradiction — it is simply not an affirmative statement of that value.
    private static func classifiedSentences(in answer: String) -> [ClassifiedSentence] {
        let unlabeled = answer.replacingOccurrences(
            of: #"\[[A-Za-z]{1,3}\d{1,4}\]"#,
            with: " ",
            options: .regularExpression
        )
        let masked = unlabeled.replacingOccurrences(
            of: #"(?<=\d)\.(?=\d)"#,
            with: "\u{F8FF}",
            options: .regularExpression
        )
        return masked
            .components(separatedBy: CharacterSet(charactersIn: ".!?;\n"))
            .map { $0.replacingOccurrences(of: "\u{F8FF}", with: ".") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .flatMap(negationSpans)
    }

    /// Splits one sentence into negation-scoped spans. Contrast is recognized only
    /// when both sides contain DISJOINT values of the same typed field and the
    /// denied/replacement side is a bare value phrase. That deliberately excludes
    /// comma-not adjuncts ("not including tax"), appositives, hypotheticals, and a
    /// post-but re-mention of the denied value. Unrecognized shapes keep
    /// whole-sentence negation and therefore fail closed.
    private static func negationSpans(_ sentence: String) -> [ClassifiedSentence] {
        // Reverse contrastive first ("not X, but Y"). The replacement must be a
        // bare, disjoint typed value; prose that merely re-mentions the denied value
        // ("but the draft lists X") cannot become affirmative credit.
        if let match = firstMatch(
            #"(?i)^(.*?\b(?:not|never)\b.*?),\s*but\s+(?:rather\s+)?(.+)$"#,
            in: sentence
        ), isBareTypedValuePhrase(match[1]), hasDisjointTypedContrast(match[0], match[1]) {
            return [ClassifiedSentence(text: match[0], negated: true)] + negationSpans(match[1])
        }

        // Forward contrastive ("X, not Y"). Only the bare competitor is negated;
        // any following clause remains affirmative and subject to value allowlists.
        if let match = firstMatch(
            #"(?i)^(.*?),\s*(?:but\s+)?(?:not|never)\b(.*)$"#,
            in: sentence
        ), !beginsWithConditional(match[0]),
           let contrast = contrastiveAtomAndSuffix(head: match[0], tail: match[1]) {
            var spans = negationSpans(match[0])
            spans.append(ClassifiedSentence(text: contrast.atom, negated: true))
            if let suffix = contrast.suffix {
                spans.append(contentsOf: negationSpans(suffix))
            }
            return spans
        }

        // Preserve an independent affirmative clause before a later negated one.
        // This is intentionally narrower than general "but" splitting: the prefix
        // must itself be non-negated and the remainder must contain negation.
        if let match = firstMatch(
            #"(?i)^(.+?),\s*but\s+(.+\b(?:not|never)\b.*)$"#,
            in: sentence
        ), !isNegated(match[0]) {
            return negationSpans(match[0]) + negationSpans(match[1])
        }
        return [ClassifiedSentence(text: sentence, negated: isNegated(sentence))]
    }

    /// Finds the shortest comma-delimited tail prefix that is a bare typed value
    /// contrast. Commas inside currency have no following whitespace; commas inside
    /// long-form dates are skipped until the prefix parses as a complete date.
    private static func contrastiveAtomAndSuffix(
        head: String,
        tail: String
    ) -> (atom: String, suffix: String?)? {
        guard !beginsWithConditional(head) else { return nil }
        guard let comma = try? NSRegularExpression(pattern: #",\s+"#) else { return nil }
        let fullRange = NSRange(tail.startIndex..<tail.endIndex, in: tail)
        for match in comma.matches(in: tail, range: fullRange) {
            guard let delimiter = Range(match.range, in: tail) else { continue }
            let atom = String(tail[..<delimiter.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let suffix = String(tail[delimiter.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            if isBareTypedValuePhrase(atom), hasDisjointTypedContrast(head, atom) {
                return (atom, suffix.isEmpty ? nil : suffix)
            }
        }
        let atom = tail.trimmingCharacters(in: .whitespaces)
        guard isBareTypedValuePhrase(atom), hasDisjointTypedContrast(head, atom) else {
            return nil
        }
        return (atom, nil)
    }

    /// Contrast is safe only when both sides state at least one value of the same
    /// typed field and those sets do not overlap.
    private static func hasDisjointTypedContrast(_ lhs: String, _ rhs: String) -> Bool {
        let lhsMoney = Set(moneyValues(in: lhs))
        let rhsMoney = Set(moneyValues(in: rhs))
        if !lhsMoney.isEmpty, !rhsMoney.isEmpty, lhsMoney.isDisjoint(with: rhsMoney) {
            return true
        }
        let lhsDates = Set(dateValues(in: lhs))
        let rhsDates = Set(dateValues(in: rhs))
        return !lhsDates.isEmpty && !rhsDates.isEmpty && lhsDates.isDisjoint(with: rhsDates)
    }

    /// A typed value without relational prose. Keeping this deliberately strict is
    /// the scorer's fail-closed boundary: "$9,000" and "June 15, 2026" qualify;
    /// "the draft lists $9,000" and "including tax" do not.
    private static func isBareTypedValuePhrase(_ text: String) -> Bool {
        guard !moneyValues(in: text).isEmpty || !dateValues(in: text).isEmpty else {
            return false
        }
        let allowedWords: Set<String> = ["and", "dollars", "usd"]
        return tokens(in: text).allSatisfy { token in
            token.allSatisfy(\.isNumber)
                || token.range(of: #"^\d+(?:st|nd|rd|th)$"#, options: .regularExpression) != nil
                || numberWords[token] != nil
                || months[token] != nil
                || allowedWords.contains(token)
        }
    }

    private static func beginsWithConditional(_ text: String) -> Bool {
        guard let first = tokens(in: text).first else { return false }
        return ["if", "unless", "whether", "assuming", "provided"].contains(first)
    }

    private static let negationTokens: Set<String> = [
        "no", "not", "never", "without", "none", "nor", "neither", "cannot",
        "dont", "doesnt", "didnt", "wasnt", "werent", "isnt", "arent", "cant",
        "couldnt", "wouldnt", "shouldnt", "hasnt", "havent",
    ]

    private static func isNegated(_ sentence: String) -> Bool {
        // "no later than" is a deadline idiom, not a negation — the same phrase the
        // support verifier normalizes to "due".
        let normalized = sentence.lowercased().replacingOccurrences(of: "no later than", with: " by ")
        return !Set(tokens(in: normalized)).isDisjoint(with: negationTokens)
    }

    private static func tokens(in text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "'", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func significantTokens(in text: String) -> Set<String> {
        Set(tokens(in: text).filter { $0.count >= 2 })
    }

    private static func containsWordBounded(_ term: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: term)
        return text.range(of: "\\b\(escaped)\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Tests the expected fields as one proposition. Global typed-value checks still
    /// run afterward to reject contradictions and unauthorized additions elsewhere.
    private static func sentenceSatisfiesExpectedProposition(
        _ sentence: ClassifiedSentence,
        expected: TypedProseExpectedAnswer
    ) -> Bool {
        guard !sentence.negated else { return false }
        if let money = expected.money, !moneyValues(in: sentence.text).contains(money) {
            return false
        }
        if let date = expected.date, !dateValues(in: sentence.text).contains(date) {
            return false
        }
        if let actor = expected.actor {
            let actorTokens = significantTokens(in: actor)
            guard !actorTokens.isEmpty,
                  actorTokens.isSubset(of: significantTokens(in: sentence.text))
            else { return false }
        }
        for term in expected.terms where !containsWordBounded(term, in: sentence.text) {
            return false
        }
        return true
    }

    /// The set of values of one type stated affirmatively (in non-negated sentences).
    private static func affirmativeValues<Value: Hashable>(
        of sentences: [ClassifiedSentence],
        extractor: (String) -> [Value]
    ) -> Set<Value> {
        Set(sentences.filter { !$0.negated }.flatMap { extractor($0.text) })
    }

    // MARK: - Money

    private static func moneyValues(in sentence: String) -> [Decimal] {
        var values: [Decimal] = []
        for pattern in [
            #"\$\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)"#,
            #"(?i)\b([0-9][0-9,]*(?:\.[0-9]{1,2})?)\s*(?:dollars|usd)\b"#,
        ] {
            values.append(contentsOf: captures(pattern, in: sentence).compactMap { raw in
                Decimal(string: raw.replacingOccurrences(of: ",", with: ""))
            })
        }
        values.append(contentsOf: wordNumberDollarValues(in: sentence))
        return values
    }

    /// Bounded English number-word amounts followed by "dollars"/"usd" ("nine
    /// thousand dollars"). Deliberately small: units through ninety plus
    /// hundred/thousand/million multipliers — enough for authored fixtures, and an
    /// unparsed phrase simply contributes no value (fail closed).
    private static func wordNumberDollarValues(in sentence: String) -> [Decimal] {
        let words = tokens(in: sentence)
        var values: [Decimal] = []
        var index = 0
        while index < words.count {
            guard numberWords[words[index]] != nil else {
                index += 1
                continue
            }
            var end = index
            while end < words.count, numberWords[words[end]] != nil || words[end] == "and" {
                end += 1
            }
            if end < words.count, words[end] == "dollars" || words[end] == "usd",
               let value = parseNumberWords(Array(words[index..<end])) {
                values.append(value)
            }
            index = end + 1
        }
        return values
    }

    private static func parseNumberWords(_ words: [String]) -> Decimal? {
        var total = 0
        var current = 0
        var sawNumber = false
        for word in words where word != "and" {
            guard let entry = numberWords[word] else { return nil }
            sawNumber = true
            switch entry {
            case let .unit(value):
                current += value
            case .hundred:
                current = max(current, 1) * 100
            case let .multiplier(value):
                total += max(current, 1) * value
                current = 0
            }
        }
        return sawNumber ? Decimal(total + current) : nil
    }

    private enum NumberWord {
        case unit(Int)
        case hundred
        case multiplier(Int)
    }

    private static let numberWords: [String: NumberWord] = {
        var map: [String: NumberWord] = [:]
        let units = [
            "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
            "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
            "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
            "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
            "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
            "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
        ]
        for (word, value) in units { map[word] = .unit(value) }
        map["hundred"] = .hundred
        map["thousand"] = .multiplier(1_000)
        map["million"] = .multiplier(1_000_000)
        return map
    }()

    // MARK: - Dates

    private static func dateValues(in sentence: String) -> [TypedProseExpectedAnswer.Day] {
        var days: [TypedProseExpectedAnswer.Day] = []

        for match in groupCaptures(#"\b(\d{4})-(\d{1,2})-(\d{1,2})\b"#, in: sentence) {
            if let year = Int(match[0]), let month = Int(match[1]), let day = Int(match[2]) {
                appendValidDay(year: year, month: month, day: day, to: &days)
            }
        }
        for match in groupCaptures(#"\b(\d{1,2})/(\d{1,2})/(\d{4})\b"#, in: sentence) {
            if let month = Int(match[0]), let day = Int(match[1]), let year = Int(match[2]) {
                appendValidDay(year: year, month: month, day: day, to: &days)
            }
        }
        let monthNames = months.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        let named = #"(?i)\b("# + monthNames + #")\s+(\d{1,2})(?:st|nd|rd|th)?\s*,?\s*(\d{4})\b"#
        for match in groupCaptures(named, in: sentence) {
            if let month = months[match[0].lowercased()],
               let day = Int(match[1]), let year = Int(match[2]) {
                appendValidDay(year: year, month: month, day: day, to: &days)
            }
        }
        return days
    }

    private static func appendValidDay(year: Int, month: Int, day: Int, to days: inout [TypedProseExpectedAnswer.Day]) {
        guard (1...12).contains(month), (1...31).contains(day) else { return }
        days.append(TypedProseExpectedAnswer.Day(year: year, month: month, day: day))
    }

    private static let months: [String: Int] = [
        "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3,
        "april": 4, "apr": 4, "may": 5, "june": 6, "jun": 6, "july": 7, "jul": 7,
        "august": 8, "aug": 8, "september": 9, "sep": 9, "sept": 9,
        "october": 10, "oct": 10, "november": 11, "nov": 11, "december": 12, "dec": 12,
    ]

    // MARK: - Regex helpers

    private static func captures(_ pattern: String, in text: String) -> [String] {
        groupCaptures(pattern, in: text).compactMap(\.first)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }

    private static func groupCaptures(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).map { match in
            (1..<match.numberOfRanges).compactMap { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) }
            }
        }
    }
}
