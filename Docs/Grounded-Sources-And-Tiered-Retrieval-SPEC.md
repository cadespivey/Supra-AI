# Grounded Source Previews & Tiered Retrieval — Implementation Spec

Goal: three capabilities that share one **"fast preliminary, optional deeper"** grounding
pattern, plus **clickable source footnotes** that open a slideover preview jumping to the
exact passage a source is grounded in.

- **A — Source-linked footnotes.** When a chat/Q&A answer cites a source (`[S1]` matter doc,
  `[A1]` case law/CourtListener), the inline marker is a clickable link that opens a slideover
  preview of that source and jumps to (and highlights) the grounding segment.
- **B — Tiered document retrieval.** For factual questions over a matter's documents, answer
  first from the *most-likely* documents (fast), and offer an optional *deeper* exhaustive
  search that takes longer.
- **C — Tiered research.** For legal-research questions, consult the matter's *saved
  authorities* first when it has a body of them; fall back to CourtListener — silently when the
  matter has no authorities yet.

> **Design principle: build on what exists.** The codebase already has locators, a
> source-mapping table, a PDFKit preview that jumps-and-highlights, and hybrid ranked
> retrieval. This spec mostly *wires existing pieces together* and adds a fast tier — it does
> not rebuild preview or retrieval.

---

## 1. What already exists (verified against current code)

| Capability | Where | State |
| --- | --- | --- |
| Exact source locations | `DocumentSourceLocator` (`SupraDocuments`) — `sourceKind, pageIndex, pageLabel, charStart/charEnd, sheetName, cellRange, emailPartPath` | ✅ complete, serialized as `locatorJSON` |
| `[S#]` → (doc, location) map | `document_output_sources` (`citationLabel, documentID, chunkID, locatorJSON, excerpt, rank`) keyed by `document_source_sets.structuredOutputVersionID` | ✅ persisted per output version |
| Preview that jumps + highlights | `DocumentPreviewView` + `PDFKitView` (`MatterDocumentsView.swift`); `DocumentPreviewLoader.load(documentID, locator)` | ✅ PDF page-nav + `findString` highlight; text char-range highlight |
| Hybrid ranked retrieval | `DocumentRetrievalService.retrieve(matterID, query, scope, limit)` — FTS5 + semantic, fused by RRF; candidate pool 30; **mandatory** LLM rerank → top 10 | ✅ but single-pass, all-or-nothing |
| Legal research + authorities | `GlobalChatController.legalResearchOutput` → `retrieveAuthorities` (always CourtListener); `authorities`/`research_results` tables; `LegalAuthorityRanker` | ✅ network-only; no local-first path |
| Citation extraction | `CitationCoverage.usedLabels(answer)` regex over `[S#]`; `LegalCitationVerifier` for `[A#]` | ✅ |

**Gaps this spec closes:**
1. Chat `MessageRecord` has no link to the sources its `[S#]`/`[A#]` markers cite (doc sources
   attach to `StructuredOutputVersionRecord`; legal sources live in an *ephemeral* in-memory
   `LegalSourcePacket`). Restart/regenerate loses the link.
2. The chat markdown renderer (`MarkdownView`/`MarkdownInline`, `GlobalChatsView.swift`) renders
   `[S#]`/`[A#]` as plain text — no click handling.
3. The preview is a fixed modal `.sheet` (560×460), not a slideover.
4. No fast/deep tier in retrieval; the LLM rerank always runs.
5. No local-authority search; saved authorities carry no opinion text to ground from.

---

## 2. Feature A — Source-linked footnotes → slideover preview

### 2.1 Persist a message-level citation index

Add a table so any rendered message can resolve its own citations without walking the audit
trail or depending on in-memory packets.

```sql
CREATE TABLE message_citations (
  id            TEXT PRIMARY KEY,
  message_id    TEXT NOT NULL,            -- MessageRecord.id
  label         TEXT NOT NULL,            -- "S1", "A3"
  kind          TEXT NOT NULL,            -- "document" | "authority"
  -- document citations:
  document_id   TEXT,
  chunk_id      TEXT,
  locator_json  TEXT,                     -- serialized DocumentSourceLocator
  -- authority citations:
  authority_id  TEXT,                     -- authorities.id (persisted) when saved
  opinion_id    TEXT,                     -- CourtListener opinion id (fallback)
  cluster_id    TEXT,
  absolute_url  TEXT,
  created_at    DATETIME NOT NULL
);
-- index (message_id), (message_id, label)
```

