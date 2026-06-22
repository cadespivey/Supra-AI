# Changelog

All notable changes to Supra AI are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> Development history is tracked in detail in [`Docs/Milestones/`](Docs/Milestones/)
> (per-milestone implementation plans, work orders, and progress logs) and in the
> git history. This file summarizes user-facing changes per release.

## [Unreleased]

### Changed

- **Documents tab updates live during processing.** Each document's status badge
  and classifier category chips now appear as it finishes, without leaving and
  re-entering the tab (the controller reloads on each processing phase and polls
  while a job for the matter is active).

### Added

- **Models: delete a registered model** (swipe / context menu in the Models tab,
  with confirmation). App-downloaded models have their files removed from disk to
  reclaim space; user-registered folders are only unregistered (the folder is left
  in place). Deleting unloads the model if it's loaded and clears any task-role
  assignments so no "Missing model" entry is left behind.

## [1.3.4] - 2026-06-21

### Added

- **Authorities: delete a saved authority** (swipe / context menu / detail button),
  and **import your own research** (PDF/Word/RTF/text) through the matter document
  pipeline so the model can RAG over it via Ask Documents.
- **Opinion text + HTML/PDF in the Authority and Research detail.** A longer
  50–100-word excerpt (windowed on the search snippet), an in-app **opinion HTML
  viewer** (JavaScript off; remote subresources blocked) with HTML download, and a
  **Download PDF** action with an in-app **PDF preview** between Status and Notes.

### Changed

- Research results/citations are sanitized of CourtListener highlight markup
  (`<mark>`) and HTML entities; the preferred citation is reporter-ranked (official
  U.S. Reports / S. Ct. / L. Ed. over regional/specialty reporters).
