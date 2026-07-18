import Foundation

/// Independent verification questions. Proposition support is retained as an
/// explicit dimension alongside the ten refinement-plan dimensions so the old
/// aggregate support result is factored rather than erased or repurposed.
public enum VerificationDimensionName: String, Codable, CaseIterable, Hashable, Sendable {
    case propositionSupport = "proposition_support"
    case citationResolution = "citation_resolution"
    case criticalValueFidelity = "critical_value_fidelity"
    case contraryEvidence = "contrary_evidence"
    case listCompleteness = "list_completeness"
    case chronologyCoverage = "chronology_coverage"
    case numericDateEntityReconciliation = "numeric_date_entity_reconciliation"
    case versionValidity = "version_validity"
    case lowConfidenceHandling = "low_confidence_handling"
    case corpusCoverage = "corpus_coverage"
    case negativeValidity = "negative_validity"
}

public enum VerificationDimensionStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case satisfied
    case failed
    case notRun = "not_run"
    case notApplicable = "not_applicable"
}

public struct VerificationDimensionEvidence: Codable, Equatable, Hashable, Sendable {
    public var sourceID: String
    public var sourceLabel: String?
    public var locator: String
    public var excerpt: String

    public init(sourceID: String, sourceLabel: String? = nil, locator: String, excerpt: String) {
        self.sourceID = sourceID
        self.sourceLabel = sourceLabel
        self.locator = locator
        self.excerpt = excerpt
    }
}

public struct VerificationDimensionResult: Codable, Equatable, Hashable, Sendable {
    public var dimension: VerificationDimensionName
    public var status: VerificationDimensionStatus
    public var reason: String?
    public var evidence: [VerificationDimensionEvidence]

    public init(
        dimension: VerificationDimensionName,
        status: VerificationDimensionStatus,
        reason: String? = nil,
        evidence: [VerificationDimensionEvidence] = []
    ) {
        self.dimension = dimension
        self.status = status
        self.reason = reason
        self.evidence = evidence
    }
}

/// Complete, ordered dimension ledger for one output version. Callers may form
/// partial values for validation tests, but repository writers accept only
/// `isComplete` ledgers and readers fail closed to `allNotRun` on absent or
/// malformed historical JSON.
public struct VerificationDimensions: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var results: [VerificationDimensionResult]

    public init(schemaVersion: Int = Self.schemaVersion, results: [VerificationDimensionResult]) {
        self.schemaVersion = schemaVersion
        self.results = results
    }

    public static var allNotRun: VerificationDimensions {
        complete(overrides: [])
    }

    public static func complete(
        overrides: [VerificationDimensionResult]
    ) -> VerificationDimensions {
        let overrideByName = Dictionary(
            overrides.map { ($0.dimension, $0) },
            uniquingKeysWith: { _, later in later }
        )
        return VerificationDimensions(results: VerificationDimensionName.allCases.map { name in
            overrideByName[name] ?? VerificationDimensionResult(
                dimension: name,
                status: .notRun,
                reason: "This verification dimension was not run for the version."
            )
        })
    }

    public var isComplete: Bool {
        schemaVersion == Self.schemaVersion
            && results.count == VerificationDimensionName.allCases.count
            && Set(results.map(\.dimension)) == Set(VerificationDimensionName.allCases)
    }

    public func result(for dimension: VerificationDimensionName) -> VerificationDimensionResult {
        results.first { $0.dimension == dimension } ?? VerificationDimensionResult(
            dimension: dimension,
            status: .notRun,
            reason: "This verification dimension was not recorded."
        )
    }

    /// `not_run` is never treated as satisfied. Tasks choose their required
    /// dimensions explicitly, keeping non-applicable future checks orthogonal.
    public func satisfies(required: Set<VerificationDimensionName>) -> Bool {
        required.allSatisfy { result(for: $0).status == .satisfied }
    }
}
