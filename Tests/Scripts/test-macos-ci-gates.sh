#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
scripts="${repo_root}/Scripts"
temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT
failures=0

record_failure() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

run_case() {
  local name="$1"
  local expected_status="$2"
  local expected_text="$3"
  shift 3
  local output_file="${temporary_dir}/output-${RANDOM}.txt"
  local status=0

  "$@" >"$output_file" 2>&1 || status=$?
  if [[ "$status" -ne "$expected_status" ]]; then
    record_failure "${name}: expected status ${expected_status}, got ${status}"
    sed 's/^/  | /' "$output_file" >&2
  elif ! grep -Fq -- "$expected_text" "$output_file"; then
    record_failure "${name}: expected output to contain: ${expected_text}"
    sed 's/^/  | /' "$output_file" >&2
  else
    printf 'PASS: %s\n' "$name"
  fi
}

package_fixture="${temporary_dir}/packages"
mkdir -p "${package_fixture}/Packages"
while IFS= read -r package; do
  mkdir -p "${package_fixture}/Packages/${package}"
  : >"${package_fixture}/Packages/${package}/Package.swift"
done <<'PACKAGES'
SupraCore
SupraDesignSystem
SupraDiagnostics
SupraDocuments
SupraDrafting
SupraDraftingCore
SupraExports
SupraNetworking
SupraResearch
SupraRuntimeClient
SupraRuntimeInterface
SupraSessions
SupraStore
SupraTestKit
PACKAGES

run_case \
  "fixed package inventory accepts the exact set" \
  0 \
  "Local package inventory passed: 14 packages." \
  env SUPRA_REPO_ROOT="$package_fixture" bash "${scripts}/list-local-packages.sh" --verify

mkdir -p "${package_fixture}/Packages/SupraUnlisted"
: >"${package_fixture}/Packages/SupraUnlisted/Package.swift"
run_case \
  "an unlisted package fails inventory" \
  1 \
  "unlisted local package: SupraUnlisted" \
  env SUPRA_REPO_ROOT="$package_fixture" bash "${scripts}/list-local-packages.sh" --verify

migration_file="${temporary_dir}/SupraMigrator.swift"
printf '%s\n' \
  'migrator.registerMigration("v001_first") { _ in }' \
  'migrator.registerMigration("v002_second") { _ in }' \
  'migrator.registerMigration("v003_third") { _ in }' >"$migration_file"
run_case \
  "contiguous migrations are derived dynamically" \
  0 \
  "Migration sequence passed: v001 through v003 (3 migrations)." \
  bash "${scripts}/verify-migration-sequence.sh" "$migration_file"

printf '%s\n' \
  'migrator.registerMigration("v001_first") { _ in }' \
  'migrator.registerMigration("v003_third") { _ in }' >"$migration_file"
run_case \
  "a migration gap fails" \
  1 \
  "migration sequence gap: expected v002, found v003" \
  bash "${scripts}/verify-migration-sequence.sh" "$migration_file"

release_project="${temporary_dir}/release-project.pbxproj"
release_appcast="${temporary_dir}/release-appcast.xml"
release_constants="${temporary_dir}/release-constants.ts"
printf '%s\n' \
  'MARKETING_VERSION = 2.2.1;' \
  'CURRENT_PROJECT_VERSION = 387;' \
  'MARKETING_VERSION = 2.2.1;' \
  'CURRENT_PROJECT_VERSION = 387;' \
  'MARKETING_VERSION = 2.2.1;' \
  'CURRENT_PROJECT_VERSION = 387;' \
  'MARKETING_VERSION = 2.2.1;' \
  'CURRENT_PROJECT_VERSION = 387;' >"$release_project"
printf '%s\n' \
  '<rss xmlns:sparkle="https://sparkle-project.org/xml-namespaces/sparkle"><channel><item>' \
  '<sparkle:version>386</sparkle:version>' \
  '<sparkle:shortVersionString>2.2.0</sparkle:shortVersionString>' \
  '</item></channel></rss>' >"$release_appcast"
