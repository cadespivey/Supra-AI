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

app_smoke_selector_present() {
  local file="$1"
  local selector="$2"
  awk -v selector="$selector" '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line == selector " \\") { found = 1 }
    }
    END { exit found ? 0 : 1 }
  ' "$file"
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

guided_class_only_hook="${temporary_dir}/GuidedClassOnlyUITests.swift"
printf '%s\n' \
  'func testDiagnosticsShowsPromptClassifierAvailability() {}' \
  'func testLegacyOutputWarningAnnouncesStatusAndUnavailableExport() {}' \
  'func testLegacyBillingWarningAnnouncesReviewAndUnavailableExport() {}' \
  'final class GuidedDocumentQAUITests: XCTestCase {}' \
  >"$guided_class_only_hook"
run_case \
  "a guided Q&A class without the shipping method fails closed" \
  1 \
  "remediation accessibility smoke tests are missing" \
  env SUPRA_XPC_INTEGRATION_TEST_FILE="$xpc_hook" \
    SUPRA_ACCESSIBILITY_SMOKE_TEST_FILE="$guided_class_only_hook" \
    bash "${scripts}/run-app-smoke-tests.sh" --check

# Standing guard: restore hosted-test discovery and selector wiring landed in
# 866c551; these already-green meta-cases intentionally lock future omission.
run_case \
  "a missing restore Settings smoke test fails closed" \
  1 \
  "restore Settings/recovery accessibility smoke tests are missing" \
  env SUPRA_RESTORE_UI_TEST_FILE="$missing_hook" \
    bash "${scripts}/run-app-smoke-tests.sh" --check

accessibility_hook="${temporary_dir}/ResearchAuthoritiesUITests.swift"
printf '%s\n' \
  'func testDiagnosticsShowsPromptClassifierAvailability() {}' \
  'func testLegacyOutputWarningAnnouncesStatusAndUnavailableExport() {}' \
  'func testLegacyBillingWarningAnnouncesReviewAndUnavailableExport() {}' \
  'final class GuidedDocumentQAUITests: XCTestCase {' \
  '  func testGuidedChooserGeneratesPreviewsAndCancelsWithoutReplacingSavedResult() {}' \
  '}' \
  >"$accessibility_hook"
restore_hook="${temporary_dir}/RestoreSettingsUITests.swift"
printf '%s\n' \
  'func testInvalidSnapshotShowsFactsAndCannotBeSelected() {}' \
  'func testRestoreConfirmationNamesReplacementAndSupportsKeyboardCancel() {}' \
  'func testSuccessfulStageShowsTerminalSurfaceAndQuits() {}' \
  'func testRecoveryRequiredShellProvidesPreservationAndQuitInstructions() {}' \
  >"$restore_hook"
run_case \
  "classless restore methods fail the shipping class selector" \
  1 \
  "restore Settings/recovery accessibility smoke tests are missing" \
  env SUPRA_XPC_INTEGRATION_TEST_FILE="$xpc_hook" \
    SUPRA_ACCESSIBILITY_SMOKE_TEST_FILE="$accessibility_hook" \
    SUPRA_RESTORE_UI_TEST_FILE="$restore_hook" \
    bash "${scripts}/run-app-smoke-tests.sh" --check

printf '%s\n' \
  'final class RestoreSettingsUITests: XCTestCase {}' \
  'func testInvalidSnapshotShowsFactsAndCannotBeSelected() {}' \
  'func testRestoreConfirmationNamesReplacementAndSupportsKeyboardCancel() {}' \
  'func testSuccessfulStageShowsTerminalSurfaceAndQuits() {}' \
  'func testRecoveryRequiredShellProvidesPreservationAndQuitInstructions() {}' \
  >"$restore_hook"
run_case \
  "restore methods after an empty shipping class fail the selector" \
  1 \
  "restore Settings/recovery accessibility smoke tests are missing" \
  env SUPRA_XPC_INTEGRATION_TEST_FILE="$xpc_hook" \
    SUPRA_ACCESSIBILITY_SMOKE_TEST_FILE="$accessibility_hook" \
    SUPRA_RESTORE_UI_TEST_FILE="$restore_hook" \
    bash "${scripts}/run-app-smoke-tests.sh" --check

printf '%s\n' \
  'final class RestoreSettingsUITests: XCTestCase {' \
  '  func testInvalidSnapshotShowsFactsAndCannotBeSelected() {}' \
  '  func testRestoreConfirmationNamesReplacementAndSupportsKeyboardCancel() {}' \
  '  func testSuccessfulStageShowsTerminalSurfaceAndQuits() {}' \
  '  func testRecoveryRequiredShellProvidesPreservationAndQuitInstructions() {}' \
  '}' \
  >"$restore_hook"
run_case \
  "missing supported motion hosted smoke tests fail closed" \
  1 \
  "supported motion hosted smoke tests are missing" \
  env SUPRA_XPC_INTEGRATION_TEST_FILE="$xpc_hook" \
    SUPRA_ACCESSIBILITY_SMOKE_TEST_FILE="$accessibility_hook" \
    bash "${scripts}/run-app-smoke-tests.sh" --check

printf '%s\n' \
  'func testDiagnosticsShowsPromptClassifierAvailability() {}' \
  'func testLegacyOutputWarningAnnouncesStatusAndUnavailableExport() {}' \
  'func testLegacyBillingWarningAnnouncesReviewAndUnavailableExport() {}' \
  'final class GuidedDocumentQAUITests: XCTestCase {' \
  '  func testGuidedChooserGeneratesPreviewsAndCancelsWithoutReplacingSavedResult() {}' \
  '}' \
  'func testTUIMTD01Through03SupportedMotionProducesResultActionsAndOpenableDOCX() {}' \
  'func testTUIMTD04Through05BlockedMotionNamesReasonAndHasNoFileActions() {}' \
  'func testTUIMTD06CancellingInFlightMotionLeavesNoArtifact() {}' \
  >"$accessibility_hook"
