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
    'MARKETING_VERSION = 2.3.0;' \
    'CURRENT_PROJECT_VERSION = 387;' \
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

# The production default for the gh command is the bare name "gh", resolved via
# PATH at execution time. The availability gate must accept it when a gh exists
# on PATH even though no ./gh file exists in the working directory.
# Expected RED reason: the gate tests the bare name with [[ -x gh ]], which
# checks for a file named "gh" relative to the current directory, so preflight
# dies with "release preflight command is unavailable: gh" before any check runs.
preflight_default_gh() {
  local source_repo="$1"
  local expected_sha="$2"
  local output="$3"
  env \
    PATH="${mock_bin}:$PATH" \
    MOCK_RELEASE_LOG="$mock_log" \
    MOCK_CI_HEAD_SHA="$expected_sha" \
    SUPRA_PROTECTED_RELEASE_ENVIRONMENT=1 \
    SUPRA_RELEASE_TESTING=1 \
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
make_source_repo default-gh
run_case \
  'default bare gh command resolves through PATH' \
  0 \
  'Release source preflight passed for v2.3.0' \
  preflight_default_gh "$SOURCE_REPO" "$SOURCE_SHA" "${temporary_dir}/default-gh-preflight.json"

# Signed-app entitlements carry the RESOLVED bundle identifier in the Sparkle
# mach-lookup exception (Xcode substitutes $(PRODUCT_BUNDLE_IDENTIFIER) at
# build time), so the artifact-side check must accept the resolved values for
# the verified bundle id while the source-file check keeps expecting the
# template. Expected RED reason: verify-entitlements.sh has no --bundle-id
# mode, exits 2 on the unknown option, and the resolved fixture cannot pass.
resolved_app_entitlements="${temporary_dir}/resolved-app.entitlements"
resolved_xpc_entitlements="${temporary_dir}/resolved-xpc.entitlements"
cat >"$resolved_app_entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.files.bookmarks.app-scope</key><true/>
  <key>com.apple.security.files.user-selected.read-write</key><true/>
  <key>com.apple.security.network.client</key><true/>
  <key>com.apple.security.temporary-exception.mach-lookup.global-name</key>
  <array><string>ai.supra.SupraAI-spks</string><string>ai.supra.SupraAI-spki</string></array>
</dict></plist>
PLIST
cat >"$resolved_xpc_entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.app-sandbox</key><true/>
</dict></plist>
PLIST
run_case \
  'resolved signed entitlements pass with the verified bundle id' \
  0 \
  'Entitlement expectations passed.' \
  bash "${scripts}/verify-entitlements.sh" \
    --app "$resolved_app_entitlements" \
    --service "$resolved_xpc_entitlements" \
    --bundle-id ai.supra.SupraAI
run_case \
  'resolved entitlements for a different bundle id fail' \
  1 \
  'app entitlement drift: com.apple.security.temporary-exception.mach-lookup.global-name' \
  bash "${scripts}/verify-entitlements.sh" \
    --app "$resolved_app_entitlements" \
    --service "$resolved_xpc_entitlements" \
    --bundle-id ai.evil.Other

# The manifest CMS signer must select its identity deterministically and fail
# closed when the requested identity does not exist, instead of silently
# signing with an arbitrary default the way `security cms -S -N` does.
# Expected RED reason: Scripts/sign-release-manifest.swift does not exist, so
# the interpreter fails without the required refusal message.
run_case \
  'manifest signer refuses an unknown identity' \
  1 \
  'no signing identity matches' \
  env DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}" \
    swift "${scripts}/sign-release-manifest.swift" \
    --identity 'Nonexistent Release Identity (SYNTHETIC0)' \
    --team-id SYNTHETIC0 \
    --input "${repo_root}/Tests/Scripts/Fixtures/Release/mock-command.sh" \
    --output "${temporary_dir}/never-created.cms"

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

