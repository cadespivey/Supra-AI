import Foundation

/// How instruction-shaped a piece of untrusted text is.
public enum InstructionShapeTier: String, Sendable, Equatable, Codable {
    /// No instruction-shaped content detected.
    case clean
    /// Matched a pattern that also occurs in ordinary legal prose. Surfaced as a
    /// warning; never blocks, because blocking on these quarantines genuine authority.
    case advisory
    /// Matched a structurally unambiguous injection pattern. Blocks: the text is not
    /// usable as evidence.
    case blocking
}

/// What the detector found, including which pattern fired, so tests can pin a specific
/// rule rather than a bare boolean.
public struct InstructionShapeFinding: Sendable, Equatable {
    public let tier: InstructionShapeTier
    /// Stable identifier of the matched pattern, or nil when `tier == .clean`.
    public let patternID: String?

    public init(tier: InstructionShapeTier, patternID: String? = nil) {
        self.tier = tier
        self.patternID = patternID
    }

    public static let clean = InstructionShapeFinding(tier: .clean, patternID: nil)
}

/// The one detector for instruction-shaped (prompt-injection-shaped) content in
/// untrusted text.
///
/// Three private copies of this guard existed, written within 26 minutes of each other
/// and never reconciled: a 10-pattern regex list in the document verifier, a 6-pattern
/// list in the legal-citation verifier, and an 8-substring list in the draft verifier
/// with no word boundaries at all (it matched bare `"output format"` and `"assistant:"`).
/// They disagreed in both directions — one caught `"you are now"` and exfiltration
/// phrasing the others missed; another caught `"tool call"` the first missed.
///
/// ## Why two tiers
///
/// Every surface this guards holds LEGAL PROSE — imported pleadings and opinions on the
/// document side, court opinions on the research side. Four of the patterns fire on
/// routine litigation writing:
///
/// - `"Relators must show the claim was false and material."` (False Claims Act)
/// - `"To state a claim for defamation… which statements were false"`
/// - `"declined to reveal the identity of the confidential source"` (informant privilege)
/// - `"did not use the tool during the inspection"` (products liability)
/// - `"You are now in default under the Note."` (quoted default notice)
///
/// Measured over an adversarial probe set, the 10-pattern list flagged 7 of 8 genuine
/// legal excerpts while catching 9 of 14 injection payloads; the 6-pattern list flagged
/// 0 of 8 and caught 5 of 14. Blocking on the imprecise patterns therefore costs far
/// more than it buys — a false positive marks real authority unusable.
///
/// The precision trade is acceptable because this detector is a BACKSTOP, not a
/// barrier: untrusted text has already reached the model by the time any of this runs.
/// It only decides whether to distrust the resulting answer. Four of fourteen probes
/// evade every pattern in both lists, so treating it as a hard boundary was never sound.
public enum InstructionShapeDetector {
    /// Structurally unambiguous injection shapes. These do not occur in ordinary legal
    /// prose, so they block on every surface.
    static let blockingPatterns: [(id: String, pattern: String)] = [
        ("ignore-instructions", #"\bignore\b.{0,80}\b(instructions?|prompt|system|developer|assistant)\b"#),
        ("switch-role", #"\b(change|switch|override|assume)\b.{0,40}\b(role|persona|identity)\b"#),
        ("follow-these-instructions", #"\b(follow|obey|execute)\b.{0,40}\b(these|the following|my)\b.{0,20}\binstructions?\b"#),
        ("system-role-json", #"[\"']role[\"']\s*:\s*[\"']system[\"']"#),
        ("system-message", #"\bsystem message\b"#),
        ("tool-invocation", #"\btool (call|request)\b"#),
    ]

    /// Patterns that also match ordinary legal prose. Retained for their signal, but
    /// advisory only — see the type's discussion.
    static let advisoryPatterns: [(id: String, pattern: String)] = [
        ("exfiltrate-sources", #"\b(reveal|disclose|print|show)\b.{0,80}\b(other )?(source|prompt|secret|instruction)s?\b"#),
        ("assert-falsehood", #"\b(output|state|claim|answer|say)\b.{0,80}\b(false|fabricated|untrue|unsupported)\b"#),
        ("invoke-tool", #"\b(call|invoke|use|run)\b.{0,40}\b(tool|function|command)s?\b"#),
        ("you-are-now", #"\byou are now\b"#),
    ]

    /// Classifies untrusted text. Blocking patterns are checked first, so a text that
    /// matches both tiers is reported as blocking.
    public static func classify(_ text: String) -> InstructionShapeFinding {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return .clean }
        if let hit = firstMatch(in: normalized, among: blockingPatterns) {
            return InstructionShapeFinding(tier: .blocking, patternID: hit)
        }
        if let hit = firstMatch(in: normalized, among: advisoryPatterns) {
            return InstructionShapeFinding(tier: .advisory, patternID: hit)
        }
        return .clean
    }

    /// Whether the text must not be used as evidence.
    public static func isBlocking(_ text: String) -> Bool {
        classify(text).tier == .blocking
    }

    private static func firstMatch(
        in normalized: String,
        among patterns: [(id: String, pattern: String)]
    ) -> String? {
        patterns.first { normalized.range(of: $0.pattern, options: .regularExpression) != nil }?.id
    }

    /// Case- and diacritic-folded, whitespace-collapsed. Collapsing whitespace matters:
    /// the bounded `.{0,N}` gaps are measured in characters, so a payload broken across
    /// lines would otherwise slip past a pattern that matches the same words inline.
    static func normalize(_ text: String) -> String {
        text
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
