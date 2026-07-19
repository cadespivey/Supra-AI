#!/usr/bin/env bash
# Developer-side release entrypoint: verify candidate readiness, start the
# release runner, and dispatch the protected release workflow bound to
# origin/main's exact SHA and its green Protected macOS CI run.
#
# The reviewed commit on main is the only statement of release version intent:
# no version or build values are forwarded — the workflow re-derives them from
# the checked-out project via Scripts/reviewed-release-metadata.sh, and the
# release preflight re-verifies every binding fail-closed. This script only
# assembles inputs and gives fast feedback; it is not a gate the transaction
# relies on.
set -euo pipefail

script_root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Scripts/lib/release-common.sh
source "${script_root}/Scripts/lib/release-common.sh"

usage() {
  printf 'Usage: release-dispatch.sh [--repository OWNER/REPO] [--rehearsal]\n' >&2
  exit 2
}

repository=''
workflow_name='Protected production release'
while (( $# > 0 )); do
  case "$1" in
    --repository) repository="${2:-}"; shift 2 ;;
    --rehearsal) workflow_name='Protected signed release rehearsal'; shift ;;
    *) usage ;;
  esac
done

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || release_die 'release dispatch must run inside the repository checkout'

if [[ -z "$repository" ]]; then
  origin_url="$(git -C "$repo_root" remote get-url origin 2>/dev/null || true)"
  repository="$(printf '%s\n' "$origin_url" \
    | sed -nE 's#^(https://github\.com/|git@github\.com:)([^/]+/[^/]+)\.git$#\2#p; s#^(https://github\.com/|git@github\.com:)([^/]+/[^/]+)$#\2#p' \
    | head -1)"
fi
release_validate_repository "$repository"

for command in git jq sed mktemp; do
  release_require_command "$command"
done
gh_command="$(release_resolve_command_override SUPRA_GH_COMMAND gh)"
asset_audit="$(release_resolve_command_override SUPRA_ASSET_AUDIT_COMMAND \
  "${script_root}/Scripts/verify-public-repository-assets.sh")"
runner_stop_override="$(release_resolve_command_override SUPRA_RUNNER_STOP_COMMAND '')"
runner_home="${SUPRA_RUNNER_HOME:-${HOME}/actions-runner}"

poll_seconds=5
if [[ "${SUPRA_RELEASE_TESTING:-0}" == '1' && -n "${SUPRA_RELEASE_CHECK_POLL_SECONDS:-}" ]]; then
  poll_seconds="$SUPRA_RELEASE_CHECK_POLL_SECONDS"
fi
spawn_wait_seconds="$poll_seconds"
if [[ "$spawn_wait_seconds" == '0' ]]; then
  spawn_wait_seconds='0.1'
fi

stop_runner() {
  if [[ -n "$runner_stop_override" ]]; then
    "$runner_stop_override" || true
  else
    pkill -INT -f "${runner_home}/bin/Runner.Listener" 2>/dev/null || true
  fi
}

project_at_sha=''
runner_started=0
cleanup() {
  local exit_status=$?
  [[ -n "$project_at_sha" ]] && rm -f "$project_at_sha"
  if (( exit_status != 0 && runner_started == 1 )); then
    printf 'Stopping the release runner after a failed dispatch…\n' >&2
    stop_runner
  fi
}
trap cleanup EXIT

"$gh_command" auth status >/dev/null 2>&1 \
  || release_die 'GitHub authentication is unavailable (gh auth status failed)'

printf 'Resolving origin/main…\n'
git -C "$repo_root" fetch origin main --quiet || release_die 'unable to fetch origin/main'
sha="$(git -C "$repo_root" rev-parse --verify FETCH_HEAD)"
release_validate_sha "$sha"

project_at_sha="$(mktemp)"
git -C "$repo_root" show "${sha}:Apps/SupraAI/SupraAI.xcodeproj/project.pbxproj" \
  >"$project_at_sha" 2>/dev/null \
  || release_die 'reviewed project metadata is missing at origin/main'
version="$(bash "${script_root}/Scripts/reviewed-release-metadata.sh" "$project_at_sha" version)"
build="$(bash "${script_root}/Scripts/reviewed-release-metadata.sh" "$project_at_sha" build)"
tag="v${version}"
printf 'Reviewed candidate at origin/main: %s (build %s)\n' "$tag" "$build"

