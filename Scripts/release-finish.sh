#!/usr/bin/env bash
# Developer-side release wrap-up: watch a dispatched protected release run to
# completion, stop the release runner, archive evidence via
# Scripts/reset-release-runner.sh. The protected transaction owns public
# verification and records it in release-result JSON. Evidence archival happens for every completed run,
# green or red; a run that never completes leaves the runner and workspace
# untouched for investigation.
set -euo pipefail

script_root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Scripts/lib/release-common.sh
source "${script_root}/Scripts/lib/release-common.sh"

usage() {
  printf 'Usage: release-finish.sh [--repository OWNER/REPO] [--run RUN_ID] [--rehearsal]\n' >&2
  exit 2
}

repository=''
run_id=''
rehearsal=0
workflow_name='Protected production release'
while (( $# > 0 )); do
  case "$1" in
    --repository) repository="${2:-}"; shift 2 ;;
    --run) run_id="${2:-}"; shift 2 ;;
    --rehearsal) rehearsal=1; workflow_name='Protected signed release rehearsal'; shift ;;
    *) usage ;;
  esac
done

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || release_die 'release finish must run inside the repository checkout'

if [[ -z "$repository" ]]; then
  origin_url="$(git -C "$repo_root" remote get-url origin 2>/dev/null || true)"
  repository="$(printf '%s\n' "$origin_url" \
    | sed -nE 's#^(https://github\.com/|git@github\.com:)([^/]+/[^/]+)\.git$#\2#p; s#^(https://github\.com/|git@github\.com:)([^/]+/[^/]+)$#\2#p' \
    | head -1)"
fi
release_validate_repository "$repository"

for command in git jq mktemp; do
  release_require_command "$command"
done
gh_command="$(release_resolve_command_override SUPRA_GH_COMMAND gh)"
reset_command="$(release_resolve_command_override SUPRA_RESET_COMMAND \
  "${script_root}/Scripts/reset-release-runner.sh")"
runner_stop_override="$(release_resolve_command_override SUPRA_RUNNER_STOP_COMMAND '')"
pkill_command="$(release_resolve_command_override SUPRA_PKILL_COMMAND pkill)"
pgrep_command="$(release_resolve_command_override SUPRA_PGREP_COMMAND pgrep)"
runner_home="${SUPRA_RUNNER_HOME:-${HOME}/actions-runner}"

poll_seconds=30
if [[ "${SUPRA_RELEASE_TESTING:-0}" == '1' && -n "${SUPRA_RELEASE_CHECK_POLL_SECONDS:-}" ]]; then
  poll_seconds="$SUPRA_RELEASE_CHECK_POLL_SECONDS"
fi
max_attempts=360
if [[ "${SUPRA_RELEASE_TESTING:-0}" == '1' && -n "${SUPRA_RELEASE_FINISH_MAX_ATTEMPTS:-}" ]]; then
  max_attempts="$SUPRA_RELEASE_FINISH_MAX_ATTEMPTS"
fi

if [[ -z "$run_id" ]]; then
  runs_json="$("$gh_command" run list --repo "$repository" --workflow "$workflow_name" \
    --json databaseId,status,url --limit 1)" \
    || release_die 'unable to list workflow runs'
  run_id="$(jq -r '.[0].databaseId // empty' <<<"$runs_json")"
  [[ -n "$run_id" ]] || release_die "no ${workflow_name} run was found to finish"
fi

run_status=''
conclusion=''
run_url=''
for (( attempt = 0; attempt < max_attempts; attempt++ )); do
  run_json="$("$gh_command" run view "$run_id" --repo "$repository" \
    --json status,conclusion,url)" \
    || release_die "unable to inspect workflow run ${run_id}"
  run_status="$(jq -r '.status // empty' <<<"$run_json")"
  conclusion="$(jq -r '.conclusion // empty' <<<"$run_json")"
  run_url="$(jq -r '.url // empty' <<<"$run_json")"
  [[ "$run_status" == 'completed' ]] && break
  sleep "$poll_seconds"
done
if [[ "$run_status" != 'completed' ]]; then
  release_die "timed out waiting for run ${run_id}; the runner and workspace were left untouched (${run_url})"
fi

printf 'Run %s concluded: %s\n' "$run_id" "$conclusion"

stop_poll_seconds=1
if [[ "${SUPRA_RELEASE_TESTING:-0}" == '1' && -n "${SUPRA_RELEASE_CHECK_POLL_SECONDS:-}" ]]; then
  stop_poll_seconds="$SUPRA_RELEASE_CHECK_POLL_SECONDS"
fi

runner_alive() {
  "$pgrep_command" -f "${runner_home}/bin/Runner.Listener|${runner_home}/run-helper.sh" \
    >/dev/null 2>&1
}

runner_stop_wait() {
  local attempts="$1"
  local attempt
  for (( attempt = 0; attempt < attempts; attempt++ )); do
    runner_alive || return 0
    sleep "$stop_poll_seconds"
  done
  ! runner_alive
}

printf 'Stopping the release runner…\n'
if [[ -n "$runner_stop_override" ]]; then
  "$runner_stop_override" || true
else
  # run.sh wraps Runner.Listener in run-helper.sh, and the helper RESPAWNS the
  # listener when it exits — killing only the listener let it come straight
  # back, and finish died here demanding a manual stop on BOTH v2.3.3
  # production rounds. Stop the respawning wrappers first, then the listener.
  "$pkill_command" -f "${runner_home}/run-helper.sh" 2>/dev/null || true
  "$pkill_command" -f "${runner_home}/run.sh" 2>/dev/null || true
  "$pkill_command" -INT -f "${runner_home}/bin/Runner.Listener" 2>/dev/null || true
fi
if ! runner_stop_wait 20; then
  # A listener orphaned to launchd (its wrapper died with the operator's
  # session) ignores SIGINT — observed on the first post-release rehearsal.
  # Escalate to TERM, then KILL; give up only if it survives KILL.
  printf 'Runner ignored INT; escalating to TERM…\n'
  "$pkill_command" -TERM -f "${runner_home}/bin/Runner.Listener" 2>/dev/null || true
  if ! runner_stop_wait 5; then
    printf 'Runner ignored TERM; escalating to KILL…\n'
    "$pkill_command" -KILL -f "${runner_home}/bin/Runner.Listener" 2>/dev/null || true
    runner_stop_wait 5 \
      || release_die 'the release runner did not stop; stop it manually, then run Scripts/reset-release-runner.sh'
  fi
fi

printf 'Archiving evidence and clearing the runner workspace…\n'
"$reset_command"

if [[ "$conclusion" != 'success' ]]; then
  printf 'ERROR: run %s concluded %s (%s)\n' "$run_id" "$conclusion" "$run_url" >&2
  printf '%s\n' 'Evidence is archived. If a release became public, use the Protected emergency release rollback workflow with the archived release-result JSON (see Docs/Release-Runbook.md).' >&2
  exit 1
fi

if (( rehearsal == 1 )); then
  printf 'Rehearsal run %s completed green; no publication was attempted.\n' "$run_id"
else
  printf 'Release run %s completed green; transaction verification is archived with the release evidence.\n' "$run_id"
fi
