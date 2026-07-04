# Government Data Connectors - Claude Execution Plan

This plan is for Claude Code working in the existing Supra AI repository.
It translates `/Users/cadespivey/Desktop/supra_ai_government_data_connectors.md`
into repo-specific implementation steps.

Verified context:

- The app is a SwiftUI macOS app with public legal-data clients in
  `Packages/SupraResearch`.
- Existing network policy lives in `Packages/SupraNetworking`.
- Existing app persistence lives in `Packages/SupraStore`, but
  `SupraResearch` currently does not import `SupraStore`.
- Tests use XCTest and async stubs around `AuthorizedHTTPClientProtocol`.
- Docs live under `Docs/`, not lowercase `docs/`.
- Do not revert current user changes in:
  - `Packages/SupraResearch/Sources/SupraResearch/LegalResearch/BluebookCitation.swift`
  - `Packages/SupraResearch/Tests/SupraResearchTests/GroundedRetrievalHardeningTests.swift`

Official source checks made before this plan:

- SEC EDGAR API docs confirm unauthenticated JSON APIs at
  `https://data.sec.gov/submissions/CIK##########.json`,
  `companyconcept`, `companyfacts`, and `frames`; submissions include current
  company metadata and recent filings, and additional filing-history JSON files
  when more filings exist. SEC also publishes nightly bulk ZIPs.
  Source: https://www.sec.gov/search-filings/edgar-application-programming-interfaces
- CFPB API docs confirm base server
  `https://www.consumerfinance.gov/data-research/consumer-complaints/search/api/v1/`,
  search at `/`, complaint-by-id at `/{complaintId}`, trends at `/trends`, and
  documented filters including company, product, issue, state, zip code,
  date_received_min/max, has_narrative, submitted_via, tags, and timely.
  Sources: https://cfpb.github.io/api/ccdb/api.html and
  https://github.com/cfpb/ccdb5-api/blob/main/swagger-config.yaml
- NLRB official pages expose recent filings and recent election results with
  `Download CSV` links; NLRB also lists historical CATS/CHIPS data via Data.gov
  or the National Archives catalog. Treat NLRB as dataset/export-first, not as a
  stable REST API. Sources:
  https://www.nlrb.gov/reports/graphs-data/recent-filings,
  https://www.nlrb.gov/reports/graphs-data/recent-election-results,
  https://www.nlrb.gov/data-on-datagov, and
  https://www.nlrb.gov/advanced-search.

## Work Order

Implement in this order. Do not build UI in this pass unless required to wire a
compile break. The deliverable is reusable connector APIs, normalization,
cache/dedup, tests, and docs.

## Ambiguity Audit

This section records the ambiguity in the original prompt and fixes the
implementation choices before Claude starts coding.

1. Connector home
   - Decision: put reusable connector logic in `Packages/SupraResearch`.
   - Reason: existing official legal/public-data clients already live there
     (`CourtListener`, `OpenLegalCodes`, `Statutes`, `Developments`).
   - Do not create a new package in this milestone.

2. Persistence
   - Decision: use a protocol-driven, file-backed connector cache/store inside
     `SupraResearch`.
   - Reason: `SupraResearch` currently depends on `SupraCore` and
     `SupraNetworking`, while `SupraStore` depends outward from the app data
     layer. Importing `SupraStore` into `SupraResearch` would change package
     boundaries and risks dependency drift.
   - Do not add GRDB migrations in this milestone.

3. App integration
   - Decision: expose connector APIs and `LegalDataIngestionRecord` output only.
   - Do not wire these connectors into `GlobalChatController`,
     `ResearchSessionController`, `DocumentIndexingService`, SwiftUI views, or
     app settings in this milestone unless compilation requires a tiny export.

4. Network path
   - Decision: every request uses `AuthorizedHTTPClientProtocol.sendUnauthenticated`.
   - Reason: `send` is CourtListener-token-specific and intentionally refuses
     non-CourtListener authenticated hosts.
   - Regression guard: add tests that connector stubs fail if `send` is called.

5. Live tests
   - Decision: all live tests are opt-in and skipped by default.
   - Gate: `LEGAL_DATA_CONNECTORS_ENABLE_LIVE_TESTS=true`.
   - SEC live tests also require `SEC_EDGAR_USER_AGENT`.

6. Naming
   - Decision: use Swift type names `SecEdgarConnector`,
     `CfpbComplaintConnector`, and `NlrbDataConnector`.
   - Directory casing may follow existing style, but use the exact type names
     above.

7. Dates
   - Decision: store source dates as source strings in normalized models unless
     a field is used for sorting/filtering. For sorting/filtering, parse through
     small local helpers that accept ISO dates and NLRB display dates. Do not
     globally change `SupraCore/DateCoding.swift`.

8. Raw data preservation
   - Decision: preserve raw decoded JSON/CSV row values as `JSONValue`, not as
     arbitrary dictionaries or lossy strings. For CSV rows, store the raw
     header-to-value object.

9. Source uncertainty
   - Decision: when official behavior is unclear, document the uncertainty in
     the connector doc and add a test around the chosen defensive behavior.
   - Do not hard-code private, browser-discovered, session-bound, or form-token
     URLs as if they are stable APIs.

## Non-Regression Guardrails

Claude must keep these invariants intact:

- Do not modify existing CourtListener, eCFR, GovInfo, OpenLegalCodes, Federal
  Register, or Regulations.gov behavior except for shared tests that prove the
  new network allow-list entries are allowed.
- Do not loosen `NetworkPolicyService` beyond the explicit official hosts in
  this plan. Keep HTTPS-only, no embedded credentials.
- Do not send API keys, SEC User-Agent contents, local paths, raw query terms,
  raw payloads, or stack traces to user-facing errors.
- Do not change `AuthorizedHTTPClient` token injection rules.
- Do not add dependencies to `SupraResearch/Package.swift` unless absolutely
  necessary. Foundation and CryptoKit are enough for this milestone.
- Keep new code Swift 6 compatible. Public cross-concurrency types should be
  `Sendable`; classes that wrap immutable collaborators can use
  `@unchecked Sendable` following existing clients.
- Keep line-ending and formatting style close to the existing Swift files.
- Add fixtures under `Packages/SupraResearch/Tests/SupraResearchTests/Fixtures/`
  rather than embedding large JSON/CSV strings in every test. Small inline
  snippets are fine for narrow unit tests.

## Phase 0 - Repo Safety And Baseline

1. Run `git status --short --branch`.
2. Confirm the two dirty SupraResearch files above are user-owned and leave them
   alone unless a test failure proves they must be touched.
3. Use `rg --files Packages/SupraResearch Packages/SupraNetworking Docs` to
   orient before editing.
4. Run or attempt:
   - `swift test --package-path Packages/SupraResearch`
   - `swift test --package-path Packages/SupraNetworking`
   If XCTest cannot resolve under CommandLineTools, switch to the full Xcode
   toolchain or verify through the app workspace with `xcodebuild test`.
5. Record baseline failures before editing. If baseline fails, do not "fix"
   unrelated failures inside the connector commit. Mention them in the final
   implementation note.
6. Before editing network policy, run:
   `sed -n '1,220p' Packages/SupraNetworking/Sources/SupraNetworking/NetworkPolicyService.swift`
   and preserve all existing allowed hosts.
7. Before editing connector code, inspect representative existing clients:
   - `Packages/SupraResearch/Sources/SupraResearch/OpenLegalCodes/OpenLegalCodesClient.swift`
   - `Packages/SupraResearch/Sources/SupraResearch/Statutes/ECFRClient.swift`
   - `Packages/SupraResearch/Sources/SupraResearch/Developments/FederalRegisterClient.swift`
   - `Packages/SupraResearch/Sources/SupraResearch/CourtListener/CourtListenerClient.swift`
   Use their patterns for protocol-first clients, request construction, and
   typed error mapping.

