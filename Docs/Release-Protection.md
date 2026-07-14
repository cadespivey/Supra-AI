# Release protection and recovery

Supra AI releases are built only from a clean `main` checkout whose `HEAD` equals
`origin/main`. The protected release environment must approve the run, and the supplied
source SHA must match a successful `Protected macOS CI` run. A reviewed commit must first set
the app and runtime-service marketing/build metadata to the intended release. Those same
values are passed as build settings; release automation does not rewrite reviewed source.

Xcode metadata therefore identifies the reviewed release candidate. Until the protected
transaction publishes its signed artifact, the newest appcast item and website fallback
constants continue to identify the latest published release. Repository gates accept only two
coherent states: candidate version/build exactly equal published version/build, or candidate
semantic version and build both strictly newer. Appcast publication updates the appcast and
fallback constants together only after the signed candidate has passed release qualification.

## Required repository settings

Configure these controls in GitHub. The ruleset, protected environment, and repository
roles are administrative controls; their live configuration must be captured in the
release evidence because repository files cannot activate them.

As of 2026-07-13 the repository is operated by a single maintainer, and the settings
below are the single-maintainer adaptation of the original two-person design: GitHub
cannot require a second reviewer who does not exist (an author cannot approve their own
pull request), and a mandatory-review ruleset would deadlock both daily work and the
release transaction's automated appcast merge.

- A `main` branch ruleset with required status checks (listed below) and blocked force
  pushes and branch deletion. Do not configure an administrator or automation bypass for
  release, workflow, security-claim, or appcast changes. Pull requests are not formally
  required, but because the required checks only run via `pull_request` events, pushes to
  `main`, or manual dispatch, a commit must already have green checks on its exact SHA
  before `main` can move to it — in practice changes land through a pull request or
  through a branch whose `Protected macOS CI` run was dispatched and passed.
- Required checks from `Protected macOS CI`:
  - `Repository inventory and gate tests`
  - all 14 `Swift package - <name>` matrix checks
  - both `Unsigned Debug app and XPC` and `Unsigned Release app and XPC`
  - `App UI and hosted XPC smoke`
  - `Shipping migration fixtures`
  - `Website lint, build, audit, and asset guards`
  - `Secrets, entitlements, artifacts, models, and public metadata`
  `Dependency review` continues to run on every pull request but is not marked required,
  so that a branch-verified SHA can fast-forward `main` without a pull request.
- A tag ruleset on `v*` that blocks tag updates and deletions. Tags are created by the
  release transaction using the release token; on a single-maintainer personal repository
  GitHub cannot restrict tag creation to a separate identity, so published-tag
  immutability is the enforced property.
- Approving reviews, Code Owner approval, and required signed commits are not enforced by
  ruleset (single maintainer). `.github/CODEOWNERS` remains the authoritative statement
  of ownership, release and appcast commits are still cryptographically signed
  (`git commit -S`), and the release preflight independently re-verifies the source/CI
  binding regardless of ruleset state. Human release owners approve the environment; they
  do not publish manually outside the release workflows.

`.github/CODEOWNERS` assigns workflows, release scripts, product-claims inventory,
`SECURITY.md`, and public privacy copy to the release/security owner. Branch protection must
require the resulting Code Owner review.

## Protected environments

`production-release` requires a designated reviewer's approval before the job starts. With a
single maintainer that reviewer is the repository owner, so the approval is a deliberate
release decision recorded by GitHub, not an independent second-person review. The environment
is the only one with access to the Developer ID identity, notarization Keychain profile,
Sparkle signing key, manifest-signing identity, protected release-model location, and the
release token that can create tags/releases and appcast PRs. The signed model/XPC smoke driver
is repository-owned reviewed code, not a secret or an operator-supplied override. PR CI and
scheduled security jobs receive none of the release credentials or private model resources.
`SUPRA_RELEASE_GITHUB_TOKEN` is a fine-grained personal access token restricted to this single
repository (contents and pull-request read/write, actions read), is used for nothing except
the release workflows, and is stored only in this environment. Do not substitute the
workflow's automatic `GITHUB_TOKEN`: GitHub suppresses recursive workflow runs for changes it
creates, which would prevent the appcast PR from receiving its required checks.

## Release runner isolation

Signed release qualification and signed rehearsal must run only on the runner carrying both
the `supra-release` and `supra-release-isolated` labels. The original design specified
dedicated, ephemeral Apple Silicon hardware with a dedicated release UID; as of 2026-07-13
the repository owner operates that runner under the owner's own account on owner-controlled
Apple Silicon hardware. The boundary that the labels and `SUPRA_RELEASE_ISOLATED_RUNNER=1`
attest is:

- The runner is registered only to this repository and is offline except while a single
  approved release or rehearsal job runs: it is started manually for one approved job and
  stopped afterward. It is never used for pull requests, ordinary CI, or concurrent jobs.
- Every release credential (Developer ID identity, notarization Keychain profile, Sparkle
  EdDSA private key, Git signing key) lives in the owner's login Keychain — the same place
  it lived for manual releases — and the release token is scoped to this repository and
  stored only in the `production-release` environment.
- After every run, `Scripts/reset-release-runner.sh` archives the release evidence and
  clears the workspace, restoring an ephemeral-equivalent baseline between releases.

