#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
xpc_test="${SUPRA_XPC_INTEGRATION_TEST_FILE:-${repo_root}/Apps/SupraAI/SupraAIUITests/RuntimeXPCIntegrationTests.swift}"
accessibility_test="${SUPRA_ACCESSIBILITY_SMOKE_TEST_FILE:-${repo_root}/Apps/SupraAI/SupraAIUITests/ResearchAuthoritiesUITests.swift}"
check_only=0
if [[ "${1:-}" == "--check" ]]; then
  check_only=1
  shift
fi
if (( $# != 0 )); then
  printf 'Usage: %s [--check]\n' "$0" >&2
  exit 2
fi
if [[ ! -f "$xpc_test" ]] || ! grep -Eq 'class[[:space:]]+RuntimeXPCIntegrationTests' "$xpc_test"; then
  printf '%s\n' 'ERROR: hosted XPC integration test is missing: SupraAIUITests/RuntimeXPCIntegrationTests' >&2
  exit 1
fi
if [[ ! -f "$accessibility_test" ]] \
    || ! grep -Fq 'testLegacyOutputWarningAnnouncesStatusAndUnavailableExport' "$accessibility_test" \
    || ! grep -Fq 'testLegacyBillingWarningAnnouncesReviewAndUnavailableExport' "$accessibility_test"; then
  printf '%s\n' 'ERROR: remediation accessibility smoke tests are missing' >&2
  exit 1
fi
printf '%s\n' 'Hosted XPC integration hook passed.'
(( check_only != 0 )) && exit 0

xcodebuild \
  -workspace "${repo_root}/SupraAI.xcworkspace" \
  -scheme SupraAI \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  -only-testing:SupraAIUITests/DraftingBlockedStateUITests \
  -only-testing:SupraAIUITests/ResearchAuthoritiesUITests/testLegacyOutputWarningAnnouncesStatusAndUnavailableExport \
  -only-testing:SupraAIUITests/ResearchAuthoritiesUITests/testLegacyBillingWarningAnnouncesReviewAndUnavailableExport \
  -only-testing:SupraAIUITests/RuntimeXPCIntegrationTests \
  test
