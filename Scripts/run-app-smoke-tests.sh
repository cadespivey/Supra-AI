#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
xpc_test="${SUPRA_XPC_INTEGRATION_TEST_FILE:-${repo_root}/Apps/SupraAI/SupraAIUITests/RuntimeXPCIntegrationTests.swift}"
accessibility_test="${SUPRA_ACCESSIBILITY_SMOKE_TEST_FILE:-${repo_root}/Apps/SupraAI/SupraAIUITests/ResearchAuthoritiesUITests.swift}"
recovery_test="${SUPRA_DRAFT_RECOVERY_UI_TEST_FILE:-${accessibility_test}}"
restore_test="${SUPRA_RESTORE_UI_TEST_FILE:-${repo_root}/Apps/SupraAI/SupraAIUITests/RestoreSettingsUITests.swift}"
review_test="${SUPRA_CASE_FILE_REVIEW_UI_TEST_FILE:-${repo_root}/Apps/SupraAI/SupraAIUITests/CaseFileReviewUITests.swift}"
check_only=0
if [[ "${1:-}" == "--check" ]]; then
  check_only=1
  shift
fi

class_contains_test() {
  local file="$1"
  local class_name="$2"
  local method_name="$3"
  awk -v class_name="$class_name" -v method_name="$method_name" '
    function count_matches(value, pattern, copy) {
      copy = value
      return gsub(pattern, "", copy)
    }
    {
      opens = count_matches($0, "\\{")
      closes = count_matches($0, "\\}")
      if ($0 ~ "^[[:space:]]*final[[:space:]]+class[[:space:]]+" class_name "[[:space:]]*:") {
        in_class = 1
        class_depth = depth + 1
      }
      if (in_class && $0 ~ "^[[:space:]]*func[[:space:]]+" method_name "[[:space:]]*\\(") {
        found = 1
      }
      depth += opens - closes
      if (in_class && depth < class_depth) { in_class = 0 }
    }
    END { exit found ? 0 : 1 }
  ' "$file"
}

class_contains_literal() {
  local file="$1"
  local class_name="$2"
  local literal="$3"
  awk -v class_name="$class_name" -v literal="$literal" '
    function count_matches(value, pattern, copy) {
      copy = value
      return gsub(pattern, "", copy)
    }
    {
      opens = count_matches($0, "\\{")
      closes = count_matches($0, "\\}")
      if ($0 ~ "^[[:space:]]*final[[:space:]]+class[[:space:]]+" class_name "[[:space:]]*:") {
        in_class = 1
        class_depth = depth + 1
      }
      if (in_class && index($0, literal) > 0) { found = 1 }
      depth += opens - closes
      if (in_class && depth < class_depth) { in_class = 0 }
    }
    END { exit found ? 0 : 1 }
  ' "$file"
}

if [[ ! -f "$restore_test" ]] \
    || ! class_contains_test "$restore_test" RestoreSettingsUITests testInvalidSnapshotShowsFactsAndCannotBeSelected \
    || ! class_contains_test "$restore_test" RestoreSettingsUITests testRestoreConfirmationNamesReplacementAndSupportsKeyboardCancel \
    || ! class_contains_test "$restore_test" RestoreSettingsUITests testSuccessfulStageShowsTerminalSurfaceAndQuits \
    || ! class_contains_test "$restore_test" RestoreSettingsUITests testRecoveryRequiredShellProvidesPreservationAndQuitInstructions; then
  printf '%s\n' 'ERROR: restore Settings/recovery accessibility smoke tests are missing' >&2
  exit 1