printf '%s\n' \
  'export const FALLBACK_RELEASE_TAG = "v2.2.0";' \
  'export const FALLBACK_RELEASE_VERSION = "2.2.0";' >"$release_constants"

run_case \
  "a reviewed candidate may lead the published appcast" \
  0 \
  "Release version state passed: candidate 2.2.1 (387), published 2.2.0 (386)." \
  bash "${scripts}/verify-release-version-state.sh" \
    --project "$release_project" --appcast "$release_appcast" --constants "$release_constants"

mixed_release_project="${temporary_dir}/mixed-release-project.pbxproj"
awk '!changed && sub(/CURRENT_PROJECT_VERSION = 387;/, "CURRENT_PROJECT_VERSION = 18;") { changed = 1 } { print }' \
  "$release_project" >"$mixed_release_project"
run_case \
  "mixed app and XPC candidate builds fail closed" \
  1 \
  "app and XPC build numbers must be one reviewed value" \
  bash "${scripts}/verify-release-version-state.sh" \
    --project "$mixed_release_project" --appcast "$release_appcast" --constants "$release_constants"

stale_release_constants="${temporary_dir}/stale-release-constants.ts"
sed 's/v2.2.0/v2.1.3/; s/"2.2.0"/"2.1.3"/' \
  "$release_constants" >"$stale_release_constants"
run_case \
  "published fallback drift fails closed" \
  1 \
  "website fallback release metadata must match the newest appcast item" \
  bash "${scripts}/verify-release-version-state.sh" \
    --project "$release_project" --appcast "$release_appcast" --constants "$stale_release_constants"

nonmonotonic_release_project="${temporary_dir}/nonmonotonic-release-project.pbxproj"
sed 's/CURRENT_PROJECT_VERSION = 387;/CURRENT_PROJECT_VERSION = 386;/g' \
  "$release_project" >"$nonmonotonic_release_project"
run_case \
  "a new marketing version requires a newer build" \
  1 \
  "candidate marketing version requires a build newer than the published appcast" \
  bash "${scripts}/verify-release-version-state.sh" \
    --project "$nonmonotonic_release_project" --appcast "$release_appcast" --constants "$release_constants"

published_release_project="${temporary_dir}/published-release-project.pbxproj"
sed -e 's/MARKETING_VERSION = 2.2.1;/MARKETING_VERSION = 2.2.0;/g' \
  -e 's/CURRENT_PROJECT_VERSION = 387;/CURRENT_PROJECT_VERSION = 386;/g' \
  "$release_project" >"$published_release_project"
run_case \
  "candidate metadata may equal the published release after publication" \
  0 \
  "Release version state passed: candidate 2.2.0 (386), published 2.2.0 (386)." \
  bash "${scripts}/verify-release-version-state.sh" \
    --project "$published_release_project" --appcast "$release_appcast" --constants "$release_constants"

older_release_project="${temporary_dir}/older-release-project.pbxproj"
sed 's/MARKETING_VERSION = 2.2.1;/MARKETING_VERSION = 2.1.9;/g' \
  "$release_project" >"$older_release_project"
run_case \
  "an older marketing version fails even with a newer build" \
  1 \
  "candidate marketing version must be newer than the published appcast" \
  bash "${scripts}/verify-release-version-state.sh" \
    --project "$older_release_project" --appcast "$release_appcast" --constants "$release_constants"

same_version_new_build_project="${temporary_dir}/same-version-new-build-project.pbxproj"
sed 's/MARKETING_VERSION = 2.2.1;/MARKETING_VERSION = 2.2.0;/g' \
  "$release_project" >"$same_version_new_build_project"
run_case \
  "an unchanged marketing version cannot carry a different build" \
  1 \
  "candidate build must match the published appcast when the marketing version is unchanged" \
  bash "${scripts}/verify-release-version-state.sh" \
    --project "$same_version_new_build_project" --appcast "$release_appcast" --constants "$release_constants"

