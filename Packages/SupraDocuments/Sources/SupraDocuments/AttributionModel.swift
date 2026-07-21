import Foundation

// Phase 0 of the reasoning-framework reorganization: the typed value model a grounded
// answer is expressed in, so attribution can be validated by EXACT structural rules
// instead of lexical token-overlap. These types live in SupraDocuments for now (home of
// the existing grounding/verification types); they graduate to a dedicated SupraReasoning
// package at Phase 4. Nothing here calls a model — the model EMITS an AnswerDraft (later
// phases) and this module validates it.

/// A stable identifier for a retrieved evidence span. **Not** a positional ordinal:
/// for documents it is the existing source id ("matter/chunk"); for authorities the
/// packet authority id. Stability is what lets a citation survive packet re-ordering.
public struct SpanID: Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public var description: String { rawValue }
}

/// A retrieved evidence span the model may cite. `exactText` is the ONLY text a quote may
/// be validated against; `id` is stable across packet ordering.
public struct Span: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable { case document, authority }

    public let id: SpanID
    public let kind: Kind
    public let exactText: String
    public let lowConfidence: Bool

    public init(id: SpanID, kind: Kind, exactText: String, lowConfidence: Bool = false) {
        self.id = id
        self.kind = kind
        self.exactText = exactText
        self.lowConfidence = lowConfidence
    }
}

/// The set of spans offered to the model for one grounded turn. Attribution validation is
/// closed over this set: a citation to anything outside it is a structural violation.
public struct EvidenceSet: Sendable, Codable, Equatable {
    public let spans: [Span]

    public init(spans: [Span]) { self.spans = spans }

    public var ids: Set<SpanID> { Set(spans.map(\.id)) }
    public func span(_ id: SpanID) -> Span? { spans.first { $0.id == id } }
}

/// A verbatim quotation the model claims is drawn from a specific span. Validated as an
/// exact substring of that span's `exactText`.
public struct Quote: Sendable, Codable, Equatable {
    public let spanID: SpanID
    public let verbatim: String

    public init(spanID: SpanID, verbatim: String) {
        self.spanID = spanID
        self.verbatim = verbatim
    }
}

/// One unit of a grounded answer: prose bound to the spans that support it. A material
/// segment with no citations and no quotes is an uncited claim (a structural violation).
public struct Segment: Sendable, Codable, Equatable {
    public let text: String
    public let citations: [SpanID]
    public let quotes: [Quote]

    public init(text: String, citations: [SpanID] = [], quotes: [Quote] = []) {
        self.text = text
        self.citations = citations
        self.quotes = quotes
    }
}

/// Why a grounded turn declined to answer — the typed replacement for the canonical
/// refusal *sentence* that three code paths string-match today. A refusal asserts nothing,
/// so it is a clean outcome that carries no attribution and is never a "proposition."
public struct Refusal: Sendable, Codable, Equatable {
    public enum Reason: String, Sendable, Codable {
        /// Sources were retrieved but none support an answer to the question.
        case noCoverage
        /// The selected scope is not fully indexed yet.
        case stillIndexing
        /// Nothing is indexed in scope at all.
        case emptyScope
    }

    public let reason: Reason
    public init(_ reason: Reason) { self.reason = reason }
}

/// A typed grounded answer: either substantive `segments`, or a typed `refusal`. Kept as
/// explicit fields (rather than an enum) so a tolerant decoder can populate whichever the
/// model produced, and `reasoning` carries the model's `<think>` channel as data rather
/// than a tag parsed out of prose.
public struct AnswerDraft: Sendable, Codable, Equatable {
    public let segments: [Segment]
    public let refusal: Refusal?
    public let reasoning: String?

    public init(segments: [Segment] = [], refusal: Refusal? = nil, reasoning: String? = nil) {
        self.segments = segments
        self.refusal = refusal
        self.reasoning = reasoning
    }

    /// True when the model declined to answer for lack of supporting evidence.
    public var insufficientEvidence: Bool { refusal != nil }
}