- The research query-planner prompt asks for diverse, operator-aware queries.
- Authority **use status** displays human-readable labels (e.g. "Retrieved from
  CourtListener") instead of raw `snake_case` tokens.

### Fixed

- "Download HTML…" on the opinion viewer now works (it used an app-modal save panel
  that never appeared from within a sheet; now uses `.fileExporter`).

### Security

- Opinion PDF downloads use CourtListener's public storage CDN
  (`storage.courtlistener.com`) only, token-free, on explicit user action; the
  allow-list and SECURITY.md are updated accordingly.

## [1.3.3] - 2026-06-21

### Added

- **Global Chat history sidebar** — an interior, title-searchable chat list with
  rename, delete (confirmed), and move-to-matter actions for chats that turn out to
  be matter-specific. Chats are auto-titled from their first message.
- **Example prompts** — a blank Global Chat opens to four randomized legal prompt
  starters (drawn from a 36-prompt set) that fill the composer for editing; the app
  opens to a fresh chat on launch.
- A 1.3.2 adversarial review ([`Docs/Review-1.3.2.md`](Docs/Review-1.3.2.md)) with
  module findings, feature blockers, and product-page screenshot recommendations.

### Changed

- Website now serves from the apex custom domain **https://supralegal.ai/**.
- Product-page copy reflects the current app flow (local model role assignment,
  global-chat history); download fallback points at v1.3.3.

### Fixed

- Static-export `basePath` left over from project-site hosting baked `/Supra-AI/`
  into every asset URL, so the site rendered unstyled at the apex root. Removed the
  basePath and added `website/public/CNAME` so the custom domain persists across
  deploys.
- Chat delete/move are blocked while a chat is still generating and surface store
  errors instead of swallowing them; the move audit event is recorded only after the
  store confirms the move.

## [1.3.2] - 2026-06-20

### Added

- **Automatic document classification** — imported documents are classified into
  legal categories (metadata-only suggestions).

## [1.3.1] - 2026-06-20

### Changed

- Chat rendering overhaul — assistant answers render as Markdown.
- Configurable **citation styles** (Bluebook, Indigo Book, MLA, and per-state
  guidance) in Settings.
- Guided model setup in the Models tab.

### Fixed

- Document import fix.

## [1.3.0] - 2026-06-20

### Added

- **Conversation context** — prior turns are replayed so the model can answer
  follow-ups in context.
- **Jurisdiction-bound research** in Global Chat (auto-detected or explicitly
  selected, with optional related-federal courts).
- Marketing **website** and the GitHub Pages deploy workflow.

### Changed

- High-quality legal reasoning now defaults to DeepSeek-R1-Distill-Qwen-32B.
- Deterministic per-route model selection; chat UI polish.

## [1.2.0] - 2026-06-19

### Added

- **In-app software update check** (opt-in; queries GitHub Releases only).
- Developer ID signing + a notarized release pipeline ([`Scripts/release.sh`](Scripts/release.sh));
  the updater prefers the notarized `.dmg` over the `.zip`.

## [1.1.0] - 2026-06-19

### Added

- Downloadable model catalog (the plan's role models) and per-chat-route model
  recommendations based on what's already downloaded.

## [1.0.0] - 2026-06-19

First public release. Supra AI is a local, MLX-powered macOS research and drafting
assistant for legal work — on-device generation, source-grounded legal research, and
matter document intelligence, with citation verification built in.

v1.0.0 is the sum of three planned milestones (M1 → M2 → M3). Each was specified
up front in [`Docs/Milestones/`](Docs/Milestones/) and delivered against explicit
acceptance criteria and a validation suite.

### Added — Milestone 1: Local MLX runtime vertical slice

- Sandboxed XPC runtime service (`SupraRuntimeService`) that loads and runs local
  MLX models, with single-active-generation enforcement, streamed generation events,
  cancellation, and metrics.
- Cross-process model-file access via security-scoped bookmarks minted by the app and
  resolved inside the sandboxed service (see
  [`Docs/Architecture/RuntimeFileAccess.md`](Docs/Architecture/RuntimeFileAccess.md)).
- Local Swift package graph: `SupraCore`, `SupraStore` (GRDB persistence + migrations),
  `SupraRuntimeInterface`, `SupraRuntimeClient`, `SupraSessions`, `SupraDiagnostics`.
- Global chat with persisted send/stream/cancel/fail flow.
- Model library: register local MLX model folders and load the active model.
- Bundled default system prompt wired into every generation.
- Diagnostics + a deterministic validation suite with persisted run history.

### Added — Milestone 2: Legal utility layer

- **Matter workspaces** — organize chat, research, authorities, outputs, and an audit
  trail per matter, with jurisdiction and party-perspective metadata.
- **Source-grounded legal research** via CourtListener REST API v4: research-session
  planning, locally generated and user-approved search queries, review-before-save
  results, and a per-matter authority library with enforced use-status transitions.
- **Default-deny network policy** — only CourtListener is allowlisted; every request
  (approved or blocked) is logged; local rate-limit tracking; CourtListener token stored
  only in the Keychain.
- **Structured legal outputs** — issue spotting, research plan, case-result summary,
  rule synthesis, argument outline, drafting skeleton — with deterministic
  missing-section detection and version-preserving structure repair.
- New packages: `SupraNetworking` (Keychain, network policy, authorized HTTP client,
  rate limiting) and `SupraResearch` (CourtListener client, DTOs, citation handling).
- UI polish pass: sidebar restructure, status badges, empty states, right-side
  inspectors, and a three-level warning hierarchy that blocks unsafe actions.

### Added — Milestone 3: Matter document intelligence

- **Document import** — batch import of nested folders and mixed formats (PDF, DOCX/DOC,
  XLSX, RTF, HTML, XML, Markdown, text, EML with attachments as child documents), with
  content-addressed managed storage, sha256 dedup, continue-on-failure, and a full
  per-file import report.
- **On-device OCR** (Vision) for scanned PDFs and images, with confidence summaries that
  surface in cited answers, and editable extracted text that triggers re-indexing.
- **Hybrid retrieval** — deterministic chunking, SQLite FTS5 full-text search, and local
  semantic search via on-device embeddings (`MLXEmbedders`, default `BAAI/bge-base-en-v1.5`),
  with folder/tag/date filters, duplicate collapse, and scope-readiness gating.
- **Source-grounded Q&A** (auto-source and guided) and **fact chronologies**
  (table/narrative) — every factual claim carries inline citations and a source appendix;
  post-generation citation checks flag unresolved or unsupported claims as needing review.
- **In-app source preview** — citation links open the cited document at the page/cell/chunk
  with best-effort highlighting and a text fallback that never fails silently.
- **Exports** to PDF, Markdown, DOCX, CSV, and XLSX with inline citations and a source
  appendix (raw source documents are never embedded).
- **Trash / restore / auto-purge** with instance-scoped soft delete and safe blob GC.
- New package: `SupraDocuments` (import, extraction, OCR, chunking, retrieval, grounding,
  export). Document processing runs as a single-active, FIFO, resumable job queue with
  pause-on-quit and ask-before-resume.
- M3 validation suite: a deterministic SwiftPM pipeline suite plus an app-run document
  intelligence suite exposed in Diagnostics.

### Added — Pre-publish hardening (v1.0.0)

- Assistant Profile ("soul document") settings.
- Global-chat file/image attachments (OCR-to-text).
- Collapsible reasoning view in chat (assistant answers rendered as Markdown).
- Chat status bar with model/processing state and generation settings.
- App icon, launch splash, and "See Supra" brand banner.
- CourtListener API-token status surfaced in Settings.
- Automatic load of the selected default model into the runtime on startup.

### Security & privacy

- Generation is fully on-device; only CourtListener research makes network calls, through
  an allow-listed, rate-limited, Keychain-authenticated client.
- Privileged query terms are redacted to stable fingerprints in logs and diagnostics by
  default.
- No telemetry. See [SECURITY.md](SECURITY.md) for the full model.

[Unreleased]: https://github.com/cadespivey/Supra-AI/compare/v1.3.4...HEAD
[1.3.4]: https://github.com/cadespivey/Supra-AI/compare/v1.3.3...v1.3.4
[1.3.3]: https://github.com/cadespivey/Supra-AI/compare/v1.3.2...v1.3.3
[1.3.2]: https://github.com/cadespivey/Supra-AI/compare/v1.3.1...v1.3.2
[1.3.1]: https://github.com/cadespivey/Supra-AI/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/cadespivey/Supra-AI/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/cadespivey/Supra-AI/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/cadespivey/Supra-AI/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/cadespivey/Supra-AI/releases/tag/v1.0.0