make_source_repo release-gate-fail
release_gate_output="${temporary_dir}/release-gate-failure.log"
release_gate_status=0
MOCK_RELEASE_GATE_FAIL=1 preflight "$SOURCE_REPO" "$SOURCE_SHA" "${temporary_dir}/release-gate.json" >"$release_gate_output" 2>&1 || release_gate_status=$?
if [[ "$release_gate_status" -ne 1 ]] || ! grep -Fq 'release integration gate failed' "$release_gate_output"; then
  fail 'failed package/integration release gate did not block release'
else
  printf '%s\n' 'PASS: failed package/integration release gate blocks release'
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
# Mirror what codesign extracts from a real signed app: Xcode substitutes
# $(PRODUCT_BUNDLE_IDENTIFIER) at build time, so the fixture must carry the
# resolved values matching the fixture Info.plist's CFBundleIdentifier.
sed 's/$(PRODUCT_BUNDLE_IDENTIFIER)/ai.supra.SupraAI/g' \
  "${repo_root}/Apps/SupraAI/SupraAI/SupraAI.entitlements" >"$app_entitlements"
cp "${repo_root}/Apps/SupraAI/SupraRuntimeService/SupraRuntimeService.entitlements" "$service_entitlements"
zip="${artifact_root}/SupraAI-2.3.0.zip"
dmg="${artifact_root}/SupraAI-2.3.0.dmg"
ditto -c -k --keepParent "$app" "$zip"
printf '%s\n' synthetic-dmg >"$dmg"
final_manifest="${artifact_root}/preflight-manifest.json"
smoke_result="${temporary_dir}/signed-runtime-smoke.json"
release_source_sha="$(jq -r '.source.sha' "$source_manifest")"
app_tree_sha="$(
  bash -c 'source "$1"; release_directory_digest "$2"' \
    _ "${scripts}/lib/release-common.sh" "$app"
)"
model_sha='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
smoke_nonce='cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
jq -n \
  --arg nonce "$smoke_nonce" \
  --arg sourceSha "$release_source_sha" \
  --arg appTreeSHA256 "$app_tree_sha" \
  --arg modelSHA256 "$model_sha" \
  '{
    schemaVersion: 1,
    status: "passed",
    nonce: $nonce,
    sourceSha: $sourceSha,
    appTreeSHA256: $appTreeSHA256,
    modelSHA256: $modelSHA256,
    appBundleIdentifier: "ai.supra.SupraAI",
    xpcBundleIdentifier: "ai.supra.SupraAI.SupraRuntimeService",
    appVersion: "2.3.0",
    appBuild: "387",
    modelRepositoryID: "mlx-community/Release-Smoke-4bit",
    modelRevision: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    verification: {
      xpcConnected: true,
      modelLoaded: true,
      generationStarted: true,
      generationCompleted: true,
      modelUnloaded: true,
      modelReverified: true
    },
    eventCounts: {
      total: 4,
      generationStarted: 1,
      token: 1,
      metrics: 1,
      generationCompleted: 1,
      generationFailed: 0,
      generationCancelled: 0,
      reserved: 0
    },
    generatedTokenCount: 7,
    timings: {
      loadTimeMs: 123,
      firstTokenLatencyMs: 45,
      tokensPerSecond: 12.5
    }
  }' >"$smoke_result"
# The embedded digest covers canonical sorted JSON so independent verifiers can
# reproduce it after extracting the attestation from the signed manifest.
smoke_result_sha="$(jq -S -c . "$smoke_result" | shasum -a 256 | awk '{print $1}')"

manifest_output="${temporary_dir}/strict-manifest.log"
manifest_status=0
bash "${scripts}/create-preflight-manifest.sh" \
  --source-manifest "$source_manifest" --app "$app" --zip "$zip" --dmg "$dmg" \
  --team-id 2DP657YB3K --smoke-result "$smoke_result" --output "$final_manifest" \
  >"$manifest_output" 2>&1 || manifest_status=$?
