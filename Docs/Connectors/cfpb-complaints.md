# CFPB Consumer-Complaint Connector

## Purpose

Search, retrieve, profile, and trend the CFPB's public consumer-complaint
database as normalized, raw-preserving records and neutral ingestion text.
Complaints are consumer ALLEGATIONS — nothing this connector emits states or
implies that a complaint is true, proven, adjudicated, or meritorious.

## Official sources

- API docs: https://cfpb.github.io/api/ccdb/api.html
- Swagger: https://github.com/cfpb/ccdb5-api/blob/main/swagger-config.yaml
- Fetched host: `www.consumerfinance.gov` only (base
  `/data-research/consumer-complaints/search/api/v1/`).

## Configuration (environment)

| Variable | Default | Notes |
|---|---|---|
| `SUPRA_CFPB_RATE_LIMIT_PER_SECOND` | 2 | Clamped 0.1–10. |
| `SUPRA_LEGAL_DATA_CACHE_DIR` | `~/Library/Caches/SupraAI/LegalDataConnectors` | Response cache root. |

No key. App wiring should give this connector its OWN `AuthorizedHTTPClient`
with a CFPB-tuned `RateLimitTracker` (suggested 60/min, 300/hr).

## Behavior

- **Parameters** map exactly to the documented names
  (`date_received_min/max`, `zip_code`, `submitted_via`, `has_narrative`,
  `company_response`, …); array filters use repeated query items (Swagger
  `explode: true`).
- **Not sent**: `sub_product`, `sub_issue`, `consumer_disputed` — not
  confirmed as first-class parameters. They are applied CLIENT-SIDE over the
  fetched pages, and every use records that limitation on the result.
- **Pagination**: `frm` offsets; `size` clamped 1–1000 (default 100);
  `maxPages` default 5, capped at 20 (100 with `allowsLargeExport`) — never
  unbounded. Stops early on a short page. When the source-reported total
  exceeds the fetch, the result says so.
- **Complaint by ID** accepts numeric strings only, validated before network.
- **Normalization** tolerates the Elasticsearch envelope
  (`hits.hits[]._source`), bare arrays, and single objects; timestamps
  normalize to `yyyy-MM-dd`; empty strings become nil. `sourceUrl` is the
  public detail page (`…/search/detail/{id}`).
- **Profiles** are factual: counts by product/issue/state/channel/response,
  timely share, narrative count + samples, interval trend, limitations
  (including "the database does not adjudicate complaints").
- **Trends** are computed from the bounded page set: the documented `/trends`
  endpoint returns counts WITHOUT the per-bucket product/issue/company
  breakdowns the bucket contract requires, so it is used only as a counts
  cross-check (`parseTrendCounts`). Buckets: month / calendar quarter / year,
  with `intervalStart`/`intervalEnd`/`count`/tops (company tops omitted when a
  company filter is present).
- **Caching**: 24h for search, detail, and trends. **Retry**: 429/502/503/504
  + transport, max 3 attempts, `Retry-After` honored.

## RAG text

Per-complaint text frames everything as a submission ("Company the complaint
was submitted about", "Consumer narrative (as submitted, an allegation)");
narrative and public-response sections are omitted when absent — no
placeholders. Profile summaries say "The database contains N complaints
matching…" and never use conclusion words.

## Known limitations

- Client-side filters (`sub_product`, `sub_issue`, `consumer_disputed`) see
  only the fetched pages.
- Deep pagination via `search_after` is not implemented (no confirmed stable
  cursor in the documented response); the page bound is the honest limit.
- `sort = created_date_desc` follows the documented UI default.

## Regression safety

- No authenticated CourtListener path is used.
- Live tests are disabled by default (opt-in env flag; narrow query, size ≤ 5).
- Raw source data is preserved on every record.
- Unsupported source behavior is recorded as limitations, not guessed.
- The connector provides no legal or consumer-protection conclusions.

## Tests

```sh
cd Packages/SupraResearch
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --filter Cfpb
```
