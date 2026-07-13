#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
scripts="${repo_root}/Scripts"
fixture_command="${repo_root}/Tests/Scripts/Fixtures/Release/mock-command.sh"
temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT
mock_bin="${temporary_dir}/bin"
mkdir -p "$mock_bin"
for command in credential-gate font-gate release-gate website-gate signed-smoke gh sign_update codesign xcrun spctl hdiutil security appcast-publish appcast-rollback curl; do
  ln -s "$fixture_command" "${mock_bin}/${command}"
done
mock_log="${temporary_dir}/release-commands.log"
: >"$mock_log"
failures=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

run_case() {
  local name="$1"
  local expected_status="$2"
  local expected_text="$3"
  shift 3
  local output="${temporary_dir}/case-${RANDOM}.log"
  local result=0
  "$@" >"$output" 2>&1 || result=$?
  if [[ "$result" -ne "$expected_status" ]]; then
    fail "${name}: expected status ${expected_status}, got ${result}"
    sed 's/^/  | /' "$output" >&2
  elif ! grep -Fq -- "$expected_text" "$output"; then
    fail "${name}: expected output to contain: ${expected_text}"
    sed 's/^/  | /' "$output" >&2
  else
    printf 'PASS: %s\n' "$name"
  fi
}

make_source_repo() {
  local name="$1"
  SOURCE_REPO="${temporary_dir}/source-${name}"
  ORIGIN_REPO="${temporary_dir}/origin-${name}.git"
  mkdir -p \
    "${SOURCE_REPO}/Apps/SupraAI/SupraAI.xcodeproj" \
    "${SOURCE_REPO}/SupraAI.xcworkspace/xcshareddata/swiftpm" \
    "${SOURCE_REPO}/website/public" \
    "${SOURCE_REPO}/website/lib"
  printf '%s\n' \
    'MARKETING_VERSION = 2.2.0;' \
    'CURRENT_PROJECT_VERSION = 386;' \
    >"${SOURCE_REPO}/Apps/SupraAI/SupraAI.xcodeproj/project.pbxproj"
  printf '%s\n' \
    '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>' \
    '<!-- APPCAST_ITEMS: synthetic -->' \
    '<item><sparkle:version>386</sparkle:version><sparkle:shortVersionString>2.2.0</sparkle:shortVersionString></item>' \
    '</channel></rss>' >"${SOURCE_REPO}/website/public/appcast.xml"
  printf '%s\n' \
    'export const FALLBACK_RELEASE_TAG = "v2.2.0";' \
    'export const FALLBACK_RELEASE_VERSION = "2.2.0";' \
    >"${SOURCE_REPO}/website/lib/constants.ts"
  printf '%s\n' '{"pins":[],"version":3}' \
    >"${SOURCE_REPO}/SupraAI.xcworkspace/xcshareddata/swiftpm/Package.resolved"
  git -C "$SOURCE_REPO" init -q -b main
  git -C "$SOURCE_REPO" config user.name 'Release Test'
  git -C "$SOURCE_REPO" config user.email 'release-test@example.invalid'
  git -C "$SOURCE_REPO" add .
  git -C "$SOURCE_REPO" commit -qm 'source fixture'
  git clone -q --bare "$SOURCE_REPO" "$ORIGIN_REPO"
  git -C "$SOURCE_REPO" remote add origin "$ORIGIN_REPO"
  SOURCE_SHA="$(git -C "$SOURCE_REPO" rev-parse HEAD)"
}

preflight() {
  local source_repo="$1"
  local expected_sha="$2"
  local output="$3"
  env \
    PATH="${mock_bin}:$PATH" \
    MOCK_RELEASE_LOG="$mock_log" \
    MOCK_CI_HEAD_SHA="${MOCK_CI_HEAD_SHA:-$expected_sha}" \
    SUPRA_PROTECTED_RELEASE_ENVIRONMENT=1 \
    SUPRA_RELEASE_TESTING=1 \
    SUPRA_GH_COMMAND="${mock_bin}/gh" \
    SUPRA_CREDENTIAL_GATE_COMMAND="${mock_bin}/credential-gate" \
    SUPRA_FONT_GUARD_COMMAND="${mock_bin}/font-gate" \
    SUPRA_RELEASE_GATE_COMMAND="${mock_bin}/release-gate" \
    bash "${scripts}/release-preflight.sh" \
      --repo-root "$source_repo" \
      --repository example/supra \
      --version 2.3.0 \
      --build 387 \
      --expected-sha "$expected_sha" \
      --ci-run-id 42 \
      --output "$output"
}