if [[ "$manifest_status" -ne 0 || ! -f "$final_manifest" ]]; then
  fail 'artifact manifest rejected the strict signed runtime smoke attestation'
  sed 's/^/  | /' "$manifest_output" >&2

  # Keep the independent downstream fail-closed cases runnable during RED by
  # deriving a structurally valid fixture from the current implementation.
  legacy_smoke_result="${temporary_dir}/legacy-signed-runtime-smoke.json"
  jq -n \
    --arg sourceSha "$release_source_sha" \
    --arg appTreeSHA256 "$app_tree_sha" \
    --arg modelSHA256 "$model_sha" \
    '{schemaVersion: 1, status: "passed", sourceSha: $sourceSha,
      appTreeSHA256: $appTreeSHA256, modelSHA256: $modelSHA256,
      xpcBundleIdentifier: "ai.supra.SupraAI.SupraRuntimeService", generatedTokens: 7}' \
    >"$legacy_smoke_result"
  bash "${scripts}/create-preflight-manifest.sh" \
    --source-manifest "$source_manifest" --app "$app" --zip "$zip" --dmg "$dmg" \
    --team-id 2DP657YB3K --smoke-result "$legacy_smoke_result" --output "$final_manifest"
  jq --slurpfile smoke "$smoke_result" --arg resultSHA256 "$smoke_result_sha" \
    '.signedRuntimeSmoke = ($smoke[0] + {resultSHA256: $resultSHA256})' \
    "$final_manifest" >"${final_manifest}.strict"
  mv "${final_manifest}.strict" "$final_manifest"
elif ! jq -e \
  --slurpfile smoke "$smoke_result" --arg resultSHA256 "$smoke_result_sha" \
  '.signedRuntimeSmoke == ($smoke[0] + {resultSHA256: $resultSHA256})' \
  "$final_manifest" >/dev/null; then
  fail 'preflight manifest did not preserve the complete strict attestation plus resultSHA256'
  jq --slurpfile smoke "$smoke_result" --arg resultSHA256 "$smoke_result_sha" \
    '.signedRuntimeSmoke = ($smoke[0] + {resultSHA256: $resultSHA256})' \
    "$final_manifest" >"${final_manifest}.strict"
  mv "${final_manifest}.strict" "$final_manifest"
else
  printf '%s\n' 'PASS: artifact manifest binds exact bytes and preserves the complete strict smoke attestation'
fi
cp "$final_manifest" "${final_manifest}.cms" 2>/dev/null || true

artifact_verify() {
  local requested_build="${1:-387}"
  local requested_manifest="${2:-$final_manifest}"
  local requested_signature="${requested_manifest}.cms"
  env \
    PATH="${mock_bin}:$PATH" \
    MOCK_RELEASE_LOG="$mock_log" \
    MOCK_APP_SOURCE="$app" \
    MOCK_APP_ENTITLEMENTS="$app_entitlements" \
    MOCK_SERVICE_ENTITLEMENTS="$service_entitlements" \
    MOCK_TEAM_ID=2DP657YB3K \
    SUPRA_RELEASE_TESTING=1 \
    bash "${scripts}/verify-release-artifacts.sh" \
      --app "$app" --zip "$zip" --dmg "$dmg" \
      --manifest "$requested_manifest" --manifest-signature "$requested_signature" \
      --version 2.3.0 --build "$requested_build" --source-sha "$(jq -r '.source.sha' "$source_manifest" 2>/dev/null || printf '%040d' 0)" \
      --team-id 2DP657YB3K
}

run_case \
  'signed notarized artifacts and manifest pass' \
  0 \
  'Release artifacts verified' \
  artifact_verify

run_case \
  'artifact build drift cannot be published under the release tag' \
  1 \
  'preflight manifest metadata does not match requested release' \
  artifact_verify 386

null_smoke_manifest="${temporary_dir}/preflight-null-smoke.json"
malformed_smoke_manifest="${temporary_dir}/preflight-malformed-smoke.json"
mismatched_smoke_manifest="${temporary_dir}/preflight-mismatched-smoke.json"
forged_digest_smoke_manifest="${temporary_dir}/preflight-forged-digest-smoke.json"
jq '.signedRuntimeSmoke = null' "$final_manifest" >"$null_smoke_manifest"
jq 'del(.signedRuntimeSmoke.verification.modelReverified)' \
  "$final_manifest" >"$malformed_smoke_manifest"
