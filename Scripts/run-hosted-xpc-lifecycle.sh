#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${1:-}" == '--check' ]]; then
  exec "${repo_root}/Scripts/verify-runtime-xpc-boundary.sh"
fi
if (( $# != 0 )); then
  printf 'Usage: %s [--check]\n' "$0" >&2
  exit 2
fi

derived_data="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/SupraAI-XPC-Lifecycle-${$}"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}" \
xcodebuild \
  -project "${repo_root}/Apps/SupraAI/SupraAI.xcodeproj" \
  -scheme SupraAI \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  -only-testing:SupraAIUITests/RuntimeXPCIntegrationTests \
  test

"${repo_root}/Scripts/verify-runtime-xpc-boundary.sh" \
  "${derived_data}/Build/Products/Debug/SupraAI.app"