# Standing guard: the existing class-name check already rejects classless
# functions; this fixture ensures the class-scope hardening keeps doing so.
run_case \
  "classless motion methods fail the shipping class selector" \
  1 \
  "supported motion hosted smoke tests are missing" \
  env SUPRA_XPC_INTEGRATION_TEST_FILE="$xpc_hook" \
    SUPRA_ACCESSIBILITY_SMOKE_TEST_FILE="$accessibility_hook" \
    bash "${scripts}/run-app-smoke-tests.sh" --check

printf '%s\n' \
  'func testDiagnosticsShowsPromptClassifierAvailability() {}' \
  'func testLegacyOutputWarningAnnouncesStatusAndUnavailableExport() {}' \
  'func testLegacyBillingWarningAnnouncesReviewAndUnavailableExport() {}' \
  'final class GuidedDocumentQAUITests: XCTestCase {' \
  '  func testGuidedChooserGeneratesPreviewsAndCancelsWithoutReplacingSavedResult() {}' \
  '}' \
  'final class MotionToDismissWorkspaceUITests: XCTestCase {}' \
  'func testTUIMTD01Through03SupportedMotionProducesResultActionsAndOpenableDOCX() {}' \
  'func testTUIMTD04Through05BlockedMotionNamesReasonAndHasNoFileActions() {}' \
  'func testTUIMTD06CancellingInFlightMotionLeavesNoArtifact() {}' \
  >"$accessibility_hook"
# Expected RED: independent class and method greps accept methods placed after
# an empty shipping class, but the selected XCTest class still runs none of them.
run_case \
  "motion methods after an empty shipping class fail the selector" \
  1 \
  "supported motion hosted smoke tests are missing" \
  env SUPRA_XPC_INTEGRATION_TEST_FILE="$xpc_hook" \
    SUPRA_ACCESSIBILITY_SMOKE_TEST_FILE="$accessibility_hook" \
    bash "${scripts}/run-app-smoke-tests.sh" --check

printf '%s\n' \
  'func testDiagnosticsShowsPromptClassifierAvailability() {}' \
  'func testLegacyOutputWarningAnnouncesStatusAndUnavailableExport() {}' \
  'func testLegacyBillingWarningAnnouncesReviewAndUnavailableExport() {}' \
  'final class GuidedDocumentQAUITests: XCTestCase {' \
  '  func testGuidedChooserGeneratesPreviewsAndCancelsWithoutReplacingSavedResult() {}' \
  '}' \
  'final class MotionToDismissWorkspaceUITests: XCTestCase {' \
  '  func testTUIMTD01Through03SupportedMotionProducesResultActionsAndOpenableDOCX() {}' \
  '  func testTUIMTD04Through05BlockedMotionNamesReasonAndHasNoFileActions() {}' \
  '  func testTUIMTD06CancellingInFlightMotionLeavesNoArtifact() { XCTAssertEqual(regularArtifacts(beneath: storageRoot), []) }' \
  '  func testTUIAUTH01ReviewedPropositionCanBeRemovedAndRecordedExactly() {}' \
  '  func testTUIAUTH02BlockedAuthorityRemediatesIntoMotionReadiness() {}' \
  '  private func regularArtifacts(beneath root: URL) -> [String] {' \
  '    _ = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [])' \
  '    _ = values.isRegularFile == true' \
  '    return []' \
  '  }' \
  '}' \
  'final class InterruptedDraftRecoveryUITests: XCTestCase {' \
  '  func testTUIDRAFTREC01Through04NoticeRevealAndAcknowledgementPreserveFiles() {' \
  '    let notice = app.sheets.firstMatch' \
  '    _ = NSPredicate(format: "value == %@", "Review previous generated work")' \
  '    _ = root.appendingPathComponent(".supra-ui-test-store", isDirectory: true)' \
  '    _ = secondLaunch.recoveryIDs,' \
  '        firstLaunch.recoveryIDs,' \
  '    _ = secondLaunch.databaseFileNumber,' \
  '        firstLaunch.databaseFileNumber' \
  '    app.terminate()' \
  '    _ = app.wait(for: .notRunning, timeout: 5)' \
  '    _ = app.descendants(matching: .any)["drafting.interruptedRecovery.fixtureEvidence"]' \
  '    let expectedDigest = SHA256.hash(data: expectedBytes)' \
  '    XCTAssertEqual(secondLaunch.fixtureEvidence.regularArtifactCount, 1)' \
  '    let acknowledgedEvidence = try recoveryFixtureEvidence(in: app)' \
  '    _ = acknowledgedEvidence.relativePath, secondLaunch.fixtureEvidence.relativePath' \
  '    _ = acknowledgedEvidence.matterID, secondLaunch.fixtureEvidence.matterID' \
  '    _ = acknowledgedEvidence.byteCount, secondLaunch.fixtureEvidence.byteCount' \
  '    _ = acknowledgedEvidence.sha256, secondLaunch.fixtureEvidence.sha256' \
  '  }' \
  '}' \
  >"$accessibility_hook"
run_case \
  "a missing interrupted draft recovery hosted test fails closed" \
  1 \
  "interrupted draft recovery hosted smoke tests are missing" \
  env SUPRA_XPC_INTEGRATION_TEST_FILE="$xpc_hook" \
    SUPRA_ACCESSIBILITY_SMOKE_TEST_FILE="$accessibility_hook" \
    SUPRA_DRAFT_RECOVERY_UI_TEST_FILE="$missing_hook" \
    SUPRA_RESTORE_UI_TEST_FILE="$restore_hook" \
    bash "${scripts}/run-app-smoke-tests.sh" --check

recovery_old_selector_hook="${temporary_dir}/InterruptedDraftRecoveryOldSelectorUITests.swift"
printf '%s\n' \
  'final class InterruptedDraftRecoveryUITests: XCTestCase {' \
  '  func testTUIDRAFTREC01Through04NoticeRevealAndAcknowledgementPreserveFiles() {' \
  '    let notice = app.alerts["Review previous generated work"]' \
  '  }' \
  '}' \
  >"$recovery_old_selector_hook"
