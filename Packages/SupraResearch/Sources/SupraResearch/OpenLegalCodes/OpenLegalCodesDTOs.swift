import Foundation

// DTOs modeled directly from live Open Legal Codes API responses
// (https://openlegalcodes.org/api/v1). Successful payloads are wrapped in
// `{ "data": ..., "meta": ... }`; crawl-state payloads (202/503) are top-level.

/// The `{ data, meta }` envelope every successful OLC response uses.
public struct OLCEnvelope<T: Decodable & Sendable>: Decodable, Sendable {
    public let data: T
    public let meta: OLCMeta?
}

public struct OLCMeta: Decodable, Sendable, Equatable {
    public let total: Int?
    public let limit: Int?
    public let offset: Int?
    public let timestamp: String?
    public let poweredBy: String?
}

/// A single statutory/regulatory section's full text (`/jurisdictions/:id/code/:path`).
public struct OLCSection: Decodable, Sendable, Equatable {
    public let jurisdiction: String          // jurisdiction id, e.g. "fl-statutes"
    public let jurisdictionName: String?
    public let codeId: String?
    public let path: String                  // slash-separated, e.g. "chapter-i/.../section-1.1"
    public let num: String?                  // e.g. "§ 1.1"
    public let heading: String?
    public let level: String?
    public let text: String
    public let url: String?
}

/// Search results within one code, or across jurisdictions. For a within-code search the
/// `results` carry only `path`; for a cross-jurisdiction search each hit also names its
/// `jurisdictionId`/`jurisdictionName`.
public struct OLCSearchResults: Decodable, Sendable, Equatable {
    public let jurisdiction: String?
    public let jurisdictionName: String?
    public let codeId: String?
    public let query: String
    public let results: [OLCSearchHit]
}

public struct OLCSearchHit: Decodable, Sendable, Equatable {
    public let jurisdictionId: String?
    public let jurisdictionName: String?
    public let path: String
    public let num: String?
    public let heading: String?
    public let snippet: String?
    public let url: String?
}

/// A jurisdiction's metadata (`/jurisdictions/:id`). The freshness fields
/// (`lastCrawled`/`lastUpdated`/`lastScanned`) are frequently empty strings — OLC exposes
/// no reliable currency stamp, which is why OLC statutory text is treated as un-verified.
public struct OLCJurisdiction: Decodable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let type: String                  // "federal" | "state" | "county" | "city"
    public let state: String?
    public let parentId: String?
    public let sourceUrl: String?
    public let lastCrawled: String?
    public let lastUpdated: String?
    public let lastScanned: String?
    public let status: String                // "cached" | "available" | "discoverable" | ...
    public let publisher: Publisher?

    public struct Publisher: Decodable, Sendable, Equatable {
        public let name: String?
        public let sourceId: String?
        public let url: String?
    }

    /// Whether OLC reports the code's text as already crawled and instantly retrievable.
    public var isCached: Bool { status.lowercased() == "cached" }

    /// Whether OLC exposes any non-empty freshness timestamp at all.
    public var hasFreshnessStamp: Bool {
        [lastCrawled, lastUpdated, lastScanned].contains { ($0?.isEmpty == false) }
    }
}

/// The top-level body returned for crawl states (HTTP 202 `CRAWL_IN_PROGRESS`,
/// HTTP 503 `CRAWL_FAILED`).
public struct OLCCrawlStatus: Decodable, Sendable, Equatable {
    public let status: String
    public let message: String?
    public let error: String?
    public let retryAfter: TimeInterval?
}
