#!/bin/bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
DEST="$ROOT/Packages/SupraStore/Tests/SupraStoreTests/Fixtures/ShippingMigrations"
HELPER="$ROOT/Scripts/ShippingMigrationFixtureGeneratorTests.swift"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/supra-shipping-fixtures.XXXXXX")"
WORKTREES=()

cleanup() {
  for worktree in "${WORKTREES[@]:-}"; do
    git -C "$ROOT" worktree remove --force "$worktree" >/dev/null 2>&1 || true
  done
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT INT TERM

mkdir -p "$DEST"

# seed-version|immutable source ref|expected commit|optional migration cutoff
FIXTURES=(
  "v1.4.1|v1.4.1|b664db0930e0476f3890aea38de3b2561f5acc2c|"
  "v1.5.2|v1.5.2|583d18e5ad8770525c23bea3c39e476f4575fa92|"
  "v1.8.0|v1.8.0|ecc5c98b2db27959537626e5d197b90b307d23e8|"
  "v2.0.0|v2.0.0|4951c4253a6de840447aa433a646dbf8bff05980|"
  "v2.1.0|v2.1.0|c21cff69d7268a21724853cad4396bb0d8678a84|"
  "v2.1.3|v2.1.3|67f8707fcd3d2e6c151b244919f2a065ce1ab5ff|"
  "v2.2.0|v2.2.0|4c2a8ff21d5765751651a82129304f1bc6257029|"
  "latest-minus-one|63cf63f32a78aa76eb2edd13ab5a53119fcc7616|63cf63f32a78aa76eb2edd13ab5a53119fcc7616|v056_add_document_blob_integrity"
)

for specification in "${FIXTURES[@]}"; do
  IFS='|' read -r seed_version source_ref expected_sha stop_at <<< "$specification"
  actual_sha="$(git -C "$ROOT" rev-parse "${source_ref}^{commit}")"
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    echo "Ref $source_ref resolved to $actual_sha, expected $expected_sha" >&2
    exit 1
  fi

  safe_name="${seed_version//./-}"
  worktree="$TEMP_ROOT/worktree-$safe_name"
  database="$TEMP_ROOT/$safe_name.sqlite"
  compressed="$DEST/$safe_name.sqlite.gz"
  git -C "$ROOT" worktree add --detach "$worktree" "$actual_sha" >/dev/null
  WORKTREES+=("$worktree")
  cp "$HELPER" "$worktree/Packages/SupraStore/Tests/SupraStoreTests/ShippingMigrationFixtureGeneratorTests.swift"

  generator_environment=(
    "SUPRA_FIXTURE_OUTPUT=$database"
    "SUPRA_FIXTURE_SEED_VERSION=$seed_version"
  )
  if [[ -n "$stop_at" ]]; then
    generator_environment+=("SUPRA_FIXTURE_STOP_AT_MIGRATION=$stop_at")
  fi
  env "${generator_environment[@]}" \
    DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}" \
    swift test \
      --package-path "$worktree/Packages/SupraStore" \
      --filter ShippingMigrationFixtureGeneratorTests/testGenerateSyntheticFixture

  gzip -9 -n -c "$database" > "$compressed"
  git -C "$ROOT" worktree remove --force "$worktree" >/dev/null
done

echo "Generated ${#FIXTURES[@]} synthetic shipping migration fixtures in $DEST"
echo "Update manifest.json with the generated SHA-256 values and migration lists, then run the fixture tests."
