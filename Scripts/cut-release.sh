#!/usr/bin/env bash
# The one-command release. From a logged-in owner session:
#
#   bash Scripts/cut-release.sh --patch --notes-file NOTES.md   # next patch
#   bash Scripts/cut-release.sh 2.4.0 --notes-file NOTES.md     # explicit version
#   bash Scripts/cut-release.sh --rehearsal                     # signed rehearsal
#
# It sequences the whole runbook: preflight, the version/changelog candidate
# on a release branch, the candidate PR, babysat CI (only GitHub "Set up job"
# infrastructure flakes are rerun, and only a bounded number of times), the
# merge, the main-CI wait, release-dispatch.sh, the production-release
# deployment-gate approval (automatic — running this command IS the owner's
# approval; pass --hold to keep the gate manual), and release-finish.sh.
#
# Every fail-closed gate stays exactly as strict as before: this script only
# removes the human choreography between the gates. Its CI waits track the
# NEWEST run per branch as progress; exact-SHA green CI is re-verified
# fail-closed by release-dispatch.sh and again inside the protected
# transaction, where nothing here can weaken it.
set -euo pipefail

script_root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Scripts/lib/release-common.sh
source "${script_root}/Scripts/lib/release-common.sh"

usage() {
  printf 'Usage: cut-release.sh (--patch | X.Y.Z) --notes-file FILE [--hold]\n' >&2
  printf '       cut-release.sh --rehearsal [--hold]\n' >&2
  exit 2
}

requested_version=''
notes_file=''
hold=0
rehearsal=0
while (( $# > 0 )); do
  case "$1" in
    --patch) requested_version='--patch'; shift ;;
    --notes-file) notes_file="${2:-}"; shift 2 ;;
    --hold) hold=1; shift ;;
    --rehearsal) rehearsal=1; shift ;;
    [0-9]*.[0-9]*.[0-9]*) requested_version="$1"; shift ;;
    *) usage ;;
  esac
done
if (( rehearsal == 0 )); then
  [[ -n "$requested_version" ]] || usage
fi

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

poll_seconds=30
if [[ "${SUPRA_RELEASE_TESTING:-0}" == '1' && -n "${SUPRA_RELEASE_CHECK_POLL_SECONDS:-}" ]]; then
  poll_seconds="$SUPRA_RELEASE_CHECK_POLL_SECONDS"
fi
max_ci_polls="${SUPRA_CUT_MAX_CI_POLLS:-720}"
flake_reruns="${SUPRA_CUT_FLAKE_RERUNS:-2}"

# --- Preflight (git-side first: refuse before any GitHub interaction) -------
[[ -z "$(git -C "$repo_root" status --porcelain)" ]] \
  || release_die 'the working tree must be clean to cut a release'
if (( rehearsal == 0 )); then
  current_branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)"
  [[ "$current_branch" == 'main' ]] \
    || release_die "cut-release starts from main (currently on ${current_branch})"
  git -C "$repo_root" fetch origin main --quiet \
    || release_die 'unable to fetch origin/main'
  [[ "$(git -C "$repo_root" rev-parse HEAD)" == "$(git -C "$repo_root" rev-parse FETCH_HEAD)" ]] \
    || release_die 'local main must match origin/main before cutting'
  [[ -n "$notes_file" && -s "$notes_file" ]] \
    || release_die 'a release needs user-facing notes: pass --notes-file FILE (non-empty markdown body for the changelog entry)'
fi

"$gh_command" auth status >/dev/null 2>&1 || release_die 'gh is not authenticated'

# The v2.3.2 round-1 failure: notarization needs the login keychain, which is
# unavailable while the console is locked. Refuse up front, not 20 minutes in.
if [[ -n "$console_check_command" ]]; then
  "$console_check_command" \
    || release_die 'the console is locked; unlock the session before cutting a release'
else
  ioreg -n Root -d1 -a 2>/dev/null | grep -A1 IOConsoleLocked | grep -q '<false/>' \
    || release_die 'the console is locked (IOConsoleLocked); unlock the session before cutting a release'
fi

runner_home="${SUPRA_RUNNER_HOME:-${HOME}/actions-runner}"
if "$pgrep_command" -f "${runner_home}/bin/Runner.Listener" >/dev/null 2>&1; then
  release_die 'the release runner is already running; release-dispatch starts it per run — stop it first (Scripts/reset-release-runner.sh after stopping)'
fi

