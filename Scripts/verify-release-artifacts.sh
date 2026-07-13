#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Scripts/lib/release-common.sh
source "${root}/Scripts/lib/release-common.sh"

usage() {
  printf '%s\n' \
    'Usage: verify-release-artifacts.sh --app APP --zip ZIP --dmg DMG --manifest JSON --manifest-signature CMS --version X.Y.Z --build N --source-sha SHA --team-id TEAM' >&2
  exit 2
}

app=''; zip=''; dmg=''; manifest=''; manifest_signature=''
version=''; build=''; source_sha=''; team_id=''
while (( $# > 0 )); do
  case "$1" in
    --app) app="${2:-}"; shift 2 ;;
    --zip) zip="${2:-}"; shift 2 ;;
    --dmg) dmg="${2:-}"; shift 2 ;;
    --manifest) manifest="${2:-}"; shift 2 ;;
    --manifest-signature) manifest_signature="${2:-}"; shift 2 ;;
    --version) version="${2:-}"; shift 2 ;;
    --build) build="${2:-}"; shift 2 ;;
    --source-sha) source_sha="${2:-}"; shift 2 ;;
    --team-id) team_id="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -d "$app" && -f "$zip" && -f "$dmg" && -f "$manifest" && -f "$manifest_signature" ]] || usage
release_validate_version "$version"
release_validate_build "$build"
release_validate_sha "$source_sha"
[[ "$team_id" =~ ^[A-Z0-9]{10}$ ]] || release_die 'invalid release Team ID'
for command in jq shasum codesign xcrun spctl hdiutil security ditto unzip plutil; do
  release_require_command "$command"
done

temporary_dir="$(mktemp -d)"
mountpoint="${temporary_dir}/dmg"
mounted=0
cleanup() {
  if (( mounted != 0 )); then
    hdiutil detach "$mountpoint" -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$temporary_dir"
}
trap cleanup EXIT

decoded_manifest="${temporary_dir}/decoded-manifest.json"
release_verify_cms_manifest "$manifest_signature" "$manifest" "$team_id" "$decoded_manifest"

jq -e \
  --arg version "$version" --arg build "$build" --arg source "$source_sha" --arg team "$team_id" '
  .schemaVersion == 1 and .manifestKind == "supra-release-preflight" and
  .release.version == $version and .release.build == $build and
  .release.tag == ("v" + $version) and
  .reviewedBuildMetadata.marketingVersion == $version and
  .reviewedBuildMetadata.currentProjectVersion == $build and
  .source.sha == $source and .source.originMain == $source and
  .signing.teamID == $team and
  .signing.appBundleIdentifier == "ai.supra.SupraAI" and
  .signing.xpcBundleIdentifier == "ai.supra.SupraAI.SupraRuntimeService" and
  .signing.hardenedRuntimeRequired == true and .signing.notarizationRequired == true and
  (.ciRuns | length >= 1) and
  (.ciRuns | all(.[]; .headSha == $source and .conclusion == "success")) and
  (.artifacts | map(.kind) | sort == ["app", "dmg", "zip"])
' "$manifest" >/dev/null || release_die 'preflight manifest metadata does not match requested release'

expected_artifact_value() {
  local kind="$1" key="$2"
  jq -r --arg kind "$kind" --arg key "$key" '.artifacts[] | select(.kind == $kind) | .[$key]' "$manifest"
}

manifest_app_sha="$(expected_artifact_value app sha256)"
release_validate_digest "$manifest_app_sha"
release_verify_embedded_smoke_attestation \
  "$manifest" "$source_sha" "$manifest_app_sha" "$version" "$build"

verify_file_manifest_entry() {
  local kind="$1" path="$2"
  local expected_name expected_sha expected_size actual_sha actual_size
  expected_name="$(expected_artifact_value "$kind" name)"
  expected_sha="$(expected_artifact_value "$kind" sha256)"
  expected_size="$(expected_artifact_value "$kind" sizeBytes)"
  [[ "$(basename "$path")" == "$expected_name" ]] || release_die "${kind} filename does not match manifest"
  actual_sha="$(release_sha256 "$path")"
  actual_size="$(release_file_size "$path")"
  [[ "$actual_sha" == "$expected_sha" && "$actual_size" == "$expected_size" ]] \
    || release_die 'artifact digest does not match manifest'
}

app_sha="$(release_directory_digest "$app")"
app_size="$(release_directory_size "$app")"
[[ "$app_sha" == "$(expected_artifact_value app sha256)" \
  && "$app_size" == "$(expected_artifact_value app sizeBytes)" ]] \
  || release_die 'artifact digest does not match manifest'
[[ "$(basename "$app")" == "$(expected_artifact_value app name)" ]] \
  || release_die 'app filename does not match manifest'
