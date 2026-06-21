# Supra AI

**A local, MLX-powered macOS research and drafting assistant for legal work.**

Supra AI runs large language models entirely on-device with Apple's [MLX](https://github.com/ml-explore/mlx),
keeping your matters, documents, and queries on your Mac. It pairs local generation with
**source-grounded** legal research (via [CourtListener](https://www.courtlistener.com/)) and a
document-intelligence pipeline, with citation verification built in so the model never presents
unverified authority as settled law.

![Platform](https://img.shields.io/badge/platform-macOS%2015%2B-blue)
![Apple Silicon](https://img.shields.io/badge/silicon-Apple%20Silicon-black)
![Swift](https://img.shields.io/badge/Swift-6.0-orange)
![License](https://img.shields.io/badge/license-MIT-green)

> ⚖️ **Not legal advice.** Supra AI is a drafting and research aid for legal professionals. Every
> citation, quotation, and proposition it produces must be independently verified by a qualified
> attorney before any reliance.

---

## Highlights

- **Fully local generation.** Models load and run in a sandboxed XPC service via MLX — no prompt,
  document, or query leaves the device for generation.
- **Source-grounded legal research.** `/research` and `/legal` retrieve authority from CourtListener,
  rank it (jurisdiction, court level, recency, precedential status), and constrain the model to the
  retrieved packet. Answers are **citation-verified**: fabricated or unsupported cites are flagged
  and quarantined behind a "do not rely" banner rather than shown as good law.
- **Document intelligence.** Import files and folders (PDF, DOCX, XLSX, RTF, EML, images), with OCR,
  chunking, on-device embeddings, hybrid retrieval, source-cited Q&A, fact chronologies, and
  exportable structured outputs — all scoped per matter.
- **Matter workspace.** Organize chats, research sessions, authorities, documents, and outputs by
  matter, with an audit trail.
- **Global chat management.** Global Chat opens to a fresh set of legal prompt starters, keeps a
  searchable, title-based chat history in an interior sidebar, and lets you rename, delete, or move a
  chat into a matter when it turns out to be case-specific.
- **Privacy by default.** Privileged query terms are redacted (stored as stable fingerprints) in
  logs and diagnostics unless explicitly enabled; the CourtListener token lives in the Keychain,
  bound to the device.

## Slash commands

| Command | Mode |
|---|---|
| `/draft` | Attorney-editable drafting (flags where research is needed) |
| `/ask`, `/general` | General assistant |
| `/legal` | Source-grounded legal Q&A |
| `/research`, `/research-hq` | Full source-grounded legal research (HQ = higher-quality model) |
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
cp .env.example .env        # then fill in model names / CourtListener token
open SupraAI.xcworkspace     # build & run the "SupraAI" scheme in Xcode
```

1. **Download models.** Follow [`Docs/local-legal-model-setup.md`](Docs/local-legal-model-setup.md)
   to fetch the MLX model weights, then register them in the app's **Models** tab.
2. **Configure** `.env` (see below) — `.env` is gitignored and never committed.
3. **Legal research (optional):** add your CourtListener token in **Settings**.
4. **Document intelligence (optional):** complete the one-time embedding-model setup in **Settings**,
   then import documents per matter.

## Configuration

Configuration is read from `.env` / the process environment (defaults shown in
[`.env.example`](.env.example)):

| Variable | Purpose |
|---|---|
| `SUPRA_MODEL_LEGAL_REASONING` / `…_HIGH_QUALITY` | Reasoning model(s) for legal routes |
| `SUPRA_MODEL_DRAFTING`, `SUPRA_MODEL_CRITIQUE` | Drafting / critique models |
| `SUPRA_DEFAULT_CONTEXT_TOKENS`, `SUPRA_MAX_CONTEXT_TOKENS` | Context-window budget |
| `SUPRA_ENABLE_COURTLISTENER`, `SUPRA_COURTLISTENER_*` | CourtListener integration & token |
| `SUPRA_LEGAL_REQUIRE_CITATIONS`, `…_ALLOW_UNGROUNDED_LAW`, `…_VERIFY_CITATIONS`, `…_JURISDICTION_REQUIRED` | Legal-safety gates |
| `SUPRA_LEGAL_LOG_QUERY_TERMS` | Opt-in to store raw query terms (off by default; fingerprints otherwise) |

## Development

The app and runtime service are built with Xcode; the packages also build with the Swift toolchain.

```bash
# Build & run the app (app + XPC service + all packages)
xcodebuild -workspace SupraAI.xcworkspace -scheme SupraAI -destination 'platform=macOS' build

# Test an individual package
cd Packages/SupraSessions && swift test
```

## Privacy & legal-safety design

- Generation is **on-device**; the only network calls are CourtListener research (through an
  allow-listed, rate-limited, Keychain-authenticated client) and user-initiated, token-free
  opinion PDF downloads from CourtListener's storage CDN.
- Legal answers are constrained to retrieved authority; the citation verifier flags unsupported
  citations/quotes and jurisdiction mismatches, and structured outputs that assert authority always
  carry a verification banner.
- Privileged query terms are redacted to fingerprints in request logs and diagnostics by default.

## License

[MIT](LICENSE) © Cade Spivey