# Keep the session awake through build + notarization; released on exit.
"$caffeinate_command" -dimsu -t 14400 &
caffeinate_pid=$!
trap 'kill "$caffeinate_pid" 2>/dev/null || true' EXIT

# --- CI babysitting ---------------------------------------------------------
# Reruns are allowed ONLY when every failed job died in GitHub's own "Set up
# job" step — runner provisioning, before any repository code executed. A
# failure in any real step aborts the cut immediately.
run_is_setup_flake() {
  local run_id="$1"
  "$gh_command" run view "$run_id" --json jobs \
    | jq -e '
        [.jobs[] | select(.conclusion == "failure")] as $failed
        | ($failed | length) > 0
          and ($failed | all(
                [.steps[] | select(.conclusion == "failure") | .name] as $steps
                | ($steps | length) > 0 and ($steps | all(. == "Set up job"))
              ))
      ' >/dev/null 2>&1
}

wait_for_branch_ci() {
  local branch="$1" label="$2"
  local reruns_left="$flake_reruns"
  local poll runs run_id status conclusion url
  for (( poll = 0; poll < max_ci_polls; poll++ )); do
    runs="$("$gh_command" run list --branch "$branch" --workflow 'Protected macOS CI' \
      --json databaseId,headSha,status,conclusion,url --limit 1)" \
      || release_die "unable to list CI runs for ${label}"
    run_id="$(jq -r '.[0].databaseId // empty' <<<"$runs")"
    status="$(jq -r '.[0].status // empty' <<<"$runs")"
    conclusion="$(jq -r '.[0].conclusion // empty' <<<"$runs")"
    url="$(jq -r '.[0].url // empty' <<<"$runs")"
    if [[ -n "$run_id" && "$status" == 'completed' ]]; then
      if [[ "$conclusion" == 'success' ]]; then
        printf 'CI green on %s (run %s).\n' "$label" "$run_id"
        return 0
      fi
      if run_is_setup_flake "$run_id" && (( reruns_left > 0 )); then
        reruns_left=$(( reruns_left - 1 ))
        printf 'CI on %s failed only in "Set up job" (infrastructure flake); rerunning failed jobs (%s rerun(s) left).\n' \
          "$label" "$reruns_left"
        "$gh_command" run rerun "$run_id" --failed \
          || release_die "unable to rerun flaked run ${run_id}"
      else
        release_die "CI failed on ${label} (${url:-run ${run_id}}); not an infrastructure flake — fix the cause and run cut-release again"
      fi
    fi
    sleep "$poll_seconds"
  done
  release_die "timed out waiting for CI on ${label}"
}

# --- Candidate commit, PR, merge (production only) ---------------------------
version=''
build=''
if (( rehearsal == 0 )); then
  current_version="$(bash "${script_root}/Scripts/reviewed-release-metadata.sh" \
    "${repo_root}/${project}" version)"
  current_build="$(bash "${script_root}/Scripts/reviewed-release-metadata.sh" \
    "${repo_root}/${project}" build)"
  if [[ "$requested_version" == '--patch' ]]; then
    version="${current_version%.*}.$(( ${current_version##*.} + 1 ))"
  else
    version="$requested_version"
  fi
  release_validate_version "$version"
  [[ "$version" != "$current_version" ]] \
    || release_die "version ${version} is already the reviewed candidate"
  build=$(( current_build + 1 ))

  old_version_count="$(grep -c "MARKETING_VERSION = ${current_version};" "${repo_root}/${project}")"
  old_build_count="$(grep -c "CURRENT_PROJECT_VERSION = ${current_build};" "${repo_root}/${project}")"
  sed -i '' \
    -e "s/MARKETING_VERSION = ${current_version};/MARKETING_VERSION = ${version};/g" \
    -e "s/CURRENT_PROJECT_VERSION = ${current_build};/CURRENT_PROJECT_VERSION = ${build};/g" \
    "${repo_root}/${project}"
  [[ "$(grep -c "MARKETING_VERSION = ${version};" "${repo_root}/${project}")" == "$old_version_count" \
    && "$(grep -c "CURRENT_PROJECT_VERSION = ${build};" "${repo_root}/${project}")" == "$old_build_count" ]] \
    || release_die 'version bump did not rewrite every reviewed occurrence'

  entry="$(mktemp)"
  {
    printf '## [%s] - %s\n\n' "$version" "$(date +%Y-%m-%d)"
    cat "$notes_file"
    printf '\n'
  } >"$entry"
  changelog="${repo_root}/CHANGELOG.md"
  awk -v entry="$entry" '
    /^## \[/ && !inserted { while ((getline line < entry) > 0) print line; print ""; inserted = 1 }
    { print }
  ' "$changelog" >"${changelog}.tmp"
  mv "${changelog}.tmp" "$changelog"
  rm -f "$entry"
  grep -Fq "## [${version}]" "$changelog" \
    || release_die 'changelog entry was not written'

  candidate_branch="release/${version}"
  git -C "$repo_root" checkout -b "$candidate_branch" --quiet
  git -C "$repo_root" add "$project" CHANGELOG.md
  git -C "$repo_root" commit --quiet \
    -m "Release ${version} (${build}): version bump and changelog"
  git -C "$repo_root" push --quiet -u origin "$candidate_branch"

  pr_url="$("$gh_command" pr create \
    --title "Release ${version} (${build})" \
    --body "Release-candidate commit per Docs/Release-Runbook.md, opened by Scripts/cut-release.sh: version ${version}, build ${build}, changelog entry from the provided notes.")"
  printf 'Candidate PR: %s\n' "$pr_url"

  wait_for_branch_ci "$candidate_branch" "the candidate PR"
  "$gh_command" pr merge "$candidate_branch" --merge --delete-branch \
    || release_die 'unable to merge the candidate PR'
  git -C "$repo_root" checkout main --quiet
  git -C "$repo_root" fetch origin main --quiet
  git -C "$repo_root" merge --ff-only FETCH_HEAD --quiet 2>/dev/null || true
  wait_for_branch_ci main "main after the candidate merge"
