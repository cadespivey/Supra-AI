#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
website="${1:-${repo_root}/website}"
npm_command="${SUPRA_NPM:-npm}"
font_guard="${SUPRA_FONT_GUARD:-${repo_root}/Scripts/verify-public-font-license.sh}"
if (( $# > 1 )) || [[ ! -f "${website}/package-lock.json" ]]; then
  printf 'Usage: %s [website-directory]\n' "$0" >&2
  exit 2
fi

run_step() {
  local name="$1"
  shift
  local status=0
  "$@" || status=$?
  if (( status != 0 )); then
    printf 'ERROR: Website gate failed: %s\n' "$name" >&2
    exit "$status"
  fi
}

run_step 'pre-build public font guard' "$font_guard"
cd "$website"
run_step 'npm ci' "$npm_command" ci
run_step 'lint' "$npm_command" run lint
run_step 'typecheck' "$npm_command" run typecheck
run_step 'static build' "$npm_command" run build:pages
# The dependency audit is the one gate here that fails because the OUTSIDE WORLD
# changed rather than because someone changed something: a newly published advisory
# against an unmodified tree turns it red. Blocking every merge in the repository on
# that is a mismatch — a Swift-only change cannot introduce an npm advisory, and this
# site is a static export, so these build-time packages never execute for a visitor.
#
# CI therefore sets SUPRA_SKIP_DEP_AUDIT=1 when a run touches nothing under website/,
# and the weekly scheduled audit (.github/workflows/security-scheduled.yml) owns
# advisory drift. Unset or 0 — including every local run — audits as before.
if [[ "${SUPRA_SKIP_DEP_AUDIT:-0}" == "1" ]]; then
  printf 'SKIP: dependency audit — no website/ changes in this run; the weekly scheduled audit covers advisory drift.\n'
else
  run_step 'dependency audit' "$npm_command" audit --audit-level=high
fi
run_step 'post-build public font guard' "$font_guard"
printf '%s\n' 'Website gates passed.'
