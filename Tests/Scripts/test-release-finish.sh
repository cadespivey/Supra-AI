#!/usr/bin/env bash
# Hermetic gating tests for Scripts/release-finish.sh — the developer-side
# command that watches a dispatched protected release run to completion, stops
# the release runner, archives evidence via the reset script, and re-verifies
# the published release and appcast as a user would.
#
# All GitHub, network, runner, and reset interactions go through command shims
# recorded in a log. Nothing contacts the network.
#
# Expected RED reason: Scripts/release-finish.sh does not exist yet, so every
# case exits with bash's missing-file status (127) instead of the expected
# behavior.
#
# Fixtures use non-default values (9.4.7 / 941, run id 770002). The public
# verification is wire-proofed with a stale-appcast case: a successful run
# whose appcast does not list the reviewed version must fail, so the check
# cannot pass by ignoring appcast content.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
finish="${repo_root}/Scripts/release-finish.sh"
failures=0

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

bin="${workdir}/bin"
state="${workdir}/state"
shim_log="${workdir}/shim.log"
mkdir -p "$bin" "$state"
: >"$shim_log"

cat >"${bin}/gh" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh %s\n' "$*" >>"${SHIM_LOG:?}"
case "${1:-} ${2:-}" in
  'auth status') exit 0 ;;
  'run list')
    printf '%s\n' "${SHIM_DISPATCHED_RUNS:?}"
    exit 0 ;;
  'run view')
    counter_file="${SHIM_STATE:?}/poll-count"
    count=0
    [[ -f "$counter_file" ]] && count="$(cat "$counter_file")"
    count=$((count + 1))
    printf '%s\n' "$count" >"$counter_file"
    if (( count <= ${SHIM_PENDING_POLLS:-0} )); then
      printf '%s\n' "${SHIM_PENDING_RUN_JSON:?}"
    else
      printf '%s\n' "${SHIM_FINAL_RUN_JSON:?}"
    fi
    exit 0 ;;
  'release view')
    printf '%s\n' "${SHIM_RELEASE_JSON:?}"
    exit 0 ;;
esac
exit 0
SHIM

cat >"${bin}/curl" <<'SHIM'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"${SHIM_LOG:?}"
printf '%s\n' "${SHIM_APPCAST:?}"
exit 0
SHIM

cat >"${bin}/reset" <<'SHIM'
#!/usr/bin/env bash
printf 'reset\n' >>"${SHIM_LOG:?}"
printf 'evidence archived under /fixture/evidence/20990101T000000Z\n'
exit 0
SHIM

cat >"${bin}/runner-stop" <<'SHIM'
#!/usr/bin/env bash
printf 'runner-stop\n' >>"${SHIM_LOG:?}"
exit 0
SHIM
chmod +x "${bin}/gh" "${bin}/curl" "${bin}/reset" "${bin}/runner-stop"

# Fixture origin repository whose reviewed metadata says 9.4.7 (build 941).
seed="${workdir}/seed"
origin="${workdir}/origin.git"
clone="${workdir}/clone"
mkdir -p "${seed}/Apps/SupraAI/SupraAI.xcodeproj"
{
  printf '// !$*UTF8*$!\n{\n'
  for configuration in AppDebug AppRelease XPCDebug XPCRelease; do
    printf '\t\t\tbuildSettings = {\n'
    printf '\t\t\t\tCONFIGURATION = %s;\n' "$configuration"
    printf '\t\t\t\tCURRENT_PROJECT_VERSION = 941;\n'
    printf '\t\t\t\tMARKETING_VERSION = 9.4.7;\n'
    printf '\t\t\t};\n'
  done
  printf '}\n'
} >"${seed}/Apps/SupraAI/SupraAI.xcodeproj/project.pbxproj"
git -C "$seed" init --quiet --initial-branch=main
git -C "$seed" -c user.name=fixture -c user.email=fixture@example.invalid add -A
git -C "$seed" -c user.name=fixture -c user.email=fixture@example.invalid \
  commit --quiet -m 'fixture candidate'
git clone --quiet --bare "$seed" "$origin"
git clone --quiet "$origin" "$clone"

run_url='https://github.com/example/fixture/actions/runs/770002'
run_pending='{"status":"in_progress","conclusion":"","url":"'"$run_url"'"}'
run_success='{"status":"completed","conclusion":"success","url":"'"$run_url"'"}'
run_failure='{"status":"completed","conclusion":"failure","url":"'"$run_url"'"}'
dispatched_runs='[{"databaseId":770002,"status":"in_progress","url":"'"$run_url"'"}]'
release_json='{"tagName":"v9.4.7","isDraft":false,"url":"https://github.com/example/fixture/releases/tag/v9.4.7"}'
appcast_current='<rss><channel><item><sparkle:shortVersionString>9.4.7</sparkle:shortVersionString><sparkle:version>941</sparkle:version></item></channel></rss>'
appcast_stale='<rss><channel><item><sparkle:shortVersionString>9.4.6</sparkle:shortVersionString><sparkle:version>940</sparkle:version></item></channel></rss>'

finish_status=0
finish_output="${workdir}/output.txt"