## Phase 1 - Shared Connector Infrastructure

Create `Packages/SupraResearch/Sources/SupraResearch/Connectors/`.

Add these files:

- `LegalDataConnectorConfiguration.swift`
- `LegalDataConnectorError.swift`
- `LegalDataConnectorCache.swift`
- `LegalDataConnectorModels.swift`
- `ConnectorPacer.swift`
- `JSONValue.swift`

### Required Shared Types

Use these concrete shapes unless a compile issue requires a minor Swift
adjustment. Keep the semantic contract identical.

```swift
public struct LegalDataConnectorConfiguration: Sendable, Equatable {
    public var cacheDirectory: URL
    public var nlrbLocalDataDirectory: URL
    public var liveTestsEnabled: Bool
    public var secEdgarUserAgent: String?
    public var secEdgarRateLimitPerSecond: Double
    public var cfpbRateLimitPerSecond: Double
    public var nlrbRateLimitPerSecond: Double

    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Self
    public func requireSecEdgarUserAgent(connectorName: String, operation: String) throws -> String
}
```

```swift
public struct ConnectorHealth: Codable, Equatable, Sendable {
    public var connectorName: String
    public var checkedAt: Date
    public var reachable: Bool
    public var message: String
    public var sanitizedMetadata: [String: String]
}
```

```swift
public struct LegalDataCacheEntry: Codable, Equatable, Sendable {
    public var connectorName: String
    public var operation: String
    public var requestURL: String
    public var requestParams: JSONValue
    public var retrievedAt: Date
    public var expiresAt: Date?
    public var httpStatus: Int
    public var rawPayloadBase64: String
    public var payloadHash: String
}
```

```swift
public struct LegalDataIngestionRecord: Codable, Equatable, Sendable {
    public var source: String
    public var sourceVariant: String?
    public var sourceRecordType: String
    public var sourceRecordId: String
    public var sourceUrl: String?
    public var retrievedAt: Date
    public var rawPayload: JSONValue
    public var normalizedPayload: JSONValue
    public var ragText: String
    public var rawHash: String
    public var normalizedHash: String
}
```

```swift
public protocol LegalDataConnectorCache: Sendable {
    func get(key: String, now: Date) async throws -> LegalDataCacheEntry?
    func put(_ entry: LegalDataCacheEntry, key: String) async throws
    func removeExpired(now: Date) async throws
}
```

Implement:

1. `LegalDataConnectorConfiguration`
   - Reads from an injected environment dictionary, defaulting to
     `ProcessInfo.processInfo.environment`.
   - Values:
     - `SEC_EDGAR_USER_AGENT`
     - `SEC_EDGAR_RATE_LIMIT_PER_SECOND`, default 2, max 10
     - `CFPB_RATE_LIMIT_PER_SECOND`, default 2
     - `NLRB_RATE_LIMIT_PER_SECOND`, default 1
     - `LEGAL_DATA_CACHE_DIR`
     - `NLRB_LOCAL_DATA_DIR`
     - `LEGAL_DATA_CONNECTORS_ENABLE_LIVE_TESTS`
   - Default cache directory when env is missing:
     `FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]/SupraAI/LegalDataConnectors`.
   - SEC must fail fast before any request if `SEC_EDGAR_USER_AGENT` is blank.
   - Parse booleans accepting only `true`, `false`, `1`, `0`, `yes`, `no`,
     case-insensitive. Any other value should fall back to default and add a
     sanitized warning only in docs/tests, not crash app startup.
   - Rate limits:
     - `SEC_EDGAR_RATE_LIMIT_PER_SECOND`: default `2`, clamp to `0.1...10`.
     - `CFPB_RATE_LIMIT_PER_SECOND`: default `2`, clamp to `0.1...10`.
     - `NLRB_RATE_LIMIT_PER_SECOND`: default `1`, clamp to `0.05...5`.
   - Do not read `.env` files directly. Supra currently relies on environment
     injection or Keychain-backed stores elsewhere.

2. `LegalDataConnectorError`
   - Use one enum with cases matching the prompt:
     `config`, `validation`, `rateLimit`, `sourceUnavailable`, `download`,
     `notFound`, `parse`, `importFailed`, `transport`.
   - Store:
     `connectorName`, `operation`, `sourceVariant`, `sourceURL`,
     `httpStatus`, `retryable`, `message`, `sanitizedMetadata`.
   - Conform to `Error`, `Equatable` where practical, `Sendable`,
     `LocalizedError`.
   - Never include secrets, local paths, raw stack traces, or raw payloads in
     user-facing descriptions.
   - Error mapping rules:
     - HTTP 400/422 -> `validation`, retryable `false`.
     - HTTP 401/403 -> `sourceUnavailable`, retryable `false`.
     - HTTP 404 -> `notFound`, retryable `false`.
     - HTTP 429 -> `rateLimit`, retryable `true`.
     - HTTP 500...599 -> `sourceUnavailable`, retryable `true`.
     - JSON decode failure -> `parse`, retryable `false`.
     - Network policy block -> `sourceUnavailable`, retryable `false`.
     - Local pacing exhaustion should not normally throw; if it does, map to
       `rateLimit`, retryable `true`.
   - `sanitizedMetadata` may include connector operation, HTTP status,
     normalized CIK, record count, and source variant. It must not include raw
     query strings for user-entered search terms.

3. `LegalDataConnectorCache`
   - Define protocol exactly as shown in `Required Shared Types`:
     `get(key:now:)`, `put(_:key:)`, `removeExpired(now:)`.
   - Default implementation: file-backed JSON cache under
     `LEGAL_DATA_CACHE_DIR/{connectorName}/`.
   - Cache entry fields:
     `connectorName`, `operation`, `requestURL`, `requestParams`,
     `retrievedAt`, `expiresAt`, `httpStatus`, `rawPayloadBase64`,
     `payloadHash`.
   - Record entry fields:
     `source`, `sourceVariant`, `sourceRecordId`, `sourceUrl`, `retrievedAt`,
     `rawPayload`, `normalizedPayload`, `ragText`, `rawHash`,
     `normalizedHash`.
   - Use `CryptoKit.SHA256` for hashes.
   - Dedup keys:
     `source + sourceRecordId`, `source + sourceUrl`, content hash.
   - Cache key rule:
     `sha256(method + "\n" + absoluteURL + "\n" + canonicalRequestParamsJSON)`.
     Use the final URL after `URLComponents` encoding. Do not include transient
     headers such as `User-Agent`.
   - File layout:
     - `LEGAL_DATA_CACHE_DIR/{connectorName}/responses/{cacheKey}.json`
     - `LEGAL_DATA_CACHE_DIR/{connectorName}/records/{sourceRecordIdHash}.json`
     - `LEGAL_DATA_CACHE_DIR/{connectorName}/dedup-index.json`
   - `sourceRecordIdHash` is
     `sha256(source + "\n" + (sourceVariant ?? "") + "\n" + sourceRecordId)`.
   - Writes must be atomic: write to a temp file in the same directory and move
     into place.
   - Cache miss means no file, expired file, unreadable JSON, or hash mismatch.
     If a cache file is corrupt, ignore it and replace it on the next successful
     source fetch.
   - Do not cache non-2xx responses in this milestone.
   - Suggested TTLs:
     - SEC submissions: 6 hours.
     - SEC XBRL facts/concept/frame: 24 hours.
     - CFPB search and complaint-by-ID: 24 hours.
     - CFPB trends/profile searches: 24 hours.
     - NLRB official CSV discovery page: 6 hours.
     - NLRB imported dataset records: no expiry until explicit refresh.