jq '.signedRuntimeSmoke.sourceSha = "dddddddddddddddddddddddddddddddddddddddd"' \
  "$final_manifest" >"$mismatched_smoke_manifest"
jq '.signedRuntimeSmoke.resultSHA256 =
  "0000000000000000000000000000000000000000000000000000000000000000"' \
  "$final_manifest" >"$forged_digest_smoke_manifest"
for altered_manifest in \
  "$null_smoke_manifest" "$malformed_smoke_manifest" "$mismatched_smoke_manifest" \
  "$forged_digest_smoke_manifest"; do
  cp "$altered_manifest" "${altered_manifest}.cms"
done

assert_artifact_smoke_rejected() {
  local name="$1"
  local altered_manifest="$2"
  local output="${temporary_dir}/${name}-artifact.log"
  local status=0
  artifact_verify 387 "$altered_manifest" >"$output" 2>&1 || status=$?
  if [[ "$status" -ne 1 ]]; then
    fail "verify-release-artifacts accepted ${name} signed runtime smoke evidence"
  else
    printf 'PASS: verify-release-artifacts rejects %s signed runtime smoke evidence\n' "$name"
  fi
}

assert_artifact_smoke_rejected null "$null_smoke_manifest"
assert_artifact_smoke_rejected malformed "$malformed_smoke_manifest"
assert_artifact_smoke_rejected mismatched "$mismatched_smoke_manifest"
assert_artifact_smoke_rejected forged-digest "$forged_digest_smoke_manifest"

cms_output="${temporary_dir}/cms-failure.log"
cms_status=0
MOCK_CMS_FAIL=1 artifact_verify >"$cms_output" 2>&1 || cms_status=$?
if [[ "$cms_status" -ne 1 ]] || ! grep -Fq 'manifest CMS signature verification failed' "$cms_output"; then
  fail 'manifest signature failure did not block artifact verification'
else
  printf '%s\n' 'PASS: manifest signature failure blocks artifact verification'
fi

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

run_case \
  'signed runtime smoke attestation binds app/model/source' \
  0 \
  'Signed runtime smoke attestation verified' \
  bash "${scripts}/verify-signed-runtime-smoke-result.sh" \
    --result "$smoke_result" --source-sha "$release_source_sha" \
    --app-sha "$app_tree_sha" --model-sha "$model_sha" \
    --version 2.3.0 --build 387 --nonce "$smoke_nonce"

publish_root="${temporary_dir}/publish-root"
mkdir -p "${publish_root}/build/release" "${publish_root}/website/public" "${publish_root}/website/lib"
cp "$appcast_in" "${publish_root}/website/public/appcast.xml"
cp "$constants_in" "${publish_root}/website/lib/constants.ts"
public_appcast="${temporary_dir}/public-appcast.xml"
: >"$public_appcast"

publish_transaction() {
  local requested_manifest="${1:-$final_manifest}"
  local requested_signature="${requested_manifest}.cms"
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
    MOCK_MANIFEST_SOURCE="$requested_manifest" MOCK_SIGNATURE_SOURCE="$requested_signature" \
    MOCK_PUBLIC_APPCAST_DEST="$public_appcast" \
    MOCK_SOURCE_SHA="$(jq -r '.source.sha' "$source_manifest" 2>/dev/null || true)" \
    bash "${scripts}/publish-release-transaction.sh" \
      --repo-root "$publish_root" --repository example/supra \
      --source-sha "$(jq -r '.source.sha' "$source_manifest" 2>/dev/null || true)" \
      --version 2.3.0 --build 387 --zip "$zip" --dmg "$dmg" \
      --manifest "$requested_manifest" --manifest-signature "$requested_signature" \
      --appcast-in "$appcast_in" --constants-in "$constants_in" \
      --sign-update "${mock_bin}/sign_update"
}