verify_file_manifest_entry zip "$zip"
verify_file_manifest_entry dmg "$dmg"

xpc="${app}/Contents/XPCServices/SupraRuntimeService.xpc"
[[ -d "$xpc" ]] || release_die 'embedded runtime service is missing'
codesign --verify --deep --strict --verbose=2 "$app" >/dev/null 2>&1 \
  || release_die 'code signature verification failed for app'
codesign --verify --strict --verbose=2 "$xpc" >/dev/null 2>&1 \
  || release_die 'code signature verification failed for runtime service'
codesign --verify --strict --verbose=2 "$dmg" >/dev/null 2>&1 \
  || release_die 'code signature verification failed for DMG'

for signed_path in "$app" "$xpc"; do
  signature_details="$(codesign -dv --verbose=4 "$signed_path" 2>&1)" \
    || release_die 'unable to inspect code signature metadata'
  printf '%s\n' "$signature_details" | grep -Fq "TeamIdentifier=${team_id}" \
    || release_die 'code signature Team ID mismatch'
  printf '%s\n' "$signature_details" | grep -Eq 'flags=.*\(.*runtime.*\)' \
    || release_die 'hardened runtime flag is missing'
done
dmg_signature_details="$(codesign -dv --verbose=4 "$dmg" 2>&1)" \
  || release_die 'unable to inspect DMG signature metadata'
printf '%s\n' "$dmg_signature_details" | grep -Fq "TeamIdentifier=${team_id}" \
  || release_die 'DMG code signature Team ID mismatch'

app_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${app}/Contents/Info.plist")"
xpc_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${xpc}/Contents/Info.plist")"
app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${app}/Contents/Info.plist")"
app_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${app}/Contents/Info.plist")"
xpc_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${xpc}/Contents/Info.plist")"
xpc_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${xpc}/Contents/Info.plist")"
[[ "$app_bundle_id" == 'ai.supra.SupraAI' && "$xpc_bundle_id" == 'ai.supra.SupraAI.SupraRuntimeService' ]] \
  || release_die 'signed bundle identifier mismatch'
[[ "$app_version" == "$version" && "$xpc_version" == "$version" \
  && "$app_build" == "$build" && "$xpc_build" == "$build" ]] \
  || release_die 'signed bundle version/build does not match manifest'

app_entitlements="${temporary_dir}/app.entitlements"
xpc_entitlements="${temporary_dir}/xpc.entitlements"
codesign -d --entitlements :- "$app" >"$app_entitlements" 2>/dev/null \
  || release_die 'unable to read app entitlements'
codesign -d --entitlements :- "$xpc" >"$xpc_entitlements" 2>/dev/null \
  || release_die 'unable to read runtime-service entitlements'
bash "${root}/Scripts/verify-entitlements.sh" --app "$app_entitlements" --service "$xpc_entitlements" >/dev/null \
  || release_die 'signed entitlement verification failed'

xcrun stapler validate "$app" >/dev/null 2>&1 || release_die 'staple validation failed for app'
xcrun stapler validate "$dmg" >/dev/null 2>&1 || release_die 'staple validation failed for DMG'
spctl --assess --type execute --verbose=4 "$app" >/dev/null 2>&1 \
  || release_die 'Gatekeeper rejected signed app'
spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg" >/dev/null 2>&1 \
  || release_die 'Gatekeeper rejected signed DMG'

if unzip -Z1 "$zip" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
  release_die 'ZIP contains an absolute or traversing path'
fi
zip_root="${temporary_dir}/zip"
mkdir -p "$zip_root"
ditto -x -k "$zip" "$zip_root"
zip_app="${zip_root}/SupraAI.app"
[[ -d "$zip_app" ]] || release_die 'ZIP does not contain SupraAI.app at its root'
[[ "$(release_directory_digest "$zip_app")" == "$app_sha" ]] \
  || release_die 'ZIP app bytes do not match signed app manifest'
bash "${root}/Scripts/verify-release-artifact-contents.sh" "$zip_root" >/dev/null \
  || release_die 'ZIP content policy verification failed'

mkdir -p "$mountpoint"
hdiutil attach "$dmg" -readonly -nobrowse -mountpoint "$mountpoint" >/dev/null \
  || release_die 'unable to mount release DMG for verification'
mounted=1
dmg_app="${mountpoint}/SupraAI.app"
[[ -d "$dmg_app" ]] || release_die 'DMG does not contain SupraAI.app at its root'
[[ "$(release_directory_digest "$dmg_app")" == "$app_sha" ]] \
  || release_die 'DMG app bytes do not match signed app manifest'
bash "${root}/Scripts/verify-release-artifact-contents.sh" "$mountpoint" >/dev/null \
  || release_die 'DMG content policy verification failed'

printf 'Release artifacts verified for v%s (%s) at %s.\n' "$version" "$build" "$source_sha"
