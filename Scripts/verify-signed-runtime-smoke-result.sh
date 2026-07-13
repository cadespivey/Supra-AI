#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Scripts/lib/release-common.sh
source "${root}/Scripts/lib/release-common.sh"

usage() {
  printf '%s\n' \
    "Usage: $0 --result FILE --source-sha SHA --app-sha SHA256 --model-sha SHA256 --version X.Y.Z --build N --nonce SHA256" >&2
  exit 2
}

result=''
source_sha=''
app_sha=''
model_sha=''
version=''
build_number=''
nonce=''
while (( $# > 0 )); do
  case "$1" in
    --result) result="${2:-}"; shift 2 ;;
    --source-sha) source_sha="${2:-}"; shift 2 ;;
    --app-sha) app_sha="${2:-}"; shift 2 ;;
    --model-sha) model_sha="${2:-}"; shift 2 ;;
    --version) version="${2:-}"; shift 2 ;;
    --build) build_number="${2:-}"; shift 2 ;;
    --nonce) nonce="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -f "$result" && ! -L "$result" ]] || usage
release_validate_sha "$source_sha"
release_validate_digest "$app_sha"
release_validate_digest "$model_sha"
release_validate_version "$version"
release_validate_build "$build_number"
release_validate_digest "$nonce"
release_require_command jq

(( $(release_file_size "$result") <= 16384 )) \
  || release_die 'signed-app smoke attestation exceeds 16384 bytes'
jq -e -s 'length == 1' "$result" >/dev/null 2>&1 \
  || release_die 'signed-app smoke must contain exactly one JSON document'

# Keep this dependency-free validator aligned with the repository's strict
# Draft 2020-12 schema. Exact key sets enforce additionalProperties: false at
# every level, including the content-bearing fields this attestation forbids.
jq -e '
  def exact_keys($expected):
    type == "object" and ((keys | sort) == ($expected | sort));
  def git_sha:
    type == "string" and test("^[0-9a-f]{40}$");
  def sha256:
    type == "string" and test("^[0-9a-f]{64}$");
  def semantic_version:
    type == "string" and
    test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)([-+][0-9A-Za-z.-]+)?$");
  def positive_build:
    type == "string" and test("^[1-9][0-9]*$");
  def nonnegative_integer:
    type == "number" and floor == . and . >= 0;
  def positive_number:
    type == "number" and . > 0;

  exact_keys([
    "schemaVersion", "status", "nonce", "sourceSha", "appTreeSHA256",
    "modelSHA256", "appBundleIdentifier", "xpcBundleIdentifier",
    "appVersion", "appBuild", "modelRepositoryID", "modelRevision",
    "verification", "eventCounts", "generatedTokenCount", "timings"
  ]) and
  .schemaVersion == 1 and
  .status == "passed" and
  (.nonce | sha256) and
  (.sourceSha | git_sha) and
  (.appTreeSHA256 | sha256) and
  (.modelSHA256 | sha256) and
  .appBundleIdentifier == "ai.supra.SupraAI" and
  .xpcBundleIdentifier == "ai.supra.SupraAI.SupraRuntimeService" and
  (.appVersion | semantic_version) and
  (.appBuild | positive_build) and
  (.modelRepositoryID | type == "string" and
    test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")) and
  (.modelRevision | git_sha) and
  (.verification | exact_keys([
    "xpcConnected", "modelLoaded", "generationStarted",
    "generationCompleted", "modelUnloaded", "modelReverified"
  ])) and
  (.verification | all(.[]; . == true)) and
  (.eventCounts | exact_keys([
    "total", "generationStarted", "token", "metrics",
    "generationCompleted", "generationFailed", "generationCancelled",
    "reserved"
  ])) and
  (.eventCounts | all(.[]; type == "number" and floor == . and . >= 0)) and
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
  (.generatedTokenCount | type == "number" and floor == . and . > 0) and
  (.timings | exact_keys([
    "loadTimeMs", "firstTokenLatencyMs", "tokensPerSecond"
  ])) and
  (.timings.loadTimeMs | nonnegative_integer) and
  (.timings.firstTokenLatencyMs | nonnegative_integer) and
  (.timings.tokensPerSecond | positive_number)
' "$result" >/dev/null \
  || release_die 'signed runtime smoke attestation has an invalid schema'

jq -e \
  --arg source "$source_sha" \
  --arg app "$app_sha" \
  --arg model "$model_sha" \
  --arg version "$version" \
  --arg build "$build_number" \
  --arg nonce "$nonce" '
    .sourceSha == $source and
    .appTreeSHA256 == $app and
    .modelSHA256 == $model and
    .appVersion == $version and
    .appBuild == $build and
    .nonce == $nonce
  ' "$result" >/dev/null \
  || release_die 'signed runtime smoke attestation does not match release source/app/model/version/build/nonce'

printf 'Signed runtime smoke attestation verified for %s.\n' "$source_sha"
