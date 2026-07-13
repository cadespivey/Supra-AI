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
run_step 'dependency audit' "$npm_command" audit --audit-level=high
run_step 'post-build public font guard' "$font_guard"
printf '%s\n' 'Website gates passed.'
