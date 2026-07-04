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

## Phase 1 - Shared Connector Infrastructure

Create `Packages/SupraResearch/Sources/SupraResearch/Connectors/`.

Add these files:

- `LegalDataConnectorConfiguration.swift`
- `LegalDataConnectorError.swift`
- `LegalDataConnectorCache.swift`
- `LegalDataConnectorModels.swift`
- `ConnectorPacer.swift`
- `JSONValue.swift`

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

3. `LegalDataConnectorCache`
   - Define protocol:
     `get(key:)`, `put(entry:)`, `removeExpired(now:)`.
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

4. `ConnectorPacer`
   - Actor that enforces per-connector minimum delay between requests:
     `minDelay = 1.0 / requestsPerSecond`.
   - Keep using `AuthorizedHTTPClientProtocol.sendUnauthenticated`; do not call
     `send`, because `send` is CourtListener-token-specific.
   - For 429 and 5xx, support bounded retry with `Retry-After` when present.

5. `JSONValue`
   - Small `Codable`, `Equatable`, `Sendable` enum for preserving unknown JSON:
     object, array, string, number, bool, null.
   - Also add helpers to encode stable canonical JSON for hashing.

Update `Packages/SupraNetworking/Sources/SupraNetworking/NetworkPolicyService.swift`:

- Add official hosts:
  - SEC: `data.sec.gov`, `www.sec.gov`, `sec.gov`
  - CFPB: `www.consumerfinance.gov`, `consumerfinance.gov`
  - NLRB: `www.nlrb.gov`, `nlrb.gov`
  - Historical-data discovery only as needed after source confirmation:
    `catalog.data.gov`, `www.data.gov`, `catalog.archives.gov`
- Add tests in `Packages/SupraNetworking/Tests/SupraNetworkingTests/SupraNetworkingTests.swift`
  proving these hosts are HTTPS-only and credential-free.

Update `.env.example` with the connector env vars. Leave secrets blank.

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

Implementation details:

1. `normalizeCik`
   - Accept `String` and `Int` overloads.
   - Trim whitespace, strip harmless formatting, require only digits after
     cleanup, reject empty or more than 10 digits, left-pad to 10.
   - Tests:
     `320193`, `"320193"`, `"0000320193"`, empty, nonnumeric, too long.

2. Endpoints
   - `https://data.sec.gov/submissions/CIK{normalized}.json`
   - Historical continuation files from the `files` array:
     `https://data.sec.gov/submissions/{name}`
   - `https://data.sec.gov/api/xbrl/companyfacts/CIK{normalized}.json`
   - `https://data.sec.gov/api/xbrl/companyconcept/CIK{normalized}/{taxonomy}/{concept}.json`
   - `https://data.sec.gov/api/xbrl/frames/{taxonomy}/{concept}/{unit}/{frame}.json`
   - Encode path components safely. Keep taxonomy/concept/unit/frame validation
     strict enough to block slashes or embedded URLs.

3. Requests
   - Always set `User-Agent` from `SEC_EDGAR_USER_AGENT`.
   - Set `Accept: application/json`.
   - Fail with `LegalDataConnectorError.config` before network if the UA is
     missing.
   - Use cache by URL+operation. Suggested TTL:
     submissions 6 hours, company facts 24 hours, concept/frame 24 hours.

4. Normalization
   - Decode SEC submissions preserving raw JSON.
   - SEC `filings.recent` is columnar. Zip arrays by index into filing records.
   - Normalize company record fields from the top-level submission object.
   - Normalize recent filings and historical continuation filings to the prompt's
     filing model.
   - Source record IDs:
     `sec_edgar:company:{cik}`, `sec_edgar:filing:{cik}:{accessionNumber}`,
     `sec_edgar:xbrl:{kind}:{cik}:{taxonomy}:{concept}:{unit}:{period}:{accessionNumber}`.
   - Filing archive base:
     `https://www.sec.gov/Archives/edgar/data/{cikWithoutLeadingZeroes}/{accessionWithoutDashes}/`
   - Primary document URL only when `primaryDocument` exists.

5. RAG text
   - Implement exactly the neutral template from the source prompt.
   - Omit empty optional fields rather than writing placeholders.
   - Do not infer legal significance, materiality, fraud, compliance, or
     securities-law conclusions.

