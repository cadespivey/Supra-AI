# Scripts

Repository build, focused validation, release, and maintenance automation lives here.

Protected CI building blocks:

- `list-local-packages.sh --verify` owns the fixed 14-package inventory;
  `test-all-packages.sh` can test the whole set or one selected package. Affected packages and
  their dependents share one CI runner; the whole set is not required for every isolated change.
- `ci-change-plan.sh` selects affected lanes, while `verify-changed-files.sh` is the only
  always-on repository check and scans just the diff for secrets and prohibited artifacts.
- `verify-release-version-state.sh` treats Xcode metadata as the reviewed candidate and the
  well-formed newest appcast item plus website fallback constants as the published release. It
  accepts only an exact published state or a strictly newer semantic version with a strictly
  newer build.
- `verify-repo-facts.sh` checks the three Xcode targets, package/workflow inventories,
  dynamic contiguous migration sequence, candidate/published release state, full-SHA Action
  pins, and workflow structure. It does not invoke unrelated verifiers recursively.
- `verify-product-claims.sh` validates `Docs/Verified-Product-Claims.yml`, its publication,
  code, test, workflow, appcast-authoritative release, supported release line,
  migration/support, and package anchors. It runs when claims inputs change and in the weekly
  full sweep.
- `verify-secrets.sh`, `verify-prohibited-artifacts.sh`, and `verify-entitlements.sh` are
  path-only fail-closed security scans. Findings never print matched secret values.
- `build-macos-app.sh`, `run-app-smoke-tests.sh`, and
  `run-shipping-migration-fixtures.sh` are the macOS build, hosted-XPC, UI, and upgrade
  hooks used by `.github/workflows/macos-ci.yml`.
- `test-website.sh` runs locked installation, lint, typecheck, static build, and dependency
  audit.

Run `Tests/Scripts/test-macos-ci-gates.sh` and
`Tests/Scripts/test-verify-product-claims.sh` to exercise deliberate failure fixtures.
See `Docs/Protected-CI.md` for the aggregate, change-aware CI policy.

Protected release controls:

- `release-preflight.sh` is the stable, read-only source/SHA/CI/gate entrypoint.
- `release.sh` builds the exact reviewed SHA without editing source versions, verifies signed
  artifacts and model/XPC smoke evidence, then delegates to the transactional publisher.
- `create-preflight-manifest.sh`, `verify-release-artifacts.sh`, and
  `prepare-release-appcast.sh` bind and validate the app, ZIP, DMG, Team ID, entitlements,
  notarization, digests, Sparkle metadata, and release provenance.
- `publish-release-transaction.sh` uses a draft-first release and rolls back public state on
  appcast/deployment/digest failure. It validates prepared appcast metadata without rebuilding
  the website; Pages performs the single full build. Appcast publication and rollback each run
  the narrow change-aware CI path, then fast-forward the validated metadata commit without a
  review PR.
- `release-finish.sh` stops the runner and archives transaction evidence. It does not repeat the
  public release and appcast verification already performed by the transaction.
- `verify-release-protection.sh` checks repository-owned protection hooks. The hermetic
  failure-injection rehearsal is `Tests/Scripts/test-release-transaction.sh`.

See `Docs/Release-Protection.md` for the simplified single-maintainer release policy, unique
publication checks, evidence, and withdrawal procedure.

Runtime/XPC qualification:

- `verify-runtime-xpc-boundary.sh` checks reciprocal supported code-signing requirements,
  the Release Team-ID binding, unchanged service sandbox/entitlements, and optional built
  product signatures.
- `run-hosted-xpc-lifecycle.sh` ad-hoc-signs the Debug app and embedded XPC, then runs the
  exact `SupraAIUITests/RuntimeXPCIntegrationTests` selector. The lifecycle scenario performs
  20 iterations and covers bookmark rejection/containment, load/unload concurrency,
  reconnect, client drop, cancellation, and exactly-once stream completion.
- `run-runtime-sanitizer.sh thread|address|undefined` applies the requested sanitizer to the
  focused runtime package/hosted lifecycle gate. The instrumented lifecycle records XPC RSS
  but does not claim the separate uninstrumented 256 MiB production envelope. Tool exclusions
  and observed results live in `Docs/Architecture/RuntimeXPCQualification.md`.
