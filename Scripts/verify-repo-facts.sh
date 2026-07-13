#!/usr/bin/env bash
set -euo pipefail

repo_root="${SUPRA_REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
repo_root="$(cd "$repo_root" && pwd -P)"
pbxproj="${repo_root}/Apps/SupraAI/SupraAI.xcodeproj/project.pbxproj"
macos_workflow="${repo_root}/.github/workflows/macos-ci.yml"
scheduled_workflow="${repo_root}/.github/workflows/security-scheduled.yml"
status=0

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  status=1
}

[[ -f "$pbxproj" ]] || { printf '%s\n' 'ERROR: Xcode project source is missing' >&2; exit 1; }
bash "${repo_root}/Scripts/list-local-packages.sh" --verify || status=1
bash "${repo_root}/Scripts/verify-migration-sequence.sh" || status=1

temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT
expected_targets="${temporary_dir}/expected-targets.txt"
actual_targets="${temporary_dir}/actual-targets.txt"
printf '%s\n' SupraAI SupraAIUITests SupraRuntimeService | LC_ALL=C sort >"$expected_targets"
sed -n '/Begin PBXNativeTarget section/,/End PBXNativeTarget section/p' "$pbxproj" \
  | sed -nE 's/^[[:space:]]*name = ([^;]+);/\1/p' \
  | LC_ALL=C sort >"$actual_targets"
if ! cmp -s "$expected_targets" "$actual_targets"; then
  fail 'Xcode target inventory drifted; expected SupraAI, SupraAIUITests, and SupraRuntimeService'
fi

project_setting() {
  local identifier="$1"
  local key="$2"
  awk -v identifier="$identifier" -v key="$key" '
    index($0, identifier " /*") { candidate = 1 }
    candidate && /isa = XCBuildConfiguration;/ { configuration = 1 }
    candidate && configuration && index($0, key " = ") {
      value = $0
      sub(".*" key " = ", "", value)
      sub(";.*", "", value)
      print value
      exit
    }
    candidate && /^\t\t};$/ { candidate = 0; configuration = 0 }
  ' "$pbxproj"
}

app_debug_version="$(project_setting 5A0000000000000000000D03 MARKETING_VERSION)"
app_release_version="$(project_setting 5A0000000000000000000D04 MARKETING_VERSION)"
xpc_debug_version="$(project_setting 5A0000000000000000000D05 MARKETING_VERSION)"
xpc_release_version="$(project_setting 5A0000000000000000000D06 MARKETING_VERSION)"
app_debug_build="$(project_setting 5A0000000000000000000D03 CURRENT_PROJECT_VERSION)"
app_release_build="$(project_setting 5A0000000000000000000D04 CURRENT_PROJECT_VERSION)"
xpc_debug_build="$(project_setting 5A0000000000000000000D05 CURRENT_PROJECT_VERSION)"
xpc_release_build="$(project_setting 5A0000000000000000000D06 CURRENT_PROJECT_VERSION)"

[[ -n "$app_debug_version" && "$app_debug_version" == "$app_release_version" \
  && "$app_debug_version" == "$xpc_debug_version" && "$app_debug_version" == "$xpc_release_version" ]] \
  || fail 'Debug/Release app and XPC marketing versions must agree'
[[ "$app_debug_build" =~ ^[0-9]+$ && "$app_debug_build" == "$app_release_build" ]] \
  || fail 'Debug/Release app build numbers must agree and be numeric'
[[ "$xpc_debug_build" =~ ^[0-9]+$ && "$xpc_debug_build" == "$xpc_release_build" ]] \
  || fail 'Debug/Release XPC build numbers must agree and be numeric'

appcast="${repo_root}/website/public/appcast.xml"
website_constants="${repo_root}/website/lib/constants.ts"
appcast_version="$(sed -nE 's|.*<sparkle:shortVersionString>([^<]+)</sparkle:shortVersionString>.*|\1|p' "$appcast" | head -1)"
appcast_build="$(sed -nE 's|.*<sparkle:version>([^<]+)</sparkle:version>.*|\1|p' "$appcast" | head -1)"
[[ "$appcast_version" == "$app_debug_version" && "$appcast_build" == "$app_debug_build" ]] \
  || fail 'the newest appcast item must match the app marketing version and build number'
grep -Fq "FALLBACK_RELEASE_TAG = \"v${app_debug_version}\"" "$website_constants" \
  || fail 'website fallback release tag does not match the app version'
grep -Fq "FALLBACK_RELEASE_VERSION = \"${app_debug_version}\"" "$website_constants" \
  || fail 'website fallback release version does not match the app version'

required_workflows=(
  .github/workflows/deploy-website.yml
  .github/workflows/macos-ci.yml
  .github/workflows/security-scheduled.yml
  .github/workflows/verify-model-ids.yml
  .github/workflows/verify-public-repository-assets.yml
)
for relative in "${required_workflows[@]}"; do
  [[ -f "${repo_root}/${relative}" ]] || fail "required workflow is missing: ${relative}"
done

if [[ -f "$macos_workflow" ]]; then
  expected_packages="${temporary_dir}/expected-packages.txt"
  workflow_packages="${temporary_dir}/workflow-packages.txt"
  bash "${repo_root}/Scripts/list-local-packages.sh" | LC_ALL=C sort >"$expected_packages"
  awk '
    /^[[:space:]]+package:$/ { packages = 1; next }
    packages && /^[[:space:]]+-[[:space:]]+[A-Za-z0-9_-]+[[:space:]]*$/ {
      value = $0
      sub(/^[[:space:]]+-[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      print value
      next
    }
    packages { exit }
  ' "$macos_workflow" | LC_ALL=C sort >"$workflow_packages"
  cmp -s "$expected_packages" "$workflow_packages" \
    || fail 'macOS CI package matrix must contain the exact fixed 14-package inventory'

  for job in inventory swift-packages app-build app-smoke migration-fixtures website security dependency-review; do
    grep -Eq "^  ${job}:" "$macos_workflow" || fail "macOS CI job is missing: ${job}"
  done
fi

if [[ -f "$scheduled_workflow" ]]; then
  grep -Eq '^[[:space:]]+schedule:' "$scheduled_workflow" || fail 'scheduled security workflow has no schedule trigger'
  grep -Fq 'Scripts/verify-model-ids.sh' "$scheduled_workflow" || fail 'scheduled security workflow omits live model-ID verification'
  grep -Fq 'Scripts/verify-public-repository-assets.sh' "$scheduled_workflow" || fail 'scheduled security workflow omits public-ref metadata verification'
fi

while IFS=: read -r workflow line_number line; do
  reference="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]+//')"
  if [[ ! "$reference" =~ ^[^[:space:]#]+@[0-9a-f]{40}([[:space:]]*#[[:space:]]*.*)?$ ]]; then
    fail "GitHub Action is not pinned to a full commit SHA: ${workflow#${repo_root}/}:${line_number}"
  fi
done < <(grep -nH -E '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]+' "${repo_root}/.github/workflows/"*.yml || true)

if grep -RqsE '^[[:space:]]*pull_request_target:' "${repo_root}/.github/workflows"; then
  fail 'pull_request_target is prohibited for repository CI'
fi

bash "${repo_root}/Scripts/verify-entitlements.sh" || status=1
bash "${repo_root}/Scripts/verify-public-font-license.sh" || status=1

if (( status != 0 )); then
  printf '%s\n' 'Repository facts verification failed.' >&2
  exit 1
fi
printf 'Repository facts passed: 3 targets, 14 packages, app %s (%s), XPC build %s.\n' \
  "$app_debug_version" "$app_debug_build" "$xpc_debug_build"