4. `ConnectorPacer`
   - Actor that enforces per-connector minimum delay between requests:
     `minDelay = 1.0 / requestsPerSecond`.
   - Keep using `AuthorizedHTTPClientProtocol.sendUnauthenticated`; do not call
     `send`, because `send` is CourtListener-token-specific.
   - For 429 and 5xx, support bounded retry with `Retry-After` when present.
   - Retry policy:
     - Max attempts: 3 total.
     - Retry only 429, 502, 503, 504, and transport failures that are not
       validation/policy errors.
     - Delay: `Retry-After` if present, else 0.5s, then 1.0s.
     - Tests may inject a sleeper closure so retry tests do not actually wait.
   - Pacing must happen before each actual network attempt, including retries.

5. `JSONValue`
   - Small `Codable`, `Equatable`, `Sendable` enum for preserving unknown JSON:
     object, array, string, number, bool, null.
   - Also add helpers to encode stable canonical JSON for hashing.
   - Preserve integer-looking and decimal-looking numbers as `Double` is
     acceptable for normalized convenience values, but raw JSON preservation
     should avoid stringifying numbers. If exact numeric round-tripping is hard,
     document the limitation and keep the original raw bytes in cache entries.

6. Shared HTTP helper
   - Add a small internal helper, for example `ConnectorHTTPExecutor`, to avoid
     duplicating cache/pacer/retry/status handling in all three connectors.
   - It should accept:
     `connectorName`, `operation`, `URLRequest`, `cacheTTL`, `cacheKey`,
     `decode`.
   - It should return both decoded payload and raw `Data` so normalizers can
     hash and preserve raw source data.
   - Keep it internal to `SupraResearch`; the public API should be connector
     types and models, not a general HTTP framework.

Update `Packages/SupraNetworking/Sources/SupraNetworking/NetworkPolicyService.swift`:

- Add official hosts:
  - SEC: `data.sec.gov`, `www.sec.gov`, `sec.gov`
  - CFPB: `www.consumerfinance.gov`, `consumerfinance.gov`
  - NLRB: `www.nlrb.gov`, `nlrb.gov`
  - Historical-data discovery only as needed after source confirmation:
    `catalog.data.gov`, `www.data.gov`, `catalog.archives.gov`
- Add tests in `Packages/SupraNetworking/Tests/SupraNetworkingTests/SupraNetworkingTests.swift`
  proving these hosts are HTTPS-only and credential-free.
- Negative tests:
  - `http://data.sec.gov/...` is rejected.
  - `https://user:pass@www.consumerfinance.gov/...` is rejected.
  - `https://example.nlrb.gov/...` is rejected unless it is explicitly listed.

Update `.env.example` with the connector env vars. Leave secrets blank.

Shared infrastructure tests:

- `LegalDataConnectorConfigurationTests.swift`
  - Defaults.
  - Env overrides.
  - SEC rate clamp at 10.
  - Invalid booleans do not crash.
  - Cache directory default is non-empty.
- `LegalDataConnectorCacheTests.swift`
  - Cache hit.
  - Cache miss.
  - Expired entry ignored.
  - Hash mismatch ignored.
  - Atomic write leaves readable JSON.
  - Dedup index prefers `sourceRecordId`, then `sourceUrl`, then hash.
- `ConnectorPacerTests.swift`
  - Respects injected rate.
  - Retries 429/503.
  - Does not retry 400/404.

## Phase 2 - SEC EDGAR Connector

Create `Packages/SupraResearch/Sources/SupraResearch/SecEdgar/`.

Files:

- `SecEdgarConnector.swift`
- `SecEdgarEndpoint.swift`
- `SecEdgarDTOs.swift`
- `SecEdgarModels.swift`
- `SecEdgarNormalizer.swift`
- `SecEdgarErrorMapping.swift`

Public API:

- `healthCheck()`
- `normalizeCik(_:)`
- `getCompanySubmissions(_:)`
- `getCompanyFacts(_:)`
- `getCompanyConcept(cik:taxonomy:concept:)`
- `getFrame(taxonomy:concept:unit:frame:)`
- `getRecentFilings(cik:filters:)`
- `getFilingByAccession(cik:accessionNumber:)`
- `buildFilingUrl(cik:accessionNumber:primaryDocument:)`
- `toIngestionRecords(_:)`
- Helpers: annual reports, quarterly reports, current reports,
  material event filings, exhibit-bearing filings, form search, date search,
  company profile.

Use explicit Swift signatures similar to:

```swift
public final class SecEdgarConnector: @unchecked Sendable {
    public init(
        httpClient: any AuthorizedHTTPClientProtocol,
        configuration: LegalDataConnectorConfiguration = .fromEnvironment(),
        cache: any LegalDataConnectorCache,
        now: @escaping @Sendable () -> Date = Date.init
    )

    public func healthCheck() async -> ConnectorHealth
    public static func normalizeCik(_ cik: String) throws -> String
    public static func normalizeCik(_ cik: Int) throws -> String
    public func getCompanySubmissions(_ cik: String) async throws -> SecCompanySubmissions
    public func getCompanyFacts(_ cik: String) async throws -> SecCompanyFacts
    public func getCompanyConcept(cik: String, taxonomy: String, concept: String) async throws -> SecCompanyConcept
    public func getFrame(taxonomy: String, concept: String, unit: String, frame: String) async throws -> SecFrame
    public func getRecentFilings(cik: String, filters: SecFilingFilters = .init()) async throws -> [SecFilingRecord]
    public func getFilingByAccession(cik: String, accessionNumber: String) async throws -> SecFilingRecord?
    public static func buildFilingUrl(cik: String, accessionNumber: String, primaryDocument: String?) throws -> SecFilingURLs
    public func toIngestionRecords(_ records: [SecFilingRecord]) throws -> [LegalDataIngestionRecord]
}
```

`healthCheck()` should validate local config and, if config is valid, return a
non-network success message. Do not make a live SEC request from health checks by
default; otherwise app startup could unexpectedly hit public services. Add a
separate live test for reachability.

### SEC Models

Create normalized model structs with every field from the prompt. All fields
that may be absent should be optional. Required fields:

```swift
public struct SecCompanyRecord: Codable, Equatable, Sendable {
    public var source: String                  // "sec_edgar"
    public var sourceRecordType: String        // "company"
    public var cik: String
    public var entityName: String?
    public var tickers: [String]
    public var exchanges: [String]
    public var sourceUrl: String
    public var retrievedAt: Date
    public var raw: JSONValue
    // plus all prompt company fields
}
```

```swift
public struct SecFilingRecord: Codable, Equatable, Sendable {
    public var source: String                  // "sec_edgar"
    public var sourceRecordType: String        // "filing"
    public var cik: String
    public var accessionNumber: String
    public var form: String?
    public var filingDate: String?
    public var filingUrl: String
    public var sourceUrl: String
    public var retrievedAt: Date
    public var raw: JSONValue
    // plus all prompt filing fields
}
```

```swift
public struct SecXbrlRecord: Codable, Equatable, Sendable {
    public var source: String                  // "sec_edgar"
    public var sourceRecordType: String        // company_fact/company_concept/frame
    public var cik: String?
    public var entityName: String?
    public var taxonomy: String?
    public var concept: String?
    public var unit: String?
    public var period: String?
    public var accessionNumber: String?
    public var value: JSONValue?
    public var sourceUrl: String
    public var retrievedAt: Date
    public var raw: JSONValue
    // plus prompt XBRL summary fields
}
```

```swift
public struct SecFilingFilters: Codable, Equatable, Sendable {
    public var formTypes: [String]
    public var startDate: String?
    public var endDate: String?
    public var accessionNumber: String?
    public var includeAmendments: Bool
    public var limit: Int?
}

public struct SecFilingURLs: Codable, Equatable, Sendable {
    public var filingUrl: String
    public var primaryDocumentUrl: String?
}
```

Filter semantics:

