import Foundation

/// NLRB case-type taxonomy. `unknown` NEVER erases source data — the raw
/// case-type code is preserved verbatim on the record.
public enum NlrbCaseTypeCategory: String, Codable, Equatable, Sendable, CaseIterable {
    case unfairLaborPractice = "unfair_labor_practice"
    case representation = "representation"
    case unitClarification = "unit_clarification"
    case unionDeauthorization = "union_deauthorization"
    case amendmentOfCertification = "amendment_of_certification"
    case unknown = "unknown"
}

/// Maps NLRB case-type codes to categories. An explicit source case-type
/// field wins over the code embedded in the case number (`01-RC-389901` →
/// middle segment `RC`).
enum NlrbCaseClassifier {
    private static let categoryByCode: [String: NlrbCaseTypeCategory] = [
        "CA": .unfairLaborPractice, "CB": .unfairLaborPractice, "CC": .unfairLaborPractice,
        "CD": .unfairLaborPractice, "CE": .unfairLaborPractice, "CG": .unfairLaborPractice,
        "CP": .unfairLaborPractice,
        "RC": .representation, "RD": .representation, "RM": .representation,
        "UC": .unitClarification,
        "UD": .unionDeauthorization,
        "AC": .amendmentOfCertification
    ]

    static func category(forCode code: String?) -> NlrbCaseTypeCategory {
        guard let code = code?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), !code.isEmpty else {
            return .unknown
        }
        return categoryByCode[code] ?? .unknown
    }

    /// The case-type code from a case number's middle segment, nil when the
    /// number doesn't carry one.
    static func code(fromCaseNumber caseNumber: String) -> String? {
        let segments = caseNumber
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "-")
            .map(String.init)
        guard segments.count >= 3 else { return nil }
        let candidate = segments[1].uppercased()
        guard candidate.count == 2, candidate.allSatisfy(\.isLetter) else { return nil }
        return candidate
    }

    /// (raw code, category): the explicit field is trimmed and preferred; the
    /// case number is the fallback.
    static func classify(caseNumber: String, explicitCaseType: String?) -> (code: String?, category: NlrbCaseTypeCategory) {
        let derived = code(fromCaseNumber: caseNumber)
        if let explicit = explicitCaseType?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            let explicitCategory = category(forCode: explicit)
            // A recognized explicit value always wins; an unrecognized one
            // must not BLOCK the case-number fallback. Only when neither is
            // recognized does the explicit value survive verbatim.
            if explicitCategory != .unknown || category(forCode: derived) == .unknown {
                return (explicit, explicitCategory)
            }
        }
        return (derived, category(forCode: derived))
    }
}
