#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
verifier="${repo_root}/Scripts/verify-case-file-review-retirement.sh"
temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT
failures=0

write_file() {
  local path="$1"
  shift
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$@" >"$path"
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
    printf 'FAIL: %s: expected status %s, got %s\n' "$name" "$expected_status" "$status" >&2
    sed 's/^/  | /' "$output_file" >&2
    failures=$((failures + 1))
  elif ! grep -Fq -- "$expected_text" "$output_file"; then
    printf 'FAIL: %s: expected output to contain: %s\n' "$name" "$expected_text" >&2
    sed 's/^/  | /' "$output_file" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s\n' "$name"
  fi
}

make_shipping_fixture() {
  local fixture_root="$1"

  write_file "${fixture_root}/Apps/SupraAI/SupraAI/Chat/OrdinaryDraftReviewView.swift" \
    'struct OrdinaryDraftReviewView {' \
    '    let guidance = "Review the draft before filing."' \
    '}'
  write_file "${fixture_root}/Apps/SupraAI/SupraAI.xcodeproj/project.pbxproj" \
    '// OrdinaryDraftReviewView.swift remains in the shipping application.'

  write_file "${fixture_root}/Packages/SupraSessions/Sources/SupraSessions/ChatSuggestions.swift" \
    'enum ChatSuggestions {' \
    '    static let retained = (title: "Review a Draft", prompt: "Review this draft.")' \
    '}'
  write_file "${fixture_root}/Packages/SupraSessions/Sources/SupraSessions/DocumentProcessingQueue.swift" \
    'enum RetiredCorpusAnalysisPolicy {' \
    '    static let identityPrefix = "guided-review:"' \
    '}'
  write_file "${fixture_root}/Packages/SupraSessions/Sources/SupraSessions/DocumentRelationReviewController.swift" \
    'public final class DocumentRelationReviewController {}'
  write_file "${fixture_root}/Packages/SupraSessions/Sources/SupraSessions/CorpusAnalysisQueueRunner.swift" \
    'public final class CorpusAnalysisQueueRunner: @unchecked Sendable {}'
  write_file "${fixture_root}/Packages/SupraSessions/Sources/SupraSessions/ExhaustiveListTask.swift" \
    'public final class ExhaustiveListTask: @unchecked Sendable {}'
  write_file "${fixture_root}/Packages/SupraSessions/Sources/SupraSessions/MatterDraftingController.swift" \
    'public struct DraftArtifact {' \
    '    public var reviewNotes: [String] { [] }' \
    '}'
  write_file "${fixture_root}/Packages/SupraStore/Sources/SupraStore/Records/AuthorityReviewedProposition.swift" \
    'public struct AuthorityReviewedProposition {}'
  mkdir -p "${fixture_root}/Packages/SupraStore/Sources/SupraStore/Repositories"
  cp \
    "${repo_root}/Packages/SupraStore/Sources/SupraStore/Repositories/DocumentLibraryRepository.swift" \
    "${fixture_root}/Packages/SupraStore/Sources/SupraStore/Repositories/DocumentLibraryRepository.swift"
  write_file "${fixture_root}/Packages/SupraCore/Sources/SupraCore/LegalDomainTypes.swift" \
    'public enum ResearchResultReviewState: String {' \
    '    case unreviewed' \
    '}' \
    'public enum StructuredOutputKind {' \
    '    /// Legal-authority output remains flagged for citation review.' \
    '    public var assertsLegalAuthority: Bool { true }' \
    '}'
  write_file "${fixture_root}/Packages/SupraCore/Sources/SupraCore/PropositionSupport.swift" \
    'public enum OutputVerificationStatus: String {' \
    '    case needsReview = "needs_review"' \
    '}'

  mkdir -p "${fixture_root}/Packages/SupraStore/Sources/SupraStore/Database"
  cp \
    "${repo_root}/Packages/SupraStore/Sources/SupraStore/Database/SupraMigrator.swift" \
    "${fixture_root}/Packages/SupraStore/Sources/SupraStore/Database/SupraMigrator.swift"

  write_file "${fixture_root}/Scripts/run-app-smoke-tests.sh" \
    '#!/usr/bin/env bash' \
    'xcodebuild -only-testing:SupraAIUITests/ResearchAuthoritiesUITests/testReviewedProposition'
  write_file "${fixture_root}/Docs/Verified-Product-Claims.yml" \
    'claims:' \
    '  - id: "STORE-MIGRATION-SEQUENCE"' \
    '    topic: "migration-count"' \
    '    expected: "v077_create_accepted_research_packets"' \
    '  - id: "RETAINED-ATTORNEY-REVIEW"' \
    '    wording: "Research results and reviewed authorities remain available for attorney review."'
  write_file "${fixture_root}/ARCHITECTURE.md" \
    '# Architecture' \
    'Research-result review, reviewed authorities, document-relation review, drafting review notes, citation review, and generic needsReview states remain supported.'
  write_file "${fixture_root}/Docs/local-legal-model-setup.md" \
    '# Local Legal Model Setup' \
    'The critique route supplies a defect-focused review prompt for an ordinary draft.'
}

