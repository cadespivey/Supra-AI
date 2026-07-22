import Foundation

/// Result of the narrow instruction-shaped evidence rejection policy.
public enum InstructionShapeTier: String, Sendable, Equatable, Codable {
    /// No rejection pattern matched. This does not mean the text is trusted or attack-free.
    case clean
    /// Matched a narrow, high-confidence rejection pattern; the text is not usable as evidence.
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

/// The shared, narrow rejection policy for instruction-shaped content in untrusted text.
///
/// Three private copies of this guard existed, written within 26 minutes of each other
/// and never reconciled: a 10-pattern regex list in the document verifier, a 6-pattern
/// list in the legal-citation verifier, and an 8-substring list in the draft verifier
/// with no word boundaries at all (it matched bare `"output format"` and `"assistant:"`).
/// They disagreed in both directions — one caught `"you are now"` and exfiltration
/// phrasing the others missed; another caught `"tool call"` the first missed.
///
/// ## Why there is no advisory tier
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
/// The former advisory patterns had no production consumer and classified all of the
/// ordinary legal examples above as suspicious. Keeping a public signal with no behavior
/// invited callers to promote those false positives into a gate, so Phase 5 removed it.
///
/// This policy is a BACKSTOP, not a prompt-injection security boundary. Source-data
/// envelopes and explicit instructions keep evidence separate from operator instructions;
/// these regexes only reject a small set of especially unambiguous shapes. The committed
/// injection/legal-prose corpus and `InstructionShapeCorpusTests` publish the policy's
/// deliberately incomplete recall and its false-positive count from inspectable inputs.
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

    /// Applies the narrow evidence-rejection policy. `.clean` means only that none of
    /// these patterns matched; it is not a trust or attack-detection verdict.
    public static func classify(_ text: String) -> InstructionShapeFinding {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return .clean }
        if let hit = firstMatch(in: normalized, among: blockingPatterns) {
            return InstructionShapeFinding(tier: .blocking, patternID: hit)
        }
        return .clean
    }

    /// Whether the text matches the narrow policy and must not be used as evidence.
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
