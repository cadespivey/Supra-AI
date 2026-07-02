import Foundation

/// The unified "legal developments" tracking layer — a sibling to `StatutorySource`, NOT part of
/// the citable-authority packet. Developments are *what's pending or changing* (bills, proposed
/// rules, notices), surfaced to the attorney as context — never cited as authority for a legal
/// proposition (that would corrupt the firewall). Conform a provider (Federal Register today;
/// OpenStates / Regulations.gov next) by implementing `lookup` over its transport.

public enum LegalDevelopmentKind: String, Sendable, Equatable, Codable {
    case legislative   // a bill (OpenStates)
    case regulatory    // a rulemaking / proposed rule / notice (Federal Register / Regulations.gov)
}

public struct LegalDevelopmentQuery: Sendable, Equatable {
    public var terms: String
    public var jurisdiction: String?
    public var limit: Int
    /// Optional ISO date bounds (from the classified prompt, e.g. "since 2024") that
    /// date-capable sources apply as publication/action filters.
    public var dateAfter: String?
    public var dateBefore: String?

    public init(terms: String, jurisdiction: String? = nil, limit: Int = 5, dateAfter: String? = nil, dateBefore: String? = nil) {
        self.terms = terms
        self.jurisdiction = jurisdiction
        self.limit = limit
        self.dateAfter = dateAfter
        self.dateBefore = dateBefore
    }
}

/// A normalized development across providers, so the orchestrator can merge/dedupe/sort uniformly.
public struct LegalDevelopment: Sendable, Equatable {
    public var sourceID: String
    public var sourceName: String
    public var kind: LegalDevelopmentKind
    public var identifier: String      // "FR Doc 2026-12993" / "FL HB 123"
    public var title: String
    public var jurisdiction: String    // "Federal" / "Florida"
    public var status: String?         // "Proposed Rule (HHS)" / "Passed House 2026-03-04"
    public var date: String?           // publication / last-action date (ISO, for sorting)
    public var summary: String?
    public var url: String?

    public init(
        sourceID: String,
        sourceName: String,
        kind: LegalDevelopmentKind,
        identifier: String,
        title: String,
        jurisdiction: String,
        status: String? = nil,
        date: String? = nil,
        summary: String? = nil,
        url: String? = nil
    ) {
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.kind = kind
        self.identifier = identifier
        self.title = title
        self.jurisdiction = jurisdiction
        self.status = status
        self.date = date
        self.summary = summary
        self.url = url
    }

    public var dedupKey: String { "\(kind.rawValue)|\(identifier.lowercased())" }
}

public struct LegalDevelopmentLookupResult: Sendable, Equatable {
    public var developments: [LegalDevelopment]
    public var note: String?

    public init(developments: [LegalDevelopment] = [], note: String? = nil) {
        self.developments = developments
        self.note = note
    }
}

public protocol LegalDevelopmentSource: Sendable {
    var id: String { get }
    var displayName: String { get }
    var kind: LegalDevelopmentKind { get }
    /// Best-effort — must not throw; wrap failures into the result's `note`.
    func lookup(_ query: LegalDevelopmentQuery) async -> LegalDevelopmentLookupResult
}
