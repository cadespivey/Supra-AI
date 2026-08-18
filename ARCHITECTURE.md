# Architecture

Supra AI is a SwiftUI macOS app plus a sandboxed MLX runtime XPC service, layered over a
set of focused local Swift packages. This document describes how those pieces fit together
and why. For dependency pins and runtime file-access details, see
[`Docs/Architecture/`](Docs/Architecture/).

## Goals that shaped the design

- **Local-first.** Model generation, document processing, OCR, embeddings, retrieval, and
  source selection run on the user's Mac. Outbound traffic is separately inventoried: legal
  research and legal-data lookups, opinion downloads, model metadata/artifact downloads, and
  Sparkle update checks/downloads. See [SECURITY.md](SECURITY.md) for initiators and payload limits.
- **Source-grounded, verifiable output.** Legal answers are constrained to retrieved
  authority; document answers and chronologies are constrained to selected sources. A
  citation verifier flags unsupported or unresolved claims rather than presenting them as
  settled.
- **Process isolation for heavy/native work.** MLX model execution lives in a separate
  sandboxed XPC service so a model crash or a long generation can't take down the UI
  process, and so the security-scoped file access for model weights is contained.
- **Clear package boundaries.** Domain logic, persistence, networking, research,
  documents, and UI primitives are separate packages with one-way dependencies, so each
  is independently testable.

## High-level shape

```
┌──────────────────────────────────────────────────────────────┐
│ SupraAI.app  (SwiftUI, @MainActor)                            │
│   Matters · Global Chat · Research · Public Records           │
│   · Authorities · Documents · Outputs · ScratchPad            │
│   · Models · Diagnostics · Settings                            │
│                                                               │
│   SupraSessions  (app-facing controllers / orchestration)     │
└───────┬───────────────────────────────┬──────────────────────┘
        │ XPC (typed RPC)               │ in-process
        ▼                               ▼
┌────────────────────────┐   ┌──────────────────────────────────┐
│ SupraRuntimeService.xpc │   │ Store · Research · Networking     │
│   MLX chat + embeddings │   │ Documents · Drafting · Exports    │
│   (sandboxed)           │   └──────────────┬───────────────────┘
└────────────────────────┘                  │ allow-listed HTTPS
                                            ▼
                                Named legal-data providers
```

## Package graph

The packages form a layered, one-way dependency graph rooted at `SupraCore`.
The fixed list below contains the 14 packages checked by `Scripts/list-local-packages.sh` and CI.

```
Apps/SupraAI
├─ SupraAI                 SwiftUI app (all matter/chat/research/document/output/settings UI)
└─ SupraRuntimeService     Sandboxed XPC service: loads & runs MLX models (chat + embeddings)

Packages/
├─ SupraCore               Domain types, IDs, model routing, generation options, reasoning split
├─ SupraStore              GRDB persistence: migrations, records, repositories
├─ SupraSessions           App-facing controllers (chat, research, documents, Q&A, outputs, models, jobs, ScratchPad/billing, drafting)
├─ SupraDraftingCore       Shared drafting types (kinds, slots, house style sheet, document model, gates)
├─ SupraDrafting           Drafting pipeline: slot resolution, generation/authority firewall, verification, pre-file gate
├─ SupraExports            Package root: neutral SupraOOXML primitives + drafting-specific court/letterhead → .docx
├─ SupraResearch           Named legal-data clients + authority normalization, ranking, verification
├─ SupraDocuments          Extraction, OCR, chunking, retrieval, grounding, rich output export
├─ SupraNetworking         Authorized HTTP client, default-deny network policy, rate limiting, Keychain
├─ SupraRuntimeInterface   XPC DTOs / protocols shared by app and runtime service
├─ SupraRuntimeClient      Typed client for the runtime XPC service
├─ SupraDiagnostics        Validation suites & diagnostic reports
├─ SupraDesignSystem       Shared UI primitives plus explicit-mode, citation-aware Markdown presentation
└─ SupraTestKit            Test fixtures / seed corpus
```

Dependency rules that are enforced by package boundaries:

