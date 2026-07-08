# Supra AI — agent notes

Native macOS 15+ SwiftUI app (Apple Silicon / MLX) + 11 local Swift packages. Read
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
  -scheme SupraAI`; per-package `swift test` from `Packages/<Name>/`). There is no CI that
  compiles Swift — the package suites are the merge gate and must pass with zero failures.
- Fixtures are synthetic (`TestData/`); never introduce real client data. Secrets live in
  `.env` / Keychain, never in source.
