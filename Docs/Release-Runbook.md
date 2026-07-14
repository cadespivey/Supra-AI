# Release runbook

Step-by-step procedure for cutting a Supra AI release under the protected release
pipeline. Policy and rationale live in [Release-Protection.md](Release-Protection.md);
this document is the operational checklist. Every step is fail-closed: if a gate fails,
stop and fix the cause — never weaken a gate to proceed.

## One-time infrastructure (already configured when this runbook applies)

- Local macOS user `suprarelease` (noninteractive; used only for releases) holding, in
  its own login Keychain: the Developer ID Application identity, the `supra-notary`
  notarytool profile, and the Sparkle EdDSA private key matching the app's
  `SUPublicEDKey`.
- GitHub Actions runner installed at `~suprarelease/actions-runner` with labels
  `supra-release` and `supra-release-isolated` (plus the automatic `self-hosted`,
  `macOS`, `ARM64`), provisioned by `Scripts/provision-release-runner.sh`.
- The `production-release` environment with the repository owner as required reviewer,
  the eleven release variables, and the `SUPRA_RELEASE_GITHUB_TOKEN` secret (fine-grained
  PAT restricted to this repository).
- The `main` required-checks ruleset and the `v*` tag ruleset.
- The verified smoke model installed under the release user's app container
  (`~suprarelease/Library/Containers/ai.supra.SupraAI/Data/Library/Application Support/`
  `ai.supra.SupraAI/Models/<org>__<name>`) with its `.supra-model-manifest.json`, and
  `SUPRA_RELEASE_SMOKE_MODEL_SHA256` set to the canonical fingerprint reported by
  `Scripts/smoke-model-tool.swift`.

## Per-release procedure

### 1. Candidate readiness (developer account)

1. The release candidate commit (version + build bump in the pbxproj, `CHANGELOG.md`
   entry) is on `main`, and `origin/main` == the candidate SHA.
2. `Protected macOS CI` is green on that exact SHA. Record the run id:
   `gh run list --branch main --workflow "Protected macOS CI" --limit 1 \
    --json databaseId,headSha,conclusion`
3. The live public-asset audit passes:
   `bash Scripts/verify-public-repository-assets.sh cadespivey/Supra-AI`
   If it reports prohibited font paths/blobs in any advertised ref, the release is
   blocked until GitHub Support removes those refs. Do not weaken the gate.
4. No release or tag exists yet for the version:
   `gh release view vX.Y.Z` must fail; `git ls-remote --tags origin vX.Y.Z` must be empty.

### 2. Start the runner (release account)

1. Fast-user-switch (or `su`) into `suprarelease` and open a login session — the login
   Keychain must be unlocked for signing and notarization.
2. Start the runner in the foreground for this run only:
   `cd ~/actions-runner && ./run.sh`
3. Confirm the runner shows **Idle** under repository Settings → Actions → Runners.

### 3. Rehearse first (developer account)

Every release is preceded by a green rehearsal of the same inputs — real signing,
notarization, stapling, and the signed model/XPC smoke, with publication structurally
impossible (`--no-publish`):

```sh
gh workflow run "Protected signed release rehearsal" \
  -f version=X.Y.Z -f build=NNN \
  -f expected_sha=<40-hex origin/main SHA> -f ci_run_id=<green CI run id>
```

Approve the `production-release` deployment when GitHub prompts, then watch the run to
completion. After it finishes, run step 5 (evidence + reset) before anything else.

### 4. Produce (developer account)

Same inputs, production workflow:

```sh
gh workflow run "Protected production release" \
  -f version=X.Y.Z -f build=NNN \
  -f expected_sha=<same SHA> -f ci_run_id=<same run id>
```

Approve the environment deployment. The transaction creates a draft release, uploads and
re-verifies artifacts, signs the ZIP downloaded back from the draft, publishes, opens and
merges the appcast PR (two files: `website/public/appcast.xml`, `website/lib/constants.ts`),
waits for the Pages deployment, and re-downloads everything unauthenticated for digest
comparison. `origin/main` must not move during the run — do not push anything until it
completes.

On success, verify as a user would: the GitHub release page shows the notarized
`SupraAI-X.Y.Z.dmg`/`.zip`, https://supralegal.ai serves the new version, and
https://supralegal.ai/appcast.xml lists the new item.

### 5. Evidence and reset (release account)

Immediately after every rehearsal or release run, from the `suprarelease` session:

```sh
bash <repo-workspace>/Scripts/reset-release-runner.sh
```

This archives `build/release/` (manifests, signed-smoke result, and
`release-result-vX.Y.Z.json` — the emergency rollback workflow requires its recorded
appcast merge commit) into `~/ReleaseEvidence/<timestamp>/`, then clears the runner
workspace. Then stop the runner (Ctrl-C on `run.sh`) and log the release session out.
The runner stays offline until the next approved run.

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