Accepted residual risk (repository owner, 2026-07-13): the same-UID mutate/restore race
against model files during the load interval — MLX opens model files by pathname, so
snapshot verification alone cannot defeat a hostile process under the same UID — is NOT
mitigated by UID separation in this configuration. Any process running as the owner during
a release job could in principle tamper with the smoke model or the build inputs. The owner
accepts this because every release credential already resides in the owner's account, so
same-UID malware defeats the release pipeline regardless of where the smoke runs; content
hashing before and after generation still forces tampering to win a narrow race rather than
simply substituting files. A dedicated release UID or dedicated ephemeral hardware remains
the documented upgrade path if maintainers are added, hardware is shared, or credentials
move off this machine.

`SUPRA_RELEASE_ISOLATED_RUNNER=1` makes the release entrypoint fail closed if this boundary
is not explicitly attested. The flag is only an assertion and does not replace the runner's
single-job discipline, the offline-except-approved-runs rule, evidence archival, or
protected environment review.

The environment executes one of three manual workflows:

- `Protected signed release rehearsal` builds, signs, notarizes, staples, scans, and runs the
  real signed model/XPC smoke, then exits at the explicit `--no-publish` boundary. It cannot
  create a tag, release, upload, appcast commit, push, or deployment.
- `Protected production release` repeats the SHA-bound preflight and signed build, creates a
  draft release, validates the exact uploaded ZIP and staged appcast, then performs the
  transactional publication.
- `Protected emergency release rollback` first returns the GitHub release to draft, then
  reverts the recorded appcast commit through a normal reviewed PR and waits for deployment.

Appcast publication and rollback intentionally use ordinary reviewed PRs and required checks.
The release environment does not use `--admin`, a ruleset bypass, a force push, or direct
`main` updates.

## Transaction and evidence

`Scripts/release-preflight.sh` is the stable local preflight entrypoint. It verifies the clean
branch/SHA/origin relationship, unused version/tag, exact green CI run, release-only
credentials, preventive font/security/claims gates, dependency lock hashes, and toolchain.
`Scripts/release.sh` then produces a signed manifest conforming to
`Docs/Schemas/release-preflight-manifest.schema.json`. The manifest binds source SHA, version,
build, CI evidence, app tree, ZIP, DMG, signing identity, and signed runtime-smoke result.

Before a release becomes public, the transaction verifies signatures, Team ID, entitlements,
hardened runtime, notarization/stapling, Gatekeeper, package contents, restricted paths,
secrets, and byte digests. It signs the ZIP downloaded back from the draft release, validates
the temporary appcast and website, and only then makes the release public. Appcast/deployment
failure returns it to draft. A final unauthenticated download/appcast digest check must pass.
Machine-readable results and content-free incident records are written beneath
`build/release/` and must be attached to protected release evidence.

Because the runner workspace is cleared between runs, evidence archival is mandatory before
any cleanup: `Scripts/reset-release-runner.sh` copies `build/release/` — including
`release-result-v<version>.json`, whose recorded appcast merge commit is a required input to
the emergency rollback workflow — into a timestamped directory under the release user's home
before clearing the workspace. Never clear the runner workspace without this archival; losing
the release result would make a post-cleanup emergency rollback impossible to parameterize.
The operational procedure is documented step by step in [Release-Runbook.md](Release-Runbook.md).

## Safe rehearsal

The local rehearsal is hermetic and mock-only:

```sh
bash Tests/Scripts/test-release-transaction.sh
```

It injects dirty-tree, SHA, tag, CI, font, credential, signature, notarization, Sparkle,
website, upload, deployment, and public-digest failures. Its command shims do not contact
GitHub, Apple, Sparkle infrastructure, or the public website. A signed release-candidate
rehearsal is a separate, approved `Protected signed release rehearsal` run and must retain its
manifest and log evidence; it is never performed from a developer checkout.

## Emergency withdrawal

Use the rollback workflow with the release result's version, source SHA, and exact appcast
merge commit. It immediately makes the release nonpublic, creates a two-file revert PR, waits
for required review/checks, merges normally, waits for Pages deployment, and records a
content-free incident. If the appcast rollback is delayed, keep the release draft; do not
restore it manually or bypass branch protection. Preserve manifests and logs without client
content, tokens, signing material, private filesystem paths, or model bytes.

The weekly `Scheduled security verification` workflow remains read-only. It checks public-ref
and release metadata, model IDs, repository security invariants, and website dependencies.
Existing public-ref cleanup is coordinated separately with GitHub Support; no release-control
exception weakens the local, artifact, or recurrence-prevention gates.

Owner decision (2026-07-13): releases may proceed while GitHub Support completes deletion of
the twelve ticketed pull-request refs (`refs/pull/39/head` through `refs/pull/50/head`) that
still advertise the six known font blobs. `Scripts/public-ref-audit-exceptions.tsv` pins each
ticketed violation by exact (ref, object, path); the audit reports pinned matches as KNOWN and
fails on anything else. Only immutable `refs/pull/N/head` entries are honored — branches,
tags, releases, new blobs, and new refs cannot be excepted, so the local, artifact, and
recurrence-prevention gates are unchanged. Rationale: release artifacts are independently
verified font-free, and publishing does not extend the pre-existing exposure, which only
Support can remove. The exception file must be deleted as soon as Support confirms removal.
