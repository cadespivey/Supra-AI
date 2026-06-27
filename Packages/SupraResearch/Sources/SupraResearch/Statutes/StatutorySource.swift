import Foundation

/// How much weight a statutory source's text carries, by *verifiability of currency*.
/// Higher tiers win conflicts and are never overridden by lower ones (the locked policy:
/// user-provided > currency-verifiable > convenience).
public enum SourceWeightTier: Int, Sendable, Comparable, Codable {
    /// Free, best-effort lookups that cannot prove how current they are (e.g. Open Legal Codes).
    case convenience = 1
    /// Sources that carry a reliable version / effective-date (e.g. govinfo's USCODE `dateIssued`).
    case currencyVerifiable = 2
    /// Statutory text the user pasted or explicitly confirmed. Highest authority.
    case userProvided = 3

    public static func < (lhs: SourceWeightTier, rhs: SourceWeightTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A normalized statutory-lookup request, derived from the query classification.
public struct StatutoryQuery: Sendable, Equatable {
    /// Search terms (the legal issue), e.g. "statute of frauds sale of goods".
    public var terms: String
    /// Human jurisdiction label from the classifier, e.g. "Florida", "Federal".
    public var jurisdiction: String?
    /// A statutory citation the user mentioned, e.g. "Fla. Stat. § 672.201" or "42 U.S.C. § 1983".
    public var citation: String?
    /// Max provisions to return.
    public var limit: Int

    public init(terms: String, jurisdiction: String? = nil, citation: String? = nil, limit: Int = 4) {
        self.terms = terms
        self.jurisdiction = jurisdiction
        self.citation = citation
        self.limit = limit
    }
}

/// One statutory/regulatory provision returned by a source, normalized across providers so the
/// orchestrator can weight, dedupe, and rank them uniformly regardless of transport (REST, MCP, …).
public struct StatutoryProvision: Sendable, Equatable {
    public var sourceID: String            // "open-legal-codes", "govinfo", "openlaws", …
    public var sourceName: String          // "Open Legal Codes"
    public var weightTier: SourceWeightTier
    public var jurisdictionID: String?     // provider id, e.g. "fl-statutes" / "USCODE-2024-title11"
    public var jurisdictionName: String    // human, e.g. "Florida Statutes"
    public var citation: String            // "§ 672.201"
    public var heading: String?
    public var snippet: String?
    public var text: String                // the provision text to ground from (snippet if no full text)
    public var url: String?
    public var locatorPath: String?        // provider locator (e.g. OLC path) for a future preview
    /// A version / effective-date the source vouches for, or nil when it can't (the OLC case).
    public var effectiveDate: String?
    /// A caveat to show with this provision (non-nil for `.convenience` sources).
    public var currencyCaveat: String?

    public init(
        sourceID: String,
        sourceName: String,
        weightTier: SourceWeightTier,
        jurisdictionID: String? = nil,
        jurisdictionName: String,
        citation: String,
        heading: String? = nil,
        snippet: String? = nil,
        text: String,
        url: String? = nil,
        locatorPath: String? = nil,
        effectiveDate: String? = nil,
        currencyCaveat: String? = nil
    ) {
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.weightTier = weightTier
        self.jurisdictionID = jurisdictionID
        self.jurisdictionName = jurisdictionName
        self.citation = citation
        self.heading = heading
        self.snippet = snippet
        self.text = text
        self.url = url
        self.locatorPath = locatorPath
        self.effectiveDate = effectiveDate
        self.currencyCaveat = currencyCaveat
    }

    /// Dedup key — two provisions for the same section are the same regardless of which provider
    /// returned them, so the orchestrator's higher-tier-wins rule actually fires across providers.
    /// Keyed on STRUCTURED identity (the shared `jurisdictionID` space + the bare section number),
    /// NOT provider display names — e.g. eCFR's "40 CFR § 261.11" and a future provider's
    /// "§ 261.11" both reduce to `us-cfr-title-40|261.11`.
    public var dedupKey: String {
        let jurisdiction = (jurisdictionID ?? jurisdictionName).lowercased()
        return "\(jurisdiction)|\(Self.canonicalSection(from: citation))"
    }

    /// Reduces a citation to its bare section token: "40 CFR § 261.11" / "§ 672.201" → "261.11" / "672.201".
    static func canonicalSection(from citation: String) -> String {
        let lower = citation.lowercased()
        let afterSection = lower.range(of: "§").map { String(lower[$0.upperBound...]) } ?? lower
        if let range = afterSection.range(of: #"[0-9]+[0-9a-z.\-]*"#, options: .regularExpression) {
            return String(afterSection[range])
        }
        return afterSection.trimmingCharacters(in: .whitespaces)
    }
}

/// The result of one source's lookup. Best-effort: a source NEVER throws to the orchestrator —
/// on failure it returns no provisions plus an optional human note (e.g. "OLC is still crawling").
public struct StatutoryLookupResult: Sendable, Equatable {
    public var provisions: [StatutoryProvision]
    public var note: String?

    public init(provisions: [StatutoryProvision] = [], note: String? = nil) {
        self.provisions = provisions
        self.note = note
    }
}

/// A pluggable statutory source. Conform a new provider (govinfo, Openlaws, an MCP-backed source)
/// by implementing `lookup` over its transport and declaring its `weightTier`; the orchestrator and
/// the legal-research integration treat every conformer identically.
public protocol StatutorySource: Sendable {
    var id: String { get }
    var displayName: String { get }
    var weightTier: SourceWeightTier { get }
    /// Whether the source can stamp an effective date / version (drives currency caveats).
    var providesCurrency: Bool { get }
    /// Best-effort lookup. Implementations must not throw — wrap failures into the result's `note`.
    func lookup(_ query: StatutoryQuery) async -> StatutoryLookupResult
}
