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

## Per-release procedure

The release candidate commit (version + build bump in the pbxproj, `CHANGELOG.md`
entry — advancing SECURITY.md's supported line and `Docs/Verified-Product-Claims.yml`
when the covered wording changes) must be on `main` with `Protected macOS CI` green on
its exact SHA. The reviewed commit is the only statement of the release version and
build; nothing is hand-typed at dispatch time. Then, from a logged-in owner session
(login Keychain unlocked, as it is during normal use):

### 1. Dispatch

```sh
bash Scripts/release-dispatch.sh
```

This verifies readiness (green `Protected macOS CI` on origin/main's exact SHA, unused
version/tag, live public-asset audit), starts the runner for this run only, and
dispatches `Protected production release` bound to that SHA and CI run. Every check it
performs is re-verified fail-closed inside the protected transaction; the script only
assembles inputs and fails fast. If the public-asset audit reports prohibited font
paths/blobs in any advertised ref, the release is blocked until GitHub Support removes
those refs — do not weaken the gate.

### 2. Approve

Approve the `production-release` deployment when GitHub prompts. The transaction creates
a draft release, uploads and re-verifies artifacts, signs the ZIP downloaded back from
the draft, publishes, opens and merges the appcast PR (two files:
`website/public/appcast.xml`, `website/lib/constants.ts`), waits for the Pages
deployment, and re-downloads everything unauthenticated for digest comparison.
`origin/main` must not move during the run — do not push anything until it completes.

### 3. Finish

```sh
bash Scripts/release-finish.sh
```

This watches the run to completion, stops the runner, archives evidence via
`Scripts/reset-release-runner.sh` (including `release-result-vX.Y.Z.json`, whose
recorded appcast merge commit the emergency rollback workflow requires) into
`~/ReleaseEvidence/<timestamp>/`, and re-verifies the published release and
https://supralegal.ai/appcast.xml as a user would. Evidence is archived for every
completed run, green or red; a run that never completes leaves the runner and workspace
untouched for investigation. The runner stays offline until the next approved run.

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
bash Scripts/release-dispatch.sh --rehearsal
# approve the deployment, then
bash Scripts/release-finish.sh --rehearsal
```

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
