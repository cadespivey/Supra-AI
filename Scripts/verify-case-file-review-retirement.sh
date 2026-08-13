#!/usr/bin/env bash
set -euo pipefail

repo_root="${SUPRA_REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
repo_root="$(cd "$repo_root" && pwd -P)"
temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT
scoped_corpus="${temporary_dir}/shipping-scope.txt"
: >"$scoped_corpus"

status=0
error_count=0
finding_count=0
file_count=0
retained_count=0

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  status=1
  error_count=$((error_count + 1))
}

require_path() {
  local label="$1"
  local path="$2"
  [[ -e "$path" ]] || fail "required ${label} scope is missing: ${path#${repo_root}/}"
}

append_source_file() {
  local file="$1"
  local relative="${file#${repo_root}/}"

  printf '%s:0:%s\n' "$relative" "$relative" >>"$scoped_corpus"
  LC_ALL=C awk -v source="$relative" '
    {
      sub(/\r$/, "")
      printf "%s:%d:%s\n", source, NR, $0
    }
  ' "$file" >>"$scoped_corpus"
  file_count=$((file_count + 1))
}

sha256_file() {
  local file="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{ print $1 }'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{ print $1 }'
  else
    printf '%s\n' 'ERROR: shasum or sha256sum is required' >&2
    exit 2
  fi
}

app_sources="${repo_root}/Apps/SupraAI/SupraAI"
project_file="${repo_root}/Apps/SupraAI/SupraAI.xcodeproj/project.pbxproj"
packages_root="${repo_root}/Packages"
smoke_script="${repo_root}/Scripts/run-app-smoke-tests.sh"
claims_file="${repo_root}/Docs/Verified-Product-Claims.yml"
architecture_file="${repo_root}/ARCHITECTURE.md"
help_file="${repo_root}/Docs/local-legal-model-setup.md"
migrator="${repo_root}/Packages/SupraStore/Sources/SupraStore/Database/SupraMigrator.swift"

require_path 'shipping App Swift' "$app_sources"
require_path 'shipping App project' "$project_file"
require_path 'package Sources' "$packages_root"
require_path 'current app smoke' "$smoke_script"
require_path 'verified product claims' "$claims_file"
require_path 'current architecture' "$architecture_file"
require_path 'current local-model help' "$help_file"
require_path 'immutable migration compatibility' "$migrator"

if (( status != 0 )); then
  printf 'Case File Review retirement verification failed: %d required scope error(s).\n' \
    "$error_count" >&2
  exit 1
fi

app_source_count=0
while IFS= read -r -d '' file; do
  append_source_file "$file"
  app_source_count=$((app_source_count + 1))
done < <(find "$app_sources" -type f -name '*.swift' -print0)
if (( app_source_count == 0 )); then
  fail 'shipping App Swift scope contains no files'
fi
append_source_file "$project_file"

package_source_count=0
while IFS= read -r -d '' file; do
  if [[ "$file" == "$migrator" ]]; then
    continue
  fi
  append_source_file "$file"
  package_source_count=$((package_source_count + 1))
done < <(find "$packages_root" -type f -path '*/Sources/*' -print0)
if (( package_source_count == 0 )); then
  fail 'package Sources scope contains no files outside the migration compatibility source'
fi

# v073 is already on shared main and must remain byte-identical even though its
# product capability is retired. Only its exact frozen closure is excluded; the
# rest of SupraMigrator.swift remains in the absence scan.
readonly expected_v073_sha256='819515bfe405e1459adbbce65288754f241b94239543fe077793c624f4c4d14f'
readonly expected_reset_compatibility_sha256='93a75b7fb141dc79698ea3ee42f132784b3cd81020302b5b3670a3f18ad8e1ee'
v073_start="$(awk '
  $0 == "        migrator.registerMigration(\"v073_create_case_file_review_projects\") { db in" {
    print NR
    exit
  }
' "$migrator")"
v073_end=''
if [[ -n "$v073_start" ]]; then
  v073_end="$(awk -v start="$v073_start" '
    NR > start && $0 == "        }" {
      print NR
      exit
    }
  ' "$migrator")"