- `formTypes` matches case-insensitively after trimming.
- `startDate` and `endDate` compare against `filingDate` as ISO `yyyy-MM-dd`
  strings. Reject non-ISO date filters with `validation`.
- `limit` default is nil. If provided, clamp to `1...1_000`.
- `includeAmendments = false` means exclude forms ending in `/A` unless the
  caller explicitly included an amended form in `formTypes`.

Implementation details:

1. `normalizeCik`
   - Accept `String` and `Int` overloads.
   - Trim whitespace, strip harmless formatting, require only digits after
     cleanup, reject empty or more than 10 digits, left-pad to 10.
   - Tests:
     `320193`, `"320193"`, `"0000320193"`, empty, nonnumeric, too long.
   - "Harmless formatting" means whitespace, internal spaces, and hyphens only.
     Do not silently strip letters or punctuation like `/`, `?`, `#`, `@`.
     Examples:
     - `" 320193 "` -> `0000320193`
     - `"000-0320193"` -> `0000320193`
     - `"CIK320193"` -> validation error.
     - `"320193?x=1"` -> validation error.

2. Endpoints
   - `https://data.sec.gov/submissions/CIK{normalized}.json`
   - Historical continuation files from the `files` array:
     `https://data.sec.gov/submissions/{name}`
   - `https://data.sec.gov/api/xbrl/companyfacts/CIK{normalized}.json`
   - `https://data.sec.gov/api/xbrl/companyconcept/CIK{normalized}/{taxonomy}/{concept}.json`
   - `https://data.sec.gov/api/xbrl/frames/{taxonomy}/{concept}/{unit}/{frame}.json`
   - Encode path components safely. Keep taxonomy/concept/unit/frame validation
     strict enough to block slashes or embedded URLs.
   - Endpoint builders must return `URL`, not `String`, and must be unit-tested
     without performing network.
   - Base URL overrides are not required for production, but tests may inject
     exact URLs through the HTTP stub. If adding overrides, pin them to official
     hosts like existing endpoint builders do.

3. Requests
   - Always set `User-Agent` from `SEC_EDGAR_USER_AGENT`.
   - Set `Accept: application/json`.
   - Fail with `LegalDataConnectorError.config` before network if the UA is
     missing.
   - Use cache by URL+operation. Suggested TTL:
     submissions 6 hours, company facts 24 hours, concept/frame 24 hours.
   - Never send the SEC User-Agent to non-SEC hosts.
   - Include `Accept-Encoding` only if URLSession handles it automatically; do
     not manually decompress unless needed.
   - `healthCheck` must not trigger a SEC request just to discover missing UA.

4. Normalization
   - Decode SEC submissions preserving raw JSON.
   - SEC `filings.recent` is columnar. Zip arrays by index into filing records.
     If arrays have different lengths, normalize up to the longest array and
     set absent optional fields to nil. Add a warning to sanitized metadata for
     the operation, but do not crash if accession number exists.
   - Normalize company record fields from the top-level submission object.
   - Normalize recent filings and historical continuation filings to the prompt's
     filing model.
   - Source record IDs:
     `sec_edgar:company:{cik}`, `sec_edgar:filing:{cik}:{accessionNumber}`,
     `sec_edgar:xbrl:{kind}:{cik}:{taxonomy}:{concept}:{unit}:{period}:{accessionNumber}`.
   - Filing archive base:
     `https://www.sec.gov/Archives/edgar/data/{cikWithoutLeadingZeroes}/{accessionWithoutDashes}/`
   - Primary document URL only when `primaryDocument` exists.
   - Historical continuation:
     `getFilingByAccession` must check recent filings first, then load
     continuation files listed in `submissions.files` until it finds the
     accession or exhausts the list. Cache each continuation response
     independently.
   - `getRecentFilings` returns only top-level recent filing records and does
     not automatically load historical continuation files.
   - Helper behavior:
     - `getAnnualReports`: forms `10-K`, `10-K/A`, `20-F`, `20-F/A`, `40-F`,
       `40-F/A`.
     - `getQuarterlyReports`: `10-Q`, `10-Q/A`.
     - `getCurrentReports`: `8-K`, `8-K/A`, `6-K`, `6-K/A`.
     - `getMaterialEventFilings`: `8-K`, `8-K/A`, then optional item filter.
     - `getRecentExhibitBearingFilings`: metadata-first filter where
       `primaryDocDescription`, `items`, or form type suggests exhibits; do not
       download document bodies.
   - XBRL:
     - Company facts response can contain many nested facts. Preserve full raw
       payload and expose a bounded summary array if practical.
     - Company concept response has `units` mapping unit -> fact array. Flatten
       only in `toIngestionRecords` or a summary helper; preserve raw.
     - Frame response has `data` facts. Normalize each fact with `taxonomy`,
       `concept`, `unit`, and `frame` context.

5. RAG text
   - Implement exactly the neutral template from the source prompt.
   - Omit empty optional fields rather than writing placeholders.
   - Do not infer legal significance, materiality, fraud, compliance, or
     securities-law conclusions.
   - Tests should assert the text contains source URL, company, CIK, form,
     filing date, accession number, and primary document when present.
   - Tests should assert missing optional fields are omitted.
   - Tests should assert words like `violated`, `fraud`, `material breach`, and
     `investment advice` are not introduced by the template.

6. Tests in `Packages/SupraResearch/Tests/SupraResearchTests/SecEdgarConnectorTests.swift`
   - Use an actor stub of `AuthorizedHTTPClientProtocol`.
   - Assert requests use `sendUnauthenticated`, never `send`.
   - Assert `User-Agent` and URL construction.
   - Cover all prompt-listed unit tests.
   - Live tests in `SecEdgarLiveTests.swift`, skipped unless
     `LEGAL_DATA_CONNECTORS_ENABLE_LIVE_TESTS=true` and
     `SEC_EDGAR_USER_AGENT` is present. Probe CIK `0000320193`.
   - Required fixture files:
     - `Fixtures/SEC/company-submissions-apple.json`
     - `Fixtures/SEC/company-submissions-historical-page.json`
     - `Fixtures/SEC/company-facts-apple-minimal.json`
     - `Fixtures/SEC/company-concept-revenues.json`
     - `Fixtures/SEC/frame-revenues.json`
   - Required test names:
     - `testNormalizeCikAcceptsCommonForms`
     - `testNormalizeCikRejectsUnsafeInput`
     - `testMissingUserAgentFailsBeforeNetwork`
     - `testCompanySubmissionsRequestUsesTenDigitCikAndUserAgent`
     - `testRecentFilingsZipColumnarArrays`
     - `testHistoricalContinuationIsLoadedForAccessionLookup`
     - `testCompanyFactsRequestAndRawPreservation`
     - `testCompanyConceptRequestAndFlattenedSummary`
     - `testFrameRequestAndSummary`
     - `testFilingURLConstructionWithAndWithoutDashes`
     - `testRAGTextIsNeutralAndSourceAttributed`
     - `testCacheHitSkipsNetwork`
     - `testTransientFailureRetries`
     - `testRatePacerRunsBeforeRequests`
     - `testMissingOptionalFieldsDoNotFailNormalization`

Docs:

- Create `Docs/Connectors/sec-edgar.md` with purpose, config, links,
  normalized fields, RAG output, limitations, and test instructions.

## Phase 3 - CFPB Complaint Connector

Create `Packages/SupraResearch/Sources/SupraResearch/CFPBComplaints/`.

Files:

- `CfpbComplaintConnector.swift`
- `CfpbComplaintEndpoint.swift`
- `CfpbComplaintDTOs.swift`
- `CfpbComplaintModels.swift`
- `CfpbComplaintNormalizer.swift`
- `CfpbComplaintAggregations.swift`

Public API:

