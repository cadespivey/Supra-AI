# Release runbook

Step-by-step procedure for cutting a Supra AI release under the protected release
pipeline. Policy and rationale live in [Release-Protection.md](Release-Protection.md);
this document is the operational checklist. Every step is fail-closed: if a gate fails,
stop and fix the cause — never weaken a gate to proceed.

## One-time infrastructure (already configured when this runbook applies)

- The owner's login Keychain holds the Developer ID Application identity, the
  `supra-notary` notarytool profile, and the Sparkle EdDSA private key matching the app's
  `SUPublicEDKey`.
- GitHub Actions runner installed at `~/actions-runner` (owner account) with labels
  `supra-release` and `supra-release-isolated` (plus the automatic `self-hosted`,
  `macOS`, `ARM64`), provisioned by `Scripts/provision-release-runner.sh`.
- The `production-release` environment with the repository owner as required reviewer,
  the eleven release variables, and the `SUPRA_RELEASE_GITHUB_TOKEN` secret (fine-grained
  PAT restricted to this repository).
- The `main` required-checks ruleset and the `v*` tag ruleset.
- The verified smoke model installed under the owner's app container
  (`~/Library/Containers/ai.supra.SupraAI/Data/Library/Application Support/`
  `ai.supra.SupraAI/Models/<org>__<name>`) with its `.supra-model-manifest.json`, and
  `SUPRA_RELEASE_SMOKE_MODEL_SHA256` set to the canonical fingerprint reported by
  `Scripts/smoke-model-tool.swift`. Do not manage or modify that model through the app
  UI; content changes invalidate the pinned fingerprint.

## Per-release procedure — one command

From a logged-in owner session (login Keychain unlocked, as it is during normal use),
with your user-facing notes in a markdown file:

```sh
bash Scripts/cut-release.sh --patch --notes-file NOTES.md
```

(`--patch` bumps the last version component and the build number; pass an explicit
`X.Y.Z` instead for a minor/major. Running the command IS the owner's approval of the
`production-release` deployment gate — pass `--hold` to keep that approval manual.)

The command sequences the whole runbook and stops on the first real failure:

1. **Preflight** — clean tree on an up-to-date `main`, `gh` authenticated, console
   unlocked (notarization needs the login Keychain; a locked console sank a
   production round), release runner offline. It holds the session awake with
   `caffeinate` for the duration.
2. **Candidate** — version + build bump in the pbxproj and the `CHANGELOG.md` entry
   from your notes file, committed on `release/X.Y.Z` and opened as a PR. (Advance
   SECURITY.md's supported line and `Docs/Verified-Product-Claims.yml` yourself first
   when the covered wording changes — patch releases normally change neither.) The
   reviewed commit remains the only statement of the release version and build;
   nothing is hand-typed at dispatch time.
3. **Babysat CI** — waits for `Protected macOS CI`; a failure whose every failed job
   died in GitHub's own "Set up job" step (runner provisioning, before any repository
   code ran) is rerun, at most twice. Any real failure aborts the cut before the
   merge. Merges when green, then waits for green on `main`.
4. **Dispatch** — `Scripts/release-dispatch.sh`: verifies readiness (green CI on
   origin/main's exact SHA, unused version/tag, live public-asset audit), starts the
   runner for this run only, and dispatches `Protected production release` bound to
   that SHA and CI run. Every check is re-verified fail-closed inside the protected
   transaction. If the public-asset audit reports prohibited font paths/blobs in any
   advertised ref, the release is blocked until GitHub Support removes those refs —
   do not weaken the gate.
5. **Approve** — the `production-release` gate is approved automatically (or by you,
   under `--hold`). The transaction creates a draft release, uploads and re-verifies
   artifacts, publishes, opens and merges the appcast PR, waits for the Pages
   deployment, and re-downloads everything unauthenticated for digest comparison.
   `origin/main` must not move during the run — do not push anything until it
   completes.
6. **Finish** — `Scripts/release-finish.sh`: watches the run to completion, stops the
   runner (including the respawning `run-helper.sh`), archives evidence via
   `Scripts/reset-release-runner.sh` (including `release-result-vX.Y.Z.json`, whose
   recorded appcast merge commit the emergency rollback workflow requires) into
   `~/ReleaseEvidence/<timestamp>/`, and re-verifies the published release and
   https://supralegal.ai/appcast.xml as a user would. Evidence is archived for every
   completed run, green or red; a run that never completes leaves the runner and
   workspace untouched for investigation.

On failure, the transaction reports its PROBED end state: a failure that published
nothing says so and is safe to fix and re-dispatch; the CRITICAL
emergency-rollback demand is reserved for a release that is verifiably still public
after a failed rollback. The dispatch/approve/finish scripts remain individually
runnable for manual operation.

### Website dependency audit and releases

The release transaction's staged website gate runs lint, typecheck, the static
build, and the font guard — it does NOT run `npm audit` (owner decision,
2026-07-24, after a third freshly disclosed transitive advisory blocked a fully
notarized release). The site is a static export whose build-time dependencies never
execute for a visitor; supply-chain coverage lives in the scoped per-PR audit and
the weekly scheduled audit (`security-scheduled.yml`). Advisories found there are
fixed on their own schedule via `overrides` pins — never `npm audit fix --force`.

## Signed rehearsal policy

A signed rehearsal — the same build, signing, notarization, stapling, and signed
model/XPC smoke with publication structurally impossible (`--no-publish`) — is required
before the next production release whenever release machinery has changed since the last
green signed run on this runner: `.github/workflows/release*.yml`, `Scripts/release*`,
`Scripts/publish-release*`, `Scripts/prepare-release-appcast.sh`,
`Scripts/lib/release-common.sh`, runner provisioning, the signing/notarization
toolchain or Xcode, or a Sparkle update. Routine releases that change only product code
proceed directly to production (owner decision, 2026-07-19); the hermetic mock
transaction (`bash Tests/Scripts/test-release-transaction.sh`) continues to cover the
transaction logic on every change.

To rehearse:

```sh
bash Scripts/cut-release.sh --rehearsal
```

(One command: dispatches, approves, and finishes in rehearsal mode with no candidate
commit. The underlying `release-dispatch.sh --rehearsal` / `release-finish.sh
--rehearsal` pair remains available for manual operation.)

## Emergency withdrawal

Use `Protected emergency release rollback` with the version, the source SHA, and the exact
appcast merge commit from the archived `release-result-vX.Y.Z.json`. The workflow returns
the release to draft first, then reverts the appcast through a normal reviewed PR and waits
for deployment. If the appcast rollback is delayed, keep the release draft; do not restore
anything manually or bypass the rulesets.

## Landing ordinary changes on main (post-ruleset)

The `main` ruleset requires green `Protected macOS CI` checks on the exact SHA. Two ways to
land work:

- Open a pull request; checks run automatically; merge when green.
- Or push a branch, dispatch `Protected macOS CI` on it
  (`gh workflow run "Protected macOS CI" --ref <branch>`), and fast-forward push to `main`
  once the SHA is green.

Force pushes and branch deletion on `main`, and any update or deletion of `v*` tags, are
blocked by ruleset for everyone.