Populate at **answer-save time**, where the labels are still known to match the answer text:
- `DocumentQAController` and `StructuredOutputController`: when they persist the answer and the
  `DocumentSourceSet`, also write one `message_citations` row per `DocumentOutputSourceRecord`
  (`kind = "document"`).
- `GlobalChatController.legalResearchOutput`: write one row per packet authority used
  (`kind = "authority"`), carrying `authority_id` when the authority is persisted (Feature C)
  and `opinion_id`/`cluster_id`/`absolute_url` otherwise.

> **Label-stability invariant.** The label written to `message_citations` MUST equal the label
> in the saved answer text. Reranking renumbers sources, so write citations from the *final*
> label assignment used to render the answer — never from a pre-rerank ordering. Add a test.

**Backfill** is optional: historical messages without rows simply show non-clickable markers
until regenerated. (A migration that walks `generation_sessions`/audit events → output version
/ research session can backfill later; not required for v1.)

### 2.2 Resolver

```swift
public enum SourceTarget: Sendable, Equatable {
    case document(documentID: String, locator: DocumentSourceLocator)
    case authority(MessageAuthorityRef)   // id/opinionId/clusterId/url + cached text
}
public protocol SourceLinkResolving {
    func resolve(messageID: String, label: String) -> SourceTarget?
}
```
A `SourceLinkResolver` (in `SupraSessions`) reads `message_citations` and decodes the locator.

### 2.3 Make `[S#]`/`[A#]` clickable in the chat renderer

`MarkdownInline.attributed()` uses Foundation's markdown parser, which ignores `[S#]`. Add a
**citation pass** over the produced `AttributedString`:
- Regex `\[(S|A)\d+\]` over the rendered text; for each match set a custom attribute
  (e.g. `AttributeScopes`-style `citationLabel`) and link styling (accent color, underline).
- In `MessageRow`/`MarkdownView`, attach a tap handler (macOS: `.onTapGesture` over the run, or
  an `NSTextView`/`AttributedString` `link`-attribute carrying a `supra-cite://<messageID>/<label>`
  URL intercepted by an `OpenURLAction`). The handler calls the resolver and opens the preview
  (§2.4). Only mark labels that resolve, so dangling markers stay inert.

### 2.4 Slideover preview presentation (reuse existing preview)

Present the **existing** `DocumentPreviewView` as a right-edge **slideover/inspector**, not a
modal sheet:
- Drive it from a workspace-level `@State previewTarget: SourceTarget?` so the panel is shared
  across the chat and overlays the conversation rather than blocking it.
- For documents: `DocumentPreviewLoader.load(documentID, locator)` already returns a
  `DocumentPreviewModel` and `PDFKitView` already does `PDFDestination` page-nav + `findString`
  highlight, and text sources highlight via `charStart/charEnd`. **No new jump logic needed** —
  pass the citation's locator straight through.