# Expected RED: a method can exist and still query a nonexistent macOS Alert
# while each launch silently receives a freshly seeded UUID Store.
run_case \
  "an alert query and fresh-store relaunch fail the recovery contract" \
  1 \
  "interrupted draft recovery smoke must reopen one Store and query the macOS sheet title" \
  env SUPRA_XPC_INTEGRATION_TEST_FILE="$xpc_hook" \
    SUPRA_ACCESSIBILITY_SMOKE_TEST_FILE="$accessibility_hook" \
    SUPRA_DRAFT_RECOVERY_UI_TEST_FILE="$recovery_old_selector_hook" \
    SUPRA_RESTORE_UI_TEST_FILE="$restore_hook" \
    bash "${scripts}/run-app-smoke-tests.sh" --check
# Standing guard: the exact methods nested in the shipping XCTest class must
# continue to satisfy check-only discovery after the fail-closed hardening.
run_case \
  "the exact hosted XPC and accessibility selectors satisfy the hook" \
  0 \
  "Hosted XPC integration hook passed." \
  env SUPRA_XPC_INTEGRATION_TEST_FILE="$xpc_hook" \
    SUPRA_ACCESSIBILITY_SMOKE_TEST_FILE="$accessibility_hook" \
    SUPRA_RESTORE_UI_TEST_FILE="$restore_hook" \
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

# T-RP-CI-02 expected RED: an unanchored selector presence check accepts a
# commented command line even though xcodebuild will never execute it.
commented_review_selector="${temporary_dir}/commented-review-selector.sh"
printf '%s\n' \
  '# -only-testing:SupraAIUITests/CaseFileReviewHostedUITests/testTRPUI18MinimumWidthSourcesKeepsProgressAndCompactFilterUsable \' \
  >"$commented_review_selector"
if app_smoke_selector_present \
    "$commented_review_selector" \
    '-only-testing:SupraAIUITests/CaseFileReviewHostedUITests/testTRPUI18MinimumWidthSourcesKeepsProgressAndCompactFilterUsable'; then
  record_failure 'app smoke selector guard accepts a commented-out Review test'
else
  printf '%s\n' 'PASS: app smoke selector guard rejects commented-out Review tests'
fi

# T-RP-CI-03 expected RED: `class_contains_test` currently accepts a commented
# Swift method inside the correct class, so --check can pass after all six
# claimed Review tests are disabled.
commented_review_tests="${temporary_dir}/CommentedCaseFileReviewUITests.swift"
printf '%s\n' \
  'final class CaseFileReviewCompositionUITests: XCTestCase {' \
  '  // func testTRPUI13WorkflowControlsPinAccessibleFiltersProgressAndGuardedNavigation() {}' \
  '}' \
  'final class CaseFileReviewHostedUITests: XCTestCase {' \
  '  // func testTRPUI14ProgressAndAttentionFiltersReconcileHiddenSourcesAndExplicitEmptyState() {}' \
  '  // func testTRPUI15DirtyDraftCancelKeepsProjectAndDiscardSwitchesWithoutCrossProjectLeak() {}' \
  '  // func testTRPUI16FailedProjectSwitchRetainsExactDraftForResume() {}' \
  '  // func testTRPUI17FailedOpenReviewRetainsExactDraftForResume() {}' \
  '  // func testTRPUI18MinimumWidthSourcesKeepsProgressAndCompactFilterUsable() {}' \
  '}' >"$commented_review_tests"
run_case \
  "commented Review methods fail the app-smoke presence guard" \
  1 \
  "claimed Review workflow smoke tests are missing" \
  env SUPRA_CASE_FILE_REVIEW_UI_TEST_FILE="$commented_review_tests" \
    bash "${scripts}/run-app-smoke-tests.sh" --check
# Expected RED: the Diagnostics routing-availability test existed but the
# protected smoke command did not select it, so deletion or wording drift would
# still leave every executed CI test green.
if grep -Fq -- '-only-testing:SupraAIUITests/DocumentChunkerRolloutUITests/testDiagnosticsShowsPromptClassifierAvailability' "$app_smoke_script"; then
  printf '%s\n' 'PASS: app smoke executes the prompt-routing Diagnostics guard'
else
  record_failure 'app smoke does not execute the prompt-routing Diagnostics guard'
fi

# Guided document Q&A is a production hosted-runtime workflow, so the protected
# smoke selector must execute its deterministic generate/preview/cancel contract.
if grep -Fq -- '-only-testing:SupraAIUITests/GuidedDocumentQAUITests/testGuidedChooserGeneratesPreviewsAndCancelsWithoutReplacingSavedResult' "$app_smoke_script"; then
  printf '%s\n' 'PASS: app smoke executes the guided document Q&A hosted guard'
else
  record_failure 'app smoke does not execute the guided document Q&A hosted guard'
fi

# T-QUEUE-03 expected RED: the shipping composition proof exists in the UI-test
# target, but the protected app-smoke command does not select it yet. A test that
# CI never executes cannot guard production runner wiring.
if grep -Fq -- '-only-testing:SupraAIUITests/CorpusReviewQueueCompositionUITests' "$app_smoke_script"; then
  printf '%s\n' 'PASS: app smoke executes the corpus review queue composition guard'
else
  record_failure 'app smoke does not execute the corpus review queue composition guard'
fi