make_source_repo clean
source_manifest="${temporary_dir}/source-preflight.json"
run_case \
  'clean source and exact green CI pass preflight' \
  0 \
  'Release source preflight passed for v2.3.0' \
  preflight "$SOURCE_REPO" "$SOURCE_SHA" "$source_manifest"
if [[ -f "$source_manifest" ]]; then
  jq -e --arg sha "$SOURCE_SHA" '
    .schemaVersion == 1 and .source.sha == $sha and .release.version == "2.3.0" and
    .release.build == "387" and .ciRuns[0].id == "42"
  ' "$source_manifest" >/dev/null || fail 'source preflight manifest did not bind SHA/version/build/CI'
else
  fail 'source preflight did not create its manifest'
fi

make_source_repo dirty
printf '%s\n' dirty >"${SOURCE_REPO}/untracked.txt"
run_case \
  'dirty tree fails before publication' \
  1 \
  'working tree is not clean' \
  preflight "$SOURCE_REPO" "$SOURCE_SHA" "${temporary_dir}/dirty.json"

make_source_repo sha-mismatch
wrong_sha='1111111111111111111111111111111111111111'
run_case \
  'expected SHA mismatch fails' \
  1 \
  'HEAD does not match expected release SHA' \
  preflight "$SOURCE_REPO" "$wrong_sha" "${temporary_dir}/sha.json"

make_source_repo origin-mismatch
printf '%s\n' later >"${SOURCE_REPO}/later.txt"
git -C "$SOURCE_REPO" add later.txt
git -C "$SOURCE_REPO" commit -qm 'local ahead'
SOURCE_SHA="$(git -C "$SOURCE_REPO" rev-parse HEAD)"
run_case \
  'origin main mismatch fails' \
  1 \
  'HEAD does not equal origin/main' \
  preflight "$SOURCE_REPO" "$SOURCE_SHA" "${temporary_dir}/origin.json"

make_source_repo stale-tag
git -C "$ORIGIN_REPO" update-ref refs/tags/v2.3.0 "$SOURCE_SHA"
run_case \
  'stale or existing tag fails' \
  1 \
  'release tag already exists on origin' \
  preflight "$SOURCE_REPO" "$SOURCE_SHA" "${temporary_dir}/tag.json"

make_source_repo ci-fail
ci_output="${temporary_dir}/ci-failure.log"
ci_status=0
MOCK_CI_CONCLUSION=failure preflight "$SOURCE_REPO" "$SOURCE_SHA" "${temporary_dir}/ci.json" >"$ci_output" 2>&1 || ci_status=$?
if [[ "$ci_status" -ne 1 ]] || ! grep -Fq 'protected CI run is not successful' "$ci_output"; then
  fail 'failed protected CI gate did not block release'
else
  printf '%s\n' 'PASS: failed protected CI gate blocks release'
fi

make_source_repo font-fail
font_output="${temporary_dir}/font-failure.log"
font_status=0
MOCK_FONT_FAIL=1 preflight "$SOURCE_REPO" "$SOURCE_SHA" "${temporary_dir}/font.json" >"$font_output" 2>&1 || font_status=$?
if [[ "$font_status" -ne 1 ]] || ! grep -Fq 'public font gate failed' "$font_output"; then
  fail 'missing or failed font gate did not block release'
else
  printf '%s\n' 'PASS: missing or failed font gate blocks release'
fi

make_source_repo credential-fail
credential_output="${temporary_dir}/credential-failure.log"
credential_status=0
MOCK_CREDENTIAL_FAIL=1 preflight "$SOURCE_REPO" "$SOURCE_SHA" "${temporary_dir}/credential.json" >"$credential_output" 2>&1 || credential_status=$?
if [[ "$credential_status" -ne 1 ]] || ! grep -Fq 'release credential gate failed' "$credential_output"; then
  fail 'missing signing credential gate did not block release'
else
  printf '%s\n' 'PASS: missing signing credential blocks release'
fi

if grep -Eq 'gh release (create|upload|edit)' "$mock_log"; then
  fail 'source preflight invoked a release publication command'
else
  printf '%s\n' 'PASS: all preflight failures occur before publication'
fi