- **"Finder-style" answer:** Apple's QuickLook (`QLPreviewController` / `.quickLookPreview`) is
  the system preview standard but is read-only and **cannot deep-link/highlight a location**.
  The jump-to-segment requirement therefore uses the app's existing PDFKit/AttributedString
  preview. Keep QuickLook as an **open-only fallback** for formats the in-app preview can't
  render (it opens the file, no jump). Document this tradeoff in the panel ("preview-only — no
  source highlight for this file type").
- Slideover styling: a detached/inspector panel ~360–460pt wide with a header (doc name +
  locator `displayString`, e.g. "p. 3" / "Sheet1!B4"), the preview body, and a "Open in
  Documents" / "Reveal in Finder" action. Persisting last size is nice-to-have.

### 2.5 Legal-authority reader (`[A#]`)

`[A#]` opens the same slideover showing an **authority reader**: case name, citation(s), court,
date, precedential status, the opinion text, and "Open on CourtListener" (`absolute_url`). Text
comes from the persisted authority (Feature C §4.3) or, if absent, a one-shot hydrate from
CourtListener by `opinion_id`. Render the opinion with the text/AttributedString path (or
`OpinionPDFView`, which already exists), highlighting the cited snippet when available.

---

## 3. Feature B — Tiered document retrieval (fast preliminary, deep on request)

### 3.1 Add a depth dimension to retrieval

```swift
public enum RetrievalDepth: Sendable { case fast, deep }
```
Extend `DocumentRetrievalService.retrieve(...)` (already a pure, side-effect-free function with
a `limit`) with depth:
- **`.fast`** — candidate pool ~12, **skip the LLM rerank**, pack the top ~5–8 by RRF, answer.
  Latency ≈ FTS + semantic + one generation (a few seconds). Consider a slightly higher
  `minSemanticSimilarity` (≈0.25) to keep the fast packet precise.
- **`.deep`** — candidate pool 60–100, run the existing LLM rerank, pack ~10–12, answer. This
  is today's behavior, widened.

`DocumentQAController.generate()` already guards the rerank on `candidatePoolSize >
packedSourceLimit`, so making it depth-driven is local.

### 3.2 Two-phase answer flow

1. Run `.fast`; return the preliminary answer + its sources immediately, with state
   `.preliminary` and a visible affordance: **"Searched the most relevant documents. Search all
   documents for a fuller answer? (slower)"**.
2. On user request, run `.deep`; replace/append a `.deep` answer. Persist a `sourcePhase`
   (`fast`/`deep`) on `DocumentOutputSourceRecord` (or the set) so the UI can label which pass
   found a source, and so "search deeper" never silently reorders the preliminary sources
   without indication.
3. Apply the same flow to **matter-chat document grounding** (`MatterChatDocumentGrounding`,
   currently hard-limit 8) so chat answers are fast-by-default with a "deeper" option.

### 3.3 When to skip the prompt (locked, §8.2)

**Auto-escalate to `.deep` once only when the fast packet is empty** — i.e. the fast pass
returned no usable sources (no FTS hits and nothing above the semantic floor). In that case run
`.deep` silently and label the answer as a full-document search. When the fast pass *does* find
sources, always show the preliminary answer with the explicit "Search deeper" affordance — do
**not** auto-escalate merely on low confidence, so the `.fast` tier stays predictable and fast.

---

## 4. Feature C — Tiered research (saved authorities first)

### 4.1 Gate: does the matter have authorities?

Add `AuthorityRepository.countAuthorities(matterID:) -> Int` (a GRDB count). In
`legalResearchOutput`, branch on it **before** any network call:
- **Has authorities (≥ 1 saved authority — §8.5):** run a local authority pass first (§4.2),
  produce a **preliminary** grounded answer from saved authorities, and offer **"Search
  CourtListener for more authority? (uses the network)"** as the deeper tier.
- **No authorities:** call CourtListener directly, **without prompting** (today's behavior).

This preserves CourtListener quota and mirrors Feature B's preliminary/deep shape.

### 4.2 Local authority search + ranking

- Add `AuthorityRepository.searchAuthorities(matterID:, classification:)` — filter saved
  authorities by `LegalQueryClassification` (legal issue terms, jurisdiction, court ids,
  citation lookups) with a `LIKE`/FTS pass over case name + citation + stored text.
- Reuse `LegalAuthorityRanker` by projecting `AuthorityRecord → LegalAuthority` and calling
  `rank(...)` with the same classification context, so local results are scored identically to
  network results.

### 4.3 Persist opinion text on save (prerequisite for grounding from locals)

Today saved authorities store only metadata + a short snippet, so a local-first answer would be
thin. When an authority is saved (`ResearchSessionController.reviewResult`/`upsertAuthority`)
**and** when chat hydrates top authorities (`hydrateTopAuthorities`), persist the hydrated
opinion text (a new `authorities.opinion_text` column or a sibling `authority_texts` table).
This also lets §2.5's authority reader work offline and avoids re-fetching from CourtListener.

> Locked (§8.3): persist opinion text **only for user-saved authorities** (curated), never for
> transient search results. Unsaved authorities hydrate on demand for a one-shot `[A#]` preview.

### 4.4 Decision logic (single place)

```
classification = classify(prompt)
if countAuthorities(matter) >= threshold:
    locals = rank(searchAuthorities(matter, classification))
    if locals strong enough:
        answer from locals  → state .preliminary, offer "Search CourtListener" (deep)
    else:
        fall through to CourtListener (optionally note "your saved authorities didn't cover this")
else:
    CourtListener search, no prompt   → today's path
```

### 4.5 Statutory tier — Open Legal Codes (client built)

Case law (CourtListener) and **statutory text** are different sources. Open Legal Codes (OLC)
is a free, key-less, unlimited statutory/regulatory lookup (USC, CFR, all 50 states' statutes
incl. `fl-statutes`, plus municipal codes — 8,443 jurisdictions). Because it costs nothing and
has no rate limits, it's an ideal *opportunistic statutory tier* that never burns CourtListener
quota.

**Built (this pass):** `OpenLegalCodesClient` in `SupraResearch/OpenLegalCodes/` —
`searchCode(jurisdictionID:query:)`, `searchAcross(query:state:)`, `fetchSection(jurisdictionID:path:)`,
`jurisdiction(id:)` — over the shared `AuthorizedHTTPClient` (always **unauthenticated**; the
CourtListener token is gated to the courtlistener hosts). `openlegalcodes.org` is on the
network allow-list. DTOs and error states are modeled from the live API, including the
lazy-crawl states (`202 CRAWL_IN_PROGRESS`, `503 CRAWL_FAILED`) as typed transient errors.
Covered by `OpenLegalCodesClientTests`.

**Reliability reality (verified by live probes 2026-06-27):** OLC's catalog is broad, but only
~6% of codes are pre-cached; the rest are crawled on first request and the crawl currently
fails for some (e.g. `fl-statutes` → "database or disk is full"). It exposes **no freshness
stamp** (`lastCrawled`/`lastUpdated` are empty), so currency cannot be verified. Therefore OLC
is **best-effort and un-verified**, and the integration must:
- handle `crawlInProgress`/`crawlFailed` gracefully (fall back; optionally retry later);
- **never present OLC statutory text without a currency caveat** and a link to the official
  `sourceUrl` OLC itself reports (e.g. `leg.state.fl.us`).

### 4.6 Source-weight hierarchy (locked policy)

Statutory grounding is ranked by *verifiability of currency*, highest to lowest:

1. **User-provided / user-verified statutory text** — the attorney pasted or confirmed it. Highest authority; never overridden by a network source.
2. **Currency-verifiable sources** — statutory text from a source that carries a reliable version/effective-date (a future official-source integration, or CourtListener-grounded statutory citations the user can confirm).
3. **Open Legal Codes** — convenience lookup only. Always the **lowest** weight, always shown with the currency caveat, and never allowed to contradict (1) or (2). When OLC is the only source, the answer is explicitly framed as a starting point to verify against the official code.

The answer pipeline attaches a `provenance` + `weight` to each statutory source and prefers
higher tiers; lower-weight sources are caveated, not silently blended as equal authority.

### 4.7 Statutory source orchestration — IMPLEMENTED

The unified, pluggable layer that realizes §4.6, in `SupraResearch/Statutes/`:

- **`StatutorySource`** protocol (`id`, `displayName`, `weightTier`, `providesCurrency`,
  `lookup(StatutoryQuery) async -> StatutoryLookupResult`) — transport-agnostic, so a REST,
  MCP, or local source all conform identically. Best-effort: `lookup` never throws; a failure
  returns no provisions + a note.
- **`SourceWeightTier`** — `.convenience` < `.currencyVerifiable` < `.userProvided`, the §4.6
  hierarchy as an ordered enum.
- **`StatutoryProvision`** — the normalized result (citation, text, jurisdiction, url, locator,
  optional `effectiveDate`, `currencyCaveat`), with a `dedupKey`.
- **`StatutorySourceOrchestrator`** — queries all registered sources in parallel, dedupes by
  `dedupKey` keeping the **higher tier**, sorts by tier desc. Adding a source is a one-line
  registry change; the orchestrator and pipeline are untouched.
- **`OpenLegalCodesStatutorySource`** — the OLC conformer (lowest `.convenience` tier). Maps
  jurisdiction→OLC id via `StatutoryJurisdictionMapper` (state name → `<postal>-statutes`;
  `N U.S.C.` → `us-usc-title-N`), best-effort hydrates the top hits' full text, and degrades to
  "no provisions + note" on a `202`/`503` crawl state. Every provision carries the currency caveat.

**Integration into the answer flow** (`GlobalChatController.legalResearchOutput`): a
`statutoryOrchestrator` is injected (default = OLC over its own token-free `AuthorizedHTTPClient`).
At the packet seam, `statutoryAwarePacket(...)` — gated on `classification.desiredAuthorityType
== .statute` — runs the orchestrator, converts each `StatutoryProvision` to a
`LegalAuthority(source: .openlegalcodes, type: .statute)` via `asLegalAuthority` (caveat folded
into the text; jurisdiction set to the classifier label so the verifier matches), and
`StatutoryPacketMerge` **leads the packet with statutes** (the primary law asked about) while
case law fills the remaining slots, capped at `maxPacketAuthorities`. Statutory provisions then
flow through the **existing** `[A#]` source-packet / prompt / `LegalCitationVerifier` machinery,
rendered as caveated statute blocks. The non-statutory path is unchanged; a statutory-lookup
miss leaves the case-law packet exactly as before.

### 4.8 Adding the next source (govinfo / Openlaws / MCP)

To wire a new statutory source:
1. Write one file conforming to `StatutorySource` over its transport, declaring its `weightTier`.
   - **govinfo** (api.data.gov key, USCODE packages/granules in USLM, `dateIssued` → real
     currency) → `.currencyVerifiable`; add `govinfo.gov`/`api.govinfo.gov` to the allow-list.
   - **Openlaws** → tier per its currency guarantees.
   - **MCP-backed** → the conformer is an MCP client; the orchestration is identical (MCP is
     just a transport behind `StatutorySource`).
2. Add `LegalAuthoritySource.<provider>` and a case in `StatutoryProvision.legalAuthoritySource(forSourceID:)`
   (today it defaults to `.openlegalcodes` — give each provider its own tag).
3. Add the source to the `StatutorySourceOrchestrator(sources:)` registry in the controller init.
   The orchestrator's tier-weighted dedupe then makes the higher-tier source (e.g. govinfo) win
   over OLC for the same section automatically — no other change.

### 4.9 eCFR — second statutory source, BUILT (proves §4.8)

`ECFRStatutorySource` (+ `ECFRClient`) wraps the official eCFR full-text search API (free,
key-less, `www.ecfr.gov` allow-listed). It's the **`.currencyVerifiable`** tier: each section
carries a real effective date (`starts_on`), so it **outranks OLC** for the same provision via
the canonical-dedup rule (§4.6). Federal-only — it skips state-specific queries (OLC's domain).
Registered alongside OLC in the controller's default orchestrator. Tests: `ECFRStatutorySourceTests`.

Adding eCFR validated the abstraction end-to-end: one conformer file + one `LegalAuthoritySource`
case + one registry line, no orchestrator/pipeline change.

### 4.10 Firewall hardening (from the statutory-integration review)

- **Currency caveat is enforced, not optional.** A prompt instruction tells the model to flag
  unverified statutory text; and deterministically, `GlobalChatController` appends a currency
  caveat to the answer whenever it cites a `.statute` authority **with no confirmed effective
  date** (OLC) — eCFR (dated) is exempt. The caveat reaches the reader regardless of model
  behavior. The prompt block also renders "Effective date: …" for dated sources vs the
  "⚠️ no verified effective date" line for undated ones.
- **Canonical cross-provider dedup.** `StatutoryProvision.dedupKey` keys on structured identity
  (`jurisdictionID` + bare section number), not display strings, so a higher-tier source actually
  overrides a lower-tier one for the same section (e.g. eCFR "40 CFR § 261.11" ≡ OLC "§ 261.11"
  under `us-cfr-title-40`).
- **Broader statutory trigger.** The tier now engages on a statutory *citation form*
  (U.S.C./C.F.R./"Stat."/"§") even when the classifier didn't tag the query `.statute`.

**Open review follow-ups (tracked, not yet done):** (a) extend `LegalCitationVerifier` to
extract statutory cite strings ("Fla. Stat. § n", "N CFR § n", bare "§ n") so a fabricated
statutory citation under a valid `[A#]` is flagged like a case cite; (b) don't waive the
content-grounding check for short statutory text (or raise OLC `hydrateLimit` to cover all
leading slots); (c) surface the orchestrator's "still crawling / unavailable" notes to the user
when a statutory lookup degrades.

### 4.11 Source categories — not everything is codified law

The user is supplying several government APIs. They sort into three categories; only the first
belongs in this statutory-grounding orchestration:

- **Codified law (statutes/regulations) → `StatutorySource`.** Open Legal Codes (built), **eCFR**
  (built), and future **govinfo** (USCODE, USLM, `dateIssued` → `.currencyVerifiable`) and
  **Openlaws** (if it serves codified statute text).
- **Legislative / bill tracking → a SEPARATE capability (proposed, not built).** **OpenStates v3**
  and **LegiScan** return *bills* (pending & enacted legislation, sponsors, votes, status across
  legislatures) — not codified statute text. They answer "what's pending / legislative history,"
  which is a different research dimension. They need API keys. Recommend a parallel
  `LegislativeSource` abstraction (mirroring `StatutorySource`) rather than forcing bills into
  `StatutoryProvision`.
- **FOIA request infrastructure → out of research scope.** **FOIA.gov `agency_components`** is a
  directory of federal agency FOIA offices for *filing* FOIA requests (needs an api.data.gov key).
  It is not legal authority; it belongs to a hypothetical FOIA-request feature, not grounding.

### 4.12 Unified legal-developments layer — BUILT (Federal Register); key'd sources next

Bills and rulemaking are **not** codified law, so they get their own orchestration parallel to
`StatutorySource`, feeding a separate **non-citable** part of the answer. Legislative (bills) and
regulatory (rules) developments share **one** layer (`SupraResearch/Developments/`):

- **`LegalDevelopmentSource`** protocol — `lookup(LegalDevelopmentQuery) async -> LegalDevelopmentLookupResult`,
  best-effort. `LegalDevelopment` is normalized across providers (`kind` legislative|regulatory,
  identifier, title, jurisdiction, status, date, summary, url).
- **`LegalDevelopmentOrchestrator`** — parallel best-effort lookup, dedupe by (kind, identifier),
  sorted most-recent-first.
- **`FederalRegisterSource`** (+ `FederalRegisterClient`) — **built**, key-less, federal-only
  (skips state queries), `www.federalregister.gov` allow-listed. Regulatory developments
  (rules / proposed rules / notices). Tests: `LegalDevelopmentTests`.
- **Surfacing (locked):** developments NEVER enter the `[A#]` citable packet. They render as a
  separate **"## Legal developments (tracking — not authority)"** section appended to the answer,
  captioned "not citable authority… verify status." `GlobalChatController.legalDevelopmentsSection`
  fetches (best-effort, gated on statutory/regulatory questions) and appends it.
- **Key'd conformers — BUILT** (each reads its key from the token store via the Settings/keychain
  wiring; a missing key yields no results + an actionable "Add a … key in Settings" note; the key
  is sent as a header where the API allows, to keep it out of request logs):
  **govinfo** (`X-Api-Key`, POST USCODE search → `.currencyVerifiable` `StatutorySource` —
  package/title-level grounding only), **OpenStates v3** (`X-API-Key`, bills → `.legislative`),
  **LegiScan** (`?key=`, 50-state + Congress bills → `.legislative`), **Regulations.gov v4**
  (`X-Api-Key`, rulemaking dockets → `.regulatory`). Hosts allow-listed; all wired into the
  orchestrators. Tests `KeyedSourceTests` cover mapping + missing-key gating.
  > **Caveat:** request/response shapes are documentation-based; live verification needs a real key
  > per source. Each source degrades gracefully (decode mismatch → empty + note), so a shape error
  > is a localized fix, never a crash or a corrupted answer.

Out of this layer: **Regulations.gov comment submission** and **FOIA.gov** are *filing actions*
(separate features, deferred); **USPTO** is a separate IP-practice capability (deferred).

---

## 5. Shared UX: the preliminary/deeper control

Both B and C present the same pattern in chat: a grounded preliminary answer with clickable
footnotes (Feature A) and a single, honest affordance under the answer — *"Search deeper
(slower)"* for documents, *"Search CourtListener (network)"* for research. The deeper pass runs
on demand, streams a fuller answer, and re-renders footnotes. Never silently discard the
preliminary answer; show that a deeper pass ran.

---

## 6. File-by-file

**New**
- `Packages/SupraStore/.../Records/MessageCitationRecord.swift` + repository — §2.1.
- `Packages/SupraSessions/.../SourceLinkResolver.swift` — §2.2.
- `Apps/SupraAI/SupraAI/Documents/SourcePreviewSlideover.swift` — slideover host wrapping
  `DocumentPreviewView` + the authority reader — §2.4–2.5.
- (optional) `authority_texts` table/migration — §4.3.

**Edited**
- `DocumentQAController.swift`, `StructuredOutputController.swift` — write `message_citations`;
  add `RetrievalDepth`; two-phase generate (§2.1, §3).
- `Packages/.../DocumentRetrievalService` — `retrieve(..., depth:)` (§3.1).
- `GlobalChatController.swift` — write `message_citations` for `[A#]`; local-first research
  branch + count gate; persist hydrated text (§2.1, §4).
- `ResearchSessionController.swift` — persist opinion text on save (§4.3).
- `Packages/.../AuthorityRepository.swift` — `countAuthorities`, `searchAuthorities` (§4.1–4.2).
- `Apps/SupraAI/SupraAI/GlobalChatsView.swift` (`MarkdownView`/`MarkdownInline`/`MessageRow`) —
  clickable citation pass + open slideover (§2.3).
- `Apps/SupraAI/SupraAI/Documents/MatterDocumentsView.swift` — factor `DocumentPreviewView` so
  it can host in a slideover, not only a modal sheet (§2.4).
- `Apps/SupraAI/SupraAI/Matters/MatterWorkspaceView.swift` — own the shared `previewTarget`
  slideover state for the chat/research/Q&A surfaces.

## 7. Phasing

1. **Footnotes for documents (A, doc-only).** `message_citations` + resolver + clickable `[S#]`
   + slideover reusing `DocumentPreviewView`. Highest value, lowest risk — the jump already
   works. Ship behind the existing Q&A/chat doc answers.
2. **Tiered document retrieval (B).** `RetrievalDepth.fast`, preliminary answer + "search
   deeper." Independent of A; pairs naturally with it.
3. **Authority text persistence + local-first research (C).** Persist opinion text, count gate,
   local search/rank, decision logic.
4. **Authority footnotes (`[A#]`) + reader (A, authorities).** Depends on C's persisted text.
5. **Polish:** slideover sizing/persistence, QuickLook fallback for exotic types, low-confidence
   auto-escalation, backfill migration.

## 8. Resolved product decisions (locked 2026-06-27)

These are decided; the body sections above reflect them.

1. **Preview presentation → right-edge inspector slideover** that overlays the conversation,
   dismissible, one shared panel reused across chat / Q&A / research (not a detached window).
   Owned by a workspace-level state object (§2.4).
2. **Weak-preliminary escalation → auto-escalate only when the fast packet is empty.** If the
   fast pass finds nothing usable, run the deep pass once, silently. Otherwise show the
   preliminary answer with an explicit "Search deeper" affordance (§3.3).
3. **Persist opinion text → user-*saved* authorities only.** Hydrated text is stored when the
   user saves an authority to the matter (not for every transient search result). Local-first
   grounding and the offline `[A#]` reader work for saved cases; unsaved ones one-shot hydrate
   on demand (§4.3).
4. **`[A#]` preview → full in-app opinion reader** — case header + full opinion text with the
   cited passage highlighted + "Open on CourtListener" (§2.5). Uses the persisted text for saved
   authorities; hydrates on demand otherwise.
5. **"Body of research" threshold → ≥ 1 saved authority** triggers the local-first path. Any
   saved authority makes the matter eligible to answer locally before CourtListener (§4.1/§4.4).

## 9. Risks

- **Stale citation index** if labels renumber on regenerate → enforce the §2.1 label-stability
  invariant and test it.
- **Slideover ≠ `.sheet` lifecycle** — moving the preview out of a modal changes dismissal;
  scope to a workspace-owned state object.
- **App-side semantic scoring is O(#embeddings)** — fast tier should FTS-prefilter before the
  semantic pass on large matters (already partly done); keep the fast pool small.
- **Local-first research can under-answer** if saved authorities are thin — always offer the
  CourtListener deeper tier and label the answer as preliminary.
- **Opinion-text storage growth** — gate persistence to saved authorities; consider compression.