base_fixture="${temporary_dir}/shipping-base"
make_shipping_fixture "$base_fixture"

# T-REVIEW-RETIRE-SCHEMA-01 standing guard: the frozen migration deliberately
# contains retired storage names, and that exact compatibility body must not make
# the absence verifier fail.
if ! grep -Fq 'case_file_review_projects' \
    "${base_fixture}/Packages/SupraStore/Sources/SupraStore/Database/SupraMigrator.swift"; then
  printf '%s\n' 'FAIL: migration fixture does not exercise the compatibility allowlist' >&2
  failures=$((failures + 1))
fi
if ! grep -Fq 'static let identityPrefix = "guided-review:"' \
    "${base_fixture}/Packages/SupraSessions/Sources/SupraSessions/DocumentProcessingQueue.swift"; then
  printf '%s\n' 'FAIL: fixture does not exercise the exact retired-queue discriminator allowlist' >&2
  failures=$((failures + 1))
fi
if ! grep -Fq 'expected: "v077_create_accepted_research_packets"' \
    "${base_fixture}/Docs/Verified-Product-Claims.yml"; then
  printf '%s\n' 'FAIL: fixture does not exercise the shipping v075 migration endpoint' >&2
  failures=$((failures + 1))
fi
if ! grep -Fq 'BEGIN hash-pinned dormant v073 evidence compatibility' \
    "${base_fixture}/Packages/SupraStore/Sources/SupraStore/Repositories/DocumentLibraryRepository.swift"; then
  printf '%s\n' 'FAIL: fixture does not exercise dormant v073 deletion compatibility' >&2
  failures=$((failures + 1))
fi
run_case \
  'immutable migration compatibility is allowlisted' \
  0 \
  'Case File Review retirement verification passed' \
  env SUPRA_REPO_ROOT="$base_fixture" bash "$verifier"

# T-REVIEW-TERMS-01 standing guard: ordinary uses of review are intentionally
# broad and must not be mistaken for the retired named product vertical.
run_case \
  'generic attorney-review language does not false-positive' \
  0 \
  'Case File Review retirement verification passed' \
  env SUPRA_REPO_ROOT="$base_fixture" bash "$verifier"

# T-REVIEW-RETIRE-CAP-01 expected RED for the stale fixture: a renamed file
# cannot hide a shipping CaseFileReview capability.
stale_capability_fixture="${temporary_dir}/stale-capability"
mkdir -p "$stale_capability_fixture"
cp -R "${base_fixture}/." "$stale_capability_fixture"
write_file \
  "${stale_capability_fixture}/Packages/SupraSessions/Sources/SupraSessions/LegacyEntryPoint.swift" \
  'public struct CaseFileReviewBackdoor {' \
  '    public init() {}' \
  '}'
run_case \
  'stale retired capability fails closed' \
  1 \
  'retired capability remains [CaseFileReview symbol]' \
  env SUPRA_REPO_ROOT="$stale_capability_fixture" bash "$verifier"

# The migration exception is a body allowlist, not a path-wide exemption.
stale_migrator_fixture="${temporary_dir}/stale-migrator-capability"
mkdir -p "$stale_migrator_fixture"
cp -R "${base_fixture}/." "$stale_migrator_fixture"
printf '%s\n' \
  'extension SupraMigrator { static let staleBackdoor = "case_file_review_backdoor" }' \
  >>"${stale_migrator_fixture}/Packages/SupraStore/Sources/SupraStore/Database/SupraMigrator.swift"
run_case \
  'retired capability outside the migration body fails closed' \
  1 \
  'retired capability remains [case_file_review storage identifier]' \
  env SUPRA_REPO_ROOT="$stale_migrator_fixture" bash "$verifier"