- `healthCheck()`
- `searchComplaints(_:)`
- `getComplaintById(_:)`
- `searchByCompany(company:options:)`
- `searchByProduct(product:options:)`
- `searchByIssue(issue:options:)`
- `searchByState(state:options:)`
- `searchByDateRange(startDate:endDate:options:)`
- `getCompanyComplaintProfile(company:options:)`
- `getComplaintTrends(filters:interval:)`
- `toIngestionRecords(_:)`

Use explicit Swift signatures similar to:

```swift
public final class CfpbComplaintConnector: @unchecked Sendable {
    public init(
        httpClient: any AuthorizedHTTPClientProtocol,
        configuration: LegalDataConnectorConfiguration = .fromEnvironment(),
        cache: any LegalDataConnectorCache,
        now: @escaping @Sendable () -> Date = Date.init
    )

    public func healthCheck() async -> ConnectorHealth
    public func searchComplaints(_ query: CfpbComplaintQuery) async throws -> CfpbComplaintSearchResult
    public func getComplaintById(_ complaintId: String) async throws -> CfpbComplaintRecord
    public func searchByCompany(company: String, options: CfpbComplaintQueryOptions) async throws -> [CfpbComplaintRecord]
    public func searchByProduct(product: String, options: CfpbComplaintQueryOptions) async throws -> [CfpbComplaintRecord]
    public func searchByIssue(issue: String, options: CfpbComplaintQueryOptions) async throws -> [CfpbComplaintRecord]
    public func searchByState(state: String, options: CfpbComplaintQueryOptions) async throws -> [CfpbComplaintRecord]
    public func searchByDateRange(startDate: String, endDate: String, options: CfpbComplaintQueryOptions) async throws -> [CfpbComplaintRecord]
    public func getCompanyComplaintProfile(company: String, options: CfpbComplaintProfileOptions) async throws -> CfpbCompanyComplaintProfile
    public func getComplaintTrends(filters: CfpbComplaintFilters, interval: CfpbTrendInterval) async throws -> [CfpbComplaintTrendBucket]
    public func toIngestionRecords(_ records: [CfpbComplaintRecord]) throws -> [LegalDataIngestionRecord]
}
```

### CFPB Models

```swift
public struct CfpbComplaintFilters: Codable, Equatable, Sendable {
    public var company: [String]
    public var product: [String]
    public var subProduct: [String]
    public var issue: [String]
    public var subIssue: [String]
    public var state: [String]
    public var zipCode: [String]
    public var dateReceivedMin: String?
    public var dateReceivedMax: String?
    public var companyResponse: [String]
    public var timely: String?
    public var consumerDisputed: String?
    public var hasNarrative: Bool?
    public var submittedVia: [String]
    public var tags: [String]
}
```

`subProduct`, `subIssue`, and `consumerDisputed` are required normalized fields
but may not be available as first-class filters in the current Swagger. If the
official API does not support one as a query parameter, do not invent a
parameter. Apply it client-side only to the bounded page set and document the
limitation.

```swift
public struct CfpbComplaintQuery: Codable, Equatable, Sendable {
    public var searchTerm: String?
    public var field: CfpbSearchField
    public var filters: CfpbComplaintFilters
    public var options: CfpbComplaintQueryOptions
}

public enum CfpbSearchField: String, Codable, Equatable, Sendable {
    case complaintWhatHappened = "complaint_what_happened"
    case companyPublicResponse = "company_public_response"
    case all
}

public struct CfpbComplaintQueryOptions: Codable, Equatable, Sendable {
    public var size: Int
    public var maxPages: Int
    public var sort: String
    public var noAggregations: Bool
    public var noHighlight: Bool
    public var allowsLargeExport: Bool
}

public struct CfpbComplaintProfileOptions: Codable, Equatable, Sendable {
    public var filters: CfpbComplaintFilters
    public var sampleNarrativeLimit: Int
    public var trendInterval: CfpbTrendInterval
    public var queryOptions: CfpbComplaintQueryOptions
}

public enum CfpbTrendInterval: String, Codable, Equatable, Sendable {
    case month
    case quarter
    case year
}
```

Default option values:

- `field = .complaintWhatHappened`.
- `size = 100`.
- `maxPages = 5`.
- `sort = "created_date_desc"` only if confirmed by fixture/request tests;
  otherwise use the documented UI default and record it in docs.
- `noAggregations = false`.
- `noHighlight = true` for connector data retrieval.
- `allowsLargeExport = false`.
- `sampleNarrativeLimit = 5`.

```swift
public struct CfpbComplaintRecord: Codable, Equatable, Sendable {
    public var source: String                  // "cfpb_complaints"
    public var sourceRecordType: String        // "consumer_complaint"
    public var complaintId: String
    public var company: String?
    public var product: String?
    public var issue: String?
    public var dateReceived: String?
    public var sourceUrl: String
    public var retrievedAt: Date
    public var raw: JSONValue
    // plus every prompt complaint field
}
```

`sourceUrl` should be a stable public URL when possible:
`https://www.consumerfinance.gov/data-research/consumer-complaints/search/detail/{complaintId}`.
If that detail URL is not confirmed by tests/live docs, use the API URL and
document the choice.

Implementation details:

1. Endpoint base:
   `https://www.consumerfinance.gov/data-research/consumer-complaints/search/api/v1/`.
2. Search endpoint: `/`.
3. Complaint by ID: `/{complaintId}`.
4. Trends endpoint: `/trends`.
5. Query params:
   `search_term`, `field`, `frm`, `size`, `sort`, `format`, `no_aggs`,
   `no_highlight`, `company`, `company_public_response`,
   `company_received_min/max`, `company_response`, `date_received_min/max`,
   `has_narrative`, `issue`, `product`, `search_after`, `state`,
   `submitted_via`, `tags`, `timely`, `zip_code`.
   - Map internal names to API names exactly:
     - `dateReceivedMin` -> `date_received_min`
     - `dateReceivedMax` -> `date_received_max`
     - `zipCode` -> `zip_code`
     - `submittedVia` -> `submitted_via`
     - `hasNarrative` -> `has_narrative`
     - `companyResponse` -> `company_response`
   - Do not send `sub_product`, `sub_issue`, or `consumer_disputed` unless
     confirmed in the current official Swagger. If unsupported, filter locally
     over retrieved records and set `sourceLimitations`.
6. Use repeated query items for array parameters, matching Swagger `explode:
   true`.
7. Defaults:
   `size = 100`, `maxPages = 5`, sort newest first if accepted by the API.
   Hard-cap untrusted caller values unless explicit options allow more.
   - Use `frm` for offset pagination. If `search_after` is needed for deep
     pagination, implement only after tests prove the response includes a stable
     next cursor.
   - `maxPages` hard cap default: 5. Absolute hard cap: 20 unless an internal
     option named `allowsLargeExport` is true. Do not expose unbounded fetch.
   - `size` hard cap default: 100. Absolute hard cap: 1000.
8. Normalize complaint records to the prompt shape and preserve raw JSON.
   - Be resilient to both direct complaint JSON and Elasticsearch-like
     structures (`hits.hits[*]._source`) if the API returns search results that
     way. Unit tests must cover the actual fixture shape used.
   - `getComplaintById` should accept numeric strings only. Reject empty,
     negative, decimal, or nonnumeric IDs before network.
9. Profile aggregation must be factual:
   counts by product/issue/state/submittedVia/companyResponse, timely
   percentage, narrative count, sample narratives, trend by selected interval,
   limitations.
10. Trends:
   Prefer documented `/trends` when it returns the requested aggregation; if the
   API shape is insufficient, compute trends from bounded search pages and
   document that fallback.
   - Supported intervals:
     - `month`: bucket by first day of `yyyy-MM`.
     - `quarter`: bucket by calendar quarter.
     - `year`: bucket by `yyyy-01-01`.
   - Bucket output must include `intervalStart`, `intervalEnd`, `count`,
     `topProducts`, `topIssues`, and `topCompanies` unless a company filter is
     present.
