# Roadmap

This roadmap describes where Supra AI has been and where it may go next. It is
forward-looking as of the **3.0.x** line — a plan, not a record of past commitments.
Dated, completed history lives in [CHANGELOG.md](CHANGELOG.md) and the per-milestone
plans in [`Docs/Milestones/`](Docs/Milestones/).

Future items are intentionally **undated**. They are grouped by confidence, not by a
schedule, and may change. Nothing below is a promise.

## Delivered so far

The first release (v1.0.0) shipped three planned milestones, each specified up front
with work orders, acceptance criteria, and a validation suite:

- **Milestone 1 — Local MLX runtime.** Sandboxed XPC model runtime, global chat, model
  library, diagnostics, validation harness.
- **Milestone 2 — Legal utility layer.** Matter workspaces, source-grounded CourtListener
  research, default-deny networking, authority library, structured legal outputs.
- **Milestone 3 — Matter document intelligence.** Local import/OCR/extraction, hybrid
  retrieval, source-grounded Q&A and fact chronologies, in-app source previews, exports,
  trash/purge.

Releases since v1.0.0 (see [CHANGELOG.md](CHANGELOG.md) for details): downloadable model
catalog + per-route recommendations (1.1.0); Developer ID signing, a notarized release
pipeline, and an opt-in update check (1.2.0); conversation context, jurisdiction-bound
research, the DeepSeek-R1 high-quality reasoning default, and the marketing website
(1.3.0); Markdown chat rendering and configurable citation styles (1.3.1); automatic
document classification (1.3.2); the Global Chat history sidebar + example prompts
(1.3.3); a broad answer-quality and retrieval-grounding audit — split QA/research prompts,
jurisdiction binding, RRF hybrid retrieval, neighbor/parent-chunk expansion, auto
critique/verify and structured-output repair, and citation-safety hardening (1.4.0); and a
model-catalog repo-ID fix with a release/CI guard that verifies every catalog model resolves
on Hugging Face (1.4.1).

- **Milestone 4 — ScratchPad (timekeeping → defensible billing), 1.5.0.** A new top-level
  section: one cross-matter **daily note** (`@matter` / `#issue` tags, work product / emails /
  filings dropped in as evidence) that a local model turns, on demand, into a reviewable, editable
  table of billing entries (Client · Matter · Narrative · Time, with UTBMS codes) plus a day
  reconciliation — exportable to **LEDES 1998B**, CSV, or the clipboard, with a pre-export validator.
  Adds firm/timekeeper Settings and per-matter billing rules (override text, code set, uploaded
  client guidelines). Nothing bills automatically; every line cites its evidence and runs on-device.
  Shipped single-call with deterministic per-field validation (UTBMS codes, calendar dates,
  arithmetic); the spec's decomposed pipeline remains the fidelity-gated upgrade path.

## Delivered in 3.0.0

These capabilities shipped in v3.0.0. See the
[`3.0.0` changelog entry](CHANGELOG.md#300---2026-08-16) for the release record:

- **Backup restore** — Settings inspects completed snapshots, blocks incompatible or damaged
  choices, stages a selected snapshot only after a verified safety copy, activates it on the next
  cold launch, automatically rolls back after activation failure, and isolates unrecoverable cases
  in a recovery-only workspace.
- **Guided document Q&A** — **Ask the Documents** offers searchable, previewable passage selection
  alongside automatic retrieval, saves the exact selected source revisions, and blocks stale,
  unavailable, or cross-matter selections.
- **OCR highlight overlay** — image previews render recognized-text regions, emphasize cited lines,
  distinguish low-confidence OCR, and expose accessible recognized text.
- **Richer exports** — PDF, DOCX, and XLSX renderers preserve their supported document structure,
  formatting, links, citations, review notices, and source appendices.
- **Grounded Florida motion to dismiss** — the matter drafting UI deterministically assembles the
  supported failure-to-state-a-claim motion from revision-bound fact excerpts and reviewed,
  proposition-specific authorities selected by the user, with pre-file and publication-recovery
  gates.

## Near-term: complete the ScratchPad follow-ups

ScratchPad (1.5.0) shipped against its [spec](Docs/ScratchPad-SPEC.md) with two pieces
deliberately deferred behind their own gates (recorded in the spec's §4/§5/§14 drift notes):

- **Decomposed billing engine + fidelity measurement.** The engine ships as a single constrained
  generation with deterministic per-field validation. The spec's multi-call decomposition (segment →
  resolve matter → draft narrative → pick code → bill/adjust) and per-segment hour caps are the
  upgrade path **if** the §6.1 golden-fixture gate — run against the real local model — shows
  single-call fidelity falls short. That measurement is the next concrete step.
- **Attachment library import.** ScratchPad attachments are captured as day-level evidence and their
  extracted text feeds the draft; importing them as real `MatterDocumentRecord`s (with classifier
  privilege/confidentiality flags) so they live in the matter's library is the planned follow-up.

## Near-term: expand drafting vertically

- **Drafting catalog breadth.** After the motion vertical proves the repeated contract, add one
  fully tested Florida document kind at a time. A kind is available only when its slots, grounding,
  verification, renderer, persistence, UI, and acceptance fixture all ship together.

## Exploring: candidate next milestones

Directions under consideration. Several were explicit **non-goals** in earlier milestones —
deliberately deferred to keep scope honest, not forgotten. Any of these would get its own
milestone plan before implementation.

- **Design-system harmonization (`SupraDesignSystem` rollout).** ScratchPad introduced several
  reusable UI patterns (confidence pills, code chips/pickers, metric rows, a reconciliation banner, a
  grouped review table, per-row action menus). In 1.5.0 these live inline in the ScratchPad views; a
  downstream initiative would extract them into `SupraDesignSystem` and adopt them across Authorities,
  Outputs, Matters, Research, and Settings for visual consistency, with per-screen review. Kept
  separate from ScratchPad on purpose: it modifies every existing screen, a different risk profile.

- **Citator / negative-treatment signals.** v1.0.0 deliberately makes **no** automatic citator
  claims. A future milestone could integrate genuine treatment data rather than inferring it.
- **Broader RECAP filing retrieval and import.** The current party-name case finder can surface
  CourtListener/RECAP dockets. A later milestone could add deeper filing retrieval, review, and
  matter-document import rather than treating docket discovery as the finished workflow.
- **Broader local model support.** Vision/multimodal models require an `MLXVLM` runtime path
  that isn't linked today (see
  [`Docs/Architecture/Dependencies.md`](Docs/Architecture/Dependencies.md)).
- **Export & integration surfaces (`SupraExports`).** More export targets and structured
  hand-off formats for downstream tools.

## Explicitly out of scope (by design)

These remain non-goals and are unlikely to change without a clear, privacy-preserving reason:

- Cloud document sync, remote embeddings, or remote document processing.
- Telemetry or analytics that leave the device.
- General web browsing or autonomous background research.
- Presenting unverified authority as settled law, or automatic "verified" claims.

## How priorities are decided

Work is organized into milestones with written plans before code (the model used for
M1–M4). If you have a use case that should move something up — or a reason an "exploring"
item should stay out of scope — open an issue. See [CONTRIBUTING.md](CONTRIBUTING.md).
