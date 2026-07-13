#!/usr/bin/env bash
set -euo pipefail

configuration="${1:-}"
if (( $# != 1 )) || [[ "$configuration" != "Debug" && "$configuration" != "Release" ]]; then
  printf 'Usage: %s Debug|Release\n' "$0" >&2
  exit 2
fi
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/SupraAI-DerivedData-${configuration}"
log_file="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/SupraAI-${configuration}.xcodebuild.log"
rm -rf "$derived_data"

set +e
xcodebuild \
  -workspace "${repo_root}/SupraAI.xcworkspace" \
  -scheme SupraAI \
  -configuration "$configuration" \
  -destination 'platform=macOS' \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  ONLY_ACTIVE_ARCH=YES \
  build 2>&1 | tee "$log_file"
pipeline_status=("${PIPESTATUS[@]}")
set -e
(( pipeline_status[0] == 0 )) || exit "${pipeline_status[0]}"
(( pipeline_status[1] == 0 )) || { printf '%s\n' 'ERROR: could not preserve the Xcode build log' >&2; exit "${pipeline_status[1]}"; }

SUPRA_PROJECT_ROOT="$repo_root" bash "${repo_root}/Scripts/verify-xcode-warnings.sh" "$log_file"
app="${derived_data}/Build/Products/${configuration}/SupraAI.app"
xpc="${app}/Contents/XPCServices/SupraRuntimeService.xpc"
[[ -d "$app" ]] || { printf 'ERROR: app product missing after %s build\n' "$configuration" >&2; exit 1; }
[[ -d "$xpc" ]] || { printf 'ERROR: embedded XPC product missing after %s build\n' "$configuration" >&2; exit 1; }
printf 'Unsigned %s app and embedded XPC build passed.\n' "$configuration"