11. RAG text:
   Omit missing narrative/public-response sections; no placeholders.
   Never say a complaint is true, proven, adjudicated, or legally meritorious.
   - Add a test that profile summary contains wording like
     `The database contains ... complaints matching...` and does not contain
     `violated`, `liable`, `proven`, `adjudicated`, or `meritorious`.

Tests in `CfpbComplaintConnectorTests.swift`:

- Request construction, filter mapping, pagination, complaint-by-ID,
  normalization with null/missing fields, RAG text generation, profile
  aggregation, trends, cache hit/miss, transient retry, rate pacing, and neutral
  wording.
- Optional live tests skipped unless
  `LEGAL_DATA_CONNECTORS_ENABLE_LIVE_TESTS=true`; use narrow queries with
  `size <= 5`.
- Required fixture files:
  - `Fixtures/CFPB/search-complaints-small.json`
  - `Fixtures/CFPB/complaint-detail.json`
  - `Fixtures/CFPB/trends-month.json`
  - `Fixtures/CFPB/search-missing-optional-fields.json`
- Required test names:
  - `testSearchRequestConstructionUsesDocumentedParameters`
  - `testArrayFiltersUseRepeatedQueryItems`
  - `testPaginationStopsAtMaxPages`
  - `testComplaintByIDValidatesInput`
  - `testComplaintNormalizationPreservesRawPayload`
  - `testMissingOptionalFieldsDoNotFail`
  - `testRAGTextOmitsMissingNarrativeSections`
  - `testCompanyProfileAggregatesNeutralFacts`
  - `testTrendsBucketsByMonthQuarterYear`
  - `testCacheHitSkipsNetwork`
  - `testTransientFailureRetries`
  - `testRatePacerRunsBeforeRequests`
  - `testNeutralSummaryDoesNotUseLegalConclusionWords`

Docs:

- Create `Docs/Connectors/cfpb-complaints.md`.

## Phase 4 - NLRB Data Connector

Create `Packages/SupraResearch/Sources/SupraResearch/NLRB/`.

Files:

- `NlrbDataConnector.swift`
- `NlrbSources.swift`
- `NlrbCSVImporter.swift`
- `NlrbDTOs.swift`
- `NlrbModels.swift`
- `NlrbNormalizer.swift`
- `NlrbCaseClassifier.swift`
- `NlrbLocalRecordStore.swift`
- `NlrbHistorySummary.swift`

Public API:

- `healthCheck()`
- `refreshAvailableDatasets(options:)`
- `importDataset(datasetSource:options:)`
- `searchCases(query:options:)`
- `getCaseByNumber(_:)`
- `searchByEmployer(_:)`
- `searchByUnion(_:)`
- `searchByPartyName(_:)`
- `searchByRegion(_:)`
- `searchByDateRange(startDate:endDate:options:)`
- `searchUnfairLaborPracticeCases(filters:)`
- `searchRepresentationCases(filters:)`
- `getElectionResults(filters:)`
- `summarizePartyNlrbHistory(partyName:options:)`
- `toIngestionRecords(_:)`

Use explicit Swift signatures similar to:

```swift
public final class NlrbDataConnector: @unchecked Sendable {
    public init(
        httpClient: any AuthorizedHTTPClientProtocol,
        configuration: LegalDataConnectorConfiguration = .fromEnvironment(),
        cache: any LegalDataConnectorCache,
        localStore: NlrbLocalRecordStore,
        now: @escaping @Sendable () -> Date = Date.init
    )

    public func healthCheck() async -> ConnectorHealth
    public func refreshAvailableDatasets(options: NlrbRefreshOptions = .init()) async throws -> [NlrbDatasetSource]
    public func importDataset(_ datasetSource: NlrbDatasetSource, options: NlrbImportOptions = .init()) async throws -> NlrbImportRun
    public func searchCases(query: String, options: NlrbSearchOptions = .init()) async throws -> [NlrbCaseRecord]
    public func getCaseByNumber(_ caseNumber: String) async throws -> NlrbCaseRecord?
    public func searchByEmployer(_ employer: String, options: NlrbSearchOptions = .init()) async throws -> [NlrbCaseRecord]
    public func searchByUnion(_ union: String, options: NlrbSearchOptions = .init()) async throws -> [NlrbCaseRecord]
    public func searchByPartyName(_ partyName: String, options: NlrbSearchOptions = .init()) async throws -> [NlrbCaseRecord]
    public func searchByRegion(_ region: String, options: NlrbSearchOptions = .init()) async throws -> [NlrbCaseRecord]
    public func searchByDateRange(startDate: String, endDate: String, options: NlrbSearchOptions = .init()) async throws -> [NlrbCaseRecord]
    public func searchUnfairLaborPracticeCases(filters: NlrbCaseFilters) async throws -> [NlrbCaseRecord]
    public func searchRepresentationCases(filters: NlrbCaseFilters) async throws -> [NlrbCaseRecord]
    public func getElectionResults(filters: NlrbElectionFilters = .init()) async throws -> [NlrbElectionResultRecord]
    public func summarizePartyNlrbHistory(partyName: String, options: NlrbHistoryOptions = .init()) async throws -> NlrbPartyHistorySummary
    public func toIngestionRecords(_ records: [NlrbIngestibleRecord]) throws -> [LegalDataIngestionRecord]
}
```

`NlrbIngestibleRecord` can be an enum:

```swift
public enum NlrbIngestibleRecord: Codable, Equatable, Sendable {
    case `case`(NlrbCaseRecord)
    case electionResult(NlrbElectionResultRecord)
    case historicalCase(NlrbHistoricalCaseRecord)
}
```

### NLRB Models

Create separate normalized models:

- `NlrbCaseRecord`
- `NlrbElectionResultRecord`
- `NlrbHistoricalCaseRecord`
- `NlrbDatasetSource`
- `NlrbImportRun`
- `NlrbPartyHistorySummary`

Every normalized record must include:

- `source = "nlrb"`
- `sourceRecordType`
- `sourceVariant`
- source URL
- retrieved/imported date
- raw row/object as `JSONValue`

`sourceVariant` must be an enum with raw string values exactly:

- `official_recent_filings`
- `official_recent_election_results`
- `official_advanced_search_export`
- `official_cats_data`
- `official_chips_data`
- `labordata_mirror`

Options and filters:

```swift
public struct NlrbRefreshOptions: Codable, Equatable, Sendable {
    public var includeHistoricalSources: Bool
    public var includeThirdPartyMirrors: Bool
}

public struct NlrbImportOptions: Codable, Equatable, Sendable {
    public var forceRefresh: Bool
    public var maxRecords: Int?
}

public struct NlrbSearchOptions: Codable, Equatable, Sendable {
    public var limit: Int
    public var includeHistorical: Bool
    public var includeElectionResults: Bool
    public var includeUndated: Bool
}

public struct NlrbCaseFilters: Codable, Equatable, Sendable {
    public var query: String?
    public var caseNumber: String?
    public var employer: String?
    public var union: String?
    public var partyName: String?
    public var caseType: String?
    public var caseTypeCategory: String?
    public var region: String?
    public var status: String?
    public var startDate: String?
    public var endDate: String?
}

public struct NlrbElectionFilters: Codable, Equatable, Sendable {
    public var caseNumber: String?
    public var employer: String?
    public var union: String?
    public var region: String?
    public var state: String?
    public var tallyStartDate: String?
    public var tallyEndDate: String?
    public var limit: Int
}

public struct NlrbHistoryOptions: Codable, Equatable, Sendable {
    public var dateRangeStart: String?
    public var dateRangeEnd: String?
    public var includeElectionResults: Bool
    public var limit: Int
}
```

Default option values:

