#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
verifier="${repo_root}/Scripts/verify-product-claims.sh"
claims="${repo_root}/Docs/Verified-Product-Claims.yml"
temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT
failures=0

run_case() {
  local name="$1"
  local expected_status="$2"
  local expected_text="$3"
  shift 3
  local output_file="${temporary_dir}/output-${RANDOM}.txt"
  local status=0

  "$@" >"$output_file" 2>&1 || status=$?
  if [[ "$status" -ne "$expected_status" ]]; then
    printf 'FAIL: %s: expected status %s, got %s\n' "$name" "$expected_status" "$status" >&2
    sed 's/^/  | /' "$output_file" >&2
    failures=$((failures + 1))
  elif ! grep -Fq -- "$expected_text" "$output_file"; then
    printf 'FAIL: %s: expected output to contain: %s\n' "$name" "$expected_text" >&2
    sed 's/^/  | /' "$output_file" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s\n' "$name"
  fi
}

# Expected RED before implementation: neither the inventory nor verifier exists.
run_case \
  "shipping claims inventory matches executable facts" \
  0 \
  "Product claims verification passed" \
  bash "$verifier"

run_case \
  "citation semantics claim retains broad proposition verification" \
  0 \
  "Packages/SupraDocuments/Tests/SupraDocumentsTests/DocumentSupportVerifierTests.swift" \
  awk '
    /^  - id: "CITATION-PROPOSITION-SEMANTICS"/ { in_claim = 1; next }
    in_claim && /^    verification:/ { print; exit }
  ' "$claims"

drifted_count="${temporary_dir}/drifted-count.yml"
awk '!changed && sub(/expected: "14"/, "expected: \"13\"") { changed = 1 } { print }' \
  "$claims" >"$drifted_count"
run_case \
  "package-count drift fails closed" \
  1 \
  "package inventory claim expected 13, executable inventory is 14" \
  env SUPRA_CLAIMS_FILE="$drifted_count" bash "$verifier"

drifted_wording="${temporary_dir}/drifted-wording.yml"
awk '!changed && sub(/The repository contains exactly 14 local Swift packages/, "The repository contains exactly thirteen local Swift packages") { changed = 1 } { print }' \
  "$claims" >"$drifted_wording"
run_case \
  "unpublished wording fails closed" \
  1 \
  "approved wording is absent from publication anchor" \
  env SUPRA_CLAIMS_FILE="$drifted_wording" bash "$verifier"

missing_owner="${temporary_dir}/missing-owner.yml"
awk 'BEGIN { removed = 0 } !removed && /^    owner:/ { removed = 1; next } { print }' \
  "$claims" >"$missing_owner"
run_case \
  "a claim missing its owner fails closed" \
  1 \
  "missing required field owner" \
  env SUPRA_CLAIMS_FILE="$missing_owner" bash "$verifier"

hardcoded_release_version="${temporary_dir}/hardcoded-release-version.yml"
awk '!changed && sub(/expected: "appcast-latest"/, "expected: \"2.2.0\"") { changed = 1 } { print }' \
  "$claims" >"$hardcoded_release_version"
run_case \
  "a hardcoded published release version claim fails closed" \
  1 \
  "release-version claim must use appcast-latest" \
  env SUPRA_CLAIMS_FILE="$hardcoded_release_version" bash "$verifier"

stale_security_support="${temporary_dir}/stale-security-support.yml"
awk '!changed && sub(/expected: "2.3.x"/, "expected: \"1.4.x\"") { changed = 1 } { print }' \
  "$claims" >"$stale_security_support"
run_case \
  "a stale security support line fails closed" \
  1 \
  "security support claim expected 1.4.x, project marketing version resolves to 2.3.x" \
  env SUPRA_CLAIMS_FILE="$stale_security_support" bash "$verifier"

if (( failures != 0 )); then
  printf 'Product claims verifier tests failed: %d\n' "$failures" >&2
  exit 1
fi

printf '%s\n' 'All product claims verifier tests passed.'
