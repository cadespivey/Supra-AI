#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Scripts/lib/release-common.sh
source "${root}/Scripts/lib/release-common.sh"

usage() {
  printf 'Usage: %s --result FILE --source-sha SHA --app-sha SHA256 --model-sha SHA256\n' "$0" >&2
  exit 2
}

result=''; source_sha=''; app_sha=''; model_sha=''
while (( $# > 0 )); do
  case "$1" in
    --result) result="${2:-}"; shift 2 ;;
    --source-sha) source_sha="${2:-}"; shift 2 ;;
    --app-sha) app_sha="${2:-}"; shift 2 ;;
    --model-sha) model_sha="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -f "$result" ]] || usage
release_validate_sha "$source_sha"
release_validate_digest "$app_sha"
release_validate_digest "$model_sha"
release_require_command jq

jq -e --arg source "$source_sha" --arg app "$app_sha" --arg model "$model_sha" '
  .schemaVersion == 1 and
  .status == "passed" and
  .sourceSha == $source and
  .appTreeSHA256 == $app and
  .modelSHA256 == $model and
  .xpcBundleIdentifier == "ai.supra.SupraAI.SupraRuntimeService" and
  (.generatedTokens | type == "number" and . > 0)
' "$result" >/dev/null || release_die 'signed runtime smoke attestation does not match release source/app/model'

printf 'Signed runtime smoke attestation verified for %s.\n' "$source_sha"
