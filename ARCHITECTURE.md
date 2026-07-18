# Architecture

Supra AI is a SwiftUI macOS app plus a sandboxed MLX runtime XPC service, layered over a
set of focused local Swift packages. This document describes how those pieces fit together
and why. For dependency pins and runtime file-access details, see
[`Docs/Architecture/`](Docs/Architecture/); for the full per-milestone design and work
orders, see [`Docs/Milestones/`](Docs/Milestones/).

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
│   Matters · Global Chat · Research · Authorities · Documents  │
│   · Outputs · Models · Diagnostics · Settings                 │
│                                                               │
│   SupraSessions  (app-facing controllers / orchestration)     │
└───────┬───────────────────────────────┬──────────────────────┘
        │ XPC (typed RPC)               │ in-process
        ▼                               ▼
┌────────────────────────┐   ┌──────────────────────────────────┐
│ SupraRuntimeService.xpc │   │ SupraStore (GRDB / SQLite)        │
│   MLX chat + embeddings │   │   migrations · records · repos    │
│   (sandboxed)           │   └──────────────────────────────────┘
└────────────────────────┘
        ▲
        │ allow-listed HTTPS (legal-data allow-list)
        ▼
   www.courtlistener.com
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
├─ SupraExports            Local OOXML renderer: court (courtFL) + letterhead shells → .docx (no Office dependency)
├─ SupraResearch           CourtListener client + DTOs + legal citation handling/ranking
├─ SupraDocuments          Extraction, OCR, chunking, retrieval, grounding, export
├─ SupraNetworking         Authorized HTTP client, default-deny network policy, rate limiting, Keychain
├─ SupraRuntimeInterface   XPC DTOs / protocols shared by app and runtime service
├─ SupraRuntimeClient      Typed client for the runtime XPC service
├─ SupraDiagnostics        Validation suites & diagnostic reports
├─ SupraDesignSystem       Shared UI primitives (badges, empty states, inspectors)
└─ SupraTestKit            Test fixtures / seed corpus
```

Dependency rules that are enforced by package boundaries:

- `SupraCore` depends on nothing internal; everything depends on it for IDs and domain enums.
- `SupraStore` owns the database connection. No other package opens the SQLite database.
- `SupraNetworking` owns the Keychain and all `URLSession` policy. `SupraResearch` builds
  CourtListener requests but never touches the Keychain or raw network policy directly.
- `SupraDocuments` owns document-intelligence domain logic but **not** the database, views,
  XPC lifecycle, Keychain, or network. It contains no `URLSession` usage at all — the
  document pipeline performs no network I/O.
- The runtime service depends only on `SupraRuntimeInterface` (the shared contract) and the
  MLX packages — not on the store, networking, or UI.

## The runtime boundary

`SupraRuntimeService` is a Swift-only XPC service that owns MLX model loading and execution.
The app talks to it through `SupraRuntimeClient`, using DTOs/protocols defined in
`SupraRuntimeInterface`. The boundary carries two kinds of work:

- **Chat generation** — load a chat model, stream generation events, cancel, report metrics.
- **Embeddings** (added in Milestone 3) — explicit `LoadEmbeddingModel` / `EmbedText` RPCs
  rather than overloading chat generation. Embedding requests are serialized inside the
  service so one batch can't race another.

Model weights may live outside the app sandbox. The app mints a transferable security-scoped
bookmark while holding its own scope; the sandboxed service resolves it and holds the scope
across the full load. Nil/stale/invalid bookmarks and canonical managed-root escapes fail
closed; raw paths grant no authority. The design and on-device verification steps
are recorded in [`Docs/Architecture/RuntimeFileAccess.md`](Docs/Architecture/RuntimeFileAccess.md).

Managed model downloads are bound to a repository revision and verified manifest, expected size, and SHA-256 digest before registration or load.

## Persistence

`SupraStore` uses [GRDB](https://github.com/groue/GRDB.swift) over SQLite with an ordered
migration list. The shipping database schema registers a contiguous migration sequence from v001 through v062. Each feature area adds migrations and a
repository:

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
- Specialized structure adapters are intentionally format-bounded. DOCX preserves Word
  numbering, tables, notes/comments, tracked changes, and section stories. PDF preserves
  pages, PDFKit line regions, Vision OCR boxes, form values, annotation text, and the
  presence of signature widgets. A signature-widget flag is not signature validation;
  PDF table inference and alternative reading-order inference remain out of scope. OCR
  and user-edited page selections reflow ranged regions against the selected immutable
  revision while retaining form and annotation nodes outside body text.
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
- Document semantic readiness is derived from complete chunk-vector coverage for
  the active embedding model, not the document's generic `ready` string alone.
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

## Two representative data flows

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
3. A question runs hybrid retrieval (FTS + cosine over normalized vectors) scoped to the
   selected folders/tags/documents/dates, gated on the scope being fully indexed.
4. The model answers from the retrieved source set with inline citations; a citation-coverage
   check resolves every label to a real source or marks the answer as needing review.
5. The answer is saved as a versioned structured output with its source set; regeneration
   creates a new version with a fresh source set, preserving the old one for auditability.

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

- Per-milestone plans, work orders, acceptance criteria, and progress logs:
  [`Docs/Milestones/`](Docs/Milestones/)
- Pinned dependencies and the extraction/embedding stack:
  [`Docs/Architecture/Dependencies.md`](Docs/Architecture/Dependencies.md)
- Cross-process model file access:
  [`Docs/Architecture/RuntimeFileAccess.md`](Docs/Architecture/RuntimeFileAccess.md)
- Forward-looking direction: [ROADMAP.md](ROADMAP.md)