split_release_appcast="${temporary_dir}/split-release-appcast.xml"
printf '%s\n' \
  '<rss xmlns:sparkle="https://sparkle-project.org/xml-namespaces/sparkle"><channel><item>' \
  '<sparkle:shortVersionString>2.2.0</sparkle:shortVersionString>' \
  '</item><item>' \
  '<sparkle:version>386</sparkle:version>' \
  '</item></channel></rss>' >"$split_release_appcast"
run_case \
  "appcast fields from different items cannot be combined" \
  1 \
  "newest appcast item must contain exactly one marketing version and build" \
  bash "${scripts}/verify-release-version-state.sh" \
    --project "$release_project" --appcast "$split_release_appcast" --constants "$release_constants"

malformed_release_appcast="${temporary_dir}/malformed-release-appcast.xml"
printf '%s\n' \
  '<rss xmlns:sparkle="https://sparkle-project.org/xml-namespaces/sparkle"><channel><item>' \
  '<sparkle:version>386</sparkle:version>' \
  '<sparkle:shortVersionString>2.2.0</sparkle:shortVersionString>' \
  '</item>' >"$malformed_release_appcast"
run_case \
  "malformed appcast XML fails closed" \
  1 \
  "appcast is not well-formed XML" \
  bash "${scripts}/verify-release-version-state.sh" \
    --project "$release_project" --appcast "$malformed_release_appcast" --constants "$release_constants"

duplicate_release_constants="${temporary_dir}/duplicate-release-constants.ts"
cp "$release_constants" "$duplicate_release_constants"
printf '%s\n' \
  'export const FALLBACK_RELEASE_TAG = "v9.9.9";' \
  'export const FALLBACK_RELEASE_VERSION = "9.9.9";' >>"$duplicate_release_constants"
run_case \
  "duplicate website fallback declarations fail closed" \
  1 \
  "website fallback release metadata must contain one tag and version" \
  bash "${scripts}/verify-release-version-state.sh" \
    --project "$release_project" --appcast "$release_appcast" --constants "$duplicate_release_constants"

artifact_fixture="${temporary_dir}/artifacts"
mkdir -p "${artifact_fixture}/Sources"
printf 'ordinary source\n' >"${artifact_fixture}/Sources/Feature.swift"
run_case \
  "a clean artifact tree passes" \
  0 \
  "Prohibited artifact scan passed." \
  bash "${scripts}/verify-prohibited-artifacts.sh" "$artifact_fixture"

mkdir -p "${artifact_fixture}/ClientData/Acme"
printf 'synthetic fixture only\n' >"${artifact_fixture}/ClientData/Acme/private.txt"
run_case \
  "a prohibited synthetic path fails" \
  1 \
  "prohibited artifact path: ClientData/Acme/private.txt" \
  bash "${scripts}/verify-prohibited-artifacts.sh" "$artifact_fixture"

secret_fixture="${temporary_dir}/secrets"
mkdir -p "$secret_fixture"
printf 'SUPRA_MODEL_BACKEND=mlx\n' >"${secret_fixture}/clean.env.example"
run_case \
  "a clean secret fixture passes" \
  0 \
  "Secret scan passed." \
  bash "${scripts}/verify-secrets.sh" "$secret_fixture"

secret_canary='sk-proj-'
secret_canary+='0123456789abcdefghijklmnop'
printf 'SUPRA_API_KEY=%s\n' "$secret_canary" >"${secret_fixture}/canary.env"
secret_output="${temporary_dir}/secret-output.txt"
secret_status=0
bash "${scripts}/verify-secrets.sh" "$secret_fixture" >"$secret_output" 2>&1 || secret_status=$?
if [[ "$secret_status" -ne 1 ]] || ! grep -Fq 'possible secret in: canary.env' "$secret_output"; then
  record_failure "a secret canary must fail without exposing its value"
  sed 's/^/  | /' "$secret_output" >&2
elif grep -Fq "$secret_canary" "$secret_output"; then
  record_failure "secret scanner output exposed the canary value"
else
  printf '%s\n' 'PASS: a secret canary fails without exposing its value'
fi

