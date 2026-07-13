#!/usr/bin/env bash
set -euo pipefail

# RED contract for the signed app executable itself. Before GREEN, the Release
# app ignores the sentinel and enters its ordinary UI event loop, so these
# bounded fail-fast probes time out instead of returning the required status.

usage() {
  printf 'Usage: %s --app APP\n' "$0" >&2
  exit 2
}

app=''
while (( $# > 0 )); do
  case "$1" in
    --app) app="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -d "$app" ]] || usage
executable="${app}/Contents/MacOS/SupraAI"
[[ -f "$executable" && -x "$executable" ]] || usage

temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT
model_directory="${temporary_dir}/Models/release-smoke"
mkdir -p "$model_directory"
failures=0
probe_number=0

source_sha='1111111111111111111111111111111111111111'
app_sha='2222222222222222222222222222222222222222222222222222222222222222'
model_sha='4444444444444444444444444444444444444444444444444444444444444444'
nonce='3333333333333333333333333333333333333333333333333333333333333333'
sentinel='--supra-signed-release-smoke-v1'

record_failure() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

run_probe() {
  local name="$1"
  local expected_status="$2"
  local descriptor_state="$3"
  shift 3

  probe_number=$((probe_number + 1))
  local prefix="${temporary_dir}/probe-${probe_number}"
  local report="${prefix}.json"
  local stdout_file="${prefix}.stdout"
  local stderr_file="${prefix}.stderr"
  local timeout_marker="${prefix}.timeout"
  local pid watchdog status

  if [[ "$descriptor_state" == 'open' ]]; then
    "$@" 3>"$report" >"$stdout_file" 2>"$stderr_file" &
  elif [[ "$descriptor_state" == 'closed' ]]; then
    "$@" 3>&- >"$stdout_file" 2>"$stderr_file" &
  else
    record_failure "${name}: invalid test descriptor state"
    return
  fi
  pid=$!

  (
    sleep 4
    if kill -0 "$pid" 2>/dev/null; then
      : >"$timeout_marker"
      kill -TERM "$pid" 2>/dev/null || :
      sleep 1
      kill -KILL "$pid" 2>/dev/null || :
    fi
  ) &
  watchdog=$!

  set +e
  wait "$pid"
  status=$?
  set -e
  kill "$watchdog" 2>/dev/null || :
  wait "$watchdog" 2>/dev/null || :

  if [[ -f "$timeout_marker" ]]; then
    record_failure "${name}: Release entrypoint timed out instead of failing closed"
  elif [[ "$status" -ne "$expected_status" ]]; then
    record_failure "${name}: expected status ${expected_status}, got ${status}"
  elif [[ -s "$report" ]]; then
    record_failure "${name}: a rejected invocation wrote a document to FD 3"
  elif [[ -s "$stdout_file" || -s "$stderr_file" ]]; then
    record_failure "${name}: a rejected invocation wrote outside FD 3"
  else
    printf 'PASS: %s\n' "$name"
  fi
}

# Expected RED: the current Release executable has no strict smoke sentinel
# parser, so these malformed invocations launch the normal app instead of 64.
run_probe 'prompt argument is rejected' 64 open \
  "$executable" "$sentinel" --prompt 'PRIVATE-PROMPT-CANARY'
run_probe 'model path argument is rejected' 64 open \
  "$executable" "$sentinel" --model-path '/tmp/forbidden-model-path'
run_probe 'output path argument is rejected' 64 open \
  "$executable" "$sentinel" --output '/tmp/forbidden-output-path'

# Expected RED: the exact sentinel currently enters the ordinary app rather
# than validating its fixed binding environment before any model work.
run_probe 'missing binding environment fails closed' 78 open \
  "$executable" "$sentinel"

# Expected RED: a valid binding with no inherited report descriptor must stop
# at the FD contract and must never fall through to the UI or model loader.
run_probe 'closed FD 3 fails before model work' 74 closed \
  env \
    SUPRA_RELEASE_SMOKE_SOURCE_SHA="$source_sha" \
    SUPRA_RELEASE_SMOKE_APP_TREE_SHA256="$app_sha" \
    SUPRA_RELEASE_SMOKE_MODEL_SHA256="$model_sha" \
    SUPRA_RELEASE_SMOKE_NONCE="$nonce" \
    SUPRA_RELEASE_SMOKE_MODEL_DIRECTORY="$model_directory" \
    "$executable" "$sentinel"

if (( failures != 0 )); then
  printf 'Signed Release smoke entrypoint contract failed: %d\n' "$failures" >&2
  exit 1
fi
printf '%s\n' 'Signed Release smoke entrypoint contract passed.'
