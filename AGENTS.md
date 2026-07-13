# Supra AI — agent notes

Native macOS 15+ SwiftUI app (Apple Silicon / MLX) + 14 local Swift packages. Read
[ARCHITECTURE.md](ARCHITECTURE.md) before cross-package changes;
[CONTRIBUTING.md](CONTRIBUTING.md) covers build/test commands, branching, and conventions.

## Development method (required)

Follow [`Docs/Test-First-Methodology.md`](Docs/Test-First-Methodology.md) for any change that
adds or modifies behavior:

- Plan substantial work as SPEC / PLAN / TESTPLAN working documents first. **Do not commit
  those planning documents** — they are scaffolding; only code, tests, and durable docs land
  in the repo.
- Author gating tests **before** production code, and commit them as a separate commit ahead
  of the implementation so the RED state is observable in history.
- Every test records its expected RED reason. Wire-proofs use non-default values and assert
  the default output absent, scoped to the exact output element. No silent skips, no
  tautologies, goldens never regenerated from the code under test.
- If your environment cannot compile Swift (e.g. a Linux container), say so: verification by
  inspection does not discharge the macOS `swift test` gate — flag it in PRs and commit
  messages, and run the static safeguard greps from the methodology doc.

## Environment facts

- Building/testing requires macOS + Xcode (`xcodebuild -workspace SupraAI.xcworkspace
  -scheme SupraAI`; per-package `swift test` from `Packages/<Name>/`). Protected macOS CI
  compiles the app/XPC in Debug and Release and tests the fixed 14-package matrix. Run
  `bash Scripts/verify-repo-facts.sh` and `bash Scripts/test-all-packages.sh` before merge;
  every deterministic check must pass with zero failures.
- Fixtures are synthetic (`TestData/`); never introduce real client data. Secrets live in
  `.env` / Keychain, never in source.

## Public website font license invariant (non-negotiable)

- **Never add, commit, push, package, upload, deploy, or otherwise expose any Equity font
  file publicly.** This applies even if a file is renamed, converted, subsetted, embedded,
  base64-encoded, placed in a release/build artifact, or kept only in Git history.
- The public repository and every artifact produced from it must remain free of Equity font
  binaries. Do not put them under `website/`, Git LFS, Actions artifacts, GitHub Pages,
  releases, fixtures, screenshots with embedded font data, or any other tracked/public path.
- Website work must use system fonts or fonts whose license expressly permits the intended
  public redistribution. A local/private font workflow may be designed separately, but it
  must default to absence, stay outside this repository, and never feed public builds.
- Every website SPEC / PLAN / TESTPLAN must repeat this invariant and include the repository
  asset-license check as an acceptance gate. Run `bash Scripts/verify-public-font-license.sh`
  before committing or deploying website changes. Never bypass or weaken that check.
- See [`Docs/Website-Asset-Licensing.md`](Docs/Website-Asset-Licensing.md) for the durable
  policy and incident procedure.