artifact_root="${temporary_dir}/artifacts"
app="${artifact_root}/SupraAI.app"
xpc="${app}/Contents/XPCServices/SupraRuntimeService.xpc"
mkdir -p "${app}/Contents/MacOS" "${xpc}/Contents/MacOS"
printf '%s\n' app >"${app}/Contents/MacOS/SupraAI"
printf '%s\n' xpc >"${xpc}/Contents/MacOS/SupraRuntimeService"
chmod +x "${app}/Contents/MacOS/SupraAI" "${xpc}/Contents/MacOS/SupraRuntimeService"
plutil -create xml1 "${app}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string ai.supra.SupraAI' "${app}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleShortVersionString string 2.3.0' "${app}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 387' "${app}/Contents/Info.plist"
plutil -create xml1 "${xpc}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string ai.supra.SupraAI.SupraRuntimeService' "${xpc}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleShortVersionString string 2.3.0' "${xpc}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 387' "${xpc}/Contents/Info.plist"
app_entitlements="${temporary_dir}/app.entitlements"
service_entitlements="${temporary_dir}/service.entitlements"
cp "${repo_root}/Apps/SupraAI/SupraAI/SupraAI.entitlements" "$app_entitlements"
cp "${repo_root}/Apps/SupraAI/SupraRuntimeService/SupraRuntimeService.entitlements" "$service_entitlements"
zip="${artifact_root}/SupraAI-2.3.0.zip"
dmg="${artifact_root}/SupraAI-2.3.0.dmg"
ditto -c -k --keepParent "$app" "$zip"
printf '%s\n' synthetic-dmg >"$dmg"
final_manifest="${artifact_root}/preflight-manifest.json"

run_case \
  'artifact manifest binds source and exact bytes' \
  0 \
  'Preflight manifest created' \
  bash "${scripts}/create-preflight-manifest.sh" \
    --source-manifest "$source_manifest" --app "$app" --zip "$zip" --dmg "$dmg" \
    --team-id 2DP657YB3K --output "$final_manifest"
cp "$final_manifest" "${final_manifest}.cms" 2>/dev/null || true

artifact_verify() {
  env \
    PATH="${mock_bin}:$PATH" \
    MOCK_RELEASE_LOG="$mock_log" \
    MOCK_APP_SOURCE="$app" \
    MOCK_APP_ENTITLEMENTS="$app_entitlements" \
    MOCK_SERVICE_ENTITLEMENTS="$service_entitlements" \
    MOCK_TEAM_ID=2DP657YB3K \
    bash "${scripts}/verify-release-artifacts.sh" \
      --app "$app" --zip "$zip" --dmg "$dmg" \
      --manifest "$final_manifest" --manifest-signature "${final_manifest}.cms" \
      --version 2.3.0 --build 387 --source-sha "$(jq -r '.source.sha' "$source_manifest" 2>/dev/null || printf '%040d' 0)" \
      --team-id 2DP657YB3K
}

run_case \
  'signed notarized artifacts and manifest pass' \
  0 \
  'Release artifacts verified' \
  artifact_verify

sign_output="${temporary_dir}/sign-failure.log"
sign_status=0
MOCK_CODESIGN_FAIL=1 artifact_verify >"$sign_output" 2>&1 || sign_status=$?
if [[ "$sign_status" -ne 1 ]] || ! grep -Fq 'code signature verification failed' "$sign_output"; then
  fail 'signature failure did not block artifact verification'
else
  printf '%s\n' 'PASS: signature failure blocks artifact verification'
fi

staple_output="${temporary_dir}/staple-failure.log"
staple_status=0
MOCK_STAPLER_FAIL=1 artifact_verify >"$staple_output" 2>&1 || staple_status=$?
if [[ "$staple_status" -ne 1 ]] || ! grep -Fq 'staple validation failed' "$staple_output"; then
  fail 'notarization/staple failure did not block artifact verification'
else
  printf '%s\n' 'PASS: notarization/staple failure blocks artifact verification'
fi

cp "$zip" "${zip}.valid"
printf '%s\n' 'tampered-after-manifest' >>"$zip"
digest_output="${temporary_dir}/artifact-digest-failure.log"
digest_status=0
artifact_verify >"$digest_output" 2>&1 || digest_status=$?
if [[ "$digest_status" -ne 1 ]] || ! grep -Fq 'artifact digest does not match manifest' "$digest_output"; then
  fail 'artifact digest mismatch did not block artifact verification'
else
  printf '%s\n' 'PASS: artifact digest mismatch blocks artifact verification'
fi
mv "${zip}.valid" "$zip"

appcast_in="${temporary_dir}/appcast-input.xml"
constants_in="${temporary_dir}/constants-input.ts"
printf '%s\n' \
  '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>' \
  '<!-- APPCAST_ITEMS: synthetic -->' \
  '</channel></rss>' >"$appcast_in"
