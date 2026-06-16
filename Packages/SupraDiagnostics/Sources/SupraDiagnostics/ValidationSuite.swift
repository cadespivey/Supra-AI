import Foundation

public struct ValidationSuite: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let version: Int
    public let name: String
    public let description: String
    public let passPolicy: String
    public let tests: [ValidationTest]

    public init(
        id: String,
        version: Int,
        name: String,
        description: String,
        passPolicy: String,
        tests: [ValidationTest]
    ) {
        self.id = id
        self.version = version
        self.name = name
        self.description = description
        self.passPolicy = passPolicy
        self.tests = tests
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case version
        case name
        case description
        case passPolicy = "pass_policy"
        case tests
    }
}

public struct ValidationTest: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let prompt: String
    public let expectedBehavior: String
    public let mechanicalChecks: [MechanicalValidationCheck]
    public let ruleChecks: [ValidationRuleCheck]

    public init(
        id: String,
        name: String,
        prompt: String,
        expectedBehavior: String,
        mechanicalChecks: [MechanicalValidationCheck],
        ruleChecks: [ValidationRuleCheck]
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.expectedBehavior = expectedBehavior
        self.mechanicalChecks = mechanicalChecks
        self.ruleChecks = ruleChecks
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case prompt
        case expectedBehavior = "expected_behavior"
        case mechanicalChecks = "mechanical_checks"
        case ruleChecks = "rule_checks"
    }
}

public enum MechanicalValidationCheck: String, Codable, Hashable, Sendable {
    case generationStarted = "generation_started"
    case streamingStarted = "streaming_started"
    case nonemptyOutput = "nonempty_output"
    case completedWithoutCrash = "completed_without_crash"
    case cancelRequestSent = "cancel_request_sent"
    case generationCancelled = "generation_cancelled"
    case partialOutputPreserved = "partial_output_preserved"
}

public struct ValidationRuleCheck: Codable, Hashable, Sendable {
    public let type: ValidationRuleCheckType
    public let severity: ValidationRuleSeverity
    public let count: Int?
    public let maxSentences: Int?
    public let terms: [String]?
    public let text: String?

    public init(
        type: ValidationRuleCheckType,
        severity: ValidationRuleSeverity,
        count: Int? = nil,
        maxSentences: Int? = nil,
        terms: [String]? = nil,
        text: String? = nil
    ) {
        self.type = type
        self.severity = severity
        self.count = count
        self.maxSentences = maxSentences
        self.terms = terms
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case severity
        case count
        case maxSentences = "max_sentences"
        case terms
        case text
    }
}

public enum ValidationRuleCheckType: String, Codable, Hashable, Sendable {
    case exactBulletCount = "exact_bullet_count"
    case noIntroBeforeFirstBullet = "no_intro_before_first_bullet"
    case roughSentenceLimit = "rough_sentence_limit"
    case containsTerms = "contains_terms"
    case containsAny = "contains_any"
    case containsHeading = "contains_heading"
    case containsPlaceholder = "contains_placeholder"
    case noCaseCitationPattern = "no_case_citation_pattern"
    case mustNotContainUnsupportedYes = "must_not_contain_unsupported_yes"
}

public enum ValidationRuleSeverity: String, Codable, Hashable, Sendable {
    case warning
    case failure
}