run_finish() {
  local extra_env=()
  while (( $# > 0 )) && [[ "$1" != '--' ]]; do
    extra_env+=("$1")
    shift
  done
  [[ "${1:-}" == '--' ]] && shift
  : >"$shim_log"
  rm -f "${state}/poll-count"
  finish_status=0
  (
    cd "$clone" && env \
      SUPRA_RELEASE_TESTING=1 \
      SUPRA_GH_COMMAND="${bin}/gh" \
      SUPRA_CURL_COMMAND="${bin}/curl" \
      SUPRA_RESET_COMMAND="${bin}/reset" \
      SUPRA_RUNNER_STOP_COMMAND="${bin}/runner-stop" \
      SUPRA_RELEASE_CHECK_POLL_SECONDS=0 \
      SUPRA_RELEASE_FINISH_MAX_ATTEMPTS=6 \
      SHIM_LOG="$shim_log" \
      SHIM_STATE="$state" \
      SHIM_PENDING_POLLS=0 \
      SHIM_PENDING_RUN_JSON="$run_pending" \
      SHIM_FINAL_RUN_JSON="$run_success" \
      SHIM_DISPATCHED_RUNS="$dispatched_runs" \
      SHIM_RELEASE_JSON="$release_json" \
      SHIM_APPCAST="$appcast_current" \
      ${extra_env[@]+"${extra_env[@]}"} \
      bash "$finish" --repository example/fixture "$@"
  ) >"$finish_output" 2>&1 || finish_status=$?
}

expect() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'PASS: %s\n' "$name"
  else
    printf 'FAIL: %s\n' "$name" >&2
    failures=$((failures + 1))
  fi
}

expect_status() {
  local name="$1"
  local expected="$2"
  if [[ "$finish_status" -eq "$expected" ]]; then
    printf 'PASS: %s\n' "$name"
  else
    printf 'FAIL: %s: expected status %s, got %s\n' "$name" "$expected" "$finish_status" >&2
    sed 's/^/  | /' "$finish_output" >&2
    failures=$((failures + 1))
  fi
}

log_line_number() {
  grep -n -- "$1" "$shim_log" | head -1 | cut -d: -f1
}

# --- Success: discovery, pending polls, stop, reset, public verification ----
run_finish SHIM_PENDING_POLLS=2 --
expect_status 'successful run finishes cleanly' 0
expect 'run discovery is used when no run id is given' \
  grep -Fq 'gh run list' "$shim_log"
expect 'pending run is polled to completion' \
  bash -c "(( $(grep -c 'gh run view' "$shim_log" 2>/dev/null || printf 0) >= 3 ))"
expect 'runner is stopped after completion' \
  grep -Fq 'runner-stop' "$shim_log"
expect 'evidence is archived via the reset script' \
  grep -Fxq 'reset' "$shim_log"
expect 'operator sees the evidence archive location' \
  grep -Fq '/fixture/evidence/20990101T000000Z' "$finish_output"
expect 'published release is re-checked' \
  grep -Fq 'gh release view' "$shim_log"
expect 'public appcast is re-checked' \
  grep -Fq 'curl' "$shim_log"
expect 'operator sees the published release URL' \
  grep -Fq 'releases/tag/v9.4.7' "$finish_output"

stop_line="$(log_line_number '^runner-stop$')"
reset_line="$(log_line_number '^reset$')"
expect 'runner stops before the workspace reset' \
  test -n "$stop_line" -a -n "$reset_line" -a "$stop_line" -lt "$reset_line"

# --- Failed run: still stop and archive, then point at rollback -------------
run_finish SHIM_FINAL_RUN_JSON="$run_failure" -- --run 770002
expect_status 'failed run exits nonzero' 1
expect 'failed run still stops the runner' \
  grep -Fq 'runner-stop' "$shim_log"
expect 'failed run still archives evidence' \
  grep -Fxq 'reset' "$shim_log"
expect 'failed run points at rollback guidance' \
  grep -Fiq 'rollback' "$finish_output"
expect 'failed run skips public verification' \
  bash -c "! grep -Fq 'gh release view' '$shim_log'"

# --- Timeout: leave the run, the runner, and the workspace untouched --------
run_finish SHIM_PENDING_POLLS=99 -- --run 770002
expect_status 'never-completing run times out' 1
expect 'timeout is named' \
  grep -Fiq 'timed out' "$finish_output"
expect 'timeout does not stop the runner' \
  bash -c "! grep -Fq 'runner-stop' '$shim_log'"
expect 'timeout does not reset the workspace' \
  bash -c "! grep -Fxq 'reset' '$shim_log'"

# --- Rehearsal: stop and archive, no public verification --------------------
run_finish -- --rehearsal --run 770002
expect_status 'successful rehearsal finishes cleanly' 0
expect 'rehearsal archives evidence' \
  grep -Fxq 'reset' "$shim_log"
expect 'rehearsal skips release verification' \
  bash -c "! grep -Fq 'gh release view' '$shim_log'"
expect 'rehearsal skips appcast verification' \
  bash -c "! grep -Fq 'curl' '$shim_log'"

# --- Stale appcast: public verification must read real content --------------
run_finish SHIM_APPCAST="$appcast_stale" -- --run 770002
expect_status 'stale public appcast fails verification' 1
expect 'stale appcast is named' \
  grep -Fiq 'appcast' "$finish_output"
expect 'stale appcast still archived evidence first' \
  grep -Fxq 'reset' "$shim_log"

if (( failures > 0 )); then
  printf '%s\n' 'Release finish tests failed.' >&2
  exit 1
fi
printf '%s\n' 'Release finish tests passed.'