# T-RP-CI-01 expected RED: the verified Review workflow claim names app-smoke,
# but that protected command does not select the progress/filter, guarded
# navigation, failed-navigation recovery, or minimum-width Sources gates.
review_workflow_selectors=(
  '-only-testing:SupraAIUITests/CaseFileReviewCompositionUITests/testTRPUI13WorkflowControlsPinAccessibleFiltersProgressAndGuardedNavigation'
  '-only-testing:SupraAIUITests/CaseFileReviewHostedUITests/testTRPUI14ProgressAndAttentionFiltersReconcileHiddenSourcesAndExplicitEmptyState'
  '-only-testing:SupraAIUITests/CaseFileReviewHostedUITests/testTRPUI15DirtyDraftCancelKeepsProjectAndDiscardSwitchesWithoutCrossProjectLeak'
  '-only-testing:SupraAIUITests/CaseFileReviewHostedUITests/testTRPUI16FailedProjectSwitchRetainsExactDraftForResume'
  '-only-testing:SupraAIUITests/CaseFileReviewHostedUITests/testTRPUI17FailedOpenReviewRetainsExactDraftForResume'
  '-only-testing:SupraAIUITests/CaseFileReviewHostedUITests/testTRPUI18MinimumWidthSourcesKeepsProgressAndCompactFilterUsable'
)
review_workflow_missing=0
for selector in "${review_workflow_selectors[@]}"; do
  if ! app_smoke_selector_present "$app_smoke_script" "$selector"; then
    review_workflow_missing=1
  fi
done
if (( review_workflow_missing == 0 )); then
  printf '%s\n' 'PASS: app smoke executes the claimed Review workflow guards'
else
  record_failure 'app smoke does not execute every claimed Review workflow guard'
fi

# The deterministic guided-Q&A runtime and model fixture are test authority, not
# ordinary launch flags. They must require the hermetic XCUITest launch and keep
# their artifacts out of the user's managed model directory.
app_environment="${repo_root}/Apps/SupraAI/SupraAI/AppEnvironment.swift"
bootstrap_body="$(sed -n '/^    func bootstrap() async {/,/^    }/p' "$app_environment")"
reconcile_line="$(grep -nF '_ = try? draftArtifactReconciler.reconcilePendingIntents()' <<<"$bootstrap_body" | cut -d: -f1 || true)"
remediation_line="$(grep -nF 'remediationRecoverySummary = (try? store.remediationRecovery.summary())' <<<"$bootstrap_body" | cut -d: -f1 || true)"
if grep -Fq 'let effectiveDraftingStorage = draftingStorage ?? documentStorage' "$app_environment" \
    && grep -Fq 'storage: effectiveDraftingStorage' "$app_environment" \
    && grep -Fq 'if !usingFallbackStore, databaseRecoveryState == nil {' <<<"$bootstrap_body" \
    && [[ -n "$reconcile_line" && -n "$remediation_line" && "$reconcile_line" -lt "$remediation_line" ]]; then
  printf '%s\n' 'PASS: shipping bootstrap reconciles draft artifact intents before remediation UI'
else
  record_failure 'shipping bootstrap does not safely reconcile draft artifact intents before remediation UI'
fi

# Expected RED on f500e5a: the hosted recovery relaunch used a new UUID Store
# per process and the filesystem-writing fixture could fall back to the user's
# default managed-document root when its dedicated root was absent.
recovery_root_policy="$(sed -n '/private static func interruptedDraftRecoveryUITestRoot()/,/^    }/p' "$app_environment")"
recovery_store_policy="$(sed -n '/private static func interruptedDraftRecoveryUITestStoreURL()/,/^    }/p' "$app_environment")"
recovery_seeder="$(sed -n '/private func seedUITestInterruptedDraftRecoveryIfNeeded()/,/^    }/p' "$app_environment")"
if grep -Fq 'guard isUITestMode,' <<<"$recovery_root_policy" \
    && grep -Fq 'arguments.contains("-uiTestInterruptedDraftRecovery")' <<<"$recovery_root_policy" \
    && grep -Fq 'environment["SUPRA_UI_TEST_DRAFT_STORAGE_ROOT"]' <<<"$recovery_root_policy" \
    && grep -Fq 'candidate.path.hasPrefix("\(temporaryRoot.path)/")' <<<"$recovery_root_policy" \
    && grep -Fq '.appendingPathComponent(".supra-ui-test-store", isDirectory: true)' <<<"$recovery_store_policy" \
    && grep -Fq '.appendingPathComponent("SupraAI.sqlite", isDirectory: false)' <<<"$recovery_store_policy" \
    && grep -Fq 'if let persistentUITestStoreURL = interruptedDraftRecoveryUITestStoreURL()' "$app_environment" \
    && grep -Eq 'guard (let )?interruptedDraftRecoveryUITestRoot( != nil)?,' <<<"$recovery_seeder"; then
  printf '%s\n' 'PASS: interrupted recovery uses one narrowly authorized hermetic on-disk UI-test Store'
else
  record_failure 'interrupted recovery does not require one narrowly authorized hermetic on-disk UI-test Store'
fi