remote_tag="$(git -C "$repo_root" ls-remote --tags origin "refs/tags/${tag}" "refs/tags/${tag}^{}")" \
  || release_die 'unable to inspect origin release tags'
[[ -z "$remote_tag" ]] || release_die "release tag already exists on origin: ${tag}"
if "$gh_command" release view "$tag" --repo "$repository" >/dev/null 2>&1; then
  release_die "release ${tag} is already published or reserved"
fi

ci_json="$("$gh_command" run list --repo "$repository" --branch main \
  --workflow 'Protected macOS CI' --json databaseId,headSha,conclusion,status --limit 20)" \
  || release_die 'unable to list Protected macOS CI runs'
ci_run_id="$(jq -r --arg sha "$sha" \
  '[.[] | select(.headSha == $sha and .status == "completed" and .conclusion == "success")][0].databaseId // empty' \
  <<<"$ci_json")"
[[ -n "$ci_run_id" ]] \
  || release_die "no green Protected macOS CI run exists for origin/main (${sha}); wait for CI or fix it first"

printf 'Running the live public-asset audit…\n'
audit_token="${PUBLIC_ASSET_GITHUB_TOKEN:-$("$gh_command" auth token 2>/dev/null || true)}"
PUBLIC_ASSET_GITHUB_TOKEN="$audit_token" "$asset_audit" "$repository" \
  || release_die 'live public-asset audit failed; the release is blocked until it passes'

[[ -x "${runner_home}/run.sh" ]] \
  || release_die "no release runner is provisioned at ${runner_home}"
if pgrep -f "${runner_home}/bin/Runner.Listener" >/dev/null 2>&1; then
  release_die 'the release runner is already running; stop it before dispatching'
fi
printf 'Starting the release runner…\n'
rm -f "${runner_home}/run.log"
(cd "$runner_home" && nohup ./run.sh >"${runner_home}/run.log" 2>&1 &)
runner_started=1

for (( attempt = 0; attempt < 40; attempt++ )); do
  [[ -s "${runner_home}/run.log" ]] && break
  sleep "$spawn_wait_seconds"
done
[[ -s "${runner_home}/run.log" ]] \
  || release_die "the release runner produced no output; check ${runner_home}/run.log"

runner_online=0
for (( attempt = 0; attempt < 24; attempt++ )); do
  runners_json="$("$gh_command" api "repos/${repository}/actions/runners" 2>/dev/null \
    || printf '{}')"
  if jq -e '.runners[]? | select(.status == "online"
      and ([.labels[].name] | index("supra-release-isolated")))' \
    >/dev/null 2>&1 <<<"$runners_json"; then
    runner_online=1
    break
  fi
  sleep "$poll_seconds"
done
(( runner_online == 1 )) \
  || release_die "the release runner did not come online in GitHub; check ${runner_home}/run.log"

printf 'Dispatching %s for %s (build %s) at %s…\n' "$workflow_name" "$tag" "$build" "$sha"
"$gh_command" workflow run "$workflow_name" --repo "$repository" \
  -f "expected_sha=${sha}" -f "ci_run_id=${ci_run_id}" \
  || release_die 'workflow dispatch failed'

run_url=''
for (( attempt = 0; attempt < 20; attempt++ )); do
  runs_json="$("$gh_command" run list --repo "$repository" --workflow "$workflow_name" \
    --json databaseId,status,url --limit 1 2>/dev/null || printf '[]')"
  run_url="$(jq -r '.[0].url // empty' <<<"$runs_json")"
  [[ -n "$run_url" ]] && break
  sleep "$poll_seconds"
done

finish_flag=''
if [[ "$workflow_name" == *rehearsal* ]]; then
  finish_flag=' --rehearsal'
fi
printf '\nDispatched %s\n' "$workflow_name"
printf '  candidate:    %s (build %s)\n' "$tag" "$build"
printf '  source SHA:   %s\n' "$sha"
printf '  CI evidence:  run %s\n' "$ci_run_id"
if [[ -n "$run_url" ]]; then
  printf '  workflow run: %s\n' "$run_url"
fi
printf '\nApprove the production-release deployment in GitHub, then run:\n'
printf '  bash Scripts/release-finish.sh%s\n' "$finish_flag"