- `SupraCore` depends on nothing internal; everything depends on it for IDs and domain enums.
- `SupraStore` owns the database connection. No other package opens the SQLite database.
- The `SupraExports` package root exposes a neutral `SupraOOXML` target for typed
  WordprocessingML models, serialization, package parts, relationships, and renderer-neutral
  styles. `SupraDocuments` consumes that product directly. Court/letterhead shells, house-style
  floors, and drafting policy remain in the separate `SupraExports` target.
- `SupraDesignSystem.SupraMarkdownView` centralizes parsing, streaming refresh, citation-link
  routing, tables, and inline presentation. Its explicit assistant-response and saved-output
  modes preserve the two established visual contracts; chat containers continue to own reading
  width, one-leaf accessibility grouping, and source-list actions.
- Store persistence records stop at the Store/Sessions boundary. High-change app surfaces receive
  stable `SupraSessions` projections for document and folder summaries, billing lines, ScratchPad
  search hits, and diagnostic events; their controllers map once while preserving persisted
  identity, ordering, and update/delete semantics.
- Cross-package transport auditing uses `SupraCore.NetworkRequestAuditWriting`; `SupraStore`
  vends the narrow `networkRequestAudits` implementation, which can only create and finish
  network-request rows. `SupraNetworking` receives only that capability and has no Store package
  edge. Backup, restore, and benchmark tooling retain explicit privileged access to the
  Store-owned database rather than widening that transport capability.
- `SupraNetworking` owns the Keychain and all `URLSession` policy. `SupraResearch` builds
  CourtListener requests but never touches the Keychain or raw network policy directly.
- `SupraDocuments` owns document-intelligence domain logic but **not** the database, views,
  XPC lifecycle, Keychain, or network. It contains no `URLSession` usage at all — the
  document pipeline performs no network I/O.
- The runtime service depends only on `SupraRuntimeInterface` (the shared contract) and the
  MLX packages — not on the store, networking, or UI.

`SupraTestKit.RepositoryArchitecturePolicy` version 8 reads the fourteen local manifests and
pins the exact acyclic 36-edge graph. `SupraTestKit` is isolated from the app product; its seven
higher-layer package dependencies are reviewed test-harness exceptions beyond `SupraCore`, and
an eighth exception fails closed. The same policy rejects inventory drift, undeclared or missing
edges, cycles, and direct Store/network capability edges from packages that must remain isolated.

`SupraCore.CanonicalJSON` owns the explicit version-one compact and pretty-printed JSON byte
contracts, and `SHA256Digest` owns lowercase SHA-256 formatting. Only the three TestKit report
encoders proven byte-identical use that shared contract today; different date strategies,
streaming file hashes, presentation JSON, and unordered values remain with their domain owners.

## The runtime boundary

`SupraRuntimeService` is a Swift-only XPC service that owns MLX model loading and execution.
The app talks to it through `SupraRuntimeClient`, using DTOs/protocols defined in
`SupraRuntimeInterface`. The boundary carries three kinds of work:

- **Chat generation** — load a chat model, stream generation events, cancel, report metrics.
- **Embeddings** (added in Milestone 3) — explicit `LoadEmbeddingModel` / `EmbedText` RPCs
  rather than overloading chat generation. Embedding requests are serialized inside the
  service so one batch can't race another.
- **Token counting** — the additive batched `CountTokens` RPC reuses the tokenizer of the
  loaded chat model and returns one ordered count per serialized prompt packet. The client
  rejects model-ID, cardinality, and negative-count mismatches instead of treating a malformed
  reply as usable budget data.

`SupraCore.TokenBudgeter` reserves the configured output and chat-template margin, then
selects the largest cumulative packet prefix whose exact token count fits. If the service is
unavailable, it uses a stricter two-UTF-8-bytes-per-token estimate. Document Q&A permits one
source-boundary retry after an authoritative runtime overflow; chronology retains its
split-and-retry path; grounded chat persists a refusal instead of partial model output or
citations when the complete packet cannot fit. The deterministic benchmark companion emits
B-CTX utilization, estimate-error, omission, recovery, and silent-overflow measurements;
protected model runs replace its frozen count matrix with the loaded tokenizer's counts.

