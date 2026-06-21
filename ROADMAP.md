# Roadmap

This roadmap describes where Supra AI has been and where it may go next. It is
forward-looking as of the **1.3.x** line — a plan, not a record of past commitments.
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
document classification (1.3.2); and the Global Chat history sidebar + example prompts
(1.3.3).

## Near-term: polish the v1.0.0 surfaces

These are concrete follow-ups already identified in the Milestone 3 handoff notes
([`Docs/Milestones/Milestone3.md`](Docs/Milestones/Milestone3.md), "known limitations").
They sharpen what already ships:

- **Documents tab UX** — nested folder tree presentation and drag-between-folders (move/copy
  already exists at the controller/repository level; the v1 sidebar is a flat list).
- **Guided Q&A in the UI** — manual source selection is supported in `DocumentQAController`
  (`guidedChunkIDs`); surface it in the "Ask" sheet alongside auto-source.
- **OCR highlight overlay** — image OCR bounding boxes are already captured
  (`boundingBoxesJSON`); draw them over the image preview (PDF page + text-range highlights
  are already implemented).
- **Richer exports** — current PDF is plain CoreText pagination and DOCX/XLSX are minimal
  OOXML; improve formatting fidelity.
- **XLSX sheet-by-relationship-id** — map worksheets by `xl/_rels` relationship id rather than
  position (affects locators only for reordered/deleted multi-sheet workbooks).
- **Performance benchmarking** — exercise the documented §13 targets at the ~200-document
  scale, and benchmark semantic/OCR quality against the chosen embedding model and Vision.
- **App-run validation with live models** — the deterministic SwiftPM suite is green; run the
  model-dependent Diagnostics scenarios against loaded chat + embedding models on-device.

## Exploring: candidate next milestones

Directions under consideration. Several were explicit **non-goals** in earlier milestones —
deliberately deferred to keep scope honest, not forgotten. Any of these would get its own
milestone plan before implementation.

- **Drafting assistance (`SupraDrafting`).** A `/draft` chat route and drafting/critique
  model roles already ship; the future work is a dedicated package for attorney-editable
  drafting grounded in a matter's authorities and documents, with research-needed flags.
  (Reserved package namespace already exists under `FutureModules/`.)
- **Citator / negative-treatment signals.** v1.0.0 deliberately makes **no** automatic citator
  claims. A future milestone could integrate genuine treatment data rather than inferring it.
- **Dockets / RECAP.** Federal docket and filing retrieval via CourtListener's RECAP data,
  beyond the v1.0.0 opinion search.
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
M1–M3). If you have a use case that should move something up — or a reason an "exploring"
item should stay out of scope — open an issue. See [CONTRIBUTING.md](CONTRIBUTING.md).