# Expected RED after the sidecar proved unreadable across the app-container
# boundary: the exact scenario needs an app-side byte probe whose accessibility
# marker contains only a validated managed-relative path and content-free facts.
recovery_drafting_view="${repo_root}/Apps/SupraAI/SupraAI/Matters/MatterDraftingView.swift"
recovery_ui_tests="${repo_root}/Apps/SupraAI/SupraAIUITests/ResearchAuthoritiesUITests.swift"
recovery_fixture_probe="$(sed -n '/private var interruptedDraftRecoveryUITestEvidence:/,/^    }/p' "$recovery_drafting_view")"
recovery_fixture_marker="$(sed -n '/if let evidence = interruptedDraftRecoveryUITestEvidence/,/^                }/p' "$recovery_drafting_view")"
recovery_fixture_parser="$(sed -n '/private func recoveryFixtureEvidence(in app:/,/^    }/p' "$recovery_ui_tests")"
if grep -Fq 'static var interruptedDraftRecoveryUITestManagedRoot: URL?' "$app_environment" \
    && grep -Fq 'drafting.interruptedRecovery.fixtureEvidence' "$recovery_drafting_view" \
    && grep -Fq '.accessibilityLabel(evidence)' <<<"$recovery_fixture_marker" \
    && grep -Fq 'let rawValue = marker.label' <<<"$recovery_fixture_parser" \
    && grep -Fq '@State private var interruptedDraftRecoveryUITestRecoveredURL: URL?' "$recovery_drafting_view" \
    && grep -Fq 'controller.interruptedDraftRecoveries.compactMap(\.fileURL)' "$recovery_drafting_view" \
    && grep -Fq '.onChange(of: controller.interruptedDraftRecoveries)' "$recovery_drafting_view" \
    && grep -Fq 'guard let recoveredURL = interruptedDraftRecoveryUITestRecoveredURL' <<<"$recovery_fixture_probe" \
    && grep -Fq 'FileManager.default.enumerator(' <<<"$recovery_fixture_probe" \
    && grep -Fq 'options: []' <<<"$recovery_fixture_probe" \
    && grep -Fq '.appendingPathComponent(".supra-ui-test-store", isDirectory: true)' <<<"$recovery_fixture_probe" \
    && grep -Fq '!artifactURL.path.hasPrefix("\(testStoreRoot.path)/")' <<<"$recovery_fixture_probe" \
    && grep -Fq 'Data(contentsOf: recoveredURL)' <<<"$recovery_fixture_probe" \
    && grep -Fq 'SHA256.hash(data: recoveredBytes)' <<<"$recovery_fixture_probe" \
    && grep -Fq 'relative=exports/\(matterUUID.uuidString)/Interrupted-publication.md' <<<"$recovery_fixture_probe" \
    && grep -Fq '|bytes=\(recoveredBytes.count)|sha256=\(digest)|regularCount=\(regularArtifactCount)' <<<"$recovery_fixture_probe" \
    && ! grep -Fq 'seeded-matter-id' "$app_environment" \
    && ! grep -Fq 'seeded-matter-id' "$recovery_drafting_view"; then
  printf '%s\n' 'PASS: hosted recovery evidence probes actual bytes without exposing local paths'
else
  record_failure 'hosted recovery evidence is not safely exposed and parsed through a reliable content-free accessibility label'
fi

root_view="${repo_root}/Apps/SupraAI/SupraAI/RootView.swift"
if grep -Fq '.onChange(of: environment.remediationRecoverySummary)' "$root_view" \
    && grep -Fq 'interruptedNoticePresentedThisLaunch' "$root_view" \
    && grep -Fq 'interruptedDraftsPending' "$root_view" \
    && grep -Fq 'presentRemediationNoticeIfNeeded()' "$root_view" \
    && grep -Fq 'Public or user-visible drafts' "$root_view" \
    && grep -Fq 'internal temporary or owned rollback files' "$root_view"; then
  printf '%s\n' 'PASS: interrupted artifact notice survives legacy acknowledgment and late bootstrap summary'
else
  record_failure 'interrupted artifact notice can be hidden by legacy acknowledgment or late bootstrap timing'
fi

drafting_view="${repo_root}/Apps/SupraAI/SupraAI/Matters/MatterDraftingView.swift"
if grep -Fq 'controller.interruptedDraftRecoveries' "$drafting_view" \
    && grep -Fq 'controller.confirmInterruptedDraftArtifactsReviewed' "$drafting_view" \
    && grep -Fq 'NSWorkspace.shared.activateFileViewerSelecting([fileURL])' "$drafting_view" \
    && grep -Fq 'drafting.interruptedRecovery.reveal.' "$drafting_view" \
    && grep -Fq 'drafting.interruptedRecoveryWarning' "$drafting_view" \
    && grep -Fq 'Regenerate Before Use' "$drafting_view"; then
  printf '%s\n' 'PASS: affected drafting surface names and resolves interrupted artifacts explicitly'
else
  record_failure 'affected drafting surface lacks interrupted artifact filenames or explicit resolution'
fi

guided_qa_runtime_composition="$(sed -n '/let guidedQAUITestAuthorized =/,/let guidedQAUITestModelRoot =/p' "$app_environment")"
if grep -Eq 'guidedQAUITestAuthorized[[:space:]]*=[[:space:]]*Self\.isUITestMode[[:space:]]*&&' <<<"$guided_qa_runtime_composition" \
    && grep -Fq 'let baseRuntimeClient: any RuntimeClientProtocol = guidedQAUITestAuthorized' <<<"$guided_qa_runtime_composition" \
    && grep -Fq '? GuidedQAUITestRuntimeClient()' <<<"$guided_qa_runtime_composition" \
    && grep -Fq ': RuntimeClient()' <<<"$guided_qa_runtime_composition" \
    && grep -Fq 'let runtimeClient = ExclusiveRuntimeClient(base: baseRuntimeClient)' <<<"$guided_qa_runtime_composition"; then
  printf '%s\n' 'PASS: guided Q&A synthetic runtime requires hermetic UI-test authority'
else
  record_failure 'guided Q&A synthetic runtime is not gated by hermetic UI-test authority'
fi

if grep -Fq 'guidedQAUITestModelRoot = guidedQAUITestAuthorized' "$app_environment" \
    && grep -Fq 'FileManager.default.temporaryDirectory' "$app_environment" \
    && grep -Fq 'managedModelRoots: guidedQAUITestManagedRoots' "$app_environment" \
    && ! grep -Fq 'ManagedModelStorage.modelsDirectory()' < <(
      sed -n '/private func seedUITestGuidedQAModel/,/^    }/p' "$app_environment"
    ); then
  printf '%s\n' 'PASS: guided Q&A model fixture stays in its authorized temporary root'
else
  record_failure 'guided Q&A model fixture can escape its authorized temporary root'
fi

if grep -Fq 'classificationService: Self.isUITestMode ? nil : DocumentClassificationService(' "$app_environment" \
    && grep -Fq '.filter { $0 && !Self.isUITestMode }' "$app_environment"; then
  printf '%s\n' 'PASS: UI-test launches cannot consume the guided Q&A runtime through background classification'
