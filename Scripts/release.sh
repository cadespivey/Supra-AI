#!/usr/bin/env bash
# Protected, fail-closed release entrypoint. It performs no repository source
# edits: version/build values are build inputs and every published byte is tied
# to the reviewed source SHA by a signed preflight manifest.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Scripts/lib/release-common.sh
source "${root}/Scripts/lib/release-common.sh"

usage() {
  printf '%s\n' \
    'Usage: release.sh --repository OWNER/REPO --version X.Y.Z --build N --expected-sha SHA --ci-run-id ID [--no-publish]' >&2
  exit 2
}

repository=''; version=''; build_number=''; expected_sha=''; ci_run_id=''; publish=1
while (( $# > 0 )); do
  case "$1" in
    --repository) repository="${2:-}"; shift 2 ;;
    --version) version="${2:-}"; shift 2 ;;
    --build) build_number="${2:-}"; shift 2 ;;
    --expected-sha) expected_sha="${2:-}"; shift 2 ;;
    --ci-run-id) ci_run_id="${2:-}"; shift 2 ;;
    --no-publish) publish=0; shift ;;
    *) usage ;;
  esac
done

[[ "$ci_run_id" =~ ^[1-9][0-9]*$ ]] || usage
release_validate_repository "$repository"
release_validate_version "$version"
release_validate_build "$build_number"
release_validate_sha "$expected_sha"
[[ "${SUPRA_RELEASE_TESTING:-0}" != '1' ]] \
  || release_die 'the production release entrypoint cannot run in mock-testing mode'
