#!/usr/bin/env bash
set -euo pipefail

# RED contract for replacing SUPRA_SIGNED_SMOKE_DRIVER with a repository-owned,
# bounded launcher of the exact signed app executable. The synthetic app records
# argv/environment inside its fixture bundle and emits controlled documents on
# inherited FD 3.

repo_root="$(git rev-parse --show-toplevel)"
driver="${repo_root}/Scripts/run-signed-release-smoke.sh"
fixture_host="${repo_root}/Tests/Scripts/Fixtures/Release/signed-smoke-host.sh"
fixture_command="${repo_root}/Tests/Scripts/Fixtures/Release/mock-command.sh"
temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT

app="${temporary_dir}/SupraAI.app"
contents="${app}/Contents"
executable="${contents}/MacOS/SupraAI"
model_directory="${temporary_dir}/Models/release-smoke"
mock_bin="${temporary_dir}/bin"
mkdir -p "$(dirname "$executable")" "$model_directory" "$mock_bin"
cp "$fixture_host" "$executable"
chmod +x "$executable"
ln -s "$fixture_command" "${mock_bin}/codesign"

source_sha='1111111111111111111111111111111111111111'
app_sha='2222222222222222222222222222222222222222222222222222222222222222'
model_sha='4444444444444444444444444444444444444444444444444444444444444444'
version='2.2.1'
build='387'
unrelated_secret='PRIVATE-RELEASE-ENVIRONMENT-CANARY'
failures=0
case_number=0
timeout_override=''

unset SUPRA_SIGNED_SMOKE_DRIVER

record_failure() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

invoke_driver() {
  local nonce="$1"
  local output="$2"
  local command_output="$3"
  local command_status=0
  local -a environment=(
    env
    "PATH=${mock_bin}:$PATH"
    'SUPRA_RELEASE_TESTING=1'
    'SUPRA_PROTECTED_RELEASE_ENVIRONMENT=1'
    "SUPRA_RELEASE_SMOKE_MODEL_DIRECTORY=${model_directory}"
    "UNRELATED_RELEASE_SECRET=${unrelated_secret}"
    "MOCK_RELEASE_LOG=${temporary_dir}/mock-release.log"
  )
  if [[ -n "$timeout_override" ]]; then
    environment+=("SUPRA_SIGNED_SMOKE_TIMEOUT_SECONDS=${timeout_override}")
  fi

  "${environment[@]}" bash "$driver" \
    --app "$app" \
    --source-sha "$source_sha" \
    --app-sha "$app_sha" \
    --model-sha "$model_sha" \
    --version "$version" \
    --build "$build" \
    --nonce "$nonce" \
    --output "$output" \
    >"$command_output" 2>&1 || command_status=$?
  return "$command_status"
}

strict_result_matches() {
  local result="$1"
  local expected_nonce="$2"
  jq -e \
    --arg source "$source_sha" \
    --arg app "$app_sha" \
    --arg model "$model_sha" \
    --arg nonce "$expected_nonce" \
    --arg version "$version" \
    --arg build "$build" '
      (keys | sort) == ([
        "schemaVersion", "status", "nonce", "sourceSha", "appTreeSHA256",
        "modelSHA256", "appBundleIdentifier", "xpcBundleIdentifier",
        "appVersion", "appBuild", "modelRepositoryID", "modelRevision",
        "verification", "eventCounts", "generatedTokenCount", "timings"
      ] | sort) and
      .schemaVersion == 1 and .status == "passed" and
      .sourceSha == $source and .appTreeSHA256 == $app and
      .modelSHA256 == $model and .nonce == $nonce and
      .appBundleIdentifier == "ai.supra.SupraAI" and
      .xpcBundleIdentifier == "ai.supra.SupraAI.SupraRuntimeService" and
      .appVersion == $version and .appBuild == $build and
      (.modelRepositoryID | type == "string" and length > 0) and
      (.modelRevision | test("^[0-9a-f]{40}$")) and
      (.verification | keys | sort) == ([
        "xpcConnected", "modelLoaded", "generationStarted",
        "generationCompleted", "modelUnloaded", "modelReverified"
      ] | sort) and
      (.verification | all(.[]; . == true)) and
      (.eventCounts | keys | sort) == ([
        "total", "generationStarted", "token", "metrics",
        "generationCompleted", "generationFailed", "generationCancelled",
        "reserved"
      ] | sort) and
      .eventCounts.generationStarted == 1 and
      .eventCounts.token > 0 and
      .eventCounts.metrics == 1 and
      .eventCounts.generationCompleted == 1 and
      .eventCounts.generationFailed == 0 and
      .eventCounts.generationCancelled == 0 and
      .eventCounts.reserved == 0 and
      .eventCounts.total == (
        .eventCounts.generationStarted + .eventCounts.token +
        .eventCounts.metrics + .eventCounts.generationCompleted +
        .eventCounts.generationFailed + .eventCounts.generationCancelled +
        .eventCounts.reserved
      ) and
      (.generatedTokenCount | type == "number" and . > 0) and
      (.timings | keys | sort) == ([
        "loadTimeMs", "firstTokenLatencyMs", "tokensPerSecond"
      ] | sort) and
      (.timings.loadTimeMs | type == "number" and . >= 0) and
      (.timings.firstTokenLatencyMs | type == "number" and . >= 0) and
      (.timings.tokensPerSecond | type == "number" and . > 0)
    ' "$result" >/dev/null
}

