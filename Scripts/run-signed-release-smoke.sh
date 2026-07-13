#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Scripts/lib/release-common.sh
source "${root}/Scripts/lib/release-common.sh"

usage() {
  printf '%s\n' \
    "Usage: $0 --app APP --source-sha SHA --app-sha SHA256 --model-sha SHA256 --version X.Y.Z --build N --nonce SHA256 --output FILE" >&2
  exit 2
}

app=''
source_sha=''
app_sha=''
model_sha=''
version=''
build_number=''
nonce=''
output=''
while (( $# > 0 )); do
  case "$1" in
    --app) app="${2:-}"; shift 2 ;;
    --source-sha) source_sha="${2:-}"; shift 2 ;;
    --app-sha) app_sha="${2:-}"; shift 2 ;;
    --model-sha) model_sha="${2:-}"; shift 2 ;;
    --version) version="${2:-}"; shift 2 ;;
    --build) build_number="${2:-}"; shift 2 ;;
    --nonce) nonce="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -d "$app" && ! -L "$app" && -n "$output" ]] || usage
release_validate_sha "$source_sha"
release_validate_digest "$app_sha"
release_validate_digest "$model_sha"
release_validate_version "$version"
release_validate_build "$build_number"
release_validate_digest "$nonce"
release_require_protected_environment
release_require_command codesign
release_require_command jq
release_require_command pgrep

model_directory="${SUPRA_RELEASE_SMOKE_MODEL_DIRECTORY:-}"
[[ -n "$model_directory" && "$model_directory" == /* \
  && -d "$model_directory" && ! -L "$model_directory" ]] \
  || release_die 'protected signed-app smoke model directory is unavailable'

executable="${app}/Contents/MacOS/SupraAI"
[[ -f "$executable" && -x "$executable" && ! -L "$executable" ]] \
  || release_die 'signed-app smoke executable is unavailable'
codesign --verify --deep --strict "$app" >/dev/null 2>&1 \
  || release_die 'signed-app smoke target has an invalid signature'

timeout_seconds=600
if [[ "${SUPRA_RELEASE_TESTING:-0}" == '1' \
  && -n "${SUPRA_SIGNED_SMOKE_TIMEOUT_SECONDS:-}" ]]; then
  [[ "$SUPRA_SIGNED_SMOKE_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] \
    || release_die 'invalid signed-app smoke timeout override'
  timeout_seconds="$SUPRA_SIGNED_SMOKE_TIMEOUT_SECONDS"
fi

output_directory="$(dirname "$output")"
mkdir -p "$output_directory"
[[ ! -e "$output" ]] \
  || release_die 'signed-app smoke output already exists'

umask 077
workspace="$(mktemp -d "${output_directory}/.supra-signed-smoke.XXXXXX")"
attestation="${workspace}/attestation.json"
standard_output="${workspace}/stdout"
standard_error="${workspace}/stderr"
timeout_marker="${workspace}/timed-out"
host_pid=''
watchdog_pid=''

cleanup() {
  if [[ -n "$watchdog_pid" ]] && kill -0 "$watchdog_pid" 2>/dev/null; then
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
  fi
  if [[ -n "$host_pid" ]] && kill -0 "$host_pid" 2>/dev/null; then
    kill "$host_pid" 2>/dev/null || true
    wait "$host_pid" 2>/dev/null || true
  fi
  rm -rf "$workspace"
}
trap cleanup EXIT

signal_process_tree() {
  local pid="$1"
  local signal="$2"
  local child
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do
    signal_process_tree "$child" "$signal"
  done
  kill "-${signal}" "$pid" 2>/dev/null || true
}

# The signed app gets exactly the five reviewed bindings. The sentinel is the
# only argument, and the attestation channel is the inherited descriptor 3.
(
  # Bound every file the child can write. Seventeen KiB preserves enough of an
  # oversized FD-3 document to classify it while preventing unbounded capture.
  ulimit -S -f 17
  exec env -i \
    "SUPRA_RELEASE_SMOKE_SOURCE_SHA=${source_sha}" \
    "SUPRA_RELEASE_SMOKE_APP_TREE_SHA256=${app_sha}" \
    "SUPRA_RELEASE_SMOKE_MODEL_SHA256=${model_sha}" \
    "SUPRA_RELEASE_SMOKE_NONCE=${nonce}" \
    "SUPRA_RELEASE_SMOKE_MODEL_DIRECTORY=${model_directory}" \
    "$executable" --supra-signed-release-smoke-v1
) </dev/null 3>"$attestation" >"$standard_output" 2>"$standard_error" &
host_pid=$!

(
  sleep "$timeout_seconds"
  if kill -0 "$host_pid" 2>/dev/null; then
    : >"$timeout_marker"
    signal_process_tree "$host_pid" TERM
    sleep 2
    signal_process_tree "$host_pid" KILL
  fi
) &
watchdog_pid=$!

host_status=0
wait "$host_pid" || host_status=$?
host_pid=''
if kill -0 "$watchdog_pid" 2>/dev/null; then
  kill "$watchdog_pid" 2>/dev/null || true
fi
wait "$watchdog_pid" 2>/dev/null || true
watchdog_pid=''

[[ ! -e "$timeout_marker" ]] \
  || release_die 'signed-app smoke host timed out'
[[ ! -s "$standard_output" && ! -s "$standard_error" ]] \
  || release_die 'signed-app smoke host wrote outside inherited FD 3'
(( $(release_file_size "$attestation") <= 16384 )) \
  || release_die 'signed-app smoke attestation exceeds 16384 bytes'
[[ "$host_status" -eq 0 ]] \
  || release_die "signed-app smoke host failed (status ${host_status})"
[[ -s "$attestation" ]] \
  || release_die 'signed-app smoke host did not emit an attestation'
jq -e -s 'length == 1' "$attestation" >/dev/null 2>&1 \
  || release_die 'signed-app smoke must contain exactly one JSON document'

bash "${root}/Scripts/verify-signed-runtime-smoke-result.sh" \
  --result "$attestation" \
  --source-sha "$source_sha" \
  --app-sha "$app_sha" \
  --model-sha "$model_sha" \
  --version "$version" \
  --build "$build_number" \
  --nonce "$nonce"

# The capture directory is on the destination filesystem, so this rename is
# atomic and occurs only after every verification above has passed.
mv "$attestation" "$output"
printf 'Repository-owned signed-app smoke passed for %s.\n' "$source_sha"
