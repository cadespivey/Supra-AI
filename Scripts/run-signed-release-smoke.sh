#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Scripts/lib/release-common.sh
source "${root}/Scripts/lib/release-common.sh"

usage() {
  printf 'Usage: %s --app APP --source-sha SHA --app-sha SHA256 --model-sha SHA256 --output FILE\n' "$0" >&2
  exit 2
}

app=''; source_sha=''; app_sha=''; model_sha=''; output=''
while (( $# > 0 )); do
  case "$1" in
    --app) app="${2:-}"; shift 2 ;;
    --source-sha) source_sha="${2:-}"; shift 2 ;;
    --app-sha) app_sha="${2:-}"; shift 2 ;;
    --model-sha) model_sha="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -d "$app" && -n "$output" ]] || usage
release_validate_sha "$source_sha"
release_validate_digest "$app_sha"
release_validate_digest "$model_sha"
release_require_protected_environment

driver="${SUPRA_SIGNED_SMOKE_DRIVER:-}"
[[ -n "$driver" && -x "$driver" && "$driver" != "$0" ]] \
  || release_die 'protected signed-app model/XPC smoke driver is unavailable'
codesign --verify --deep --strict "$app" >/dev/null 2>&1 \
  || release_die 'signed-app smoke target has an invalid signature'

mkdir -p "$(dirname "$output")"
"$driver" --app "$app" --source-sha "$source_sha" --app-sha "$app_sha" \
  --model-sha "$model_sha" --output "$output"
[[ -f "$output" ]] || release_die 'signed-app smoke driver did not produce an attestation'

bash "${root}/Scripts/verify-signed-runtime-smoke-result.sh" \
  --result "$output" --source-sha "$source_sha" --app-sha "$app_sha" --model-sha "$model_sha"