fi
v073_allowed=0
if [[ -z "$v073_start" || -z "$v073_end" ]]; then
  fail 'immutable v073 compatibility body is missing or cannot be delimited'
else
  v073_body="${temporary_dir}/v073-body.swift"
  sed -n "${v073_start},${v073_end}p" "$migrator" >"$v073_body"
  v073_actual_sha256="$(sha256_file "$v073_body")"
  if [[ "$v073_actual_sha256" != "$expected_v073_sha256" ]]; then
    fail "immutable v073 compatibility body drifted: expected ${expected_v073_sha256}, found ${v073_actual_sha256}"
  else
    v073_allowed=1
  fi
fi

# DEBUG reset retains the exact child-first v073 table list so a shared-main
# development database can still be reset. This is compatibility, not a shipping
# repository/API allowlist.
reset_start="$(awk '
  $0 == "            // Case File Review: children before project/matter ownership." {
    print NR
    exit
  }
' "$migrator")"
reset_end=''
if [[ -n "$reset_start" ]]; then
  reset_end="$(awk -v start="$reset_start" '
    NR >= start && $0 == "            \"case_file_review_projects\"," {
      print NR
      exit
    }
  ' "$migrator")"
fi
reset_allowed=0
if [[ -z "$reset_start" || -z "$reset_end" ]]; then
  fail 'exact v073 DEBUG reset compatibility block is missing or cannot be delimited'
else
  reset_body="${temporary_dir}/v073-reset-compatibility.swift"
  sed -n "${reset_start},${reset_end}p" "$migrator" >"$reset_body"
  reset_actual_sha256="$(sha256_file "$reset_body")"
  if [[ "$reset_actual_sha256" != "$expected_reset_compatibility_sha256" ]]; then
    fail "v073 DEBUG reset compatibility block drifted: expected ${expected_reset_compatibility_sha256}, found ${reset_actual_sha256}"
  else
    reset_allowed=1
  fi
fi

migrator_relative="${migrator#${repo_root}/}"
printf '%s:0:%s\n' "$migrator_relative" "$migrator_relative" >>"$scoped_corpus"
LC_ALL=C awk \
  -v source="$migrator_relative" \
  -v v073_start="${v073_start:-0}" \
  -v v073_end="${v073_end:-0}" \
  -v v073_allowed="$v073_allowed" \
  -v reset_start="${reset_start:-0}" \
  -v reset_end="${reset_end:-0}" \
  -v reset_allowed="$reset_allowed" \
  -v v072_compatibility="            // Case File Review's two export-eligible assurance states require a" '
    v073_allowed == 1 && NR >= v073_start && NR <= v073_end { next }
    reset_allowed == 1 && NR >= reset_start && NR <= reset_end { next }
    $0 == v072_compatibility { next }
    {
      sub(/\r$/, "")
      printf "%s:%d:%s\n", source, NR, $0
    }
  ' "$migrator" >>"$scoped_corpus"
file_count=$((file_count + 1))

append_source_file "$smoke_script"
append_source_file "$claims_file"
append_source_file "$architecture_file"
append_source_file "$help_file"

# These are exact product names, symbols, launch/accessibility namespaces, and
# feature-only admission/export seams. Deliberately absent: a generic /review/
# expression. Ordinary attorney review vocabulary is protected below instead.
retired_labels=(
  'CaseFileReview symbol'
  'caseFileReview API'
  'case_file_review storage identifier'
  'case-file-review slug'
  'guided-review job identity'
  'Case File Review wording'
  'Guided New Review wording'
  'Review Project capability'
  'Review Matrix capability'
  'Review workbench capability'
  'Review snapshot capability'
  'Corpus Review queue capability'
  'Review admission capability'
  'Review reconciliation capability'
  'Review creation model capability'
  'Review-only exhaustive snapshot capability'
  'Review-only corpus lookup capability'
  'Review accessibility namespace'
  'Review-only launch argument'
  'retired Review smoke selector'
  'Review export test receipt'
)
retired_patterns=(
  'CaseFileReview'
  'caseFileReview'
  'case_file_review'
  'case-file-review'
  'guided-review'
  'Case File Review'
  'Guided New Review'
  'Review Projects?'
  'Review Matrix'
  'Review workbench'
  'Review snapshot'
  'CorpusReviewQueue'
  'ReviewAdmission'
  'ReviewReconciliation'
  'ReviewCreationModel'
  'ExhaustiveListReview(Snapshot|ExcludedMember|FailedPartition)'
  '(fetchExactReviewRun|isContraryOnlyReviewCandidate|hasNonterminal(Created)?Review)'
  'review\.(creation|project|matrix|export)(\.|\")'
  '(uiTestReview(Creation|Project|Export|Navigation)|reviewCreationUITest|reviewExportUITest|seedUITestReview(Creation|Project))'
  'TRP(UI|CREATEUI|HWUI)[0-9]+'
  'SupraReviewExportUITestReceipt'
)

