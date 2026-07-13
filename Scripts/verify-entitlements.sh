#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
app="${repo_root}/Apps/SupraAI/SupraAI/SupraAI.entitlements"
service="${repo_root}/Apps/SupraAI/SupraRuntimeService/SupraRuntimeService.entitlements"

while (( $# > 0 )); do
  case "$1" in
    --app)
      app="${2:-}"
      shift 2
      ;;
    --service)
      service="${2:-}"
      shift 2
      ;;
    *)
      printf 'Usage: %s [--app path] [--service path]\n' "$0" >&2
      exit 2
      ;;
  esac
done

command -v plutil >/dev/null 2>&1 || { printf 'ERROR: plutil is required\n' >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'ERROR: jq is required\n' >&2; exit 2; }
[[ -f "$app" && -f "$service" ]] || { printf 'ERROR: entitlement file is missing\n' >&2; exit 1; }

app_json="$(plutil -convert json -o - -- "$app")"
service_json="$(plutil -convert json -o - -- "$service")"
status=0

check_app_boolean() {
  local key="$1"
  if ! jq -e --arg key "$key" '.[$key] == true' >/dev/null <<<"$app_json"; then
    printf 'ERROR: app entitlement drift: %s\n' "$key" >&2
    status=1
  fi
}

check_app_boolean 'com.apple.security.app-sandbox'
check_app_boolean 'com.apple.security.files.bookmarks.app-scope'
check_app_boolean 'com.apple.security.files.user-selected.read-write'
check_app_boolean 'com.apple.security.network.client'

if ! jq -e '
  .["com.apple.security.temporary-exception.mach-lookup.global-name"] ==
    ["$(PRODUCT_BUNDLE_IDENTIFIER)-spks", "$(PRODUCT_BUNDLE_IDENTIFIER)-spki"]
' >/dev/null <<<"$app_json"; then
  printf '%s\n' 'ERROR: app entitlement drift: com.apple.security.temporary-exception.mach-lookup.global-name' >&2
  status=1
fi

if ! jq -e 'keys | sort == [
  "com.apple.security.app-sandbox",
  "com.apple.security.files.bookmarks.app-scope",
  "com.apple.security.files.user-selected.read-write",
  "com.apple.security.network.client",
  "com.apple.security.temporary-exception.mach-lookup.global-name"
]' >/dev/null <<<"$app_json"; then
  printf '%s\n' 'ERROR: app entitlement drift: unexpected or missing key' >&2
  status=1
fi

if ! jq -e '. == {"com.apple.security.app-sandbox": true}' >/dev/null <<<"$service_json"; then
  printf '%s\n' 'ERROR: runtime-service entitlement drift' >&2
  status=1
fi

if (( status != 0 )); then
  printf '%s\n' 'Entitlement expectations failed.' >&2
  exit 1
fi
printf '%s\n' 'Entitlement expectations passed.'