app_entitlements="${temporary_dir}/SupraAI.entitlements"
service_entitlements="${temporary_dir}/SupraRuntimeService.entitlements"
plutil -create xml1 "$app_entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.app-sandbox bool true' "$app_entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.files.bookmarks.app-scope bool true' "$app_entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.files.user-selected.read-write bool true' "$app_entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.network.client bool true' "$app_entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.temporary-exception.mach-lookup.global-name array' "$app_entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.temporary-exception.mach-lookup.global-name:0 string $(PRODUCT_BUNDLE_IDENTIFIER)-spks' "$app_entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.temporary-exception.mach-lookup.global-name:1 string $(PRODUCT_BUNDLE_IDENTIFIER)-spki' "$app_entitlements"
plutil -create xml1 "$service_entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.app-sandbox bool true' "$service_entitlements"

run_case \
  "expected entitlements pass" \
  0 \
  "Entitlement expectations passed." \
  bash "${scripts}/verify-entitlements.sh" --app "$app_entitlements" --service "$service_entitlements"

/usr/libexec/PlistBuddy -c 'Set :com.apple.security.network.client false' "$app_entitlements"
run_case \
  "entitlement drift fails" \
  1 \
  "app entitlement drift: com.apple.security.network.client" \
  bash "${scripts}/verify-entitlements.sh" --app "$app_entitlements" --service "$service_entitlements"

warning_log="${temporary_dir}/xcodebuild.log"
printf '%s\n' \
  '/tmp/DerivedData/SourcePackages/checkouts/Dependency/File.swift:1: warning: upstream warning' \
  >"$warning_log"
run_case \
  "dependency warnings do not trip the project-source gate" \
  0 \
  "Project-source warning gate passed: 0 warnings." \
  env SUPRA_PROJECT_ROOT="$repo_root" bash "${scripts}/verify-xcode-warnings.sh" "$warning_log"

printf '%s\n' \
  "${repo_root}/Apps/SupraAI/SupraAI/AppEnvironment.swift:1: warning: synthetic warning" \
  >"$warning_log"
run_case \
  "a project-source warning fails" \
  1 \
  "Project-source warning gate failed: 1 warning(s)." \
  env SUPRA_PROJECT_ROOT="$repo_root" bash "${scripts}/verify-xcode-warnings.sh" "$warning_log"

missing_hook="${temporary_dir}/missing-hook.swift"
run_case \
  "a missing hosted XPC integration test fails closed" \
  1 \
  "hosted XPC integration test is missing" \
  env SUPRA_XPC_INTEGRATION_TEST_FILE="$missing_hook" \
    bash "${scripts}/run-app-smoke-tests.sh" --check

xpc_hook="${temporary_dir}/RuntimeXPCIntegrationTests.swift"
printf '%s\n' 'final class RuntimeXPCIntegrationTests: XCTestCase {}' >"$xpc_hook"

run_case \
  "a missing remediation accessibility smoke test fails closed" \
  1 \
  "remediation accessibility smoke tests are missing" \
  env SUPRA_XPC_INTEGRATION_TEST_FILE="$xpc_hook" \
    SUPRA_ACCESSIBILITY_SMOKE_TEST_FILE="$missing_hook" \
    bash "${scripts}/run-app-smoke-tests.sh" --check

accessibility_hook="${temporary_dir}/ResearchAuthoritiesUITests.swift"
printf '%s\n' \
  'func testLegacyOutputWarningAnnouncesStatusAndUnavailableExport() {}' \
  'func testLegacyBillingWarningAnnouncesReviewAndUnavailableExport() {}' \
  >"$accessibility_hook"
run_case \
  "the exact hosted XPC and accessibility selectors satisfy the hook" \
  0 \
  "Hosted XPC integration hook passed." \
  env SUPRA_XPC_INTEGRATION_TEST_FILE="$xpc_hook" \
    SUPRA_ACCESSIBILITY_SMOKE_TEST_FILE="$accessibility_hook" \
    bash "${scripts}/run-app-smoke-tests.sh" --check

