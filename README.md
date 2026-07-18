# Supra AI

**A local, MLX-powered macOS research and drafting assistant for legal work.**

Supra AI runs large language models on-device with Apple's [MLX](https://github.com/ml-explore/mlx).
Matter content stays local for generation; user-approved research terms can be sent to named
legal-data providers, and separate clients handle model downloads and signed software updates. It pairs local generation with
**source-grounded** legal research (via [CourtListener](https://www.courtlistener.com/)) and a
document-intelligence pipeline whose support checks block or flag output that lacks required
source support.

The current published Supra AI release is identified by the newest appcast entry.

![Platform](https://img.shields.io/badge/platform-macOS%2015%2B-blue)
![Apple Silicon](https://img.shields.io/badge/silicon-Apple%20Silicon-black)
![Swift](https://img.shields.io/badge/Swift-6.0-orange)
![License](https://img.shields.io/badge/license-MIT-green)

> ⚖️ **Not legal advice.** Supra AI is a drafting and research aid for legal professionals. Every
> citation, quotation, and proposition it produces must be independently verified by a qualified
> attorney before any reliance.

---

## Highlights

- **Local generation and document processing.** Model generation, document extraction and OCR, embeddings, retrieval, drafting, and billing generation execute on the Mac.
  Research and software egress are described separately in [SECURITY.md](SECURITY.md).
- **Source-grounded legal research.** `/research` and `/legal` retrieve authority from CourtListener,
  rank it (jurisdiction, court level, recency, precedential status), and constrain the model to the
  retrieved packet. Fabricated, unresolved, or unsupported citations and propositions are flagged
  or blocked; the checks do not determine subsequent history or whether authority remains good law.
- **Document intelligence.** Import files and folders (PDF, DOCX, XLSX, RTF, EML, images), with OCR,
  chunking, on-device embeddings, hybrid retrieval, source-cited Q&A, fact chronologies, and
  exportable structured outputs — all scoped per matter and organized into nested folders (new
  matters start with a folder set matched to their practice area).
- **Matter workspace.** Organize chats, research sessions, authorities, documents, outputs, and
  per-matter billing rules by matter, with an audit trail. Sort the matter sidebar by client
  (grouped under the client's name), practice area, name, or date — or pin matters to the top and
  drag your own order — and the matter form suggests known clients and practice areas as you type,
  helping users avoid duplicate client identities.
- **In-matter drafting.** A **Draft** button in a matter's chat opens a guided input sheet and
  generates a downloadable `.docx` — a Notice of Appearance (currently Florida-only) or a demand
  letter. Required slots are validated before rendering, and the signature block prints the bar
  admission whose jurisdiction matches the filing's court — configured as a multi-jurisdiction
  bar-admissions list in **Settings**. A per-firm **style profile** (also in Settings) applies your
  letterhead, caption, and signature-block conventions to supported drafts, and can be captured by
  parsing an uploaded exemplar document for review.
  Draft rendering stops before a file is created when required facts, authority support, or verification provenance are missing, unsupported, or unverifiable.
- **Timekeeping → defensible billing (ScratchPad).** Keep one running daily note — `@matter` /
  `#issue` tags, with work product, emails, and filings attached inline to the note they support.
  Tag an entry `#Note` to exclude that entry and its attachments before billing-model input. On demand, a local model turns the day into a reviewable, editable table of
  billing entries (Client · Matter · Narrative · Time, with UTBMS codes) and a day reconciliation,
  exportable to **LEDES 1998B**, CSV, or the clipboard. ScratchPad entries tagged #Note and their attachments are excluded before billing-model input; suggested lines require evidence-reachable matter assignment and remain drafts until user review and export.
- **Global chat management.** Global Chat opens to a fresh set of legal prompt starters and keeps a
  chat history in an interior sidebar, searchable by title and message content — a leading `#`
  matches a tag exactly and surfaces a cross-matter "Tag matches" section spanning chats and
  ScratchPad notes. Rename, delete, or move a chat into a matter when it turns out to be case-specific.
- **Privacy by default.** Privileged query terms are redacted (stored as per-install keyed pseudonyms) in
  logs and diagnostics unless explicitly enabled; the CourtListener token lives in the Keychain,
  bound to the device.

## Slash commands

Type `/` at the start of a chat message to open a command palette that lists every command with a
one-line description and filters as you type; each route runs on the model assigned to that task.

| Command | Mode |
|---|---|
| `/draft` | Attorney-editable drafting (flags where research is needed) |
| `/ask`, `/general` | General assistant |
| `/legal` | Source-grounded legal Q&A |
| `/research` | Full source-grounded legal research |
| `/critique`, `/redteam` | Red-team a draft for defects and unsupported propositions |
| `/verify` | Verify an analysis against the retrieved source packet |

## Architecture

Supra AI is a SwiftUI app plus a sandboxed MLX runtime XPC service, layered over a set of focused
Swift packages:

```
Apps/SupraAI
├─ SupraAI                 SwiftUI app (matters, chat, research, documents, outputs, settings)
└─ SupraRuntimeService     Sandboxed XPC service that loads & runs MLX models (chat + embeddings)

Packages/
├─ SupraCore               Domain types, model routing, generation options, reasoning split
├─ SupraStore              GRDB persistence (migrations, repositories, records)
├─ SupraSessions           App-facing controllers (chat, research, documents, outputs, models)
├─ SupraDraftingCore       Shared drafting contracts, slots, and pre-file gates
├─ SupraDrafting           Drafting generation and authority firewall
├─ SupraExports            Local DOCX and tabular export renderers
├─ SupraResearch           CourtListener client + legal citation verification & ranking
├─ SupraDocuments          Extraction, OCR, chunking, grounding, export
├─ SupraNetworking         Authorized HTTP client, network policy, rate limiting, Keychain
├─ SupraRuntimeInterface   XPC DTOs / protocols shared by app and runtime service
├─ SupraRuntimeClient      Typed client for the runtime XPC service
├─ SupraDiagnostics        Validation & diagnostics
├─ SupraDesignSystem       Shared UI primitives
└─ SupraTestKit            Test fixtures / seed corpus
```

See [`Docs/Architecture/`](Docs/Architecture/) for dependency and runtime-file-access notes.

## Requirements

- **macOS 15+** on **Apple Silicon** (MLX requires an Apple GPU).
- **Xcode 16+** (the project targets Swift 6).
- Local MLX model weights (see [model setup](Docs/local-legal-model-setup.md)).
- *(Optional)* A free [CourtListener API token](https://www.courtlistener.com/help/api/rest/) for
  legal research.

## Getting started

```bash
git clone git@github.com:cadespivey/Supra-AI.git
cd Supra-AI
cp .env.example .env        # optional nonsecret development configuration
open SupraAI.xcworkspace     # build & run the "SupraAI" scheme in Xcode
```

1. **Download models.** On first launch a skippable Welcome screen offers to download a reasoning,
   drafting, and embedding model in the background. You can also follow
   [`Docs/local-legal-model-setup.md`](Docs/local-legal-model-setup.md) to fetch the MLX weights
   manually, then register and assign them in the app's **Models** tab.
2. **Configure** nonsecret development defaults in `.env` if needed — `.env` is gitignored.
3. **Legal research (optional):** add your CourtListener token in **Settings**.
4. **Document intelligence (optional):** complete the one-time embedding-model setup in the
   **Models** tab, then import documents per matter.

## Configuration

Nonsecret DEBUG/development configuration can be read from `.env` / the process environment (defaults shown in
[`.env.example`](.env.example)):

| Variable | Purpose |
|---|---|
| `SUPRA_MODEL_LEGAL_REASONING` / `…_HIGH_QUALITY` | Reasoning model(s) for legal routes |
| `SUPRA_MODEL_DRAFTING`, `SUPRA_MODEL_CRITIQUE` | Drafting / critique models |
| `SUPRA_DEFAULT_CONTEXT_TOKENS`, `SUPRA_MAX_CONTEXT_TOKENS` | Context-window budget |
| `SUPRA_ENABLE_COURTLISTENER`, `SUPRA_COURTLISTENER_BASE_URL` | CourtListener integration and API origin |
| `SUPRA_LEGAL_REQUIRE_CITATIONS`, `…_ALLOW_UNGROUNDED_LAW`, `…_VERIFY_CITATIONS`, `…_JURISDICTION_REQUIRED` | Legal-safety gates |
| `SUPRA_LEGAL_LOG_QUERY_TERMS` | Opt-in to store raw query terms (off by default; per-install keyed pseudonyms otherwise) |

API credentials are entered in Settings and stored in the device-bound macOS
Keychain. Release builds do not read API credentials from `.env` or process
environment variables. DEBUG builds may opt into explicit environment injection
for local and live-test workflows.

## Development

The app and runtime service are built with Xcode; the packages also build with the Swift toolchain.

```bash
# Build & run the app (app + XPC service + all packages)
xcodebuild -workspace SupraAI.xcworkspace -scheme SupraAI -destination 'platform=macOS' build

# Test an individual package
cd Packages/SupraSessions && swift test
```

## Privacy & legal-safety design

- Generation is on-device. Network egress consists of user-initiated named-provider research,
  opinion downloads, model metadata/artifact downloads, and Sparkle update checks/downloads when
  enabled; [SECURITY.md](SECURITY.md) records their credential and payload limits.
- Citation coverage means a citation label resolves to retained source material; proposition verification separately requires each material claim to be supported, and neither check is a citator or good-law opinion.
- Saved output, grounded chat, chronology, and export surfaces render one shared seven-state assurance vocabulary; export is permitted only for proposition-supported or corpus-complete artifacts, and exports embed the state. A grounded matter-chat answer can be saved to Outputs with its exact retained source packet, verification, and assurance state; chat messages themselves never expose export.
- Privileged query terms are represented by per-install HMAC pseudonyms in request logs and diagnostics by default. They are not anonymous; Diagnostics can remove all stored query markers.

## License

[MIT](LICENSE) © Cade Spivey
