#!/usr/bin/env bash
# One release command: create one metadata commit, validate that exact SHA once,
# fast-forward it to main, then run the protected signed publication transaction.
set -euo pipefail

script_root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Scripts/lib/release-common.sh
source "${script_root}/Scripts/lib/release-common.sh"

usage() {
  printf 'Usage: cut-release.sh (--patch | X.Y.Z) --notes-file FILE\n' >&2
  printf '       cut-release.sh --rehearsal\n' >&2
  exit 2
}

requested_version=''
notes_file=''
rehearsal=0
while (( $# > 0 )); do
  case "$1" in
    --patch) requested_version='--patch'; shift ;;
    --notes-file) notes_file="${2:-}"; shift 2 ;;
    --rehearsal) rehearsal=1; shift ;;
    [0-9]*.[0-9]*.[0-9]*) requested_version="$1"; shift ;;
    *) usage ;;
  esac
done
(( rehearsal == 1 )) || [[ -n "$requested_version" ]] || usage

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || release_die 'cut-release must run inside the repository checkout'
project='Apps/SupraAI/SupraAI.xcodeproj/project.pbxproj'
for command in git jq sed awk; do release_require_command "$command"; done

gh_command="$(release_resolve_command_override SUPRA_GH_COMMAND gh)"
dispatch_command="$(release_resolve_command_override SUPRA_DISPATCH_COMMAND \
  "${script_root}/Scripts/release-dispatch.sh")"
finish_command="$(release_resolve_command_override SUPRA_FINISH_COMMAND \
  "${script_root}/Scripts/release-finish.sh")"
console_check_command="$(release_resolve_command_override SUPRA_CONSOLE_CHECK_COMMAND '')"
caffeinate_command="$(release_resolve_command_override SUPRA_CAFFEINATE_COMMAND caffeinate)"
pgrep_command="$(release_resolve_command_override SUPRA_PGREP_COMMAND pgrep)"
poll_seconds="${SUPRA_RELEASE_CHECK_POLL_SECONDS:-30}"
max_polls="${SUPRA_CUT_MAX_CI_POLLS:-720}"

[[ -z "$(git -C "$repo_root" status --porcelain)" ]] \
  || release_die 'the working tree must be clean to cut a release'
current_branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)"
[[ "$current_branch" == 'main' ]] || release_die "cut-release starts from main (currently on ${current_branch})"
git -C "$repo_root" fetch origin main --quiet || release_die 'unable to fetch origin/main'
[[ "$(git -C "$repo_root" rev-parse HEAD)" == "$(git -C "$repo_root" rev-parse FETCH_HEAD)" ]] \
  || release_die 'local main must match origin/main before cutting'
if (( rehearsal == 0 )); then
  [[ -n "$notes_file" && -s "$notes_file" ]] \
    || release_die 'a release needs user-facing notes: pass --notes-file FILE'
fi

"$gh_command" auth status >/dev/null 2>&1 || release_die 'gh is not authenticated'
if [[ -n "$console_check_command" ]]; then
  "$console_check_command" || release_die 'the console is locked; unlock it before releasing'
else
  ioreg -n Root -d1 -a 2>/dev/null | grep -A1 IOConsoleLocked | grep -q '<false/>' \
    || release_die 'the console is locked; unlock it before releasing'
fi
runner_home="${SUPRA_RUNNER_HOME:-${HOME}/actions-runner}"
if "$pgrep_command" -f "${runner_home}/bin/Runner.Listener" >/dev/null 2>&1; then
  release_die 'the release runner is already running; stop or reset it first'
fi

"$caffeinate_command" -dimsu -t 14400 &
caffeinate_pid=$!
trap 'kill "$caffeinate_pid" 2>/dev/null || true' EXIT

wait_for_exact_ci() {
  local branch="$1" expected_sha="$2"
  local poll runs selected status conclusion run_id
  for (( poll = 0; poll < max_polls; poll++ )); do
    runs="$("$gh_command" run list --branch "$branch" --workflow 'Protected macOS CI' \
      --json databaseId,headSha,status,conclusion,url --limit 10)" \
      || release_die 'unable to list validation runs'
    selected="$(jq --arg sha "$expected_sha" '[.[] | select(.headSha == $sha)][0] // empty' <<<"$runs")"
    if [[ -n "$selected" ]]; then
      status="$(jq -r '.status // empty' <<<"$selected")"
      conclusion="$(jq -r '.conclusion // empty' <<<"$selected")"
      run_id="$(jq -r '.databaseId // empty' <<<"$selected")"
      if [[ "$status" == 'completed' ]]; then
        if [[ "$conclusion" != 'success' ]]; then
          release_die "validation failed for ${expected_sha}"
          return 1
        fi
        printf '%s\n' "$run_id"
        return 0
      fi
    fi
    sleep "$poll_seconds"
  done
  release_die "timed out waiting for validation of ${expected_sha}"
}