6. Tests in `Packages/SupraResearch/Tests/SupraResearchTests/SecEdgarConnectorTests.swift`
   - Use an actor stub of `AuthorizedHTTPClientProtocol`.
   - Assert requests use `sendUnauthenticated`, never `send`.
   - Assert `User-Agent` and URL construction.
   - Cover all prompt-listed unit tests.
   - Live tests in `SecEdgarLiveTests.swift`, skipped unless
     `LEGAL_DATA_CONNECTORS_ENABLE_LIVE_TESTS=true` and
     `SEC_EDGAR_USER_AGENT` is present. Probe CIK `0000320193`.

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
6. Use repeated query items for array parameters, matching Swagger `explode:
   true`.
7. Defaults:
   `size = 100`, `maxPages = 5`, sort newest first if accepted by the API.
   Hard-cap untrusted caller values unless explicit options allow more.
8. Normalize complaint records to the prompt shape and preserve raw JSON.
9. Profile aggregation must be factual:
   counts by product/issue/state/submittedVia/companyResponse, timely
   percentage, narrative count, sample narratives, trend by selected interval,
   limitations.
10. Trends:
   Prefer documented `/trends` when it returns the requested aggregation; if the
   API shape is insufficient, compute trends from bounded search pages and
   document that fallback.
11. RAG text:
   Omit missing narrative/public-response sections; no placeholders.
   Never say a complaint is true, proven, adjudicated, or legally meritorious.

Tests in `CfpbComplaintConnectorTests.swift`:

- Request construction, filter mapping, pagination, complaint-by-ID,
  normalization with null/missing fields, RAG text generation, profile
  aggregation, trends, cache hit/miss, transient retry, rate pacing, and neutral
  wording.
- Optional live tests skipped unless
  `LEGAL_DATA_CONNECTORS_ENABLE_LIVE_TESTS=true`; use narrow queries with
  `size <= 5`.

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

Implementation details:

1. Treat NLRB as dataset/export-first.
2. First milestone source variants:
   - `official_recent_filings` from the official recent filings CSV.
   - `official_recent_election_results` from the official recent election
     results CSV.
   - `official_cats_data` as a discoverable/importable dataset if a stable
     download URL is confirmed from NLRB/Data.gov/National Archives.
3. Do not invent private endpoints. If parsing the NLRB page to find a
   `Download CSV` URL, isolate that logic in `NlrbSources.swift`, test it with
   static HTML fixtures, and document it as an official-page export adapter.
4. `NlrbLocalRecordStore`
   - Use a file-backed JSONL store under `NLRB_LOCAL_DATA_DIR` or the connector
     cache dir.
   - Store import run metadata:
     `connectorName`, `sourceVariant`, `datasetName`, `sourceUrl`,
     `retrievedAt`, `recordCount`, `rawFilePath` or hash,
     `normalizedRecordCount`, `errors`, `warnings`.
   - Keep indexes in sidecar JSON files for case number, party/employer/union,
     region, date, status, and case type. Load lazily.
5. Normalize cases and election results to the prompt models. Use nil for
   unavailable fields and preserve raw row data.
6. Case classifier:
   - `CA`, `CB`, `CC`, `CD`, `CE`, `CG`, `CP` -> `unfair_labor_practice`
   - `RC`, `RD`, `RM` -> `representation`
   - `UC` -> `unit_clarification`
   - `UD` -> `union_deauthorization`
   - `AC` -> `amendment_of_certification`
   - Unknown -> `unknown`, preserving raw case type.
7. RAG text:
   - Use the prompt templates.
   - Omit missing fields.
   - Do not imply violations or formal findings unless an explicit source field
     supports that statement.
8. Party history summary:
   - Counts, case types/categories, regions, statuses, reason closed
     distribution, recent cases, election results, variants used, limitations.
   - Neutral wording only.

Tests in `NlrbDataConnectorTests.swift`:

- CSV import parsing, recent filing normalization, election normalization,
  C-case and R-case classification, case-number search, employer/union/party
  search, date and region filters, RAG text, party history summary, provenance,
  deduplication, missing field handling, and import run logging.
- Optional live tests skipped unless
  `LEGAL_DATA_CONNECTORS_ENABLE_LIVE_TESTS=true`; only fetch small official
  recent CSV data or inspect headers, not repeated large downloads.

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

## Suggested Claude Commit Strategy

Use small commits if committing is requested:

1. Shared connector infrastructure and network allow-list.
2. SEC EDGAR connector, tests, docs.
3. CFPB complaint connector, tests, docs.
4. NLRB data connector, tests, docs.
5. Final docs and env example cleanup.