printf '%s\n' \
  'export const FALLBACK_RELEASE_TAG = "v2.2.0";' \
  'export const FALLBACK_RELEASE_VERSION = "2.2.0";' >"$constants_in"
appcast_out="${temporary_dir}/appcast-output.xml"
constants_out="${temporary_dir}/constants-output.ts"

prepare_appcast() {
  env PATH="${mock_bin}:$PATH" MOCK_RELEASE_LOG="$mock_log" \
    bash "${scripts}/prepare-release-appcast.sh" \
      --appcast-in "$appcast_in" --constants-in "$constants_in" \
      --appcast-out "$appcast_out" --constants-out "$constants_out" \
      --zip "$zip" --version 2.3.0 --build 387 \
      --repository example/supra --sign-update "${mock_bin}/sign_update"
}

run_case \
  'valid Sparkle signature and length prepare an isolated appcast' \
  0 \
  'Prepared validated appcast for v2.3.0' \
  prepare_appcast

bad_signature_output="${temporary_dir}/bad-signature.log"
bad_signature_status=0
MOCK_SIGN_VERIFY_FAIL=1 prepare_appcast >"$bad_signature_output" 2>&1 || bad_signature_status=$?
if [[ "$bad_signature_status" -ne 1 ]] || ! grep -Fq 'Sparkle signature verification failed' "$bad_signature_output"; then
  fail 'bad Sparkle signature did not block appcast preparation'
else
  printf '%s\n' 'PASS: bad Sparkle signature blocks appcast preparation'
fi

bad_length_output="${temporary_dir}/bad-length.log"
bad_length_status=0
MOCK_SIGN_LENGTH_DELTA=1 prepare_appcast >"$bad_length_output" 2>&1 || bad_length_status=$?
if [[ "$bad_length_status" -ne 1 ]] || ! grep -Fq 'Sparkle length does not match ZIP bytes' "$bad_length_output"; then
  fail 'bad Sparkle length did not block appcast preparation'
else
  printf '%s\n' 'PASS: bad Sparkle length blocks appcast preparation'
fi

smoke_result="${temporary_dir}/signed-runtime-smoke.json"
app_tree_sha="$(jq -r '.artifacts[] | select(.kind == "app") | .sha256' "$final_manifest" 2>/dev/null || true)"
model_sha='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
MOCK_SOURCE_SHA="$(jq -r '.source.sha' "$source_manifest" 2>/dev/null || true)" \
MOCK_APP_TREE_SHA="$app_tree_sha" MOCK_MODEL_SHA="$model_sha" \
  "${mock_bin}/signed-smoke" --output "$smoke_result"
run_case \
  'signed runtime smoke attestation binds app/model/source' \
  0 \
  'Signed runtime smoke attestation verified' \
  bash "${scripts}/verify-signed-runtime-smoke-result.sh" \
    --result "$smoke_result" --source-sha "$(jq -r '.source.sha' "$source_manifest" 2>/dev/null || true)" \
    --app-sha "$app_tree_sha" --model-sha "$model_sha"

publish_root="${temporary_dir}/publish-root"
mkdir -p "${publish_root}/build/release" "${publish_root}/website/public" "${publish_root}/website/lib"
cp "$appcast_in" "${publish_root}/website/public/appcast.xml"
cp "$constants_in" "${publish_root}/website/lib/constants.ts"
public_appcast="${temporary_dir}/public-appcast.xml"
: >"$public_appcast"

publish_transaction() {
  env \
    PATH="${mock_bin}:$PATH" \
    SUPRA_RELEASE_TESTING=1 \
    SUPRA_GH_COMMAND="${mock_bin}/gh" \
    SUPRA_CURL_COMMAND="${mock_bin}/curl" \
    SUPRA_WEBSITE_GATE_COMMAND="${mock_bin}/website-gate" \
    SUPRA_APPCAST_PUBLISH_COMMAND="${mock_bin}/appcast-publish" \
    SUPRA_APPCAST_ROLLBACK_COMMAND="${mock_bin}/appcast-rollback" \
    MOCK_RELEASE_LOG="$mock_log" \
    MOCK_ZIP_SOURCE="$zip" MOCK_DMG_SOURCE="$dmg" \
    MOCK_PUBLIC_APPCAST_DEST="$public_appcast" \
    bash "${scripts}/publish-release-transaction.sh" \
      --repo-root "$publish_root" --repository example/supra \
      --source-sha "$(jq -r '.source.sha' "$source_manifest" 2>/dev/null || true)" \
      --version 2.3.0 --build 387 --zip "$zip" --dmg "$dmg" \
      --manifest "$final_manifest" --manifest-signature "${final_manifest}.cms" \
      --appcast-in "$appcast_in" --constants-in "$constants_in" \
      --sign-update "${mock_bin}/sign_update"
}

