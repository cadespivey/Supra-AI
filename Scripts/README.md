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
- `verify-secrets.sh`, `verify-prohibited-artifacts.sh`, and `verify-entitlements.sh` are
  path-only fail-closed security scans. Findings never print matched secret values.
- `build-macos-app.sh`, `run-app-smoke-tests.sh`, and
  `run-shipping-migration-fixtures.sh` are the macOS build, hosted-XPC, UI, and upgrade
  hooks used by `.github/workflows/macos-ci.yml`.
- `test-website.sh` runs locked installation, lint, typecheck, static build, dependency
  audit, and the font guard before and after the website build.

Run `Tests/Scripts/test-macos-ci-gates.sh` to exercise deliberate failure fixtures.
See `Docs/Protected-CI.md` for branch-protection names and reviewed Action licenses/pins.