fi

# --- Dispatch, approve, finish ----------------------------------------------
dispatch_arguments=()
finish_arguments=()
transaction_workflow='Protected production release'
if (( rehearsal == 1 )); then
  dispatch_arguments+=(--rehearsal)
  finish_arguments+=(--rehearsal)
  transaction_workflow='Protected signed release rehearsal'
  # One command means waiting, not failing fast: a rehearsal typically runs
  # right after a machinery-change merge, when main's CI is still in flight.
  # Dispatch still re-verifies exact-SHA green fail-closed.
  wait_for_branch_ci main "main (rehearsal preflight)"
fi
"$dispatch_command" ${dispatch_arguments[@]+"${dispatch_arguments[@]}"} \
  || release_die 'release-dispatch failed; nothing was published — fix the cause and run cut-release again'

transaction_run=''
for (( poll = 0; poll < max_ci_polls; poll++ )); do
  runs="$("$gh_command" run list --workflow "$transaction_workflow" \
    --json databaseId,status,conclusion,url --limit 1)" \
    || release_die 'unable to list transaction runs'
  transaction_run="$(jq -r '.[0].databaseId // empty' <<<"$runs")"
  transaction_status="$(jq -r '.[0].status // empty' <<<"$runs")"
  if [[ -n "$transaction_run" && "$transaction_status" == 'waiting' ]]; then
    if (( hold == 1 )); then
      printf 'Deployment gate is waiting on run %s — approve it in GitHub (production-release environment); holding as requested.\n' \
        "$transaction_run"
    else
      environment_id="$("$gh_command" api \
        "repos/{owner}/{repo}/actions/runs/${transaction_run}/pending_deployments" \
        --jq '.[0].environment.id')" \
        || release_die 'unable to read the pending deployment'
      "$gh_command" api --method POST \
        "repos/{owner}/{repo}/actions/runs/${transaction_run}/pending_deployments" \
        -F "environment_ids[]=${environment_id}" \
        -f state=approved \
        -f comment='Approved by Scripts/cut-release.sh — running the command is the owner approval.' \
        >/dev/null \
        || release_die 'unable to approve the deployment gate'
      printf 'Deployment gate approved for run %s.\n' "$transaction_run"
      break
    fi
  elif [[ -n "$transaction_run" && "$transaction_status" != 'waiting' && -n "$transaction_status" ]]; then
    # Already past the gate (manual approval under --hold, or a fast start).
    break
  fi
  sleep "$poll_seconds"
done
[[ -n "$transaction_run" ]] || release_die 'the transaction run never appeared'

"$finish_command" ${finish_arguments[@]+"${finish_arguments[@]}"} --run "$transaction_run" \
  || release_die "the release did not complete; release-finish archived evidence and printed the actual end state (run ${transaction_run})"

if (( rehearsal == 1 )); then
  printf 'Rehearsal completed green; publication was structurally impossible.\n'
else
  printf 'Release v%s (%s) is live.\n' "$version" "$build"
fi
