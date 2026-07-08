# Contributing to Supra AI

Thanks for your interest in Supra AI. This document covers how the project is built,
tested, and organized so you can get productive quickly. It reflects how the project is
actually developed — milestone plans up front, focused PRs, and a validation suite per
milestone.

> ⚖️ Supra AI is a tool for legal professionals but is **not legal advice** and produces
> output that must be independently verified. Contributions that weaken the citation
> verification, source-grounding, or privacy guarantees will not be accepted. See the
> guardrails in each milestone plan and in [SECURITY.md](SECURITY.md).

## Prerequisites

- **macOS 15+** on **Apple Silicon** (MLX requires an Apple GPU).
- **Xcode 16+** (the project targets Swift 6).
- For MLX Metal shader compilation you may need the separate **Metal Toolchain** component.
  If a build fails with `cannot execute tool 'metal' due to missing Metal Toolchain`:

  ```sh
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -downloadComponent MetalToolchain
  ```

- A local MLX chat model and (for document intelligence) an embedding model. See
  [`Docs/local-legal-model-setup.md`](Docs/local-legal-model-setup.md).
- *(Optional)* a free [CourtListener API token](https://www.courtlistener.com/help/api/rest/)
  for legal-research work.

## Getting set up

```bash
git clone git@github.com:cadespivey/Supra-AI.git
cd Supra-AI
cp .env.example .env          # fill in model names / CourtListener token; .env is gitignored
open SupraAI.xcworkspace       # build & run the "SupraAI" scheme
```

Configuration is read from `.env` / the process environment. `.env` is never committed.

## Building and testing

The app and runtime service build with Xcode; the packages also build and test with the
Swift toolchain.

```bash
# Build the app (app + XPC service + all packages)
xcodebuild -workspace SupraAI.xcworkspace -scheme SupraAI -destination 'platform=macOS' build

# Test an individual package
cd Packages/SupraSessions && swift test
```

If the command-line `swift`/`xcodebuild` toolchain can't compile MLX (Metal Toolchain), run
builds and tests with the beta toolchain selected:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild ...
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test   # from a package dir
```

The package test suite runs **with zero failures across all packages.** Keep it that way:
a change should not merge with a red suite.

## Repository layout

```
Apps/SupraAI/           SwiftUI app (SupraAI) + sandboxed runtime service + UI tests
Packages/               11 local Swift packages (see ARCHITECTURE.md for the graph)
Docs/Milestones/        Per-milestone plans, work orders, acceptance criteria, progress logs
Docs/Architecture/      Dependency pins, runtime file-access design
Resources/              Prompt templates (chat, research, structured outputs)
TestData/               Synthetic seed corpus + validation plan (no real client data)
FutureModules/          Reserved package namespaces for planned work
```

Read [ARCHITECTURE.md](ARCHITECTURE.md) before making cross-package changes — the package
dependency rules (e.g. only `SupraStore` opens the database; the document pipeline does no
network I/O) are intentional and enforced by the boundaries.

## How work is organized

Substantial features are planned as **milestones** before implementation. A milestone plan
in `Docs/Milestones/` lists numbered **work orders**, each with explicit acceptance criteria,
plus a definition of done and a validation suite. The M3 plan also keeps a **progress log**
with per-work-order status and any deviations from the literal plan (and why). If you take on
a milestone-sized change, follow the same pattern: write the plan, then implement against it.

Tests are written **before** the code they gate, and are designed so they cannot pass without
exercising their target — wire-proofs with non-default values, frozen goldens, recorded RED
reasons, no silent skips. The full discipline (and why each rule exists) is in
[`Docs/Test-First-Methodology.md`](Docs/Test-First-Methodology.md); follow it for any change
that adds or modifies behavior.

## Branching, commits, and pull requests

- **Branch from `main`** using a type prefix that matches existing history:
  `feat/…`, `fix/…`, `chore/…`, `test/…`, or `docs/…`
  (e.g. `feat/global-chat-attachments`, `fix/model-load-state`).
- **Commit messages** are imperative and scoped, e.g.
  `Add file/image attachments to global chat (OCR-to-text, up to 10)` or
  `Audit fixes: generation-failure handling, dead code, data race`.
- **Open a PR into `main`.** Keep PRs focused (one feature/fix area). Describe what changed,
  why, and how you verified it. Note any deviation from a milestone plan.
- **Tests must pass** and new behavior should be covered. Pipeline/domain logic gets
  deterministic package tests; model-dependent behavior is exercised by the Diagnostics
  validation suites.

The git history is a good reference for scope and message style.

## Code conventions

- **Swift 6 concurrency.** Respect actor isolation; controllers that drive UI are
  `@MainActor`. New shared types are `Sendable`.
- **Respect package boundaries.** Don't reach around them (no database access outside
  `SupraStore`, no Keychain/network outside `SupraNetworking`, no network in the document
  pipeline).
- **Secrets** go in the Keychain or `.env` — never in source, SQLite, logs, diagnostics, or
  exports.
- **No new remote dependencies** without pinning the exact version and documenting it in
  [`Docs/Architecture/Dependencies.md`](Docs/Architecture/Dependencies.md), including license.
- **Match the surrounding code.** Comment density, naming, and idiom should look like the file
  you're editing.

## Reporting bugs and proposing features

- **Bugs / features:** open a GitHub issue with steps to reproduce or a clear use case.
- **Security or privacy concerns:** do **not** open a public issue — follow
  [SECURITY.md](SECURITY.md).

By contributing, you agree your contributions are licensed under the project's
[MIT License](LICENSE).