version=''
build=''
if (( rehearsal == 0 )); then
  current_version="$(bash "${script_root}/Scripts/reviewed-release-metadata.sh" "${repo_root}/${project}" version)"
  current_build="$(bash "${script_root}/Scripts/reviewed-release-metadata.sh" "${repo_root}/${project}" build)"
  if [[ "$requested_version" == '--patch' ]]; then
    version="${current_version%.*}.$(( ${current_version##*.} + 1 ))"
  else
    version="$requested_version"
  fi
  release_validate_version "$version"
  [[ "$version" != "$current_version" ]] || release_die "version ${version} is already the candidate"
  build=$((current_build + 1))

  sed -i '' \
    -e "s/MARKETING_VERSION = ${current_version};/MARKETING_VERSION = ${version};/g" \
    -e "s/CURRENT_PROJECT_VERSION = ${current_build};/CURRENT_PROJECT_VERSION = ${build};/g" \
    "${repo_root}/${project}"
  entry="$(mktemp)"
  {
    printf '## [%s] - %s\n\n' "$version" "$(date +%Y-%m-%d)"
    cat "$notes_file"
    printf '\n'
  } >"$entry"
  awk -v entry="$entry" '
    /^## \[[0-9]/ && !inserted { while ((getline line < entry) > 0) print line; print ""; inserted = 1 }
    { print }
  ' "${repo_root}/CHANGELOG.md" >"${repo_root}/CHANGELOG.md.tmp"
  mv "${repo_root}/CHANGELOG.md.tmp" "${repo_root}/CHANGELOG.md"
  rm -f "$entry"

  candidate_branch="release/${version}"
  git -C "$repo_root" switch -c "$candidate_branch" --quiet
  git -C "$repo_root" add "$project" CHANGELOG.md
  git -C "$repo_root" commit --quiet -m "Release ${version} (${build})"
  candidate_sha="$(git -C "$repo_root" rev-parse HEAD)"
  git -C "$repo_root" push --quiet -u origin "$candidate_branch"

  "$gh_command" workflow run 'Protected macOS CI' --ref "$candidate_branch"
  ci_run_id="$(wait_for_exact_ci "$candidate_branch" "$candidate_sha")"

  # The validated commit itself advances main; no merge commit and no second CI run.
  git -C "$repo_root" push origin "${candidate_sha}:refs/heads/main"
  git -C "$repo_root" push origin --delete "$candidate_branch" >/dev/null 2>&1 || true
  git -C "$repo_root" switch main --quiet
  git -C "$repo_root" merge --ff-only "$candidate_sha" --quiet
  printf 'Validated release commit %s fast-forwarded to main with CI run %s.\n' "$candidate_sha" "$ci_run_id"
fi

dispatch_arguments=()
finish_arguments=()
transaction_workflow='Protected production release'
if (( rehearsal == 1 )); then
  dispatch_arguments+=(--rehearsal)
  finish_arguments+=(--rehearsal)
  transaction_workflow='Protected signed release rehearsal'
fi
"$dispatch_command" ${dispatch_arguments[@]+"${dispatch_arguments[@]}"} \
  || release_die 'release dispatch failed; nothing was published'

transaction_run=''
for (( poll = 0; poll < max_polls; poll++ )); do
  runs="$("$gh_command" run list --workflow "$transaction_workflow" \
    --json databaseId,status,conclusion,url --limit 1)" || release_die 'unable to list release runs'
  transaction_run="$(jq -r '.[0].databaseId // empty' <<<"$runs")"
  [[ -n "$transaction_run" ]] && break
  sleep "$poll_seconds"
done
[[ -n "$transaction_run" ]] || release_die 'the release transaction never appeared'

"$finish_command" ${finish_arguments[@]+"${finish_arguments[@]}"} --run "$transaction_run" \
  || release_die "the release did not complete (run ${transaction_run})"

if (( rehearsal == 1 )); then
  printf 'Rehearsal completed green; publication was disabled.\n'
else
  printf 'Release v%s (%s) is live.\n' "$version" "$build"
fi