else
  record_failure 'UI-test launch can consume the guided Q&A runtime through background classification'
fi

if grep -Fq -- '-only-testing:SupraAIUITests/RestoreSettingsUITests' "$app_smoke_script"; then
  printf '%s\n' 'PASS: app smoke executes the restore Settings and recovery hosted guards'
else
  record_failure 'app smoke does not execute the restore Settings and recovery hosted guards'
fi

if grep -Fq -- '-only-testing:SupraAIUITests/MotionToDismissWorkspaceUITests' "$app_smoke_script"; then
  printf '%s\n' 'PASS: app smoke executes the supported motion hosted guards'
else
  record_failure 'app smoke does not execute the supported motion hosted guards'
fi

if grep -Eq '^[[:space:]]+-only-testing:SupraAIUITests/InterruptedDraftRecoveryUITests[[:space:]]+\\$' "$app_smoke_script"; then
  printf '%s\n' 'PASS: app smoke executes the interrupted draft recovery hosted guards'
else
  record_failure 'app smoke does not execute the interrupted draft recovery hosted guards'
fi

motion_view="${repo_root}/Apps/SupraAI/SupraAI/Matters/MatterDraftingView.swift"
motion_ui_tests="${repo_root}/Apps/SupraAI/SupraAIUITests/ResearchAuthoritiesUITests.swift"
letter_generation_function="$(sed -n '/private func generateLetter(token:/,/^    }/p' "$motion_view")"
if grep -Fq 'drafting.motion.fact.\(source.chunkID)' "$motion_view" \
    && grep -Fq 'drafting.motion.authority.\(source.authorityID)' "$motion_view" \
    && grep -Fq 'drafting.motion.fact.ui-motion-fact-chunk' "$motion_ui_tests" \
    && grep -Fq 'ui-motion-authority-success' "$motion_ui_tests" \
    && grep -Fq 'expectedBindingSHA256: bindingSHA256' "$motion_view" \
    && grep -Fq 'displayedAuthorityBindings[authorityID]' "$motion_view" \
    && grep -Fq 'return displayed == current' "$motion_view" \
    && grep -Fq 'source.bindingSHA256 != selection.expectedBindingSHA256' \
      "${repo_root}/Packages/SupraSessions/Sources/SupraSessions/MatterDraftingController.swift"; then
  printf '%s\n' 'PASS: motion smoke selects exact identified, review-bound production source rows'
else
  record_failure 'motion smoke does not select exact identified, review-bound production source rows'
fi

motion_core="${repo_root}/Packages/SupraDraftingCore/Sources/SupraDraftingCore/DraftingCore.swift"
motion_claims="${repo_root}/Docs/Verified-Product-Claims.yml"
if grep -Fq 'is reproduced for counsel’s analysis under the reviewed pleading standards' "$motion_core" \
    && ! grep -Fq 'does not plead the ultimate facts necessary to state a legally sufficient claim' "$motion_core" \
    && grep -Fq 'It does not decide fact-to-ground applicability, legal sufficiency, or filing readiness.' "$motion_view" \
    && grep -Fq 'For the supported motion, the gate checks required structure and exact selected-source reproduction; it does not determine fact-to-ground applicability, legal sufficiency, or filing readiness.' "$motion_claims"; then
  printf '%s\n' 'PASS: motion verification stays scoped to structure and selected-source reproduction'
else
  record_failure 'motion verification copy overstates applicability, legal sufficiency, or filing readiness'
fi

motion_source_loader="$(sed -n '/private func loadMotionSourcesIfNeeded()/,/^    }/p' "$motion_view")"
if grep -Fq -- '-uiTestMotionDraftSuccess' <<<"$motion_source_loader" \
    || grep -Fq 'selectedMotionFactIDs.insert' <<<"$motion_source_loader" \
    || grep -Fq 'selectedMotionAuthorityIDs.insert' <<<"$motion_source_loader"; then
  record_failure 'motion UI-test launch still auto-selects filing sources'
else
  printf '%s\n' 'PASS: motion UI-test launch requires explicit source selection'
fi

motion_controller="${repo_root}/Packages/SupraSessions/Sources/SupraSessions/MatterDraftingController.swift"
motion_readiness="$(sed -n '/private var currentMotionReadiness: MotionDraftReadiness/,/^    }/p' "$motion_view")"
if grep -Fq 'factSources: motionFactSources' <<<"$motion_readiness" \
    && grep -Fq 'authoritySources: motionAuthoritySources' <<<"$motion_readiness" \
    && grep -Fq 'let readiness = motionReadiness(input: input, matterID: matterID)' "$motion_controller"; then
  printf '%s\n' 'PASS: interactive motion readiness uses loaded sources while generation refreshes them'
else
  record_failure 'interactive motion readiness rescans sources or generation does not refresh them'
fi

motion_on_appear="$(sed -n '/\.onAppear {/,/^        }/p' "$motion_view")"
if grep -Fq 'if selection == .kind(.motionToDismiss) { loadMotionSourcesIfNeeded() }' <<<"$motion_on_appear"; then
  printf '%s\n' 'PASS: default non-motion drafting appearance performs no motion source load'
else
  record_failure 'default non-motion drafting appearance still loads motion sources'
fi

motion_launch_helper="$(sed -n '/private func launchMotionApp(/,/^    }/p' "$motion_ui_tests")"
if grep -Fq -- '-uiTestSelectFirstMatter' <<<"$motion_launch_helper" \
    || grep -Fq -- '-uiTestOpenDraftSheet' <<<"$motion_launch_helper" \
    || ! grep -Fq 'matter.click()' "$motion_ui_tests" \
    || ! grep -Fq 'draft.click()' "$motion_ui_tests"; then
  record_failure 'motion hosted smoke bypasses production matter and Draft navigation'
else
  printf '%s\n' 'PASS: motion hosted smoke uses production matter and Draft navigation'
fi

