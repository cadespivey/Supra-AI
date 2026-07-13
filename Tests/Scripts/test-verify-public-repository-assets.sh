#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
verifier="${repo_root}/Scripts/verify-public-repository-assets.sh"
fixtures="${repo_root}/Tests/Scripts/Fixtures/PublicRepositoryAssets"
failures=0

run_case() {
  local name="$1"
  local fixture="$2"
  local expected_status="$3"
  local expected_text="$4"
  local unexpected_text="${5:-}"
  local output_file
  local status

  output_file="$(mktemp)"
  if PUBLIC_ASSET_FIXTURE_DIR="${fixtures}/${fixture}" \
      bash "$verifier" example/synthetic >"$output_file" 2>&1; then
    status=0
  else
    status=$?
  fi

  if [[ "$status" -ne "$expected_status" ]]; then
    printf 'FAIL: %s: expected status %s, got %s\n' "$name" "$expected_status" "$status" >&2
    sed 's/^/  | /' "$output_file" >&2
    failures=$((failures + 1))
  elif ! grep -Fq -- "$expected_text" "$output_file"; then
    printf 'FAIL: %s: expected output to contain: %s\n' "$name" "$expected_text" >&2
    sed 's/^/  | /' "$output_file" >&2
    failures=$((failures + 1))
  elif [[ -n "$unexpected_text" ]] && grep -Fq -- "$unexpected_text" "$output_file"; then
    printf 'FAIL: %s: output unexpectedly contained: %s\n' "$name" "$unexpected_text" >&2
    sed 's/^/  | /' "$output_file" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s\n' "$name"
  fi

  rm -f "$output_file"
}

# Expected RED before implementation: the metadata-only verifier does not exist.
run_case \
  "clean advertised refs and release metadata" \
  clean \
  0 \
  "Public repository asset metadata check passed." \
  "ERROR:"

run_case \
  "reserved path in a branch tree" \
  prohibited-path \
  1 \
  "website/public/fonts/synthetic-guard.woff2"

run_case \
  "renamed deny-listed object" \
  prohibited-object \
  1 \
  "known prohibited object 2977a86366333533d454e8362956dbc2ca273836"

run_case \
  "advertised pull ref is traversed" \
  prohibited-pull-ref \
  1 \
  "refs/pull/51/head:website/public/fonts/pull-ref-guard.woff2"

run_case \
  "prohibited release asset name" \
  prohibited-release \
  1 \
  "release v9.9.9 asset Equity-A-synthetic.woff2"

if (( failures != 0 )); then
  printf 'Public repository asset verifier tests failed: %d\n' "$failures" >&2
  exit 1
fi

printf '%s\n' 'All public repository asset verifier tests passed.'