: >"$mock_log"
run_case \
  'draft upload, validated appcast, publication, and public digest succeed transactionally' \
  0 \
  'Release transaction completed for v2.3.0' \
  publish_transaction
successful_publish_log="${temporary_dir}/successful-publish.log"
cp "$mock_log" "$successful_publish_log"

# The production defaults for the transaction's gh and curl commands are bare
# names resolved via PATH at execution time, exactly like the preflight's.
# Expected RED reason: the availability gate tests bare names with [[ -x ]],
# a working-directory file test, so the transaction dies with "release
# transaction command is unavailable: gh" on any real runner. Observed live in
# production run 29305819825 after the signed build and smoke had passed.
publish_transaction_default_commands() {
  env \
    PATH="${mock_bin}:$PATH" \
    SUPRA_RELEASE_TESTING=1 \
    SUPRA_WEBSITE_GATE_COMMAND="${mock_bin}/website-gate" \
    SUPRA_APPCAST_PUBLISH_COMMAND="${mock_bin}/appcast-publish" \
    SUPRA_APPCAST_ROLLBACK_COMMAND="${mock_bin}/appcast-rollback" \
    MOCK_RELEASE_LOG="$mock_log" \
    MOCK_ZIP_SOURCE="$zip" MOCK_DMG_SOURCE="$dmg" \
    MOCK_MANIFEST_SOURCE="$final_manifest" MOCK_SIGNATURE_SOURCE="${final_manifest}.cms" \
    MOCK_PUBLIC_APPCAST_DEST="$public_appcast" \
    MOCK_SOURCE_SHA="$(jq -r '.source.sha' "$source_manifest" 2>/dev/null || true)" \
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
  'default bare gh and curl transaction commands resolve through PATH' \
  0 \
  'Release transaction completed for v2.3.0' \
  publish_transaction_default_commands
: >"$mock_log"

assert_publish_smoke_rejected() {
  local name="$1"
  local altered_manifest="$2"
  local output="${temporary_dir}/${name}-publish.log"
  local status=0
  : >"$mock_log"
  publish_transaction "$altered_manifest" >"$output" 2>&1 || status=$?
  if [[ "$status" -ne 1 ]]; then
    fail "publish-release-transaction accepted ${name} signed runtime smoke evidence"
  elif grep -Eq 'gh release create|gh release upload|gh release edit.*--draft=false' "$mock_log"; then
    fail "publish-release-transaction created release state before rejecting ${name} smoke evidence"
  else
    printf 'PASS: publish-release-transaction independently rejects %s signed runtime smoke evidence\n' "$name"
  fi
}

assert_publish_smoke_rejected null "$null_smoke_manifest"
assert_publish_smoke_rejected malformed "$malformed_smoke_manifest"
assert_publish_smoke_rejected mismatched "$mismatched_smoke_manifest"
assert_publish_smoke_rejected forged-digest "$forged_digest_smoke_manifest"

create_line="$(grep -n 'gh release create' "$successful_publish_log" | head -1 | cut -d: -f1 || true)"
publish_line="$(grep -n 'gh release edit.*--draft=false' "$successful_publish_log" | head -1 | cut -d: -f1 || true)"
appcast_line="$(grep -n '^appcast-publish ' "$successful_publish_log" | head -1 | cut -d: -f1 || true)"
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

release_script="${scripts}/release.sh"
if grep -Eq 'SUPRA_RELEASE_SMOKE_MODEL_DIRECTORY:\?[^}]+' "$release_script"; then
  printf '%s\n' 'PASS: release.sh requires the reviewed smoke model directory'
else
  fail 'release.sh does not require SUPRA_RELEASE_SMOKE_MODEL_DIRECTORY'
fi

release_workflow="${repo_root}/.github/workflows/release.yml"
rehearsal_workflow="${repo_root}/.github/workflows/release-rehearsal.yml"
if grep -Fq 'runs-on: [self-hosted, macOS, ARM64, supra-release, supra-release-isolated]' \
    "$release_workflow" \
  && grep -Fq 'runs-on: [self-hosted, macOS, ARM64, supra-release, supra-release-isolated]' \
    "$rehearsal_workflow" \
  && grep -Fq 'SUPRA_RELEASE_ISOLATED_RUNNER: "1"' "$release_workflow" \
  && grep -Fq 'SUPRA_RELEASE_ISOLATED_RUNNER: "1"' "$rehearsal_workflow" \
  && grep -Fq 'SUPRA_RELEASE_ISOLATED_RUNNER' "$release_script"; then
  printf '%s\n' 'PASS: signed model smoke requires the dedicated isolated release runner'
else
  fail 'signed model smoke is not fail-closed on the dedicated isolated release runner'
fi

run_case \
  'release entrypoint rejects a missing isolated-runner attestation before credentials' \
  1 \
  'signed release qualification requires the dedicated isolated release runner' \
  env SUPRA_PROTECTED_RELEASE_ENVIRONMENT=1 \
  bash "$release_script" \
    --repository example/supra \
    --version 2.3.0 \
    --build 387 \
    --expected-sha 1111111111111111111111111111111111111111 \
    --ci-run-id 42 \
    --no-publish

if grep -Eq 'SUPRA_SIGNED_SMOKE_DRIVER' \
  "$release_script" "${scripts}/run-signed-release-smoke.sh" \
  "${repo_root}/.github/workflows/release.yml" \
  "${repo_root}/.github/workflows/release-rehearsal.yml"; then
  fail 'release integration still delegates signed smoke execution through SUPRA_SIGNED_SMOKE_DRIVER'
else
  printf '%s\n' 'PASS: release integration has no external signed-smoke driver override'
fi

if grep -Eq 'openssl[[:space:]]+rand[[:space:]]+-hex[[:space:]]+32' "$release_script" \
  && grep -Eq 'smoke_nonce.*\^\[0-9a-f\].*64' "$release_script"; then
  printf '%s\n' 'PASS: release.sh creates and validates a fresh lowercase 64-hex nonce'
else
  fail 'release.sh does not create and validate a fresh lowercase 64-hex smoke nonce'
fi

smoke_driver_line="$(grep -n 'Scripts/run-signed-release-smoke.sh' "$release_script" | head -1 | cut -d: -f1 || true)"
final_manifest_line="$(
  awk -v smoke="$smoke_driver_line" \
    'NR > smoke && /Scripts\/create-preflight-manifest.sh/ { print NR; exit }' \
    "$release_script"
)"
if [[ -n "$smoke_driver_line" ]]; then
  smoke_driver_block="$(sed -n "${smoke_driver_line},$((smoke_driver_line + 10))p" "$release_script")"