# The dormant deletion exception is also one hash-pinned body, not a
# repository-file exemption. A second storage use outside the markers fails.
stale_deletion_compatibility_fixture="${temporary_dir}/stale-deletion-compatibility"
mkdir -p "$stale_deletion_compatibility_fixture"
cp -R "${base_fixture}/." "$stale_deletion_compatibility_fixture"
printf '%s\n' \
  'extension DocumentLibraryRepository { static let staleBackdoor = "case_file_review_backdoor" }' \
  >>"${stale_deletion_compatibility_fixture}/Packages/SupraStore/Sources/SupraStore/Repositories/DocumentLibraryRepository.swift"
run_case \
  'retired capability outside dormant deletion compatibility fails closed' \
  1 \
  'retired capability remains [case_file_review storage identifier]' \
  env SUPRA_REPO_ROOT="$stale_deletion_compatibility_fixture" bash "$verifier"

# The durable queue discriminator exception is one exact line in one exact
# policy. A second shipping use of the same persisted prefix remains stale.
stale_queue_identity_fixture="${temporary_dir}/stale-queue-identity"
mkdir -p "$stale_queue_identity_fixture"
cp -R "${base_fixture}/." "$stale_queue_identity_fixture"
write_file \
  "${stale_queue_identity_fixture}/Packages/SupraSessions/Sources/SupraSessions/LegacyQueueEntryPoint.swift" \
  'enum LegacyQueueEntryPoint {' \
  '    static let identityPrefix = "guided-review:"' \
  '}'
run_case \
  'guided-review identity outside the exact compatibility policy fails closed' \
  1 \
  'retired capability remains [guided-review job identity]' \
  env SUPRA_REPO_ROOT="$stale_queue_identity_fixture" bash "$verifier"

# DR-CORPUS-OWNER-01 expected RED: the post-removal audit must reject a
# shipping AppEnvironment that silently composes the retained package-only
# corpus runner, even when it contains no retired Review identifier.
stale_corpus_owner_fixture="${temporary_dir}/stale-corpus-owner"
mkdir -p "$stale_corpus_owner_fixture"
cp -R "${base_fixture}/." "$stale_corpus_owner_fixture"
write_file \
  "${stale_corpus_owner_fixture}/Apps/SupraAI/SupraAI/AppEnvironment.swift" \
  'struct AppEnvironment {' \
  '    let corpusRunner = CorpusAnalysisQueueRunner.live' \
  '    func makeQueue() {' \
  '        _ = DocumentProcessingQueue(corpusAnalysisRunner: corpusRunner.run)' \
  '    }' \
  '}'
run_case \
  'shipping generic corpus runner composition fails closed' \
  1 \
  'shipping app composes package-only corpus execution' \
  env SUPRA_REPO_ROOT="$stale_corpus_owner_fixture" bash "$verifier"

# Verified claims receive no v073 exception after v075 becomes the shipping
# endpoint. A stale Review endpoint under any claim fails the ordinary scan.
stale_claim_endpoint_fixture="${temporary_dir}/stale-claim-endpoint"
mkdir -p "$stale_claim_endpoint_fixture"
cp -R "${base_fixture}/." "$stale_claim_endpoint_fixture"
printf '%s\n' \
  '  - id: "STALE-REVIEW-CLAIM"' \
  '    expected: "v073_create_case_file_review_projects"' \
  >>"${stale_claim_endpoint_fixture}/Docs/Verified-Product-Claims.yml"
run_case \
  'stale dormant v073 endpoint in claims fails closed' \
  1 \
  'retired capability remains [case_file_review storage identifier]' \
  env SUPRA_REPO_ROOT="$stale_claim_endpoint_fixture" bash "$verifier"

# T-REVIEW-TERMS-01 expected RED for the missing fixture: retirement cannot
# silently erase Chat's ordinary draft-review affordance.
missing_retained_fixture="${temporary_dir}/missing-retained-concept"
mkdir -p "$missing_retained_fixture"
cp -R "${base_fixture}/." "$missing_retained_fixture"
write_file \
  "${missing_retained_fixture}/Packages/SupraSessions/Sources/SupraSessions/ChatSuggestions.swift" \
  'enum ChatSuggestions {' \
  '    static let otherTitle = "Summarize a Contract"' \
  '}'
run_case \
  'missing retained draft-review affordance fails closed' \
  1 \
  'retained concept is missing [Review a Draft]' \
  env SUPRA_REPO_ROOT="$missing_retained_fixture" bash "$verifier"

if (( failures != 0 )); then
  printf 'Case File Review retirement verifier tests failed: %d\n' "$failures" >&2
  exit 1
fi

printf '%s\n' 'All Case File Review retirement verifier tests passed.'
