# SEC EDGAR Connector

## Purpose

Company submissions, filing history (including SEC's historical continuation
files), and XBRL financial facts from SEC EDGAR's official JSON APIs — as
normalized, raw-preserving records and neutral ingestion text for future
RAG/document indexing. Filing **metadata** only; document bodies are never
downloaded.

## Official sources

- APIs: https://www.sec.gov/search-filings/edgar-application-programming-interfaces
- Fetched host: `data.sec.gov` only. Archive URLs (`www.sec.gov/Archives/...`)
  are BUILT for the user's browser and never fetched by the app, so
  `www.sec.gov` is deliberately absent from the network allow-list.

## Configuration (environment)

| Variable | Default | Notes |
|---|---|---|
| `SUPRA_SEC_EDGAR_USER_AGENT` | — | **Required before any SEC request** (SEC fair-access policy: a contact string like `Firm Name you@example.com`). Checked before network; never echoed in errors. |
| `SUPRA_SEC_EDGAR_RATE_LIMIT_PER_SECOND` | 2 | Clamped 0.1–10 (SEC's ceiling is 10 req/s). |
| `SUPRA_LEGAL_DATA_CACHE_DIR` | `~/Library/Caches/SupraAI/LegalDataConnectors` | File-backed response cache root. |

App wiring must give this connector its OWN `AuthorizedHTTPClient` with a
SEC-tuned `RateLimitTracker` (suggested 120/min, 600/hr) — the default tracker
is CourtListener-tuned at 5/min and would starve pagination.

## Example

```swift
let connector = SecEdgarConnector(
    httpClient: secClient,               // dedicated client, SEC-tuned tracker
    cache: .forConnector(named: SecEdgarConnector.connectorName, configuration: .fromEnvironment())
)
let filings = try await connector.getAnnualReports(cik: "320193")
let records = try connector.toIngestionRecords(filings)
```

## Behavior

- **CIK normalization**: 1–10 digits, whitespace/internal hyphens tolerated,
  left-padded to 10. Letters and URL punctuation are validation errors, never
  silently stripped.
- **Recent filings** zip SEC's columnar `filings.recent` by index (ragged
  arrays normalize to the longest column with a warning; rows without an
  accession number are skipped with a warning).
- **`getFilingByAccession`** checks recent filings, then walks historical
  continuation files lazily, each cached independently. `getRecentFilings`
  never loads continuation files.
- **Filters** are client-side (the API has no filter parameters): form types
  case-insensitive, ISO dates only (else `validation`), limit clamped 1–1000,
  `includeAmendments=false` drops `*/A` forms unless explicitly listed.
- **XBRL** responses keep the FULL raw payload; flattened fact summaries are
  capped at 500 per response (`isFactSummaryTruncated` flags the cap).
- **Caching**: submissions 6h; XBRL 24h. Non-2xx responses are never cached.
- **Retry**: 429/502/503/504 and transport failures, max 3 attempts,
  `Retry-After` honored (else 0.5s/1.0s).

## Normalized fields

`SecCompanyRecord`, `SecFilingRecord`, `SecXbrlRecord` — every record carries
`source="sec_edgar"`, a `sourceRecordType`, `sourceUrl`, `retrievedAt`, and the
raw source object as `JSONValue`. Ingestion IDs:
`sec_edgar:filing:{cik}:{accessionNumber}`,
`sec_edgar:xbrl:{kind}:{cik}:{taxonomy}:{concept}:{unit}:{period}:{accession}`.

## RAG text

Neutral and source-attributed: company + CIK, form + filing date, accession
number, period, items, primary document, archive link, and the data.sec.gov
source with retrieval date. Empty fields are omitted (no placeholders). The
template never introduces legal, securities, or investment conclusions.

## Known limitations

- Numbers in preserved raw JSON round-trip through `Double` (`JSONValue`);
  exact-precision needs are served by the cached raw bytes.
- No separate DTO layer: normalization reads `JSONValue` directly (raw-first
  by construction — a plan deviation recorded here).
- The RAG template was authored to the plan's test contract; the original
  source-prompt file is not in the repo.

## Regression safety

- No authenticated CourtListener path is used (stubs fail the suite if `send`
  is ever called).
- Live tests are disabled by default
  (`SUPRA_LEGAL_DATA_CONNECTORS_ENABLE_LIVE_TESTS=true` + UA to enable).
- Raw source data is preserved on every record.
- Unsupported/unclear source behavior is documented, not guessed.
- The connector provides no legal, securities, or investment conclusions.

## Tests

```sh
cd Packages/SupraResearch
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --filter SecEdgar
```
