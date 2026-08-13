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

# T-SETUP-12 expected RED: hardware-derived model suitability is not yet an
# independently owned product claim, so its exact policy/test anchors can drift.
run_case \
  "local AI hardware recommendation claim is registered" \
  0 \
  'Packages/SupraSessions/Tests/SupraSessionsTests/LocalAIRecommendationPolicyTests.swift' \
  awk '
    /^  - id: "LOCAL-AI-HARDWARE-RECOMMENDATION"/ { in_claim = 1 }
    in_claim { print }
    in_claim && /^    publication_anchor:/ { exit }
  ' "$claims"

claims_without_local_ai_recommendation="${temporary_dir}/claims-without-local-ai-recommendation.yml"
awk '
  /^  - id: "LOCAL-AI-HARDWARE-RECOMMENDATION"/ { removing = 1; next }
  removing && /^  - id:/ { removing = 0 }
  !removing { print }
' "$claims" >"$claims_without_local_ai_recommendation"
run_case \
  "local AI hardware recommendation cannot disappear" \
  1 \
  'required claim topic is missing: local-ai-hardware-recommendation' \
  env SUPRA_CLAIMS_FILE="$claims_without_local_ai_recommendation" bash "$verifier"

# T-RST-H10 expected RED: the public restore safety guarantees have no owned,
# versioned entries in the controlled claims inventory, so drift is not gated.
run_case \
  "quiesced restore staging claim is registered" \
  0 \
  'Apps/SupraAI/SupraAIUITests/RestoreSettingsUITests.swift' \
  awk '
    /^  - id: "RESTORE-QUIESCED-STAGING"/ { in_claim = 1 }
    in_claim { print }
    in_claim && /^    publication_anchor:/ { exit }
  ' "$claims"

run_case \
  "verified restore staging claim is registered" \
  0 \
  'Packages/SupraStore/Tests/SupraStoreTests/RestoreServiceTests.swift' \
  awk '
    /^  - id: "RESTORE-VERIFIED-STAGING"/ { in_claim = 1 }
    in_claim { print }
    in_claim && /^    publication_anchor:/ { exit }
  ' "$claims"

run_case \
  "cold-start restore recovery claim is registered" \
  0 \
  'Packages/SupraStore/Tests/SupraStoreTests/RestoreActivationServiceTests.swift' \
  awk '
    /^  - id: "RESTORE-COLD-START-RECOVERY"/ { in_claim = 1 }
    in_claim { print }
    in_claim && /^    publication_anchor:/ { exit }
  ' "$claims"

# Expected RED: app-start ordering and the recovery-required store boundary are
# implemented but have no independently owned, versioned claim or guard.
run_case \
  "cold-start restore ordering claim is registered" \
  0 \
  'Tests/Scripts/test-backup-restore-documentation.sh' \
  awk '
    /^  - id: "RESTORE-COLD-START-ORDER"/ { in_claim = 1 }
    in_claim { print }
    in_claim && /^    publication_anchor:/ { exit }
  ' "$claims"

# Expected RED: motion-specific assurances were appended to the older generic
# drafting claim while retaining its 2.2.0 version boundary.
run_case \
  "supported motion gate has a next-release controlled claim" \
  0 \
  'applicable_version: "Next release after 2.3.4"' \
  awk '
    /^  - id: "MOTION-DISMISSAL-PREFILE-GATE"/ { in_claim = 1 }
    in_claim { print }
    in_claim && /^    publication_anchor:/ { exit }
  ' "$claims"

# Expected RED: latest-minus-one still generated a pre-2.3.4 v058 schema even
# though v2.3.4 is the current published release and ships through v069.
run_case \
  "latest-minus-one generator targets the authenticated v2.3.4 tag" \
  0 \
  'latest-minus-one|v2.3.4|c0a2648b4c65c066f85eb6bf6ae702f9aa779864|' \
  grep -F \
    'latest-minus-one|v2.3.4|c0a2648b4c65c066f85eb6bf6ae702f9aa779864|' \
    "${repo_root}/Scripts/generate-shipping-migration-fixtures.sh"

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