run_case \
  "a missing shipping migration fixture matrix fails closed" \
  1 \
  "shipping migration fixture matrix is missing" \
  env SUPRA_MIGRATION_FIXTURE_TEST_FILE="$missing_hook" \
    bash "${scripts}/run-shipping-migration-fixtures.sh" --check

migration_hook="${temporary_dir}/ShippingMigrationFixtureTests.swift"
printf '%s\n' 'final class ShippingMigrationFixtureTests: XCTestCase {}' >"$migration_hook"
run_case \
  "the shipping migration selector satisfies the hook" \
  0 \
  "Shipping migration fixture hook passed." \
  env SUPRA_MIGRATION_FIXTURE_TEST_FILE="$migration_hook" \
    bash "${scripts}/run-shipping-migration-fixtures.sh" --check

# Expected RED before the hosted-boundary harness fix: the combined app smoke
# disables signing even though Debug XPC authentication requires identifier-
# bearing ad-hoc signatures on both the app and its embedded service.
app_smoke_script="${scripts}/run-app-smoke-tests.sh"
if grep -Fq 'CODE_SIGNING_ALLOWED=NO' "$app_smoke_script" \
    || ! grep -Fq 'CODE_SIGNING_ALLOWED=YES' "$app_smoke_script" \
    || ! grep -Fq 'CODE_SIGNING_REQUIRED=YES' "$app_smoke_script" \
    || ! grep -Fq 'CODE_SIGN_IDENTITY=-' "$app_smoke_script"; then
  record_failure "hosted XPC app smoke is not configured for identifier-bearing ad-hoc signatures"
else
  printf '%s\n' 'PASS: hosted XPC app smoke uses identifier-bearing ad-hoc signatures'
fi

npm_stub="${temporary_dir}/npm-stub.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [[ "$*" == "run typecheck" ]]; then exit 23; fi' \
  'exit 0' >"$npm_stub"
chmod +x "$npm_stub"
run_case \
  "a website command failure blocks the gate" \
  23 \
  "Website gate failed: typecheck" \
  env SUPRA_NPM="$npm_stub" SUPRA_FONT_GUARD=/usr/bin/true \
    bash "${scripts}/test-website.sh" "$repo_root/website"

# Expected RED before the runner-portability fix: the source guard invokes
# Homebrew's `rg`, which is not installed on GitHub's stock macOS image.
run_case \
  "the Swift portability guard uses only stock runner tools" \
  0 \
  "SupraSessions Swift 6 portability tests passed." \
  env PATH=/usr/bin:/bin \
    bash "${repo_root}/Tests/Scripts/test-supra-sessions-swift6-portability.sh"

# Expected RED after the window-resize feedback fix: Xcode 16.4 imports block-
# based NotificationCenter callbacks as Sendable/nonisolated even when the
# delivery queue is .main. Each callback must synchronously assert the documented
# main-queue contract before touching the NSView's main-actor-isolated state.
main_shell_source="${repo_root}/Apps/SupraAI/SupraAI/MainShellView.swift"
window_resize_reader_source="${temporary_dir}/WindowLiveResizeHeightView.swift"
sed -n \
  '/^private final class WindowLiveResizeHeightView: NSView {/,/^}/p' \
  "$main_shell_source" >"$window_resize_reader_source"
window_resize_observers="$(
  { grep -F 'NotificationCenter.default.addObserver(' "$window_resize_reader_source" || true; } |
    wc -l | tr -d ' '
)"
main_actor_observer_hops="$(
  { grep -F 'MainActor.assumeIsolated {' "$window_resize_reader_source" || true; } |
    wc -l | tr -d ' '
)"
if [[ "$window_resize_observers" != '3' || "$main_actor_observer_hops" != '3' ]]; then
  record_failure \
    "window resize observers are not synchronously main-actor isolated (observers=${window_resize_observers}, isolated=${main_actor_observer_hops})"
else
  printf '%s\n' 'PASS: window resize observers synchronously assert main-actor isolation'
fi

if (( failures != 0 )); then
  printf 'macOS CI gate tests failed: %d\n' "$failures" >&2
  exit 1
fi

printf '%s\n' 'All macOS CI gate tests passed.'