- `includeHistoricalSources = true`.
- `includeThirdPartyMirrors = false`.
- `forceRefresh = false`.
- `maxRecords = nil`.
- `limit = 100`, clamped to `1...1_000`.
- `includeHistorical = true`.
- `includeElectionResults = true`.
- `includeUndated = false`.

Implementation details:

1. Treat NLRB as dataset/export-first.
2. First milestone source variants:
   - `official_recent_filings` from the official recent filings CSV.
   - `official_recent_election_results` from the official recent election
     results CSV.
   - `official_cats_data` as a discoverable/importable dataset if a stable
     download URL is confirmed from NLRB/Data.gov/National Archives.
   - If CATS/CHIPS URLs are not stable after inspection, implement the source
     as `discoveredButNotImported` in `refreshAvailableDatasets` with a warning
     explaining the manual source link. Do not fail the whole connector.
3. Do not invent private endpoints. If parsing the NLRB page to find a
   `Download CSV` URL, isolate that logic in `NlrbSources.swift`, test it with
   static HTML fixtures, and document it as an official-page export adapter.
   - The official recent pages contain a `Download CSV` link. Use the href from
     that link. If it is relative, resolve against the page URL. If it requires
     an interactive download queue or form token, stop and document the source
     as unsupported rather than automating session state.
4. `NlrbLocalRecordStore`
   - Use a file-backed JSONL store under `NLRB_LOCAL_DATA_DIR` or the connector
     cache dir.
   - Store import run metadata:
     `connectorName`, `sourceVariant`, `datasetName`, `sourceUrl`,
     `retrievedAt`, `recordCount`, `rawFilePath` or hash,
     `normalizedRecordCount`, `errors`, `warnings`.
   - Keep indexes in sidecar JSON files for case number, party/employer/union,
     region, date, status, and case type. Load lazily.
   - File layout:
     - `{NLRB_LOCAL_DATA_DIR}/imports/{importRunId}.json`
     - `{NLRB_LOCAL_DATA_DIR}/raw/{sourceVariant}/{payloadHash}.csv`
     - `{NLRB_LOCAL_DATA_DIR}/records/{sourceVariant}.jsonl`
     - `{NLRB_LOCAL_DATA_DIR}/indexes/case-number.json`
     - `{NLRB_LOCAL_DATA_DIR}/indexes/party-name.json`
   - Index keys should be normalized lowercase, trimmed, whitespace-collapsed
     strings. Case-number keys should uppercase and preserve dashes.
   - Duplicate detection:
     - Case: `source + sourceVariant + caseNumber + sourceRecordType`.
     - Election: add `unitId` and `tallyDate` when present.
     - Historical: add `historicalSystem` if present.
   - Imports should be idempotent. Re-importing the same CSV should not double
     the search results.
5. Normalize cases and election results to the prompt models. Use nil for
   unavailable fields and preserve raw row data.
   - CSV parser:
     - Must handle quoted commas, escaped quotes, CRLF, LF, and blank cells.
     - Do not split CSV rows with `String.split(separator: ",")`.
     - Implement a small RFC-4180 parser or use a Foundation-compatible parser
       already in the repo if one exists. Search first.
   - Header mapping:
     - Implement case-insensitive, punctuation-insensitive aliases. Example:
       `Case Number`, `case_number`, and `CaseNumber` should map to
       `caseNumber`.
     - Keep all unmapped columns in `raw`.
6. Case classifier:
   - `CA`, `CB`, `CC`, `CD`, `CE`, `CG`, `CP` -> `unfair_labor_practice`
   - `RC`, `RD`, `RM` -> `representation`
   - `UC` -> `unit_clarification`
   - `UD` -> `union_deauthorization`
   - `AC` -> `amendment_of_certification`
   - Unknown -> `unknown`, preserving raw case type.
   - Extract the case-type code from case numbers like `01-RC-389901` by taking
     the middle segment. If a source field explicitly gives a case type, prefer
     that field after trimming.
7. RAG text:
   - Use the prompt templates.
   - Omit missing fields.
   - Do not imply violations or formal findings unless an explicit source field
     supports that statement.
   - Tests must assert no placeholder labels such as `nil`, `N/A`, or `unknown`
     are emitted for missing optional values. The only allowed `unknown` is the
     explicit `caseTypeCategory` value in normalized data.
8. Party history summary:
   - Counts, case types/categories, regions, statuses, reason closed
     distribution, recent cases, election results, variants used, limitations.
   - Neutral wording only.
   - Search behavior:
     - Exact case number lookup should be O(1) from the case index.
     - Party/employer/union search can be in-memory scan over indexed IDs for
       this milestone, but bound results with `limit` default 100.
     - Date range filtering should use parsed dates when available and ignore
       records with unparseable dates unless `includeUndated` is true.
   - Summary wording must say `matching case records`, never `violations`,
     unless a future explicit adjudication field supports that statement.

Tests in `NlrbDataConnectorTests.swift`:

- CSV import parsing, recent filing normalization, election normalization,
  C-case and R-case classification, case-number search, employer/union/party
  search, date and region filters, RAG text, party history summary, provenance,
  deduplication, missing field handling, and import run logging.
- Optional live tests skipped unless
  `LEGAL_DATA_CONNECTORS_ENABLE_LIVE_TESTS=true`; only fetch small official
  recent CSV data or inspect headers, not repeated large downloads.
- Required fixture files:
  - `Fixtures/NLRB/recent-filings-page.html`
  - `Fixtures/NLRB/recent-filings.csv`
  - `Fixtures/NLRB/recent-election-results-page.html`
  - `Fixtures/NLRB/recent-election-results.csv`
  - `Fixtures/NLRB/cats-c-case-minimal.xml` only if XML import is implemented.
- Required test names:
  - `testFindsOfficialRecentFilingsCSVLink`
  - `testFindsOfficialElectionResultsCSVLink`
  - `testCSVParserHandlesQuotedCommasAndCRLF`
  - `testRecentFilingsNormalizeCoreCaseFields`
  - `testElectionResultsNormalizeVoteFields`
  - `testCaseTypeClassifierMapsKnownTypes`
  - `testCaseTypeClassifierPreservesUnknownTypes`
  - `testCaseNumberSearchUsesNormalizedKey`
  - `testEmployerUnionAndPartySearch`
  - `testDateRangeAndRegionFiltering`
  - `testElectionRAGTextOmitsMissingFields`
  - `testCaseRAGTextIsNeutral`
  - `testPartyHistorySummaryUsesNeutralLanguage`
  - `testSourceProvenanceIsPreserved`
  - `testDuplicateImportIsIdempotent`
  - `testImportRunLogsWarningsAndErrors`

Docs:

- Create `Docs/Connectors/nlrb-data.md`.

## Phase 5 - Integration And Public Exports

1. Ensure all new public types that app code may use are `public` and `Sendable`
   where needed.
2. Update `Packages/SupraResearch/Sources/SupraResearch/SupraResearch.swift`
   only if a module-level constant or helper is useful. SwiftPM does not need
   manual source registration.
3. Do not wire connectors into `GlobalChatController` or UI in this milestone
   unless requested later. The connector APIs and `IngestionRecord` output are
   the stable seam for future RAG/document indexing integration.
4. If adding a bridge later, put app orchestration in `SupraSessions`, not
   `SupraResearch`, so package boundaries remain intact.
5. Add no SwiftUI settings pane in this milestone. The configuration seam is
   environment variables only.
6. Add no model-prompt changes in this milestone. RAG text output should be a
   data product, not automatically injected into chat prompts.
7. Do not add these connectors to `LegalAuthoritySource` unless a later task
   explicitly asks to treat them as legal authorities. These are public factual
   data sources, not citable authority sources in the existing source hierarchy.
8. If a compiler requires imports, keep them local:
   - Connector files: `Foundation`, `CryptoKit` where hashing is needed,
     `SupraNetworking`.
   - Tests: `XCTest`, `Foundation`, `SupraResearch`, `SupraNetworking`.