release_require_protected_environment
[[ "${SUPRA_RELEASE_ISOLATED_RUNNER:-0}" == '1' ]] \
  || release_die 'signed release qualification requires the dedicated isolated release runner'

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
team_id="${SUPRA_RELEASE_TEAM_ID:-2DP657YB3K}"
notary_profile="${NOTARY_PROFILE:-supra-notary}"
sign_identity="${SIGN_IDENTITY:-Developer ID Application}"
manifest_identity="${MANIFEST_SIGNING_IDENTITY:-$sign_identity}"
sparkle_bin="${SPARKLE_BIN:?SPARKLE_BIN must identify the reviewed Sparkle tools}"
sign_update="${sparkle_bin}/sign_update"
smoke_model_sha="${SUPRA_RELEASE_SMOKE_MODEL_SHA256:?SUPRA_RELEASE_SMOKE_MODEL_SHA256 is required}"
smoke_model_directory="${SUPRA_RELEASE_SMOKE_MODEL_DIRECTORY:?SUPRA_RELEASE_SMOKE_MODEL_DIRECTORY is required}"
release_validate_digest "$smoke_model_sha"
[[ "$smoke_model_directory" == /* && -d "$smoke_model_directory" \
  && ! -L "$smoke_model_directory" ]] \
  || release_die 'SUPRA_RELEASE_SMOKE_MODEL_DIRECTORY must be an absolute non-symlink directory'
export SUPRA_RELEASE_SMOKE_MODEL_DIRECTORY="$smoke_model_directory"
release_require_command openssl

temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT
source_manifest="${temporary_dir}/source-preflight.json"

bash "${root}/Scripts/release-preflight.sh" \
  --repo-root "$root" --repository "$repository" --version "$version" \
  --build "$build_number" --expected-sha "$expected_sha" \
  --ci-run-id "$ci_run_id" --output "$source_manifest"

build_root="${root}/build/release"
archive="${build_root}/SupraAI.xcarchive"
export_dir="${build_root}/export"
app="${export_dir}/SupraAI.app"
zip="${build_root}/SupraAI-${version}.zip"
dmg="${build_root}/SupraAI-${version}.dmg"
stage="${build_root}/dmg-stage"
manifest="${build_root}/preflight-manifest.json"
manifest_signature="${manifest}.cms"
smoke_result="${build_root}/signed-runtime-smoke.json"

rm -rf "$build_root"
mkdir -p "$build_root"
cp "$source_manifest" "${build_root}/source-preflight.json"

printf '%s\n' 'Building signed Release archive from unchanged source…'
xcodebuild archive \
  -workspace "${root}/SupraAI.xcworkspace" \
  -scheme SupraAI \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive" \
  MARKETING_VERSION="$version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  ENABLE_HARDENED_RUNTIME=YES
xcodebuild -exportArchive \
  -archivePath "$archive" \
  -exportPath "$export_dir" \
  -exportOptionsPlist "${root}/Scripts/ExportOptions.plist"

[[ -d "$app" ]] || release_die 'archive export did not produce SupraAI.app'
sparkle_framework="${app}/Contents/Frameworks/Sparkle.framework/Versions/B"
for helper in XPCServices/Installer.xpc Autoupdate Updater.app; do
  [[ -e "${sparkle_framework}/${helper}" ]] || release_die "Sparkle helper is missing: $helper"
  codesign --verify --strict "${sparkle_framework}/${helper}" >/dev/null 2>&1 \
    || release_die "Sparkle helper signature is invalid: $helper"
done

printf '%s\n' 'Submitting signed app for notarization and stapling…'
notary_zip="${temporary_dir}/SupraAI-notary.zip"
ditto -c -k --keepParent "$app" "$notary_zip"
xcrun notarytool submit "$notary_zip" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"

printf '%s\n' 'Creating, signing, notarizing, and stapling DMG…'
mkdir -p "$stage"
cp -R "$app" "$stage/"
ln -s /Applications "${stage}/Applications"
hdiutil create -volname "Supra AI ${version}" -srcfolder "$stage" -ov -format UDZO "$dmg"
codesign --force --timestamp --sign "$sign_identity" "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"

printf '%s\n' 'Packaging the exact stapled app bytes…'
ditto -c -k --keepParent "$app" "$zip"

# Bind the smoke to the exact signed app tree before executing any app code.
app_sha="$(release_directory_digest "$app")"
release_validate_digest "$app_sha"
smoke_nonce="$(openssl rand -hex 32)"
[[ "$smoke_nonce" =~ ^[0-9a-f]{64}$ ]] \
  || release_die 'unable to generate a fresh lowercase 64-hex smoke nonce'

bash "${root}/Scripts/run-signed-release-smoke.sh" \
  --app "$app" --source-sha "$expected_sha" --app-sha "$app_sha" \
  --model-sha "$smoke_model_sha" --version "$version" \
  --build "$build_number" --nonce "$smoke_nonce" --output "$smoke_result"
bash "${root}/Scripts/verify-signed-runtime-smoke-result.sh" \
  --result "$smoke_result" --source-sha "$expected_sha" \
  --app-sha "$app_sha" --model-sha "$smoke_model_sha" \
  --version "$version" --build "$build_number" --nonce "$smoke_nonce"

# The smoke host must not bless mutations it caused. Recheck the app tree and
# its nested code signatures before the final manifest is created and signed.
post_smoke_app_sha="$(release_directory_digest "$app")"
[[ "$post_smoke_app_sha" == "$app_sha" ]] \
  || release_die 'signed app tree changed while running the release smoke'
codesign --verify --deep --strict "$app" >/dev/null 2>&1 \
  || release_die 'signed app signature changed while running the release smoke'
post_smoke_xpc="${app}/Contents/XPCServices/SupraRuntimeService.xpc"
codesign --verify --strict "$post_smoke_xpc" >/dev/null 2>&1 \
  || release_die 'runtime service signature changed while running the release smoke'

bash "${root}/Scripts/create-preflight-manifest.sh" \
  --source-manifest "$source_manifest" --app "$app" --zip "$zip" --dmg "$dmg" \
  --team-id "$team_id" --smoke-result "$smoke_result" --output "$manifest"
# security cms -S -N resolves nicknames unreliably and silently falls back to
# an arbitrary default identity; the Swift signer selects by exact certificate
# label and validates the Team ID before signing.
swift "${root}/Scripts/sign-release-manifest.swift" \
  --identity "$manifest_identity" --team-id "$team_id" \
  --input "$manifest" --output "$manifest_signature"

bash "${root}/Scripts/verify-release-artifacts.sh" \
  --app "$app" --zip "$zip" --dmg "$dmg" \
  --manifest "$manifest" --manifest-signature "$manifest_signature" \
  --version "$version" --build "$build_number" --source-sha "$expected_sha" --team-id "$team_id"

if (( publish == 0 )); then
  printf 'Signed release-candidate rehearsal passed for v%s (%s) at %s; no GitHub release, tag, upload, appcast, push, or deployment was attempted.\n' \
    "$version" "$build_number" "$expected_sha"
  exit 0
fi

bash "${root}/Scripts/publish-release-transaction.sh" \
  --repo-root "$root" --repository "$repository" --source-sha "$expected_sha" \
  --version "$version" --build "$build_number" --zip "$zip" --dmg "$dmg" \
  --manifest "$manifest" --manifest-signature "$manifest_signature" \
  --appcast-in "${root}/website/public/appcast.xml" \
  --constants-in "${root}/website/lib/constants.ts" --sign-update "$sign_update"

printf 'Release v%s (%s) completed from exact source %s.\n' "$version" "$build_number" "$expected_sha"
