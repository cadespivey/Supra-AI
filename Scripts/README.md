# Scripts

Project automation scripts will live here as Milestone 1 build, validation, and export workflows become concrete.

Public asset gates:

- `verify-public-font-license.sh` scans the checkout and local build outputs for prohibited
  paths, names, and known font binary hashes.
- `verify-public-repository-assets.sh` performs a metadata-only audit of advertised public
  Git/GitHub refs, trees, and release asset names. It never fetches repository blobs or
  release assets. Run `Tests/Scripts/test-verify-public-repository-assets.sh` for the synthetic
  fixture suite.
