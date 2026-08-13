#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MANIFEST="${REPO_ROOT}/Docs/Architecture/Remediation/Next-Release-Delta-Manifest.yml"

BASE_SHA="c0a2648b4c65c066f85eb6bf6ae702f9aa779864"
HEAD_SHA="22472816d3346a1bb4688c3a867b66fa61fb5ba4"
EXPECTED_COMMITS=471
EXPECTED_PATHS=270
EXPECTED_ADDED=98
EXPECTED_MODIFIED=170
EXPECTED_DELETED=2
EXPECTED_INSERTIONS=84722
EXPECTED_DELETIONS=1864
EXPECTED_COMMIT_HASH="a2aabefdbaaf46d37044710d4346606c10b28cfd4924ce6e2733392141bf7666"
EXPECTED_NAME_STATUS_HASH="6586b4bf0f7324f99226f6e30ce2ce454115e10291000c74e3d31127d0d2cd36"
EXPECTED_NUMSTAT_HASH="e8bfa900c8e86892f4bc4fbe2ef845934693fbe20f6c8ee02453057d708be14b"

fail() {
  echo "Next Release Delta Manifest: FAIL: $*" >&2
  exit 1
}

expect_equal() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  [[ "${actual}" == "${expected}" ]] || fail "${label}: expected ${expected}, got ${actual}"
}

baseline_scalar() {
  local key="$1"
  awk -v wanted="${key}" '
    $0 == "baseline:" { inside = 1; next }
    inside && /^[^ ]/ { exit }
    inside {
      line = $0
      sub(/^  /, "", line)
      split(line, pair, ":")
      if (pair[1] == wanted) {
        sub(/^[^:]+:[[:space:]]*/, "", line)
        gsub(/^"|"$/, "", line)
        print line
        exit
      }
    }
  ' "${MANIFEST}"
}

top_level_scalar() {
  local key="$1"
  awk -v wanted="${key}" '
    {
      line = $0
      if (line ~ ("^" wanted ":")) {
        sub(/^[^:]+:[[:space:]]*/, "", line)
        gsub(/^"|"$/, "", line)
        print line
        exit
      }
    }
  ' "${MANIFEST}"
}

migration_scalar() {
  local key="$1"
  awk -v wanted="${key}" '
    $0 == "migrations:" { inside = 1; next }
    inside && /^[^ ]/ { exit }
    inside {
      line = $0
      sub(/^  /, "", line)
      split(line, pair, ":")
      if (pair[1] == wanted) {
        sub(/^[^:]+:[[:space:]]*/, "", line)
        gsub(/^"|"$/, "", line)
        print line
        exit
      }
    }
  ' "${MANIFEST}"
}

sha256_stream() {
  shasum -a 256 | awk '{print $1}'
}

[[ -f "${MANIFEST}" ]] || fail "missing ${MANIFEST}"
cd "${REPO_ROOT}"

expect_equal "$(top_level_scalar schema_version)" "1" "schema version"
expect_equal "$(baseline_scalar base_sha)" "${BASE_SHA}" "manifest base SHA"
expect_equal "$(baseline_scalar head_sha)" "${HEAD_SHA}" "manifest head SHA"
expect_equal "$(baseline_scalar commit_count)" "${EXPECTED_COMMITS}" "manifest commit count"
expect_equal "$(baseline_scalar changed_file_count)" "${EXPECTED_PATHS}" "manifest path count"
expect_equal "$(baseline_scalar added_files)" "${EXPECTED_ADDED}" "manifest added-file count"
expect_equal "$(baseline_scalar modified_files)" "${EXPECTED_MODIFIED}" "manifest modified-file count"
expect_equal "$(baseline_scalar deleted_files)" "${EXPECTED_DELETED}" "manifest deleted-file count"
expect_equal "$(baseline_scalar insertions)" "${EXPECTED_INSERTIONS}" "manifest insertion count"
expect_equal "$(baseline_scalar deletions)" "${EXPECTED_DELETIONS}" "manifest deletion count"
expect_equal "$(baseline_scalar commit_inventory_sha256)" "${EXPECTED_COMMIT_HASH}" "manifest commit digest"
expect_equal "$(baseline_scalar name_status_inventory_sha256)" "${EXPECTED_NAME_STATUS_HASH}" "manifest name-status digest"
expect_equal "$(baseline_scalar numstat_inventory_sha256)" "${EXPECTED_NUMSTAT_HASH}" "manifest numstat digest"
expect_equal "$(migration_scalar v073_release_disposition)" "dormant_compatibility_only" "v073 disposition"
expect_equal "$(migration_scalar v073_destructive_action_authorized)" "false" "v073 destructive-action policy"

git cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null || fail "base commit is unavailable"
git cat-file -e "${HEAD_SHA}^{commit}" 2>/dev/null || fail "head commit is unavailable"
expect_equal "$(git rev-parse v2.3.4)" "${BASE_SHA}" "v2.3.4 tag target"

DELTA_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/supra-next-release-delta.XXXXXX")"
cleanup() {
  if [[ -n "${DELTA_TMP_DIR:-}" && -d "${DELTA_TMP_DIR}" ]]; then
    rm -rf -- "${DELTA_TMP_DIR}"
  fi
}
trap cleanup EXIT

git rev-list --reverse "${BASE_SHA}..${HEAD_SHA}" > "${DELTA_TMP_DIR}/commits.ordered"
git diff --name-status "${BASE_SHA}..${HEAD_SHA}" > "${DELTA_TMP_DIR}/name-status"
git diff --numstat "${BASE_SHA}..${HEAD_SHA}" > "${DELTA_TMP_DIR}/numstat"
git diff --name-only "${BASE_SHA}..${HEAD_SHA}" > "${DELTA_TMP_DIR}/paths"

expect_equal "$(wc -l < "${DELTA_TMP_DIR}/commits.ordered" | tr -d ' ')" "${EXPECTED_COMMITS}" "reconstructed commit count"
expect_equal "$(wc -l < "${DELTA_TMP_DIR}/paths" | tr -d ' ')" "${EXPECTED_PATHS}" "reconstructed path count"
expect_equal "$(awk -F '	' '$1 == "A" { n += 1 } END { print n + 0 }' "${DELTA_TMP_DIR}/name-status")" "${EXPECTED_ADDED}" "reconstructed added-file count"
expect_equal "$(awk -F '	' '$1 == "M" { n += 1 } END { print n + 0 }' "${DELTA_TMP_DIR}/name-status")" "${EXPECTED_MODIFIED}" "reconstructed modified-file count"
expect_equal "$(awk -F '	' '$1 == "D" { n += 1 } END { print n + 0 }' "${DELTA_TMP_DIR}/name-status")" "${EXPECTED_DELETED}" "reconstructed deleted-file count"
expect_equal "$(awk -F '	' '$1 != "-" { n += $1 } END { print n + 0 }' "${DELTA_TMP_DIR}/numstat")" "${EXPECTED_INSERTIONS}" "reconstructed insertions"
expect_equal "$(awk -F '	' '$2 != "-" { n += $2 } END { print n + 0 }' "${DELTA_TMP_DIR}/numstat")" "${EXPECTED_DELETIONS}" "reconstructed deletions"
expect_equal "$(cat "${DELTA_TMP_DIR}/commits.ordered" | sha256_stream)" "${EXPECTED_COMMIT_HASH}" "reconstructed commit digest"
expect_equal "$(cat "${DELTA_TMP_DIR}/name-status" | sha256_stream)" "${EXPECTED_NAME_STATUS_HASH}" "reconstructed name-status digest"
expect_equal "$(cat "${DELTA_TMP_DIR}/numstat" | sha256_stream)" "${EXPECTED_NUMSTAT_HASH}" "reconstructed numstat digest"

