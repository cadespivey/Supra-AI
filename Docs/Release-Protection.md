# Release protection and recovery

Supra AI is a single-maintainer project. Release protection should preserve artifact integrity
and recoverability without simulating multiple reviewers or rerunning the same source checks.

## Release-ready commit

A completed project plan is release-ready when:

- the working tree is clean and the intended commit is on `main`;
- version/build metadata and release notes are coherent;
- one impact-appropriate protected CI receipt is green for the exact source SHA; and
- no known release-blocking defect remains.

The source receipt is reused by release preflight. Do not require separate green runs for the
feature branch, merged `main`, a version-only commit, and an appcast-only commit. If metadata must
change after validation, use a narrow metadata check or include the metadata in the validated
candidate; do not restart the entire application suite.

## Repository controls

- Protect `main` from force pushes and deletion and protect published `v*` tags from updates or
  deletion.
- Require one aggregate protected-CI context rather than per-package, per-build, UI, migration,
  website, and benchmark contexts.
- Do not require approving reviews or Code Owner approval while there is one maintainer. A PR is
  optional as a CI/change-summary surface and is not an independent approval gate.
- Keep release credentials only in the protected production environment and use them only from
  the repository's release workflow.

The owner starting the production command is the release authorization. Keep the
`production-release` environment for its scoped credentials, but configure it without a required
reviewer so the owner is not asked to approve the same operation twice.

## Runner boundary

The signed transaction runs on the repository-scoped Apple Silicon release runner, which stays
offline except for one approved release job and is cleared after its evidence is archived. This
operating discipline provides the intended ephemeral-equivalent boundary without adding another
qualification round.

The runner currently uses the owner's macOS account. The accepted same-UID risk remains: malware
already executing as that user could race or alter release inputs despite before/after hashing.
Use a dedicated release user or ephemeral hardware if maintainers are added, the Mac becomes
shared, or credentials move outside the owner's account.

## One production transaction

Routine releases proceed directly to one protected production transaction. It performs the
checks that cannot be supplied by source CI:

1. bind the build to the approved source SHA, version, and build number;
2. build, sign, notarize, staple, and verify Gatekeeper, Team ID, entitlements, hardened runtime,
   package contents, and digests;
3. run one signed app/XPC model smoke that proves the packaged product launches and crosses the
   release-only boundary;
4. create a draft release, upload and download the exact artifact, and verify its digest;
5. publish the release and its appcast/website metadata transactionally; and
6. verify the public appcast and unauthenticated download, rolling back to draft on failure.

Do not add unsigned UI smoke, a second signed smoke, full package tests, benchmarks, or another
general repository gate inside the release transaction when the exact source receipt already
provides that evidence.

Appcast publication receives narrow XML/version validation before the metadata commit; the Pages
workflow owns the single full website build and deploy. It should not open a second general-purpose
PR, wait for the full application pipeline, or build the same site inside the transaction.
Preserve transactional rollback and the recorded appcast commit or equivalent recovery identifier.

## Rehearsal policy

A signed rehearsal is optional for routine product releases. Run one only when signing,
notarization, packaging, entitlements, Sparkle/appcast publication, rollback logic, runner
provisioning, release credentials, or the Xcode/Sparkle toolchain changed—or when the owner
explicitly asks for it. Mock failure-injection tests remain appropriate when release code changes,
but they are not a per-release ceremony.

## Evidence and recovery

Archive the source SHA, CI receipt, signed manifest, artifact digests, notarization result,
public verification, and publication/rollback identifier. Keep evidence content-free: no client
data, tokens, private keys, model bytes, or private filesystem details.

On publication failure, return the release to draft and restore the prior appcast/website state.
Published tags remain immutable. Preserve enough evidence to run emergency withdrawal without
repeating source qualification.

## Live-settings transition

The repository automation implements the single-pass path. GitHub's live `main` ruleset must
require only the aggregate CI job, and the `production-release` environment must retain its
credentials without a required reviewer. These settings are external to the repository; until
they are updated, GitHub may still impose legacy waits that the scripts no longer request.
