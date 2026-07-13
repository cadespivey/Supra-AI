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

Configure a `main` ruleset in GitHub with all of these controls. The ruleset, protected
environment, and repository roles are administrative controls; their live configuration
must be captured in the release evidence because repository files cannot activate them.

- Require a pull request, one approving review, Code Owner approval, resolved
  conversations, and approval after the most recent reviewable push.
- Block branch deletion and force pushes. Do not configure an administrator or automation
  bypass for release, workflow, security-claim, or appcast changes.
- Require these deterministic checks from `Protected macOS CI`:
  - `Repository inventory and gate tests`
  - all 14 `Swift package - <name>` matrix checks
  - both `Unsigned Debug app and XPC` and `Unsigned Release app and XPC`
  - `App UI and hosted XPC smoke`
  - `Shipping migration fixtures`
  - `Website lint, build, audit, and asset guards`
  - `Secrets, entitlements, artifacts, models, and public metadata`
  - `Dependency review` on pull requests
- Require signed commits where supported by every contributor identity used on `main`.
- Apply a tag ruleset to `v*`: prevent update/deletion and permit creation only from the
  `production-release` environment's narrowly scoped GitHub identity.
- Limit repository release creation/editing to that same identity. Human release owners
  approve the environment; they do not publish manually with a personal token.

`.github/CODEOWNERS` assigns workflows, release scripts, product-claims inventory,
`SECURITY.md`, and public privacy copy to the release/security owner. Branch protection must
require the resulting Code Owner review.

## Protected environments

`production-release` must require a reviewer who did not author the source change. It is the
only environment with access to the Developer ID identity, notarization Keychain profile,
Sparkle signing key, manifest-signing identity, protected release-model location, and an
identity that can create tags/releases and appcast PRs. The signed model/XPC smoke driver is
repository-owned reviewed code, not a secret or an operator-supplied override. PR CI and
scheduled security jobs receive none of the release credentials or private model resources.
`SUPRA_RELEASE_GITHUB_TOKEN` belongs to the dedicated release identity, is scoped to this
repository, and is stored only in this environment. Do not substitute the workflow's automatic
`GITHUB_TOKEN`: GitHub suppresses recursive workflow runs for changes it creates, which would
prevent the appcast PR from receiving its required checks.

## Mandatory isolated release runner

Signed release qualification and signed rehearsal must run only on a dedicated, ephemeral
Apple Silicon runner carrying both the `supra-release` and `supra-release-isolated` labels.
The runner must be freshly provisioned, or securely wiped to an equivalent baseline, for one
approved release job and destroyed or wiped immediately afterward. It must use a unique,
noninteractive release UID with no interactive login, concurrent job, background service, or
untrusted same-UID process. Never reuse this runner for pull requests, ordinary CI, developer
work, or multiple concurrent release jobs. Mount the protected model directory only for the
approved job and remove access during teardown. Restrict the runner group to this repository
and to the two protected release workflows; repository labels alone are not an access-control
boundary.

This isolation is part of the signed-smoke security boundary, not merely an operations
preference. The runtime service copies the authorized model into a private, verified snapshot,
but MLX still opens model files by pathname. Snapshot verification alone cannot defeat a
hostile same-UID process that mutates and restores those bytes during the load interval. The
workflow label selects the controlled runner; `SUPRA_RELEASE_ISOLATED_RUNNER=1` makes the
release entrypoint fail closed if that boundary is not explicitly attested. The flag is only
an assertion and does not replace runner provisioning, single-tenancy, teardown, or protected
environment review.

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
