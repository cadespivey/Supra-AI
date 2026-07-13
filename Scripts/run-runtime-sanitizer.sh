#!/usr/bin/env bash
set -euo pipefail

kind="${1:-}"
case "$kind" in
  thread|address|undefined) ;;
  *) printf 'Usage: %s thread|address|undefined\n' "$0" >&2; exit 2 ;;
esac

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"

if [[ "$kind" == thread || "$kind" == address ]]; then
  DEVELOPER_DIR="$developer_dir" swift test \
    --package-path "${repo_root}/Packages/SupraRuntimeClient" \
    --disable-sandbox \
    "--sanitize=${kind}"
fi

derived_data="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/SupraAI-XPC-${kind}-${$}"
sanitizer_flag=()
case "$kind" in
  thread) sanitizer_flag=(-enableThreadSanitizer YES) ;;
  address) sanitizer_flag=(-enableAddressSanitizer YES) ;;
  undefined) sanitizer_flag=(-enableUndefinedBehaviorSanitizer YES) ;;
esac

DEVELOPER_DIR="$developer_dir" xcodebuild \
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
  "${sanitizer_flag[@]}" \
  -only-testing:SupraAIUITests/RuntimeXPCIntegrationTests/testHostedBoundaryLifecycle \
  test
