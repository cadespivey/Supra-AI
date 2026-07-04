# NLRB Data Connector

## Purpose

Import the NLRB's official recent-filings and recent-election-results CSV
exports into a local, raw-preserving store, and answer case/party/election
questions from that LOCAL data. Filings and allegations are described as
FILED/ALLEGED — nothing this connector emits states or implies that a charge
is true, that conduct was unlawful, or that a party committed violations.

## Official sources

- Recent filings page: https://www.nlrb.gov/reports/graphs-data/recent-filings
- Recent election results page:
  https://www.nlrb.gov/reports/graphs-data/recent-election-results
- Fetched host: `www.nlrb.gov` only. There is NO stable NLRB REST API; the
  importable sources are the "Download CSV" links discovered on those two
  official pages (relative hrefs resolve against the page; HTML entities in
  attribute values are decoded; anything resolving off `www.nlrb.gov` is
  rejected, so page markup cannot redirect the importer).
- CATS (historical ULP) and CHIPS (historical representation) datasets are
  listed as `discovered_but_not_imported` with manual pointers — no stable
  confirmed download URL. Third-party mirrors are defined for provenance but
  NEVER fetched (`unsupported`; no mirror host is network-allow-listed).

## Configuration (environment)

| Variable | Default | Notes |
|---|---|---|
| `SUPRA_NLRB_RATE_LIMIT_PER_SECOND` | 1 | Clamped 0.05–5. |
| `SUPRA_NLRB_LOCAL_DATA_DIR` | `{SUPRA_LEGAL_DATA_CACHE_DIR}/NLRBData` (i.e. `~/Library/Caches/SupraAI/LegalDataConnectors/NLRBData`) | Local record store root. Set this when imported records should survive OS cache eviction — app wiring should point it at Application Support. |
| `SUPRA_LEGAL_DATA_CACHE_DIR` | `~/Library/Caches/SupraAI/LegalDataConnectors` | Response cache root. |

No key. App wiring should give this connector its OWN `AuthorizedHTTPClient`
with an NLRB-tuned `RateLimitTracker` (suggested 30/min, 120/hr).

## Behavior

- **Discovery** (`refreshAvailableDatasets`): fetches the two official pages
  (cached 6h), extracts their Download CSV links, and reports every known
  source honestly — `available` only with a confirmed official download URL.
  If a page's layout changes and no link is found, the dataset is reported
  `unsupported` with a note; session state is never automated.
- **Import** (`importDataset`): downloads the CSV, parses it with a real
  RFC-4180 state machine (quoted commas, `""` escapes, CRLF/LF — CRLF is a
  single Swift `Character`, handled explicitly), normalizes rows via
  header-alias matching, and appends to the local store. Rows with no case
  number are skipped with a warning. `maxRecords` caps are logged. Every run
  saves the raw payload (`raw/{variant}/{sha256}.csv`) and an import-run
  record with counts, warnings, and errors.
- **Idempotency**: dedup keys (case: variant+caseNumber+recordType; election:
  +unitId+tallyDate, falling back to the raw-row content hash when both are
  absent) make re-imports no-ops — search results never double. There is no
  record-level upsert in this milestone: a later export row that shares a
  dedup key with an already-imported row (e.g. a corrected tally for the
  same case, unit, and tally date) is treated as a duplicate; refreshing
  such corrections requires clearing the local store and re-importing.
- **Indexes**: the store keeps case-number and dedup sidecar indexes only.
  Party/employer/union, region, date, status, and case-type searches scan
  the locally imported JSONL records — bounded, local-only work at this
  milestone's dataset sizes; the plan's additional sidecar indexes are
  deferred until a dataset shows the need.
- **Classification**: case-type code comes from an explicit `Case Type`
  column when present, else the case-number middle segment. CA/CB/CC/CD/CE/
  CG/CP → unfair-labor-practice; RC/RD/RM → representation; UC, UD, AC have
  their own categories; unknown codes are preserved verbatim as `unknown`
  category.
- **Local search** (no network): by case number (normalized uppercase,
  dashes preserved), employer, union, any party, region, ULP/representation
  category, and filed-date range (`yyyy-MM-dd` or `MM/dd/yyyy`; unparseable
  query dates throw; undated records are excluded unless `includeUndated`).
  Election results filter by case number, union, region, and tally window.
- **Party history** (`summarizePartyNlrbHistory`): counts by case type,
  category, region, status, and reason closed, plus recent cases and any
  election results — phrased as "matching case records", explicitly "not
  findings or adjudications", with the limitations listed on the summary.
- **RAG text**: one record per chunk; missing fields are omitted (never
  "N/A"); allegations render as "Allegations as categorized in the filing";
  every chunk carries the public case page (`https://www.nlrb.gov/case/…`),
  the dataset URL, and the retrieval date.

## Security invariants

- Requests go only to `www.nlrb.gov` (allow-listed in `SupraNetworking`) via
  `sendUnauthenticated` — no Authorization header, no key, no cookies.
- `importDataset` re-asserts the `https://www.nlrb.gov` pin on the download
  URL itself: dataset sources are plain Codable values, so a tampered or
  hand-built one cannot point the importer at another allow-listed host.
- Error messages and health metadata never include local paths, raw payloads,
  or raw user query terms.
- `healthCheck()` is non-network: configuration validity + import-run count.
- Live tests (`NlrbLiveTests`) run only with
  `SUPRA_LEGAL_DATA_CONNECTORS_ENABLE_LIVE_TESTS=1` and only probe discovery.

## Neutrality contract

Forbidden in any emitted text: "violated", "violation" (as a finding),
"guilty", "unlawful conduct occurred", "found to have". Summaries count
"matching case records", never "violations". Certified-representative and
status fields are reported "per the export", never inferred.

## Tests

`NlrbDataConnectorTests` (17) cover: CSV-link discovery for both pages
(including off-host decoy rejection and entity-encoded hrefs), RFC-4180
parsing, filings and election normalization, classifier known/unknown codes
and unrecognized-explicit-type fallback, normalized case-number lookup,
employer/union/party search (including `partyName`/`caseType` filters),
date-range and region filtering, off-host import rejection, RAG neutrality
and omitted-field behavior, party-history neutrality, provenance, idempotent
re-import, and import-run warnings/errors.
Fixtures live in `Tests/SupraResearchTests/Fixtures/NLRB/`.
