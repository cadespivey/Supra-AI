# Government-Data Connectors

Key-less connectors in `Packages/SupraResearch` for public government
records, built on shared infrastructure
(`Sources/SupraResearch/Connectors/`): per-connector HTTP execution with
pacing, caching, bounded retries, typed errors, SHA-256 raw-payload hashing,
and neutral `LegalDataIngestionRecord` output for RAG.

| Connector | Doc | Fetched host | Data |
|---|---|---|---|
| SEC EDGAR | [sec-edgar.md](sec-edgar.md) | `data.sec.gov` | Company submissions, filings, XBRL facts/concepts/frames |
| CFPB complaints | [cfpb-complaints.md](cfpb-complaints.md) | `www.consumerfinance.gov` | Consumer-complaint search, profiles, trends |
| NLRB data | [nlrb-data.md](nlrb-data.md) | `www.nlrb.gov` | Recent filings + election results CSV imports, local search |

Shared rules (see each doc's Security invariants):

- Only the three hosts above are network-allow-listed; requests use
  `sendUnauthenticated` (no tokens, no cookies).
- Raw source data is preserved on every record; RAG text is neutral —
  allegations stay allegations, filings stay filings.
- Errors and health metadata never leak secrets, local paths, raw payloads,
  or user query terms.
- Live tests are opt-in via `SUPRA_LEGAL_DATA_CONNECTORS_ENABLE_LIVE_TESTS=1`.
- Configuration comes from `SUPRA_`-prefixed environment variables (see
  `.env.example`); the SEC connector additionally requires
  `SUPRA_SEC_EDGAR_USER_AGENT` for live use.

Plan and amendments: `Docs/Government-Data-Connectors-Claude-Plan.md`.