awk '
  $0 == "commit_buckets:" { inside = 1; next }
  $0 == "migrations:" { inside = 0 }
  inside && /^  - id: "PR-/ {
    if (id != "") print id "\t" merge "\t" tip "\t" count
    id = $0
    sub(/^  - id: "/, "", id)
    sub(/"$/, "", id)
    merge = tip = count = ""
    next
  }
  inside && /^    merge_sha: "/ {
    merge = $0
    sub(/^    merge_sha: "/, "", merge)
    sub(/"$/, "", merge)
  }
  inside && /^    branch_tip_sha: "/ {
    tip = $0
    sub(/^    branch_tip_sha: "/, "", tip)
    sub(/"$/, "", tip)
  }
  inside && /^    introduced_commit_count_including_merge: / {
    count = $0
    sub(/^    introduced_commit_count_including_merge: /, "", count)
  }
  END {
    if (id != "") print id "\t" merge "\t" tip "\t" count
  }
' "${MANIFEST}" > "${DELTA_TMP_DIR}/buckets"

expect_equal "$(wc -l < "${DELTA_TMP_DIR}/buckets" | tr -d ' ')" "15" "commit bucket count"
expect_equal "$(awk -F '	' '{ n += $4 } END { print n + 0 }' "${DELTA_TMP_DIR}/buckets")" "${EXPECTED_COMMITS}" "declared commit-bucket sum"

: > "${DELTA_TMP_DIR}/classified-commits"
while IFS=$'	' read -r bucket_id merge_sha branch_tip_sha declared_count; do
  [[ -n "${bucket_id}" && -n "${merge_sha}" && -n "${branch_tip_sha}" && -n "${declared_count}" ]] ||
    fail "incomplete commit bucket ${bucket_id:-unknown}"
  git cat-file -e "${merge_sha}^{commit}" 2>/dev/null || fail "${bucket_id}: merge commit unavailable"
  git cat-file -e "${branch_tip_sha}^{commit}" 2>/dev/null || fail "${bucket_id}: branch tip unavailable"
  expect_equal "$(git rev-list --parents -n 1 "${merge_sha}" | awk '{ print NF - 1 }')" "2" "${bucket_id} merge parent count"
  expect_equal "$(git rev-parse "${merge_sha}^2")" "${branch_tip_sha}" "${bucket_id} second parent"
  first_parent_sha="$(git rev-parse "${merge_sha}^1")"
  git rev-list "${branch_tip_sha}" --not "${first_parent_sha}" > "${DELTA_TMP_DIR}/bucket-commits"
  printf '%s
' "${merge_sha}" >> "${DELTA_TMP_DIR}/bucket-commits"
  expect_equal "$(wc -l < "${DELTA_TMP_DIR}/bucket-commits" | tr -d ' ')" "${declared_count}" "${bucket_id} introduced commit count"
  while IFS= read -r commit_sha; do
    printf '%s	%s
' "${commit_sha}" "${bucket_id}" >> "${DELTA_TMP_DIR}/classified-commits"
  done < "${DELTA_TMP_DIR}/bucket-commits"
done < "${DELTA_TMP_DIR}/buckets"

cut -f1 "${DELTA_TMP_DIR}/classified-commits" | sort > "${DELTA_TMP_DIR}/classified-commits.sorted"
sort "${DELTA_TMP_DIR}/commits.ordered" > "${DELTA_TMP_DIR}/commits.sorted"
sort "${DELTA_TMP_DIR}/classified-commits.sorted" | uniq -d > "${DELTA_TMP_DIR}/duplicate-commits"
[[ ! -s "${DELTA_TMP_DIR}/duplicate-commits" ]] || fail "commit appears in more than one bucket: $(head -1 "${DELTA_TMP_DIR}/duplicate-commits")"
comm -3 "${DELTA_TMP_DIR}/commits.sorted" "${DELTA_TMP_DIR}/classified-commits.sorted" > "${DELTA_TMP_DIR}/commit-diff"
[[ ! -s "${DELTA_TMP_DIR}/commit-diff" ]] || fail "commit buckets do not exactly cover the frozen range"

awk '
  $0 == "groups:" { inside = 1; next }
  $0 == "coverage:" { inside = 0 }
  inside && /^  - id: "G[0-9][0-9]"/ {
    group = $0
    sub(/^  - id: "/, "", group)
    sub(/"$/, "", group)
    in_paths = 0
    next
  }
  inside && /^      paths:$/ { in_paths = 1; next }
  inside && in_paths && /^        - "/ {
    path = $0
    sub(/^        - "/, "", path)
    sub(/"$/, "", path)
    print group "\t" path
    next
  }
  inside && in_paths { in_paths = 0 }
' "${MANIFEST}" > "${DELTA_TMP_DIR}/classified-paths"

awk '
  function emit() {
    if (group != "") print group "\t" count "\t" added "\t" modified "\t" deleted "\t" insertions "\t" deletions
  }
  $0 == "groups:" { inside = 1; next }
  $0 == "coverage:" { emit(); inside = 0 }
  inside && /^  - id: "G[0-9][0-9]"/ {
    emit()
    group = $0
    sub(/^  - id: "/, "", group)
    sub(/"$/, "", group)
    count = added = modified = deleted = insertions = deletions = ""
    next
  }
  inside && /^      expected_path_count: / {
    count = $0; sub(/^      expected_path_count: /, "", count)
  }
  inside && /^      expected_added_files: / {
    added = $0; sub(/^      expected_added_files: /, "", added)
  }
  inside && /^      expected_modified_files: / {
    modified = $0; sub(/^      expected_modified_files: /, "", modified)
  }
  inside && /^      expected_deleted_files: / {
    deleted = $0; sub(/^      expected_deleted_files: /, "", deleted)
  }
  inside && /^      expected_insertions: / {
    insertions = $0; sub(/^      expected_insertions: /, "", insertions)
  }
  inside && /^      expected_deletions: / {
    deletions = $0; sub(/^      expected_deletions: /, "", deletions)
  }
' "${MANIFEST}" > "${DELTA_TMP_DIR}/group-stats"

expect_equal "$(wc -l < "${DELTA_TMP_DIR}/group-stats" | tr -d ' ')" "20" "file group count"
expect_equal "$(cut -f1 "${DELTA_TMP_DIR}/group-stats" | sort -u | wc -l | tr -d ' ')" "20" "unique file group count"
expect_equal "$(awk -F '	' '{ n += $2 } END { print n + 0 }' "${DELTA_TMP_DIR}/group-stats")" "${EXPECTED_PATHS}" "declared group path sum"
expect_equal "$(wc -l < "${DELTA_TMP_DIR}/classified-paths" | tr -d ' ')" "${EXPECTED_PATHS}" "explicit classified path count"

cut -f2 "${DELTA_TMP_DIR}/classified-paths" | sort > "${DELTA_TMP_DIR}/classified-paths.sorted"
sort "${DELTA_TMP_DIR}/paths" > "${DELTA_TMP_DIR}/paths.sorted"
sort "${DELTA_TMP_DIR}/classified-paths.sorted" | uniq -d > "${DELTA_TMP_DIR}/duplicate-paths"
[[ ! -s "${DELTA_TMP_DIR}/duplicate-paths" ]] || fail "path appears in more than one group: $(head -1 "${DELTA_TMP_DIR}/duplicate-paths")"
comm -3 "${DELTA_TMP_DIR}/paths.sorted" "${DELTA_TMP_DIR}/classified-paths.sorted" > "${DELTA_TMP_DIR}/path-diff"
[[ ! -s "${DELTA_TMP_DIR}/path-diff" ]] || fail "file groups do not exactly cover the frozen diff"

while IFS=$'	' read -r group_id declared_paths declared_added declared_modified declared_deleted declared_insertions declared_deletions; do
  actual_paths=0
  actual_added=0
  actual_modified=0
  actual_deleted=0
  actual_insertions=0
  actual_deletions=0
  while IFS=$'	' read -r path_group path; do
    [[ "${path_group}" == "${group_id}" ]] || continue
    actual_paths=$((actual_paths + 1))
    status="$(awk -F '	' -v target="${path}" '$2 == target { print $1; exit }' "${DELTA_TMP_DIR}/name-status")"
    case "${status}" in
      A) actual_added=$((actual_added + 1)) ;;
      M) actual_modified=$((actual_modified + 1)) ;;
      D) actual_deleted=$((actual_deleted + 1)) ;;
      *) fail "${group_id}: no frozen status for ${path}" ;;
    esac
    path_stats="$(awk -F '	' -v target="${path}" '
      $3 == target {
        added = ($1 == "-" ? 0 : $1)
        deleted = ($2 == "-" ? 0 : $2)
        print added " " deleted
        exit
      }
    ' "${DELTA_TMP_DIR}/numstat")"
    [[ -n "${path_stats}" ]] || fail "${group_id}: no frozen numstat for ${path}"
    path_insertions="${path_stats%% *}"
    path_deletions="${path_stats##* }"
    actual_insertions=$((actual_insertions + path_insertions))
    actual_deletions=$((actual_deletions + path_deletions))
  done < "${DELTA_TMP_DIR}/classified-paths"
  expect_equal "${actual_paths}" "${declared_paths}" "${group_id} path count"
  expect_equal "${actual_added}" "${declared_added}" "${group_id} added-file count"
  expect_equal "${actual_modified}" "${declared_modified}" "${group_id} modified-file count"
  expect_equal "${actual_deleted}" "${declared_deleted}" "${group_id} deleted-file count"
  expect_equal "${actual_insertions}" "${declared_insertions}" "${group_id} insertions"
  expect_equal "${actual_deletions}" "${declared_deletions}" "${group_id} deletions"
done < "${DELTA_TMP_DIR}/group-stats"

migration_file="${DELTA_TMP_DIR}/migrator"
git show "${HEAD_SHA}:Packages/SupraStore/Sources/SupraStore/Database/SupraMigrator.swift" > "${migration_file}"
previous_line=0
for migration_id in   v070_add_authority_reviewed_proposition   v071_create_draft_artifact_intents   v072_harden_corpus_review_integrity   v073_create_case_file_review_projects
do
  occurrence_count="$(grep -c "registerMigration(\"${migration_id}\")" "${migration_file}" || true)"
  expect_equal "${occurrence_count}" "1" "${migration_id} registration count"
  current_line="$(grep -n "registerMigration(\"${migration_id}\")" "${migration_file}" | cut -d: -f1)"
  (( current_line > previous_line )) || fail "migration sequence is not ordered at ${migration_id}"
  previous_line="${current_line}"
done

echo "Next Release Delta Manifest: PASS"
echo "  471 commits covered exactly once across 15 buckets"
echo "  270 changed paths covered exactly once across 20 groups"
echo "  98 added, 170 modified, 2 deleted; +84722/-1864"
echo "  inventory hashes and immutable v070-v073 order match"
echo "  v073 disposition is dormant compatibility only; destructive action is not authorized"
