import Foundation
import SupraCore

public struct ValidationEvaluationInput: Codable, Hashable, Sendable {
    public var generationStarted: Bool
    public var streamingStarted: Bool
    public var completedWithoutCrash: Bool
    public var cancelRequestSent: Bool
    public var generationCancelled: Bool
    public var partialOutputPreserved: Bool
    public var output: String

    public init(
        generationStarted: Bool = false,
        streamingStarted: Bool = false,
        completedWithoutCrash: Bool = false,
        cancelRequestSent: Bool = false,
        generationCancelled: Bool = false,
        partialOutputPreserved: Bool = false,
        output: String = ""
    ) {
        self.generationStarted = generationStarted
        self.streamingStarted = streamingStarted
        self.completedWithoutCrash = completedWithoutCrash
        self.cancelRequestSent = cancelRequestSent
        self.generationCancelled = generationCancelled
        self.partialOutputPreserved = partialOutputPreserved
        self.output = output
    }
}

public struct ValidationTestEvaluation: Codable, Hashable, Sendable {
    public let testID: String
    public let status: ValidationTestStatus
    public let passedChecks: [String]
    public let warnings: [String]
    public let errors: [String]

    public init(
        testID: String,
        status: ValidationTestStatus,
        passedChecks: [String],
        warnings: [String],
        errors: [String]
    ) {
        self.testID = testID
        self.status = status
        self.passedChecks = passedChecks
        self.warnings = warnings
        self.errors = errors
    }
}

public struct ValidationEvaluator: Sendable {
    public init() {}

    public func evaluate(
        test: ValidationTest,
        input: ValidationEvaluationInput
    ) -> ValidationTestEvaluation {
        var passedChecks: [String] = []
        var warnings: [String] = []
        var errors: [String] = []

        for check in test.mechanicalChecks {
            if mechanicalCheckPassed(check, input: input) {
                passedChecks.append(check.rawValue)
            } else {
                errors.append("Mechanical check failed: \(check.rawValue)")
            }
        }

        for rule in test.ruleChecks {
            let result = evaluate(rule: rule, output: input.output)
            guard let message = result.message else {
                passedChecks.append(rule.type.rawValue)
                continue
            }

            switch rule.severity {
            case .warning:
                warnings.append(message)
            case .failure:
                errors.append(message)
            }
        }

        let status: ValidationTestStatus
        if !errors.isEmpty {
            status = .failed
        } else if !warnings.isEmpty {
            status = .warning
        } else {
            status = .passed
        }

        return ValidationTestEvaluation(
            testID: test.id,
            status: status,
            passedChecks: passedChecks,
            warnings: warnings,
            errors: errors
        )
    }

    private func mechanicalCheckPassed(
        _ check: MechanicalValidationCheck,
        input: ValidationEvaluationInput
    ) -> Bool {
        switch check {
        case .generationStarted:
            input.generationStarted
        case .streamingStarted:
            input.streamingStarted
        case .nonemptyOutput:
            !input.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .completedWithoutCrash:
            input.completedWithoutCrash
        case .cancelRequestSent:
            input.cancelRequestSent
        case .generationCancelled:
            input.generationCancelled
        case .partialOutputPreserved:
            input.partialOutputPreserved && !input.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func evaluate(
        rule: ValidationRuleCheck,
        output: String
    ) -> RuleEvaluationResult {
        switch rule.type {
        case .exactBulletCount:
            let expected = rule.count ?? 0
            let actual = bulletCount(in: output)
            return actual == expected
                ? .passed
                : .failed("Expected exactly \(expected) bullet points, found \(actual).")

        case .noIntroBeforeFirstBullet:
            let firstLine = output
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            return firstLine.map(isBulletLine) == true
                ? .passed
                : .failed("Expected first nonempty line to be a bullet.")

        case .roughSentenceLimit:
            let maxSentences = rule.maxSentences ?? 0
            let actual = sentenceCount(in: output)
            return actual <= maxSentences
                ? .passed
                : .failed("Expected \(maxSentences) sentences or fewer, found roughly \(actual).")

        case .containsTerms:
            let missingTerms = (rule.terms ?? []).filter { !output.localizedCaseInsensitiveContains($0) }
            return missingTerms.isEmpty
                ? .passed
                : .failed("Missing expected terms: \(missingTerms.joined(separator: ", ")).")

        case .containsAny:
            let terms = rule.terms ?? []
            return terms.contains { output.localizedCaseInsensitiveContains($0) }
                ? .passed
                : .failed("Expected output to contain at least one of: \(terms.joined(separator: ", ")).")

        case .containsHeading:
            let text = rule.text ?? ""
            return output.localizedCaseInsensitiveContains(text)
                ? .passed
                : .failed("Missing expected heading: \(text).")

        case .containsPlaceholder:
            return containsPlaceholder(output)
                ? .passed
                : .failed("Expected a bracketed placeholder such as [NEEDS AUTHORITY].")

        case .noCaseCitationPattern:
            return containsCaseCitationPattern(output)
                ? .failed("Output appears to contain a case citation pattern.")
                : .passed

        case .mustNotContainUnsupportedYes:
            return containsUnsupportedYes(output)
                ? .failed("Output appears to answer yes despite source text not supporting that answer.")
                : .passed
        }
    }

    private func bulletCount(in output: String) -> Int {
        output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter(isBulletLine)
            .count
    }

    private func isBulletLine(_ line: String) -> Bool {
        line.hasPrefix("- ")
            || line.hasPrefix("* ")
            || line.hasPrefix("• ")
            || line.range(of: #"^\d+\.\s+"#, options: .regularExpression) != nil
    }

    private func sentenceCount(in output: String) -> Int {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        let terminalCount = trimmed.reduce(0) { count, character in
            ".!?".contains(character) ? count + 1 : count
        }
        return max(1, terminalCount)
    }

    private func containsPlaceholder(_ output: String) -> Bool {
        output.range(of: #"\[[A-Z][A-Z\s]+(?:AUTHORITY|CITE|ASSUMPTION|PLACEHOLDER|RESEARCH)[A-Z\s]*\]"#, options: .regularExpression) != nil
            || output.localizedCaseInsensitiveContains("[NEEDS")
            || output.localizedCaseInsensitiveContains("[ASSUMPTION]")
    }

    private func containsCaseCitationPattern(_ output: String) -> Bool {
        let patterns = [
            #"\b[A-Z][A-Za-z]+ v\. [A-Z][A-Za-z]+\b"#,
            #"\b\d+\s+[A-Z][A-Za-z.]*\s+\d+\b"#,
            #"\b\d{4}\s+[A-Z]{2,}\s+\d+\b"#
        ]
        return patterns.contains { pattern in
            output.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private func containsUnsupportedYes(_ output: String) -> Bool {
        let lowercased = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !lowercased.isEmpty else { return false }

        if lowercased.hasPrefix("yes") {
            return true
        }

        let affirmativeArbitration = lowercased.contains("requires arbitration")
            || lowercased.contains("does require arbitration")
            || lowercased.contains("must arbitrate")

        let negated = lowercased.contains("does not")
            || lowercased.contains("doesn't")
            || lowercased.contains("not require")
            || lowercased.contains("no arbitration")
            || lowercased.contains("no,")

        return affirmativeArbitration && !negated
    }
}

private struct RuleEvaluationResult {
    let message: String?

    static let passed = RuleEvaluationResult(message: nil)

    static func failed(_ message: String) -> RuleEvaluationResult {
        RuleEvaluationResult(message: message)
    }
}
