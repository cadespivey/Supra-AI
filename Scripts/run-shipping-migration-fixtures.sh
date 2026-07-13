#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture_test="${SUPRA_MIGRATION_FIXTURE_TEST_FILE:-${repo_root}/Packages/SupraStore/Tests/SupraStoreTests/ShippingMigrationFixtureTests.swift}"
check_only=0
if [[ "${1:-}" == "--check" ]]; then
  check_only=1
  shift
fi
if (( $# != 0 )); then
  printf 'Usage: %s [--check]\n' "$0" >&2
  exit 2
fi
if [[ ! -f "$fixture_test" ]] || ! grep -Eq 'class[[:space:]]+ShippingMigrationFixtureTests|struct[[:space:]]+ShippingMigrationFixtureTests' "$fixture_test"; then
  printf '%s\n' 'ERROR: shipping migration fixture matrix is missing: ShippingMigrationFixtureTests' >&2
  exit 1
fi
printf '%s\n' 'Shipping migration fixture hook passed.'
(( check_only != 0 )) && exit 0
bash "${repo_root}/Scripts/verify-migration-sequence.sh"
swift test \
  --package-path "${repo_root}/Packages/SupraStore" \
  --filter ShippingMigrationFixtureTests