if grep -Fq 'private var isWorking: Bool { generationTask != nil || controller.isGenerating }' "$motion_view" \
    && grep -Fq 'guard !isWorking else { return }' "$motion_view" \
    && grep -Fq '.interactiveDismissDisabled(isWorking)' "$motion_view" \
    && grep -Fq 'generationToken' "$motion_view" \
    && [[ "$(grep -Fc 'guard generationIsCurrent(token, selection: requestedSelection), !Task.isCancelled else { return }' <<<"$letter_generation_function")" -eq 2 ]] \
    && grep -Fq 'drafting.close.header' "$motion_ui_tests" \
    && grep -Fq 'drafting.close.footer' "$motion_ui_tests" \
    && grep -Fq 'regularArtifacts(beneath: storageRoot)' "$motion_ui_tests" \
    && grep -Fq 'private func regularArtifacts(beneath root: URL) -> [String]' "$motion_ui_tests" \
    && grep -Fq 'options: []' "$motion_ui_tests" \
    && grep -Fq 'values.isRegularFile == true' "$motion_ui_tests" \
    && ! grep -Fq 'options: [.skipsHiddenFiles]' "$motion_ui_tests"; then
  printf '%s\n' 'PASS: view-owned drafting work closes continuation, double-start, and dismissal races with disk proof'
else
  record_failure 'drafting UI lacks a routed-letter continuation guard, view-owned task token, dismissal lock, or disk-level absence proof'
fi

if grep -Fq '.accessibilityLabel(sourceAccessibilityLabel' "$motion_view" \
    && grep -Fq '.accessibilityValue(sourceAccessibilityValue' "$motion_view" \
    && grep -Fq 'source.blockingReason ?? source.text' "$motion_view" \
    && grep -Fq 'localizedCaseInsensitiveContains("Selected")' "$motion_ui_tests" \
    && grep -Fq 'fact.label.contains(exactMotionFactTail)' "$motion_ui_tests" \
    && grep -Fq 'authority.label.contains(exactMotionAuthorityExcerpt)' "$motion_ui_tests"; then
  printf '%s\n' 'PASS: motion source rows announce literal state and expose complete selected text'
else
  record_failure 'motion source rows lack literal accessibility state or complete selected text'
fi

if grep -Fq 'motionFactLoadError' "$motion_view" \
    && grep -Fq 'motionAuthorityLoadError' "$motion_view" \
    && grep -Fq 'drafting.motion.sources.retry' "$motion_view"; then
  printf '%s\n' 'PASS: motion source load failures remain distinct from empty libraries and expose retry'
else
  record_failure 'motion source load failures are still presented as empty libraries or have no retry'
fi

if grep -Fq 'The court, judge where applicable, and case number come from the matter.' "$motion_view" \
    && ! grep -Fq 'The court, division, and case number come from the matter.' "$motion_view"; then
  printf '%s\n' 'PASS: motion caption guidance names only fields the controller uses'
else
  record_failure 'motion caption guidance still promises an unused division field'
fi

authority_detail_view="${repo_root}/Apps/SupraAI/SupraAI/Authorities/AuthorityDetailView.swift"
authorities_controller="${repo_root}/Packages/SupraSessions/Sources/SupraSessions/AuthoritiesController.swift"
motion_ui_class="$(sed -n '/final class MotionToDismissWorkspaceUITests:/,/^}/p' "$motion_ui_tests")"
motion_authority_remediation_ui="$(sed -n '/func testTUIAUTH02BlockedAuthorityRemediatesIntoMotionReadiness()/,/^    }/p' "$motion_ui_tests")"
if grep -Fq 'authority.reviewedProposition.status' "$authority_detail_view" \
    && grep -Fq 'authority.reviewedProposition.excerpt' "$authority_detail_view" \
    && grep -Fq 'authority.reviewedProposition.save' "$authority_detail_view" \
    && grep -Fq 'authority.reviewedProposition.remove' "$authority_detail_view" \
    && grep -Fq 'testTUIAUTH01ReviewedPropositionCanBeRemovedAndRecordedExactly' <<<"$motion_ui_class" \
    && grep -Fq 'authorityID: "ui-motion-authority-success"' <<<"$motion_ui_class" \
    && grep -Fq 'exactMotionAuthorityExcerpt' <<<"$motion_ui_class"; then
  printf '%s\n' 'PASS: hosted authority editor proves exact reviewed evidence lifecycle'
else
  record_failure 'hosted authority editor does not prove the exact reviewed evidence lifecycle'
fi

if grep -Fq 'authority.reviewState.markNotAdverse' "$authority_detail_view" \
    && grep -Fq 'markAuthorityNotAdverse' "$authorities_controller" \
    && grep -Fq 'testTUIAUTH02BlockedAuthorityRemediatesIntoMotionReadiness' <<<"$motion_ui_class" \
    && grep -Fq 'ui-motion-authority-blocked' <<<"$motion_ui_class" \
    && grep -Fq 'scrollToHittable(excerpt, in: app)' <<<"$motion_authority_remediation_ui" \
    && grep -Fq 'XCTAssertTrue(excerpt.isHittable, excerpt.debugDescription)' <<<"$motion_authority_remediation_ui"; then
  printf '%s\n' 'PASS: blocked saved authority has an in-context hosted remediation path'
else
  record_failure 'blocked saved authority remediation does not make the exact-excerpt editor visibly hittable before interaction'
fi

matter_workspace_view="${repo_root}/Apps/SupraAI/SupraAI/Matters/MatterWorkspaceView.swift"
if grep -Fq 'prewarm(role: .drafting)' "$matter_workspace_view"; then
  record_failure 'opening Draft still eagerly loads a model before the user selects a model-backed kind'
elif grep -Fq 'selection == .kind(.letterDemand)' "$motion_view" \
    && grep -Fq 'library.prewarm(role: .drafting)' "$motion_view"; then
  printf '%s\n' 'PASS: drafting model prewarm is deferred to the model-backed demand-letter kind'
else
  record_failure 'demand-letter selection no longer prewarms its assigned drafting model'