fi
if [[ ! -f "$review_test" ]] \
    || ! class_contains_test "$review_test" CaseFileReviewCompositionUITests testTRPUI13WorkflowControlsPinAccessibleFiltersProgressAndGuardedNavigation \
    || ! class_contains_test "$review_test" CaseFileReviewHostedUITests testTRPUI14ProgressAndAttentionFiltersReconcileHiddenSourcesAndExplicitEmptyState \
    || ! class_contains_test "$review_test" CaseFileReviewHostedUITests testTRPUI15DirtyDraftCancelKeepsProjectAndDiscardSwitchesWithoutCrossProjectLeak \
    || ! class_contains_test "$review_test" CaseFileReviewHostedUITests testTRPUI16FailedProjectSwitchRetainsExactDraftForResume \
    || ! class_contains_test "$review_test" CaseFileReviewHostedUITests testTRPUI17FailedOpenReviewRetainsExactDraftForResume \
    || ! class_contains_test "$review_test" CaseFileReviewHostedUITests testTRPUI18MinimumWidthSourcesKeepsProgressAndCompactFilterUsable \
    || ! class_contains_test "$review_test" CaseFileReviewHostedUITests testTRPUI19DirtyDraftAndFilteredMinimumWidthExportFullSavedSnapshot \
    || ! class_contains_test "$review_test" CaseFileReviewCompositionUITests testTRPUI20FullSnapshotExportUsesPermanentLedgerStrip; then
  printf '%s\n' 'ERROR: claimed Review workflow smoke tests are missing' >&2
  exit 1
fi
if [[ ! -f "$review_test" ]] \
    || ! class_contains_test "$review_test" CaseFileReviewHostedUITests testTRPCREATEUI01NewReviewSetupUsesExactSelectedScopeAndDurableSubmission \
    || ! class_contains_test "$review_test" CaseFileReviewHostedUITests testTRPCREATEUI02PausedRunSurvivesRelaunchThenResumesAndCancels \
    || ! class_contains_test "$review_test" CaseFileReviewCompositionUITests testTRPCREATEUI03ProductionCompositionUsesAtomicPinnedQueueAndExactHandoff \
    || ! class_contains_test "$review_test" CaseFileReviewHostedUITests testTRPCREATEUI04SelectedScopeRejectsEveryExcludedSource \
    || ! class_contains_test "$review_test" CaseFileReviewHostedUITests testTRPCREATEUI05ClosingDuringModelVerificationCancelsWithoutCreatingAJob \
    || ! class_contains_test "$review_test" CaseFileReviewHostedUITests testTRPCREATEUI06ScopeDriftRefreshesReceiptAndRequiresSecondStart; then
  printf '%s\n' 'ERROR: claimed Guided New Review smoke tests are missing' >&2
  exit 1