else
  smoke_driver_block=''
fi
if grep -Fq -- '--version "$version"' <<<"$smoke_driver_block" \
  && grep -Fq -- '--build "$build_number"' <<<"$smoke_driver_block" \
  && grep -Fq -- '--nonce "$smoke_nonce"' <<<"$smoke_driver_block"; then
  printf '%s\n' 'PASS: repository smoke driver receives version, build, and fresh nonce'
else
  fail 'release.sh does not pass version, build, and fresh nonce to the repository smoke driver'
fi

if [[ -n "$smoke_driver_line" && -n "$final_manifest_line" ]]; then
  post_smoke_block="$(sed -n "$((smoke_driver_line + 1)),$((final_manifest_line - 1))p" "$release_script")"
else
  post_smoke_block=''
fi
if grep -Eq 'release_directory_digest.*\$app|verify[^[:space:]]*app[^[:space:]]*digest' \
    <<<"$post_smoke_block" \
  && grep -Eq 'codesign.*--verify.*\$app|verify[^[:space:]]*app[^[:space:]]*signature' \
    <<<"$post_smoke_block"; then
  printf '%s\n' 'PASS: signed app digest and signature are rechecked after smoke and before final manifest creation'
else
  fail 'release.sh does not recheck the app digest and signature after smoke before final manifest creation'
fi