run_success_case() {
  local name="$1"
  local nonce="$2"
  case_number=$((case_number + 1))
  local output="${temporary_dir}/case-${case_number}.json"
  local command_output="${temporary_dir}/case-${case_number}.log"
  local status=0

  invoke_driver "$nonce" "$output" "$command_output" || status=$?
  if [[ "$status" -ne 0 ]]; then
    record_failure "${name}: expected status 0, got ${status}"
  elif [[ ! -f "$output" ]]; then
    record_failure "${name}: validated attestation was not published"
  elif (( $(wc -c <"$output") > 16384 )); then
    record_failure "${name}: attestation exceeded 16384 bytes"
  elif ! jq -e -s 'length == 1' "$output" >/dev/null 2>&1; then
    record_failure "${name}: output was not exactly one JSON document"
  elif ! strict_result_matches "$output" "$nonce"; then
    record_failure "${name}: output did not satisfy the exact content-free schema"
  else
    printf 'PASS: %s\n' "$name"
  fi
}

run_failure_case() {
  local name="$1"
  local nonce="$2"
  local expected_text="$3"
  case_number=$((case_number + 1))
  local output="${temporary_dir}/case-${case_number}.json"
  local command_output="${temporary_dir}/case-${case_number}.log"
  local status=0

  invoke_driver "$nonce" "$output" "$command_output" || status=$?
  if [[ "$status" -eq 0 ]]; then
    record_failure "${name}: malformed or failed host result was accepted"
  elif ! grep -Fq -- "$expected_text" "$command_output"; then
    record_failure "${name}: expected failure text: ${expected_text}"
  elif [[ -e "$output" ]]; then
    record_failure "${name}: failure published an output artifact"
  else
    printf 'PASS: %s\n' "$name"
  fi
}

# Expected RED: the current script requires SUPRA_SIGNED_SMOKE_DRIVER and never
# launches the app executable with the FD 3 protocol.
happy_nonce='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
run_success_case 'repository-owned driver accepts one strict FD 3 document' "$happy_nonce"

argv_log="${contents}/fixture-argv.txt"
environment_log="${contents}/fixture-environment.txt"
if [[ ! -f "$argv_log" ]] || [[ "$(wc -l <"$argv_log")" -ne 1 ]] \
    || ! grep -Fxq -- '--supra-signed-release-smoke-v1' "$argv_log"; then
  record_failure 'driver did not pass exactly the fixed smoke sentinel'
elif grep -Eq -- '--(prompt|model-path|output)' "$argv_log"; then
  record_failure 'driver passed a prohibited prompt/path/output argument'
else
  printf '%s\n' 'PASS: app argv contains only the fixed smoke sentinel'
fi

if [[ ! -f "$environment_log" ]]; then
  record_failure 'synthetic app did not record its launch environment'
elif grep -Fq -- "$unrelated_secret" "$environment_log" \
    || grep -Fq 'UNRELATED_RELEASE_SECRET=' "$environment_log"; then
  record_failure 'driver leaked an unrelated release environment value to the app'
elif grep -Eq 'SUPRA_.*(PROMPT|OUTPUT)=' "$environment_log"; then
  record_failure 'driver exposed a prohibited prompt/output environment value'
elif ! grep -Fxq "SUPRA_RELEASE_SMOKE_MODEL_DIRECTORY=${model_directory}" "$environment_log"; then
  record_failure 'driver omitted the protected model directory environment binding'
else
  printf '%s\n' 'PASS: app receives only the reviewed smoke bindings from a sanitized environment'
fi

# Expected RED: the current verifier is permissive/flat and has no one-document,
# 16 KiB, nonce, nested-key, or out-of-band-output enforcement.
run_failure_case \
  'oversized attestation is rejected' \
  'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  'signed-app smoke attestation exceeds 16384 bytes'
run_failure_case \
  'multiple JSON documents are rejected' \
  'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' \
  'signed-app smoke must contain exactly one JSON document'
run_failure_case \
  'unknown top-level field is rejected' \
  'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd' \
  'signed runtime smoke attestation has an invalid schema'
run_failure_case \
  'generated output text field is rejected' \
  'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' \
  'signed runtime smoke attestation has an invalid schema'
run_failure_case \
  'stdout outside FD 3 is rejected' \
  'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff' \
  'signed-app smoke host wrote outside inherited FD 3'
run_failure_case \
  'nonzero host exit is rejected' \
  '0000000000000000000000000000000000000000000000000000000000000000' \
  'signed-app smoke host failed'
run_failure_case \
  'empty successful host result is rejected' \
  '9999999999999999999999999999999999999999999999999999999999999999' \
  'signed-app smoke host did not emit an attestation'

timeout_override='1'
run_failure_case \
  'host is terminated at the bounded deadline' \
  '8888888888888888888888888888888888888888888888888888888888888888' \
  'signed-app smoke host timed out'
timeout_override=''

if (( failures != 0 )); then
  printf 'Signed release smoke driver contract failed: %d\n' "$failures" >&2
  exit 1
fi
printf '%s\n' 'Signed release smoke driver contract passed.'