Model weights may live outside the app sandbox. The app mints a transferable security-scoped
bookmark while holding its own scope; the sandboxed service resolves it and holds the scope
across the full load. Nil/stale/invalid bookmarks and canonical managed-root escapes fail
closed; raw paths grant no authority. The design and on-device verification steps
are recorded in [`Docs/Architecture/RuntimeFileAccess.md`](Docs/Architecture/RuntimeFileAccess.md).

Managed model downloads are bound to a repository revision and verified manifest, expected size, and SHA-256 digest before registration or load.

Supra's local-AI policy conservatively maps detected unified memory to 16, 32, 64, 96, or 128 GB tiers; the 96 GB and 128 GB tiers retain the curated Qwen3 32B 4-bit work-model ceiling for headroom, and fit remains an estimated model footprint rather than a performance or successful-load guarantee.

## Persistence

`SupraStore` uses [GRDB](https://github.com/groue/GRDB.swift) over SQLite with an ordered
migration list. The shipping database schema registers a contiguous migration sequence from v001 through v078; v073 remains immutable, dormant compatibility history for databases that may already have applied it and does not represent an available product capability.
`SupraMigrator.makeMigrator()` remains the single public registry, while immutable migration closures live in versioned or cohesive source files and are invoked in exact version order. A frozen registration and schema snapshot pins all 78 names plus the resulting 82 tables, 101 indexes, 89 triggers, integrity check, and foreign-key check; the source split adds no migration and changes no schema behavior.
Each feature area adds migrations and a repository:

- Milestone 1 established chats, messages, models, and validation runs.
- Milestone 2 added matters, research sessions/queries/results, authorities, structured
  outputs + versions, network-request logs, and audit events.
- Milestone 3 added document intelligence settings, content blobs, folders, document
  instances, tags, pages/parts, chunks, an FTS5 virtual table, embedding models, chunk
  embeddings, import batches, processing jobs, source sets/output sources, and exports.
- Document extraction persists immutable part revisions plus revision-bound typed
  structure nodes and matter-scoped edges. Formats without specialized adapters emit a
  deterministic document/part wrapper tree; pre-v062 documents acquire wrappers lazily
  on their next extraction or indexing pass rather than through fabricated backfill.
- Atomic proposition-supported document Q&A publications validate every retained row for live matter-scoped source identity and, for revision-bound sources, exact chunk and revision provenance, the stored anchor excerpt, and a locator contained within the cited immutable revision; revision-bound verifier evidence must be grounded within that locator, all verifier evidence must resolve uniquely to the retained packet, and rejection rolls back the output, version, source set, and source rows together.
- Permanent document deletion rejects attachment graphs that cross a matter boundary, then removes the selected same-matter attachment subtree and its revision and index graph in one Store transaction. It clears live source identities while retaining saved output content, citation display excerpts and locators, and corpus-analysis proof records such as evidence quotes and document names; document classifications and relations are removed, connected or no-longer-verifiable same-matter output versions and corpus-analysis runs become stale, provably unrelated work remains unchanged, affected active outputs move to needs review, and the base deletion audit is written in that transaction. CorpusAnalysisRepository resume, finalize, and cancel lifecycle operations cannot restore assurance to a stale corpus run; a new run is required. Permanent matter deletion applies the same matter-boundary check and writes an FK-safe base audit in its cascade transaction; that database cascade removes in-app export records. Managed blob-file cleanup is post-commit and best-effort; prior audit history and previously written export files are not deleted by these Store operations.
- Automatic document retention purges only individually trashed documents whose owning matter remains live; a soft-deleted matter and its documents remain restorable until the user explicitly permanently deletes the matter.
- Chunker v2 is the owner-approved default and aligns retrieval chunks to revision-bound
  structure nodes while preserving table headers and linked legal units as context. Existing
  stores receive one all-matter rebuild; the v2 setting and completion marker are persisted
  only after terminal readiness with zero pending documents. Diagnostics retains an explicit
  v1 rebuild/rollback control, and its completion marker prevents bootstrap from overriding a
  later operator rollback. Persisted chunks record their node, structural unit kind, and
  chunker version; retrieval prefers same-revision parent context and explicitly discloses
  hidden-derived spreadsheet evidence. Legacy v1 text, locators, packed source JSON, immutable
  revisions, and denormalized citation display data remain available for rollback and history.
- `SupraSessions` and `SupraStore` retain a tested exhaustive-corpus substrate for persisted-data
  compatibility and synthetic benchmarking. The shipping app does not compose a
  `CorpusAnalysisQueueRunner`; its `DocumentProcessingQueue` has no corpus runner, so a newly
  encountered `corpus_analysis` job fails unavailable before model work. The following describes
  the retained package contract, not an available product workflow.
  Exhaustive corpus work uses a separate v064 coverage ledger rather than ranked retrieval.
  Each run freezes the exact selected revision IDs plus failed/review-required/import-source
  exclusions, plans deterministic part-range partitions with the shared chronology batching
  seam, and checkpoints a terminal disposition and evidence-bound findings per partition.
  SQLite and repository guards reject `corpus_complete` unless every partition succeeded and
  exclusions are disclosed. Mid-run edits do not change mapper inputs and leave the persisted
  result marked stale. Each mapper attempt is durably opened and closed in an append-only
  history. Explicitly transient failures receive at most two retries by default; permanent or
  exhausted failures remain terminal and force `corpus_incomplete`. Cancellation atomically
  retains successful checkpoints, marks every unfinished partition cancelled, and saves a
  balanced ledger. Relaunch reuses the frozen snapshot, treats completed partitions as cache
  hits, closes an orphaned running attempt as interrupted, and schedules only cancelled,
  pending, or still-retryable work. The retained FIFO substrate recognizes `corpus_analysis`
  jobs, and its strict-schema exhaustive list mapper reconciles
  duplicate keys, conflicting values, contrary evidence, named omissions, and deterministic
  precision/recall metrics without exposing raw invalid model responses. Validated evidence is
  written as a version-scoped source set, and the run/source-set/version link commits atomically.
  The v2 exhaustive-list preparation boundary hashes normalized execution fields (task and prompt versions, matter, normalized query, scope, clamped character budget and retry count), frozen membership, exact ordered slices, and a declared pinned-model identity (repository, revision, binding contract, and artifact fingerprint) into one request digest; the presentation title and run_key queue identity are intentionally excluded.
  The v2 exhaustive-list mapper boundary accepts primary or contrary evidence only when the host resolves it to exactly one presented frozen slice, normalizes it to a nonempty quote and slice-relative Character range, and derives the retained excerpt and absolute output locator from the frozen revision; a value absent from every retained primary excerpt fails proposition verification.
  Store v072 requires a complete exact-slice ledger relative to the frozen snapshot before an exhaustive-list run may retain either export-eligible assurance state, preserves legacy content without fabricating lineage while marking prior export-eligible assurance stale, and leaves chronology on its v1 revision ledger without imposing the exhaustive-list exact-slice contract; universal corpus-complete prerequisites are enforced on insert and update.
  Store v072 admits an export-eligible v2 exact-slice proof only when every succeeded checkpoint has coherent terminal attempt history, valid ordered row timestamps, and a typed findings array whose findings each cite at least one primary or contrary reference anchored to that checkpoint's own exact partition slice; optional quote and slice-relative range fields fail closed when malformed or outside that slice. Exact publication also requires the attached source set's independent frozen-corpus hash to equal the Store recomputation over the run's canonical membership and slices. While its matter exists, Store prevents drift of the exact source-set attachment/mode/hash, linked version identity/content/verification, parent matter/type, single-run ownership, and proof-linked export-eligible active selection.
  Failed or schema-invalid partitions force an attached `needs_review` output with
  `corpus_incomplete`; negative conclusions are blocked unless coverage is complete and the run
  found no positive item. Chronology also adopts this ledger without changing its established
  parser, merge, verifier, markdown, or UI-message contracts: the frozen denominator records one
  partition per included document, every successful extraction pass carries an audit, capped
  sources and omitted document names persist in reconciliation, and cancellation balances the
  run while retaining discard-all semantics for output/version/source rows. Full output UX lands
  in later work orders.
- Document-version intelligence begins with the v065 `document_relations` table. Exact shared-blob
  pairs and complete normalized-text digest pairs are backfilled and reproposed deterministically
  within one matter only. A second deterministic pass combines normalized three-token shingles with
  structure-node diffs to propose near-duplicate, draft, redline, amendment, and supersession edges;
  missing dates stay explicitly ambiguous. Symmetric kinds use a canonical sorted pair; directional
  kinds preserve their arrow. Every automatic match remains `proposed` regardless of confidence.
  The audited Documents review queue supports one-way confirm/reject decisions and distinct
  user-authored overrides; each decision atomically records provenance and marks dependent outputs
  `needs_review`. Confirmed relations alone add draft/operative/superseded retrieval metadata, while
  proposed in-scope relations name themselves as blockers for clean comparison and negative-result
  assurance. The weights, thresholds, review boundary, and B-VER key set are frozen in
  [the document relation methodology](Docs/Document-Relation-Methodology.md).
- Source packets created by document Q&A, grounded matter chat, chronology, and exhaustive
  analysis carry v066 lineage on `document_source_sets`: stable embedding repository/revision,
  selected chunker version, the exact retrieval caps/floors/RRF or task budget, and a SHA-256
  snapshot over the scoped document IDs, cited revision IDs, and index states. A canonical
  candidate report records every considered source as packed, truncated, omitted, or deferred,
  with reasons and token counts; the prompt retains the visible truncation marker used by the
  fail-closed verifier. Legacy rows remain explicitly NULL/unknown. Successful grounded chat
  turns keep the same pending packet through a nullable unique `message_id` link, validated
  against the owning matter; packed revision-bound source rows retain the verifier result JSON,
  while unpromoted turns create no structured output.
- Saved document Q&A, chronology, and exhaustive-list versions record stable model repository/revision, prompt-builder version, options, source lineage, and assurance; exact dependency changes mark only affected versions stale without rewriting their content. The
  v067 migration reuses `generation_sessions` for document artifacts without synthetic chat
  owners, leaves unrelated legacy lineage unknown, and copies assurance only from a uniquely
  linked corpus-analysis run. Source revision/edit, reprocess, reviewed relation, embedding
  model/revision, chunker, and prompt-builder changes use matter-scoped joins to set
  `assurance_state = stale`, retain the immutable version content, and move only an affected
  active output to `needs_review`. A clean assurance can be restored only by appending a new
  verified version. The deterministic B-LIN dependency matrix requires both stale-detection
  precision and recall to remain 1.0.
- Document classification uses deterministic head-and-tail sampling for every current part
  within a fixed character budget instead of taking only the document prefix. Each completed
  attempt appends a v068 `document_classifications` row that binds the exact input revision IDs
  and checksum to stable model repository/revision, prompt and sampler versions, calibration,
  categories, warnings, and validated evidence spans. Completed document classification attempts append exact revision, model, prompt, sampler, calibration, abstention, and validated evidence lineage; uncertain or ungrounded results expose no primary category and classification never writes user tags. Low-confidence or invalid-evidence model
  output is retained as an explicit abstention with no presented primary category. The legacy
  mutable JSON remains a latest-value compatibility projection, while historical JSON is never
  assigned fabricated lineage; user-authored document tags are a separate domain and are not
  written by the classifier. Deterministic B-CLS metrics report macro F1, per-class recall,
  abstention precision/recall, and evidence validity.
- The v069 schema stores a complete independent verification-dimension ledger on every newly
  verified structured-output version. Proposition support, citation resolution, critical-value
  fidelity, and low-confidence handling factor the existing deterministic verifier without
  changing its aggregate outcome; the other named dimensions remain explicitly `not_run` until
  their checks execute. Historical, absent, partial, or malformed ledgers fail closed to all
  `not_run`, never fabricate success, and never rewrite legacy content or status. Task gates name
  their required dimensions, so an unrelated `not_run` result is visible without being silently
  treated as satisfied.
  Every newly verified structured-output version persists a complete independent verification-dimension ledger; historical, absent, partial, or malformed ledgers fail closed to not run without changing legacy content or aggregate status.
  Exhaustive-list runs bind their coverage and reconciliation ledgers into independent corpus
  coverage and list-completeness results, and retain cross-partition contrary passages as
  dimension evidence alongside both positions. Negative conclusions use an explicit method gate:
  ranked retrieval, any positive finding, incomplete coverage, or an excluded/review-required
  source blocks persistence of clean absence wording. Corpus-backed verification independently records contrary evidence, list completeness, corpus coverage, and negative validity; ranked retrieval and low-confidence or incomplete corpus members cannot authorize a clean negative conclusion.
  The shared assurance presenter pins one distinct string for each of the seven persisted states
  and is consumed by output rows/details, grounded-chat banners, chronology results, and export
  headers. Only `proposition_supported` and `corpus_complete` enable export. Citation preview
  loads the recorded immutable revision with its origin/time provenance, and PDF text matching is
  restricted to the locator page rather than accepting the first document-wide occurrence.
  Document export selects the requested output's explicit active version. Exhaustive-list export must pass both preflight and completion-record checks that the version remains active, all-supported, export-eligible, and matched by exactly one persisted v2 exact-slice run for the same matter, version, and assurance. A failed completion transaction records neither the export nor its success audit; the service restores the prior file or removes the new file, or reports a partial failure if that compensation also fails.
  Scope readiness keeps failed and review-required documents in its disclosed denominator and
  names each blocker. A per-message `Save to Outputs` action atomically creates the output/version
  and attaches the existing grounded-chat source set while retaining its message link, revisions,
  verification results, lineage, and assurance. An injected failure after the version insert rolls
  back the entire promotion; unpromoted messages have no export path. Saved output, grounded chat,
  chronology, and export surfaces render one shared seven-state assurance vocabulary; export is
  permitted only for proposition-supported or corpus-complete artifacts, and exports embed the
  state. A grounded matter-chat answer can be saved to Outputs with its exact retained source
  packet, verification, and assurance state; chat messages themselves never expose export.
- Specialized structure adapters are intentionally format-bounded. DOCX preserves Word
  numbering, tables, notes/comments, tracked changes, and section stories. PDF preserves
  pages, PDFKit line regions, Vision OCR boxes, form values, annotation text, and the
  presence of signature widgets. A signature-widget flag is not signature validation;
  PDF table inference and alternative reading-order inference remain out of scope. OCR
  and user-edited page selections reflow ranged regions against the selected immutable
  revision while retaining form and annotation nodes outside body text. XLSX preserves
  typed cell values, formulas and cached results, number-format IDs, merges, explicit
  tables, and deterministic header associations. Hidden sheets, rows, and columns remain
  in the complete evidence projection with explicit hidden-source payloads; consumers
  that request a visible-only projection must exclude those marked cells. Macros are
  presence-flagged only, and charts or visual style fidelity are not inferred.
  EML preserves the parsed RFC header map (including Message-ID, In-Reply-To,
  References, and file-present BCC), separates quoted replies, and represents CID
  inline parts as attachment references while retaining the legacy flat body and
  child-attachment import. A matter-scoped, idempotent post-import linker emits
  reply/thread edges only for unambiguous Message-IDs in that matter. Outlook MSG
  and conversation UI remain unsupported.
  Image previews consume the retained Vision OCR boxes to draw selectable, accessible regions,
  emphasize the cited line, and distinguish low-confidence recognition. Malformed or unsupported
  overlay payloads produce a visible unavailable state rather than guessed geometry.
  A format-agnostic deterministic legal pass recognizes numbered discovery
  requests/responses/objections and paired deposition Q/A turns without changing
  flat text. Intra-document pairs receive `responds_to` edges immediately; a
  matter-scoped post-import linker connects uniquely numbered request/response
  nodes across documents. It does not use a model or infer transcript page-line
  fidelity beyond the revision ranges and line labels present in source text.
- Milestone 4 (ScratchPad) added scratch-pad days/entries/attachments, billing drafts +
  line items, and per-matter billing profiles, plus LEDES `client_id` / `client_matter_id`
  columns on `matters`.
- Operational hardening added a per-source import ledger with transient top-level
  bookmarks and durable target-folder intent. Completed source rows release their
  bookmark in the same transaction as the terminal-state update. Relaunch
  reconciliation atomically marks unfinished rows as resumable `interrupted`,
  finalizes their orphaned batch, and reconstructs its failure summary from the
  persisted ledger. Resume and discard consume that ledger directly: resume
  reopens top-level bookmarks and the durable target-folder identity, while
  discard terminalizes only unfinished rows.
- Draft publication first persists a Store-owned prepared intent before public installation. Finalization binds the exact installed bytes and allow-listed output format—and, for the supported motion, a fresh source snapshot—to the audit and terminal intent state in one transaction; relaunch finalizes only authenticated exact files and preserves uncertain public files for explicit recovery.
- Document semantic readiness is derived from complete chunk-vector coverage for
  the active embedding model, not the document's generic `ready` string alone.
  SupraStore owns that base readiness receipt. SupraSessions'
  `CanonicalDocumentReadinessLedger` projects the same exact receipt into
  Documents, Ask, Chronology, and Drafting; consumer-specific task exclusions
  are additive and cannot rewrite base readiness. DEBUG demo qualification uses
  the same complete revision, FTS, embedding-model, and vector graph as the
  shipping projection, with an exact three-document denominator. An active
  model switch without vectors for the new model therefore fails closed in
  every consumer rather than preserving a stale green state.
  Model switches enqueue semantic-only work that reuses current chunks and keeps
  prior-model vectors; saved text edits enqueue a full re-chunk/reindex pass.
  Extraction methods carry a toolchain-version suffix so launch-time capability
  drift can mark only older lineage stale and record a manual-reprocess reason.
- Extraction text has immutable per-part revision candidates and append-only
  selection decisions. The current part text remains a compatible materialized
  projection, while chunks bind to the exact selected revision that they index;
  v060 backfills existing parts without changing their text.

Repositories are grouped by cohesion (e.g. `DocumentLibraryRepository`,
`DocumentIndexRepository`, `DocumentJobRepository`) rather than one-per-table, matching the
existing convention where a repository owns several related tables.

## Representative data flows

### Legal research (`/research`)

1. The user creates a research session on a matter (issue text, jurisdiction, optional
   court/date filters).
2. The **local** model proposes search queries; the user edits and approves them. No network
   call happens during planning.
3. On run, each approved query goes through `SupraNetworking`'s authorized client:
   network-policy check → rate-limit check → Keychain token injection → request logged →
   CourtListener search → response logged. Failures are isolated per query.
4. Results are stored as reviewable rows. The user saves, skips, or flags each; saved items
   become authorities with an explicit, audited use-status lifecycle.
5. Answers and structured outputs are constrained to retrieved authority; the citation
   verifier flags unsupported cites/quotes and jurisdiction mismatches behind a "do not
   rely" banner.

### Document Q&A

1. Import copies files into content-addressed managed storage (originals untouched), extracts
   text (Apple frameworks + in-house parsers + ZIPFoundation for OOXML), OCRs scanned
   PDFs/images on-device, and chunks deterministically with stable locators — all as a
   resumable background job.
2. Chunks are indexed into FTS5 and embedded locally; index status advances per document.
3. A question either runs hybrid retrieval (FTS + cosine over normalized vectors) within the
   selected folders/tags/documents/dates or uses exact readable passages chosen in **Ask the
   Documents**. Guided selection rejects unavailable, stale, or cross-matter chunks. Automatic
   retrieval is gated on the scope being fully indexed. Each cumulative source packet is counted
   with the loaded model tokenizer (or a fail-closed fallback), and only the largest safe prefix
   crosses the generation boundary.
4. The model answers from the retrieved source set with inline citations; a citation-coverage
   check resolves every label to a real source or marks the answer as needing review.
5. The answer is saved as a versioned structured output with its source set; regeneration
   creates a new version with a fresh source set, preserving the old one for auditability.
   Guided regeneration instead resolves and reuses the exact saved source revisions or fails
   closed without changing that source set.

### Supported motion drafting

1. The user selects the Florida state trial-court motion to dismiss for failure to state a claim,
   enters the typed filing details, and chooses revision-bound matter excerpts.
2. Reviewed authorities contribute only proposition-specific excerpts that counsel has recorded;
   the drafting controller snapshots the selected facts and authorities before assembly.
3. Deterministic assembly creates the supported motion structure without asking a model to write
   the motion. Verification and the pre-file gate check required sections, citation shape, exact
   selected-source reproduction, provenance, and staleness; they do not decide factual
   applicability, legal sufficiency, or filing readiness.
4. Cancellation is checked after verification and immediately before rendering. Publication first
   records a prepared Store-owned intent, then binds the exact installed DOCX and fresh source
   snapshot to the audit record in one transaction.
5. Relaunch reconciliation finalizes only an authenticated exact file. An uncertain public file is
   preserved and surfaced as recovery-required for review or regeneration.

### Backup restore

1. Settings reads and verifies completed snapshots from the user-selected backup folder; incomplete,
   damaged, missing-document, or unsupported-schema snapshots remain disabled.
2. After confirmation, the app blocks normal work, closes the exact live database writer, creates
   and verifies a safety database plus managed documents, stages private copies, and publishes a
   cold-start marker only after every staged component passes.
3. On the next launch, restore activation runs before the normal store is constructed. It installs,
   opens, migrates, and validates the selected database through the ordinary database boundary.
4. Activation failure triggers installation and validation of the safety copy. If that rollback also
   fails, a recovery-only workspace preserves and reveals the entire safety folder instead of
   opening the normal store.
5. The source backup is never modified. The synthetic process-boundary drill in
   [Backup and Restore](Docs/Backup-and-Restore.md) remains a release qualification requirement.

### Document benchmark and performance gates

`SupraBench` has two deliberately separate protocols. The deterministic protocol runs the
frozen synthetic corpus and safety metrics byte-for-byte apart from timestamp and checkout
SHA. The fixed performance protocol creates fresh 10-, 50-, and 200-document matters, imports
and indexes them through the real services, exercises brute-force fast/deep cosine retrieval,
persists corpus-ledger batches and revision-bound structure nodes, and measures p50/p95,
throughput, peak RSS, and one-document incremental work. Its report records the hardware,
operating system, Xcode, Swift, thermal state, and protocol version needed to compare like with
like.

The zero-unaffected-document incremental rule is an immediate deterministic gate. Statistical
latency, throughput, memory, and incremental-time comparisons stay fail-closed for release use
until the repo owner approves the recorded baseline and completes every proposed threshold.
An approved comparison rejects an environment mismatch rather than treating unlike machines as
a regression. The harness lives in `SupraTestKit`; it adds no production package dependency or
runtime telemetry.

## Security & privacy posture

- **On-device generation**; default-deny network with a fixed legal-data allow-list
  (CourtListener API token-authenticated; its `storage.courtlistener.com` CDN and a few
  official government legal-data sources used token-free). See [SECURITY.md](SECURITY.md).
- **Release credentials in Keychain**; explicit DEBUG/test composition may inject environment
  credentials. Credential values are excluded from SQLite and application logs.
- **Privilege-aware logging** — query terms use per-install keyed pseudonyms unless the user
  opts in to raw local query logging.
- **No application telemetry client.** See [SECURITY.md](SECURITY.md) for the complete model and reporting
  process.

## Where to go next

- Pinned dependencies and the extraction/embedding stack:
  [`Docs/Architecture/Dependencies.md`](Docs/Architecture/Dependencies.md)
- Cross-process model file access:
  [`Docs/Architecture/RuntimeFileAccess.md`](Docs/Architecture/RuntimeFileAccess.md)
- Forward-looking direction: [ROADMAP.md](ROADMAP.md)