preflight_schema="${repo_root}/Docs/Schemas/release-preflight-manifest.schema.json"
smoke_schema_ref="$(jq -r '.properties.signedRuntimeSmoke["$ref"] // empty' "$preflight_schema")"
if [[ -z "$smoke_schema_ref" || "$smoke_schema_ref" == \#* ]]; then
  fail 'preflight schema does not require signedRuntimeSmoke through a dedicated strict schema'
  smoke_schema=''
else
  smoke_schema="$(dirname "$preflight_schema")/$(basename "$smoke_schema_ref")"
fi
if [[ -n "$smoke_schema" && -f "$smoke_schema" ]] \
  && jq -e '
    .type == "object" and .additionalProperties == false and
    (.required | sort) == ([
      "schemaVersion", "status", "nonce", "sourceSha", "appTreeSHA256",
      "modelSHA256", "appBundleIdentifier", "xpcBundleIdentifier",
      "appVersion", "appBuild", "modelRepositoryID", "modelRevision",
      "verification", "eventCounts", "generatedTokenCount", "timings",
      "resultSHA256"
    ] | sort) and
    (.properties.verification.required | sort) == ([
      "xpcConnected", "modelLoaded", "generationStarted",
      "generationCompleted", "modelUnloaded", "modelReverified"
    ] | sort) and
    (.properties.eventCounts.required | sort) == ([
      "total", "generationStarted", "token", "metrics",
      "generationCompleted", "generationFailed", "generationCancelled", "reserved"
    ] | sort) and
    (.properties.timings.required | sort) == ([
      "loadTimeMs", "firstTokenLatencyMs", "tokensPerSecond"
    ] | sort) and
    ([.. | objects | select(.type? == "object" and has("properties")) |
      .additionalProperties == false] | all)
  ' "$smoke_schema" >/dev/null; then
  printf '%s\n' 'PASS: preflight schema requires one non-null recursively strict signedRuntimeSmoke object'
else
  fail 'preflight schema does not require the complete non-null recursively strict signedRuntimeSmoke object'
fi

run_case \
  'repository release-protection hooks are complete' \
  0 \
  'Release protection verification passed.' \
  bash "${scripts}/verify-release-protection.sh" "$repo_root"

no_publish_line="$(grep -n 'if (( publish == 0 ))' "${scripts}/release.sh" | head -1 | cut -d: -f1 || true)"
publisher_line="$(grep -n 'Scripts/publish-release-transaction.sh' "${scripts}/release.sh" | head -1 | cut -d: -f1 || true)"
if [[ -z "$no_publish_line" || -z "$publisher_line" || "$no_publish_line" -ge "$publisher_line" ]]; then
  fail 'signed rehearsal does not stop before the publication transaction'
else
  printf '%s\n' 'PASS: signed rehearsal stops before every publication command'
fi

protection_fixture="${temporary_dir}/release-protection-fixture"
mkdir -p "${protection_fixture}/.github/workflows" "${protection_fixture}/Docs" "${protection_fixture}/Scripts"
cp "${repo_root}/.github/CODEOWNERS" "${protection_fixture}/.github/CODEOWNERS"
cp "${repo_root}/.github/workflows/macos-ci.yml" "${protection_fixture}/.github/workflows/macos-ci.yml"
cp "${repo_root}/.github/workflows/security-scheduled.yml" "${protection_fixture}/.github/workflows/security-scheduled.yml"
cp "${repo_root}/.github/workflows/release.yml" "${protection_fixture}/.github/workflows/release.yml"
cp "${repo_root}/.github/workflows/release-rehearsal.yml" "${protection_fixture}/.github/workflows/release-rehearsal.yml"
cp "${repo_root}/.github/workflows/emergency-release-rollback.yml" "${protection_fixture}/.github/workflows/emergency-release-rollback.yml"
cp "${repo_root}/Docs/Release-Protection.md" "${protection_fixture}/Docs/Release-Protection.md"
for script in release.sh release-preflight.sh publish-release-transaction.sh publish-release-appcast.sh rollback-release-appcast.sh emergency-release-rollback.sh verify-release-version-state.sh; do
  cp "${scripts}/${script}" "${protection_fixture}/Scripts/${script}"
done
run_case \
  'complete release-protection fixture passes before mutation' \
  0 \
  'Release protection verification passed.' \
  bash "${scripts}/verify-release-protection.sh" "$protection_fixture"

isolation_fixture="${temporary_dir}/release-isolation-fixture"
cp -R "$protection_fixture" "$isolation_fixture"
sed 's/, supra-release-isolated//' \
  "${isolation_fixture}/.github/workflows/release.yml" \
  >"${isolation_fixture}/.github/workflows/release.yml.tmp"
mv "${isolation_fixture}/.github/workflows/release.yml.tmp" \
  "${isolation_fixture}/.github/workflows/release.yml"
run_case \
  'removing isolated release runner label fails closed' \
  1 \
  'release workflow is not bound to the isolated release runner' \
  bash "${scripts}/verify-release-protection.sh" "$isolation_fixture"

guard_fixture="${temporary_dir}/release-isolation-guard-fixture"
cp -R "$protection_fixture" "$guard_fixture"
awk '
  $0 !~ /SUPRA_RELEASE_ISOLATED_RUNNER/ &&
  $0 !~ /signed release qualification requires the dedicated isolated release runner/
' "${guard_fixture}/Scripts/release.sh" >"${guard_fixture}/Scripts/release.sh.tmp"
mv "${guard_fixture}/Scripts/release.sh.tmp" "${guard_fixture}/Scripts/release.sh"
printf '%s\n' '# SUPRA_RELEASE_ISOLATED_RUNNER policy marker only' \
  >>"${guard_fixture}/Scripts/release.sh"
run_case \
  'replacing the isolated-runner guard with a comment fails closed' \
  1 \
  'release entrypoint does not enforce the isolated release runner' \
  bash "${scripts}/verify-release-protection.sh" "$guard_fixture"

foreign_runner_fixture="${temporary_dir}/foreign-isolated-runner-fixture"
cp -R "$protection_fixture" "$foreign_runner_fixture"
printf '%s\n' \
  '  unauthorized-release-runner:' \
  '    runs-on: [self-hosted, macOS, ARM64, supra-release, supra-release-isolated]' \
  '    steps:' \
  '      - run: exit 0' \
  >>"${foreign_runner_fixture}/.github/workflows/macos-ci.yml"
run_case \
  'using the isolated release label outside protected workflows fails closed' \
  1 \
  'isolated release runner label is used outside protected release workflows' \
  bash "${scripts}/verify-release-protection.sh" "$foreign_runner_fixture"

boundary_docs_fixture="${temporary_dir}/release-boundary-docs-fixture"
cp -R "$protection_fixture" "$boundary_docs_fixture"
sed 's/same-UID/same user/g' \
  "${boundary_docs_fixture}/Docs/Release-Protection.md" \
  >"${boundary_docs_fixture}/Docs/Release-Protection.md.tmp"
mv "${boundary_docs_fixture}/Docs/Release-Protection.md.tmp" \
  "${boundary_docs_fixture}/Docs/Release-Protection.md"
run_case \
  'removing the documented same-UID isolation boundary fails closed' \
  1 \
  'release protection documentation omits the same-UID threat boundary' \
  bash "${scripts}/verify-release-protection.sh" "$boundary_docs_fixture"

awk '$0 !~ /environment: production-release/' \
  "${protection_fixture}/.github/workflows/release.yml" \
  >"${protection_fixture}/.github/workflows/release.yml.tmp"
mv "${protection_fixture}/.github/workflows/release.yml.tmp" \
  "${protection_fixture}/.github/workflows/release.yml"
run_case \
  'removing protected release environment fails closed' \
  1 \
  'release workflow is not bound to production-release' \
  bash "${scripts}/verify-release-protection.sh" "$protection_fixture"

if (( failures != 0 )); then
  printf 'Release transaction tests failed: %d\n' "$failures" >&2
  exit 1
fi
printf '%s\n' 'All release transaction tests passed.'
