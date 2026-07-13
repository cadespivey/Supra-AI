# Scripts

Project automation scripts will live here as Milestone 1 build, validation, and export workflows become concrete.

Public asset gates:

- `verify-public-font-license.sh` scans the checkout and local build outputs for prohibited
  paths, names, and known font binary hashes.
- `verify-public-repository-assets.sh` performs a metadata-only audit of advertised public
  Git/GitHub refs, trees, and release asset names. It never fetches repository blobs or
  release assets. Run `Tests/Scripts/test-verify-public-repository-assets.sh` for the synthetic
  fixture suite.

Protected CI gates:

- `list-local-packages.sh --verify` owns the fixed 14-package inventory;
  `test-all-packages.sh` tests either that whole set or one matrix entry.
- `verify-repo-facts.sh` checks the three Xcode targets, package/workflow inventories,
  dynamic contiguous migration sequence, version metadata, full-SHA Action pins,
  entitlements, and the public-font invariant.
- `verify-product-claims.sh` validates `Docs/Verified-Product-Claims.yml`, its publication,
  code, test, workflow, release-version, migration/support, entitlement, and package anchors.
  It is called by repository facts, protected CI, and release preflight.
- `verify-secrets.sh`, `verify-prohibited-artifacts.sh`, and `verify-entitlements.sh` are
  path-only fail-closed security scans. Findings never print matched secret values.
- `build-macos-app.sh`, `run-app-smoke-tests.sh`, and
  `run-shipping-migration-fixtures.sh` are the macOS build, hosted-XPC, UI, and upgrade
  hooks used by `.github/workflows/macos-ci.yml`.
- `test-website.sh` runs locked installation, lint, typecheck, static build, dependency
  audit, and the font guard before and after the website build.

Run `Tests/Scripts/test-macos-ci-gates.sh` and
`Tests/Scripts/test-verify-product-claims.sh` to exercise deliberate failure fixtures.
See `Docs/Protected-CI.md` for branch-protection names and reviewed Action licenses/pins.

Protected release controls:

- `release-preflight.sh` is the stable, read-only source/SHA/CI/gate entrypoint.
- `release.sh` builds the exact reviewed SHA without editing source versions, verifies signed
  artifacts and model/XPC smoke evidence, then delegates to the transactional publisher.
- `create-preflight-manifest.sh`, `verify-release-artifacts.sh`, and
  `prepare-release-appcast.sh` bind and validate the app, ZIP, DMG, Team ID, entitlements,
  notarization, digests, Sparkle metadata, and release provenance.
- `publish-release-transaction.sh` uses a draft-first release and rolls back public state on
  appcast/deployment/digest failure. `emergency-release-rollback.sh` uses the same protected
  environment and a reviewed appcast-revert PR; it has no permanent branch bypass.
- `verify-release-protection.sh` checks repository-owned protection hooks. The hermetic
  failure-injection rehearsal is `Tests/Scripts/test-release-transaction.sh`.

See `Docs/Release-Protection.md` for the required live GitHub rulesets, environment approval,
signed rehearsal, evidence, and withdrawal procedure.

Runtime/XPC qualification:

- `verify-runtime-xpc-boundary.sh` checks reciprocal supported code-signing requirements,
  the Release Team-ID binding, unchanged service sandbox/entitlements, and optional built
  product signatures.
- `run-hosted-xpc-lifecycle.sh` ad-hoc-signs the Debug app and embedded XPC, then runs the
  exact `SupraAIUITests/RuntimeXPCIntegrationTests` selector. The lifecycle scenario performs
  20 iterations and covers bookmark rejection/containment, load/unload concurrency,
  reconnect, client drop, cancellation, and exactly-once stream completion.
- `run-runtime-sanitizer.sh thread|address|undefined` applies the requested sanitizer to the
  focused runtime package/hosted lifecycle gate. Tool exclusions and observed results live
  in `Docs/Architecture/RuntimeXPCQualification.md`.
