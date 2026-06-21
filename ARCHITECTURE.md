# Architecture

Supra AI is a SwiftUI macOS app plus a sandboxed MLX runtime XPC service, layered over a
set of focused local Swift packages. This document describes how those pieces fit together
and why. For dependency pins and runtime file-access details, see
[`Docs/Architecture/`](Docs/Architecture/); for the full per-milestone design and work
orders, see [`Docs/Milestones/`](Docs/Milestones/).

## Goals that shaped the design

- **Local-first.** Model generation, document processing, OCR, embeddings, search, and
  source selection all run on the user's Mac. The only network egress is explicit,
  user-initiated: CourtListener legal research and model/embedding downloads.
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
        │ allow-listed HTTPS (CourtListener only)
        ▼
   www.courtlistener.com
```

## Package graph

The packages form a layered, one-way dependency graph rooted at `SupraCore`.

```
Apps/SupraAI
├─ SupraAI                 SwiftUI app (all matter/chat/research/document/output/settings UI)
└─ SupraRuntimeService     Sandboxed XPC service: loads & runs MLX models (chat + embeddings)

Packages/
├─ SupraCore               Domain types, IDs, model routing, generation options, reasoning split
├─ SupraStore              GRDB persistence: migrations, records, repositories
├─ SupraSessions           App-facing controllers (chat, research, documents, Q&A, outputs, models, jobs)
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

Model weights live outside the app sandbox. The app mints a transferable security-scoped
bookmark while holding its own scope; the sandboxed service resolves it and holds the scope
across the full load (with a raw-path fallback). The design and on-device verification steps
are recorded in [`Docs/Architecture/RuntimeFileAccess.md`](Docs/Architecture/RuntimeFileAccess.md).

## Persistence

`SupraStore` uses [GRDB](https://github.com/groue/GRDB.swift) over SQLite with an ordered
migration list (`v001` … `v039` as of 1.3.3). Each feature area adds migrations and a
repository:

- Milestone 1 established chats, messages, models, and validation runs.
- Milestone 2 added matters, research sessions/queries/results, authorities, structured
  outputs + versions, network-request logs, and audit events.
- Milestone 3 added document intelligence settings, content blobs, folders, document
  instances, tags, pages/parts, chunks, an FTS5 virtual table, embedding models, chunk
  embeddings, import batches, processing jobs, source sets/output sources, and exports.

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

- **On-device generation**; default-deny network with only CourtListener allowlisted.
- **Secrets in the Keychain** (CourtListener token), never in SQLite, logs, diagnostics, or
  exports.
- **Privilege-aware logging** — query terms are stored as stable fingerprints unless the user
  opts in.
- **No telemetry.** See [SECURITY.md](SECURITY.md) for the complete model and reporting
  process.

## Where to go next

- Per-milestone plans, work orders, acceptance criteria, and progress logs:
  [`Docs/Milestones/`](Docs/Milestones/)
- Pinned dependencies and the extraction/embedding stack:
  [`Docs/Architecture/Dependencies.md`](Docs/Architecture/Dependencies.md)
- Cross-process model file access:
  [`Docs/Architecture/RuntimeFileAccess.md`](Docs/Architecture/RuntimeFileAccess.md)
- Forward-looking direction: [ROADMAP.md](ROADMAP.md)
