# Release runbook

This is the intended single-maintainer path from finished work to a published Supra AI release.
Policy and rationale live in [Release-Protection.md](Release-Protection.md).

## Before starting

Confirm once that:

- the intended commit is clean, on `main`, and has one green protected-CI receipt selected by
  change impact;
- version/build metadata and `CHANGELOG.md` describe the candidate;
- the login Keychain, notarization profile, Sparkle key, release token, runner, and verified smoke
  model are available; and
- no other change will move `main` during publication.

Do not rerun a successful source suite during this checklist unless the source SHA or relevant
inputs changed.

## Routine release

From the logged-in owner session:

```sh
bash Scripts/cut-release.sh --patch --notes-file NOTES.md
```

Pass an explicit `X.Y.Z` for a minor or major release. Running the command is the owner's release
approval.

The simplified command should perform four phases:

1. **Prepare** — confirm the release-ready commit and create any necessary version/release-note
   metadata without triggering a second full application pipeline.
2. **Build and qualify** — bind to the recorded SHA, sign, notarize, staple, verify the packaged
   artifact, and run one signed app/XPC model smoke.
3. **Publish transactionally** — create a draft, verify the uploaded bytes, publish the release
   and narrow appcast/website metadata, and roll back to draft if publication fails.
4. **Verify and archive** — the transaction re-downloads public bytes once and compares digests
   and appcast metadata; the finish command then stops the runner and archives that result without
   repeating the public probes.

A transient runner failure may retry the failed phase. A real product or artifact failure stops
the release. Do not respond by layering a new permanent smoke check onto every future release.

## When a rehearsal is warranted

Routine product releases skip rehearsal. Run:

```sh
bash Scripts/cut-release.sh --rehearsal
```

only after a change to signing, notarization, packaging, entitlements, release workflows,
publishing/rollback logic, release credentials, runner provisioning, or the Xcode/Sparkle
toolchain, or when the owner explicitly wants a dry run.

## GitHub settings

The scripts implement this four-phase path: the validated release-metadata SHA fast-forwards to
`main`, appcast publication uses a narrow validation run, and neither operation creates a review
PR or repeats general CI. Configure the live `main` ruleset to require only `Protected macOS CI`,
and remove required reviewers from the credential-bearing `production-release` environment. Those
two GitHub settings cannot be changed by repository files.

## Emergency withdrawal

Use `Protected emergency release rollback` with the version, source SHA, and publication recovery
identifier from the archived release result. Return the GitHub release to draft first, restore
the prior appcast/website state, verify the public state, and preserve the incident evidence.
Never force-update a published tag.