: >"$mock_log"
run_case \
  'draft upload, validated appcast, publication, and public digest succeed transactionally' \
  0 \
  'Release transaction completed for v2.3.0' \
  publish_transaction

create_line="$(grep -n 'gh release create' "$mock_log" | head -1 | cut -d: -f1 || true)"
publish_line="$(grep -n 'gh release edit.*--draft=false' "$mock_log" | head -1 | cut -d: -f1 || true)"
appcast_line="$(grep -n '^appcast-publish ' "$mock_log" | head -1 | cut -d: -f1 || true)"
if [[ -z "$create_line" || -z "$publish_line" || -z "$appcast_line" \
  || "$create_line" -ge "$publish_line" || "$publish_line" -ge "$appcast_line" ]]; then
  fail 'release transaction order is not draft -> public release -> appcast commit'
else
  printf '%s\n' 'PASS: release transaction order is draft -> public release -> appcast commit'
fi

assert_prepublication_failure() {
  local name="$1"
  local failure_variable="$2"
  : >"$mock_log"
  local output="${temporary_dir}/${name}.log"
  local result=0
  export "$failure_variable=1"
  publish_transaction >"$output" 2>&1 || result=$?
  unset "$failure_variable"
  if [[ "$result" -ne 1 ]]; then
    fail "${name}: expected failure"
  elif grep -Eq 'gh release edit .*--draft=false' "$mock_log"; then
    fail "${name}: public release was created before a pre-publication failure"
  elif ! grep -Eq 'gh release delete .*--cleanup-tag' "$mock_log"; then
    fail "${name}: draft release was not cleaned up"
  else
    printf 'PASS: %s blocks before public release and cleans the draft\n' "$name"
  fi
}

assert_prepublication_failure upload-failure MOCK_UPLOAD_FAIL
assert_prepublication_failure website-failure MOCK_WEBSITE_FAIL

assert_postpublication_failure() {
  local name="$1"
  local failure_variable="$2"
  : >"$mock_log"
  local output="${temporary_dir}/${name}.log"
  local result=0
  export "$failure_variable=1"
  publish_transaction >"$output" 2>&1 || result=$?
  unset "$failure_variable"
  local draft_count
  local rollback_count
  draft_count="$(grep -c 'gh release edit.*--draft' "$mock_log" || true)"
  rollback_count="$(grep -c '^appcast-rollback ' "$mock_log" || true)"
  if [[ "$result" -ne 1 || "$draft_count" -lt 1 ]]; then
    fail "${name}: public release was not returned to draft"
  elif [[ "$name" == 'deploy-failure' && "$rollback_count" -lt 1 ]]; then
    fail "${name}: appcast commit was not reverted"
  else
    printf 'PASS: %s rolls back public release state\n' "$name"
  fi
}

assert_postpublication_failure appcast-publication-failure MOCK_APPCAST_PUBLISH_FAIL
assert_postpublication_failure deploy-failure MOCK_DEPLOY_FAIL

: >"$mock_log"
post_output="${temporary_dir}/post-digest.log"
post_status=0
MOCK_POST_DIGEST_FAIL=1 publish_transaction >"$post_output" 2>&1 || post_status=$?
draft_count="$(grep -c 'gh release edit.*--draft' "$mock_log" || true)"
rollback_count="$(grep -c '^appcast-rollback ' "$mock_log" || true)"
if [[ "$post_status" -ne 1 || "$draft_count" -lt 1 || "$rollback_count" -lt 1 ]]; then
  fail 'post-publication digest mismatch did not revert appcast and return release to draft'
else
  printf '%s\n' 'PASS: post-publication digest mismatch triggers transactional rollback'
fi

if grep -Eq 'xcodeproj|proj\.save|MARKETING_VERSION.*project' "${scripts}/release.sh" 2>/dev/null; then
  fail 'release.sh still edits the Xcode project before build'
else
  printf '%s\n' 'PASS: release.sh does not mutate project version source'
fi

if (( failures != 0 )); then
  printf 'Release transaction tests failed: %d\n' "$failures" >&2
  exit 1
fi
printf '%s\n' 'All release transaction tests passed.'