for index in "${!retired_patterns[@]}"; do
  pattern="${retired_patterns[$index]}"
  label="${retired_labels[$index]}"
  # The source path prefix is diagnostic metadata, not source content. Match
  # only after the `path:line:` fields; the line-zero record then accounts for
  # a forbidden file name exactly once.
  scoped_pattern="^[^:]+:[0-9]+:.*(${pattern})"
  match_count="$(grep -Ec -- "$scoped_pattern" "$scoped_corpus" || true)"
  if (( match_count == 0 )); then
    continue
  fi

  finding_count=$((finding_count + match_count))
  fail "retired capability remains [${label}]: ${match_count} scoped finding(s)"
  grep -E -- "$scoped_pattern" "$scoped_corpus" \
    | sed -n '1,8p' \
    | sed 's/^/  - /' >&2
  if (( match_count > 8 )); then
    printf '  - ... %d additional finding(s)\n' "$((match_count - 8))" >&2
  fi
done

require_retained() {
  local label="$1"
  local relative="$2"
  shift 2
  local file="${repo_root}/${relative}"
  local literal

  if [[ ! -f "$file" ]]; then
    fail "retained concept is missing [${label}]: ${relative}"
    return
  fi
  for literal in "$@"; do
    if ! grep -Fq -- "$literal" "$file"; then
      fail "retained concept is missing [${label}]: ${relative} lacks ${literal}"
      return
    fi
  done
  retained_count=$((retained_count + 1))
}

require_retained \
  'Review a Draft' \
  'Packages/SupraSessions/Sources/SupraSessions/ChatSuggestions.swift' \
  'title: "Review a Draft"'
require_retained \
  'research-result review' \
  'Packages/SupraCore/Sources/SupraCore/LegalDomainTypes.swift' \
  'public enum ResearchResultReviewState:'
require_retained \
  'reviewed authority' \
  'Packages/SupraStore/Sources/SupraStore/Records/AuthorityReviewedProposition.swift' \
  'public struct AuthorityReviewedProposition'
require_retained \
  'document-relation review' \
  'Packages/SupraSessions/Sources/SupraSessions/DocumentRelationReviewController.swift' \
  'public final class DocumentRelationReviewController'
require_retained \
  'drafting review notes' \
  'Packages/SupraSessions/Sources/SupraSessions/MatterDraftingController.swift' \
  'public var reviewNotes: [String]'
require_retained \
  'citation review' \
  'Packages/SupraCore/Sources/SupraCore/LegalDomainTypes.swift' \
  'flagged for citation review' \
  'public var assertsLegalAuthority: Bool'
require_retained \
  'generic needsReview' \
  'Packages/SupraCore/Sources/SupraCore/PropositionSupport.swift' \
  'case needsReview = "needs_review"'

if (( status != 0 )); then
  printf 'Case File Review retirement verification failed: %d retired finding(s), %d gate error(s).\n' \
    "$finding_count" "$error_count" >&2
  exit 1
fi

printf 'Case File Review retirement verification passed: %d shipping files scanned, %d retained concepts confirmed; immutable v073 compatibility allowlisted.\n' \
  "$file_count" "$retained_count"