## Phase 6 - Documentation Checklist

Create `Docs/Connectors/` if it does not exist.

Each connector doc must include:

- Purpose.
- Official source links.
- Configuration.
- Rate limits and caching behavior.
- Example Swift usage.
- Normalized fields.
- RAG text shape.
- Source attribution.
- Known limitations.
- Test commands.

Add a short index file:

- `Docs/Connectors/README.md`

The docs must also include a "Regression Safety" section for each connector:

- No authenticated CourtListener path is used.
- Live tests are disabled by default.
- Raw source data is preserved.
- Known unsupported source behavior is explicit.
- The connector does not provide legal, securities, investment, labor-law, or
  consumer-protection conclusions.

## Phase 7 - Acceptance Criteria

The implementation is done only when:

1. `swift test --package-path Packages/SupraResearch` passes or any environment
   blocker is documented with the exact command and error.
2. `swift test --package-path Packages/SupraNetworking` passes after allow-list
   updates.
3. All three connector classes exist with the required public methods.
4. SEC CIK normalization, User-Agent fail-fast, submissions, XBRL facts, URL
   construction, cache, RAG records, and docs are complete.
5. CFPB search, complaint-by-ID, filters, pagination, profiles, trends, cache,
   RAG records, and docs are complete.
6. NLRB official CSV/import path, normalization, case classification, local
   search, source provenance, party summaries, RAG records, and docs are
   complete.
7. Raw source data is preserved for every normalized record.
8. Connector errors are typed, sanitized, and retry-aware.
9. Live tests are opt-in only through
   `LEGAL_DATA_CONNECTORS_ENABLE_LIVE_TESTS=true`.
10. Any uncertain source behavior is documented instead of guessed.
11. All new tests use deterministic fixtures by default.
12. Cache tests prove a cache hit avoids the HTTP stub.
13. HTTP stub tests prove no connector calls `send`.
14. Network policy tests prove existing allowed hosts still pass and new hosts
    are HTTPS-only.
15. `git diff --stat` shows connector-focused changes only:
    `Packages/SupraResearch`, `Packages/SupraNetworking`,
    `Docs/Connectors`, and `.env.example`.

## Implementation Sequence Checklist

Claude should execute the work with this checklist and not move to the next
connector until the current phase compiles and its focused tests pass or a
baseline toolchain issue is documented.

1. Shared infrastructure
   - Add `Connectors/` shared files.
   - Add shared tests.
   - Add network allow-list entries and tests.
   - Update `.env.example`.
   - Run `swift test --package-path Packages/SupraNetworking`.
   - Run focused `SupraResearch` tests for shared infrastructure.

2. SEC EDGAR
   - Add endpoint builders and tests.
   - Add DTO/raw JSON decoding.
   - Add normalizers and tests.
   - Add connector request/cache path.
   - Add RAG output and ingestion records.
   - Add docs.
   - Run `swift test --package-path Packages/SupraResearch --filter SecEdgar`.

3. CFPB
   - Add query/filter types and endpoint builders.
   - Add DTO/raw JSON decoding.
   - Add pagination.
   - Add aggregations.
   - Add connector request/cache path.
   - Add docs.
   - Run `swift test --package-path Packages/SupraResearch --filter Cfpb`.

4. NLRB
   - Add source discovery against static HTML fixtures.
   - Add CSV parser before connector code.
   - Add local store and idempotent import.
   - Add normalizers/search/summary.
   - Add docs.
   - Run `swift test --package-path Packages/SupraResearch --filter Nlrb`.

5. Full verification
   - Run `swift test --package-path Packages/SupraNetworking`.
   - Run `swift test --package-path Packages/SupraResearch`.
   - If using Xcode instead, record exact `xcodebuild test` command.
   - Run `git status --short`.
   - Review `git diff` for accidental UI, prompt, database, or unrelated
     research changes.

## Suggested Claude Commit Strategy

Use small commits if committing is requested:

1. Shared connector infrastructure and network allow-list.
2. SEC EDGAR connector, tests, docs.
3. CFPB complaint connector, tests, docs.
4. NLRB data connector, tests, docs.
5. Final docs and env example cleanup.

## Claude Review Amendments (2026-07-03)

Reviewed against the live codebase before execution. The following amendments
override the corresponding sections above; everything else stands.

1. **Network allow-list is narrower than planned.** Only the hosts the client
   actually fetches this milestone are added: `data.sec.gov`,
   `www.consumerfinance.gov`, `www.nlrb.gov`. NOT added: `sec.gov`/`www.sec.gov`
   (filing/archive URLs are BUILT for the user's browser, never fetched by the
   client), bare `nlrb.gov`/`consumerfinance.gov` apex domains, and
   `catalog.data.gov`/`www.data.gov`/`catalog.archives.gov` (CATS/CHIPS remains
   discovery-only, so nothing is fetched from them). Default-deny means hosts
   are added when a fetch exists, not in anticipation. `SECURITY.md`'s
   allow-list section must be updated in the same commit as the policy change —
   repo practice the plan omitted.

2. **Per-connector HTTP clients with source-tuned rate trackers.** The plan
   missed that `AuthorizedHTTPClient` enforces a LOCAL rolling budget via
   `RateLimitTracker` defaulting to 5/min / 50/hr / 125/day — tuned for
   CourtListener, and per-client (see memory: one client per provider). A
   connector on the default tracker starves after one pagination pass. Each
   connector therefore constructs (or is injected) its OWN client, and app-side
   construction must pass a tracker tuned to the source: SEC 120/min, 600/hr
   (well under SEC's 10 req/s fair-access ceiling, which the per-second pacer
   enforces); CFPB 60/min, 300/hr; NLRB 30/min, 120/hr. Tests inject stubs, so
   this only binds the future app wiring — but the connector docs must state it
   and the connector init must accept the client rather than build one.

3. **Error shape: struct + `Kind` enum, not a 9-case enum.** Nine cases each
   carrying eight associated values duplicates the payload nine times and makes
   `Equatable`/pattern-matching clumsy. `LegalDataConnectorError` is a struct
   with a `Kind` enum (`config`, `validation`, `rateLimit`, `sourceUnavailable`,
   `download`, `notFound`, `parse`, `importFailed`, `transport`) plus the
   planned fields. Same semantic contract, same mapping table.

4. **Environment variables take the repo's `SUPRA_` prefix**:
   `SUPRA_SEC_EDGAR_USER_AGENT`, `SUPRA_SEC_EDGAR_RATE_LIMIT_PER_SECOND`,
   `SUPRA_CFPB_RATE_LIMIT_PER_SECOND`, `SUPRA_NLRB_RATE_LIMIT_PER_SECOND`,
   `SUPRA_LEGAL_DATA_CACHE_DIR`, `SUPRA_NLRB_LOCAL_DATA_DIR`,
   `SUPRA_LEGAL_DATA_CONNECTORS_ENABLE_LIVE_TESTS`. Every existing env var in
   `.env.example` carries the prefix; unprefixed names would be the odd ones
   out.

5. **`.env.example` cleanup rides along**: the stale `SUPRA_LEGISCAN_API_KEY`
   line is removed (LegiScan support was dropped 2026-07-02).

6. **Confirmed absences** (searched before building): no existing `JSONValue`
   or RFC-4180 CSV parser in `SupraResearch` or its dependencies — both are
   built as planned. Billing CSV code in `SupraSessions` is export-only and in
   the wrong package to reuse.

7. **XBRL summaries are bounded**: flattened company-facts/concept/frame
   summaries cap at 500 facts per response (raw payload still preserved in
   full); the cap is documented in the connector doc.

8. **Baseline recorded**: SupraResearch 166 tests green, SupraNetworking green,
   app builds — immediately before connector work started.