fi

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

# The AppKit window-resize observer reader was replaced by a SwiftUI
# layout-proposal probe (macOS 27 bottom-chrome clipping fix): the shell sizes
# itself from the height SwiftUI proposes, never from NSWindow metrics observed
# through NotificationCenter. Reintroducing either mechanism would bring back
# the hazards this gate guards — the Sendable/nonisolated observer-callback
# race the previous form of this gate counted isolation hops for, and the
# AppKit-vs-SwiftUI geometry disagreement that clipped the Recycle Bin bar and
# chat composer below the window's bottom edge on macOS 27 — so the gate now
# fails closed on any observer registration or window-metric read in the shell
# (comment lines excluded; the explanatory comments name those APIs).
main_shell_source="${repo_root}/Apps/SupraAI/SupraAI/MainShellView.swift"
window_resize_observers="$(
  { grep -vE '^[[:space:]]*//' "$main_shell_source" |
      grep -F 'NotificationCenter.default.addObserver(' || true; } |
    wc -l | tr -d ' '
)"
window_metric_reads="$(
  { grep -vE '^[[:space:]]*//' "$main_shell_source" |
      grep -E 'contentRect\(forFrameRect:|contentLayoutRect|NSScreen|visibleFrame' || true; } |
    wc -l | tr -d ' '
)"
if [[ "$window_resize_observers" != '0' || "$window_metric_reads" != '0' ]]; then
  record_failure \
    "shell height must come from the SwiftUI layout proposal, not AppKit window observation (observers=${window_resize_observers}, windowMetricReads=${window_metric_reads})"
else
  printf '%s\n' 'PASS: shell height comes from the layout proposal, not AppKit window observation'
fi

# Expected RED before the chat assurance-badge removal: chat message rows must
# not render the assurance badge. The seven-state assurance vocabulary stays on
# the Outputs/export surfaces (and still travels with promoted answers); in
# chat it duplicated the collapsed Support check and read as unexplained noise
# above the answer (user decision; DOCUMENT-OUTPUT-ASSURANCE-UX wording updated
# in the same change). Comment lines excluded.
chat_view_source="${repo_root}/Apps/SupraAI/SupraAI/GlobalChatsView.swift"
chat_assurance_badges="$(
  { grep -vE '^[[:space:]]*//' "$chat_view_source" |
      grep -F 'AssuranceBadge(' || true; } |
    wc -l | tr -d ' '
)"
if [[ "$chat_assurance_badges" != '0' ]]; then
  record_failure \
    "chat message rows must not render the assurance badge (found ${chat_assurance_badges} render site(s) in GlobalChatsView)"
else
  printf '%s\n' 'PASS: chat message rows render no assurance badge'
fi

# Expected RED before the claims meta-harness was wired into CI: no workflow
# executed Tests/Scripts/test-verify-product-claims.sh, so the harness that
# verifies the product-claims gate could rot undetected on main — its
# stale-security-support mutation fixture was in fact dead after the 2.3.x
# version bump and nothing failed until a later change happened to repair it.
# A gate that is never executed is not a gate; the meta-harness must run on
# every protected CI pass.
ci_workflow="${repo_root}/.github/workflows/macos-ci.yml"
# [standing] Match an active run-block command, not a comment mentioning the
# script. This was green at introduction because the workflow already executes
# both commands; it prevents a commented-out gate from satisfying this meta-gate.
if grep -Eq '^[[:space:]]+bash Tests/Scripts/test-verify-product-claims\.sh([[:space:]]|$)' "$ci_workflow"; then
  printf '%s\n' 'PASS: Protected macOS CI executes the product-claims verifier meta-tests'
else
  record_failure 'Protected macOS CI does not execute Tests/Scripts/test-verify-product-claims.sh'
fi

# Expected RED before the one-command release landed: its hermetic contract
# tests (preflight refusals, bounded flake reruns, --hold, --rehearsal) exist
# only if CI runs them.
if grep -Fq 'Tests/Scripts/test-cut-release.sh' "$ci_workflow"; then
  printf '%s\n' 'PASS: Protected macOS CI executes the cut-release contract tests'
else
  record_failure 'Protected macOS CI does not execute Tests/Scripts/test-cut-release.sh'
fi

# Expected RED before the probe-glue guards were wired into CI: the guards over
# AppEnvironment's probe isolation glue (user-store authority, exclusive
# dispatch, no exit(), coverage unavailability reporting) exist only if CI runs
# them.
if grep -Eq '^[[:space:]]+bash Tests/Scripts/test-headless-probe-glue\.sh([[:space:]]|$)' "$ci_workflow"; then
  printf '%s\n' 'PASS: Protected macOS CI executes the headless probe glue guards'
else
  record_failure 'Protected macOS CI does not execute Tests/Scripts/test-headless-probe-glue.sh'
fi

# Expected RED before the release-transaction harness was wired into CI: the
# RELEASE-PROVENANCE claim in Docs/Verified-Product-Claims.yml names
# Tests/Scripts/test-release-transaction.sh as its verifying test with ci_job
# "macos-ci/inventory", and Docs/Release-Runbook.md leans on it as standing
# coverage — but macos-ci.yml's release ceremony step never executed it, so the
# ~1200-line hermetic transaction suite could rot undetected on main. A gate
# that is never executed is not a gate. Match an active run-block command, not
# a comment mentioning the script.
if grep -Eq '^[[:space:]]+bash Tests/Scripts/test-release-transaction\.sh([[:space:]]|$)' "$ci_workflow"; then
  printf '%s\n' 'PASS: Protected macOS CI executes the release transaction harness'
else
  record_failure 'Protected macOS CI does not execute Tests/Scripts/test-release-transaction.sh'
fi

if (( failures != 0 )); then
  printf 'macOS CI gate tests failed: %d\n' "$failures" >&2
  exit 1
fi

printf '%s\n' 'All macOS CI gate tests passed.'