fi
if (( $# != 0 )); then
  printf 'Usage: %s [--check]\n' "$0" >&2
  exit 2
fi
if [[ ! -f "$xpc_test" ]] || ! grep -Eq 'class[[:space:]]+RuntimeXPCIntegrationTests' "$xpc_test"; then
  printf '%s\n' 'ERROR: hosted XPC integration test is missing: SupraAIUITests/RuntimeXPCIntegrationTests' >&2
  exit 1
fi
if [[ ! -f "$accessibility_test" ]] \
    || ! grep -Fq 'testDiagnosticsShowsPromptClassifierAvailability' "$accessibility_test" \
    || ! grep -Fq 'testLegacyOutputWarningAnnouncesStatusAndUnavailableExport' "$accessibility_test" \
    || ! grep -Fq 'testLegacyBillingWarningAnnouncesReviewAndUnavailableExport' "$accessibility_test" \
    || ! grep -Eq 'class[[:space:]]+GuidedDocumentQAUITests' "$accessibility_test" \
    || ! grep -Fq 'testGuidedChooserGeneratesPreviewsAndCancelsWithoutReplacingSavedResult' "$accessibility_test"; then
  printf '%s\n' 'ERROR: remediation accessibility smoke tests are missing' >&2
  exit 1
fi
if ! class_contains_test "$accessibility_test" MotionToDismissWorkspaceUITests testTUIMTD01Through03SupportedMotionProducesResultActionsAndOpenableDOCX \
    || ! class_contains_test "$accessibility_test" MotionToDismissWorkspaceUITests testTUIMTD04Through05BlockedMotionNamesReasonAndHasNoFileActions \
    || ! class_contains_test "$accessibility_test" MotionToDismissWorkspaceUITests testTUIMTD06CancellingInFlightMotionLeavesNoArtifact \
    || ! class_contains_test "$accessibility_test" MotionToDismissWorkspaceUITests testTUIAUTH01ReviewedPropositionCanBeRemovedAndRecordedExactly \
    || ! class_contains_test "$accessibility_test" MotionToDismissWorkspaceUITests testTUIAUTH02BlockedAuthorityRemediatesIntoMotionReadiness; then
  printf '%s\n' 'ERROR: supported motion hosted smoke tests are missing' >&2
  exit 1
fi
if ! class_contains_test "$recovery_test" InterruptedDraftRecoveryUITests testTUIDRAFTREC01Through04NoticeRevealAndAcknowledgementPreserveFiles; then
  printf '%s\n' 'ERROR: interrupted draft recovery hosted smoke tests are missing' >&2
  exit 1
fi
if ! class_contains_literal "$recovery_test" InterruptedDraftRecoveryUITests 'let notice = app.sheets.firstMatch' \
    || ! class_contains_literal "$recovery_test" InterruptedDraftRecoveryUITests 'NSPredicate(format: "value == %@", "Review previous generated work")' \
    || ! class_contains_literal "$recovery_test" InterruptedDraftRecoveryUITests '.appendingPathComponent(".supra-ui-test-store", isDirectory: true)' \
    || ! class_contains_literal "$recovery_test" InterruptedDraftRecoveryUITests 'secondLaunch.recoveryIDs,' \
    || ! class_contains_literal "$recovery_test" InterruptedDraftRecoveryUITests 'firstLaunch.recoveryIDs,' \
    || ! class_contains_literal "$recovery_test" InterruptedDraftRecoveryUITests 'secondLaunch.databaseFileNumber,' \
    || ! class_contains_literal "$recovery_test" InterruptedDraftRecoveryUITests 'app.terminate()' \
    || ! class_contains_literal "$recovery_test" InterruptedDraftRecoveryUITests 'app.wait(for: .notRunning' \
    || ! class_contains_literal "$recovery_test" InterruptedDraftRecoveryUITests 'drafting.interruptedRecovery.fixtureEvidence' \
    || ! class_contains_literal "$recovery_test" InterruptedDraftRecoveryUITests 'let expectedDigest = SHA256.hash(data: expectedBytes)' \
    || ! class_contains_literal "$recovery_test" InterruptedDraftRecoveryUITests 'secondLaunch.fixtureEvidence.regularArtifactCount, 1' \
    || ! class_contains_literal "$recovery_test" InterruptedDraftRecoveryUITests 'let acknowledgedEvidence = try recoveryFixtureEvidence(in: app)' \
    || ! class_contains_literal "$recovery_test" InterruptedDraftRecoveryUITests 'acknowledgedEvidence.relativePath, secondLaunch.fixtureEvidence.relativePath' \
    || ! class_contains_literal "$recovery_test" InterruptedDraftRecoveryUITests 'acknowledgedEvidence.matterID, secondLaunch.fixtureEvidence.matterID' \
    || ! class_contains_literal "$recovery_test" InterruptedDraftRecoveryUITests 'acknowledgedEvidence.byteCount, secondLaunch.fixtureEvidence.byteCount' \
    || ! class_contains_literal "$recovery_test" InterruptedDraftRecoveryUITests 'acknowledgedEvidence.sha256, secondLaunch.fixtureEvidence.sha256' \
    || class_contains_literal "$recovery_test" InterruptedDraftRecoveryUITests 'seeded-matter-id' \
    || class_contains_literal "$recovery_test" InterruptedDraftRecoveryUITests 'app.alerts['; then
  printf '%s\n' 'ERROR: interrupted draft recovery smoke must reopen one Store and query the macOS sheet title' >&2
  exit 1
fi
if ! grep -Fq 'regularArtifacts(beneath: storageRoot)' "$accessibility_test" \
    || ! grep -Fq 'private func regularArtifacts(beneath root: URL) -> [String]' "$accessibility_test" \
    || ! grep -Fq 'options: []' "$accessibility_test" \
    || ! grep -Fq 'values.isRegularFile == true' "$accessibility_test" \
    || grep -Fq 'options: [.skipsHiddenFiles]' "$accessibility_test"; then
  printf '%s\n' 'ERROR: motion cancellation must inspect every regular artifact, including hidden staging files' >&2
  exit 1
fi
printf '%s\n' 'Hosted XPC integration hook passed.'
(( check_only != 0 )) && exit 0

xcodebuild \
  -workspace "${repo_root}/SupraAI.xcworkspace" \
  -scheme SupraAI \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  -only-testing:SupraAIUITests/DraftingBlockedStateUITests \
  -only-testing:SupraAIUITests/DocumentChunkerRolloutUITests/testDiagnosticsShowsPromptClassifierAvailability \
  -only-testing:SupraAIUITests/ResearchAuthoritiesUITests/testLegacyOutputWarningAnnouncesStatusAndUnavailableExport \
  -only-testing:SupraAIUITests/ResearchAuthoritiesUITests/testLegacyBillingWarningAnnouncesReviewAndUnavailableExport \
  -only-testing:SupraAIUITests/GuidedDocumentQAUITests/testGuidedChooserGeneratesPreviewsAndCancelsWithoutReplacingSavedResult \
  -only-testing:SupraAIUITests/RestoreSettingsUITests \
  -only-testing:SupraAIUITests/InterruptedDraftRecoveryUITests \
  -only-testing:SupraAIUITests/MotionToDismissWorkspaceUITests \
  -only-testing:SupraAIUITests/CorpusReviewQueueCompositionUITests \
  -only-testing:SupraAIUITests/CaseFileReviewCompositionUITests/testTRPUI13WorkflowControlsPinAccessibleFiltersProgressAndGuardedNavigation \
  -only-testing:SupraAIUITests/CaseFileReviewHostedUITests/testTRPUI14ProgressAndAttentionFiltersReconcileHiddenSourcesAndExplicitEmptyState \
  -only-testing:SupraAIUITests/CaseFileReviewHostedUITests/testTRPUI15DirtyDraftCancelKeepsProjectAndDiscardSwitchesWithoutCrossProjectLeak \
  -only-testing:SupraAIUITests/CaseFileReviewHostedUITests/testTRPUI16FailedProjectSwitchRetainsExactDraftForResume \
  -only-testing:SupraAIUITests/CaseFileReviewHostedUITests/testTRPUI17FailedOpenReviewRetainsExactDraftForResume \
  -only-testing:SupraAIUITests/CaseFileReviewHostedUITests/testTRPUI18MinimumWidthSourcesKeepsProgressAndCompactFilterUsable \
  -only-testing:SupraAIUITests/CaseFileReviewHostedUITests/testTRPUI19DirtyDraftAndFilteredMinimumWidthExportFullSavedSnapshot \
  -only-testing:SupraAIUITests/CaseFileReviewCompositionUITests/testTRPUI20FullSnapshotExportUsesPermanentLedgerStrip \
  -only-testing:SupraAIUITests/CaseFileReviewHostedUITests/testTRPCREATEUI01NewReviewSetupUsesExactSelectedScopeAndDurableSubmission \
  -only-testing:SupraAIUITests/CaseFileReviewHostedUITests/testTRPCREATEUI02PausedRunSurvivesRelaunchThenResumesAndCancels \
  -only-testing:SupraAIUITests/CaseFileReviewCompositionUITests/testTRPCREATEUI03ProductionCompositionUsesAtomicPinnedQueueAndExactHandoff \
  -only-testing:SupraAIUITests/CaseFileReviewHostedUITests/testTRPCREATEUI04SelectedScopeRejectsEveryExcludedSource \
  -only-testing:SupraAIUITests/CaseFileReviewHostedUITests/testTRPCREATEUI05ClosingDuringModelVerificationCancelsWithoutCreatingAJob \
  -only-testing:SupraAIUITests/CaseFileReviewHostedUITests/testTRPCREATEUI06ScopeDriftRefreshesReceiptAndRequiresSecondStart \
  -only-testing:SupraAIUITests/RuntimeXPCIntegrationTests \
  test
