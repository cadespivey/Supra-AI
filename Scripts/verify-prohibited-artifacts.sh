#!/usr/bin/env bash
set -euo pipefail

repo_root="${1:-${SUPRA_REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}}"
if (( $# > 1 )) || [[ ! -d "$repo_root" ]]; then
  printf 'Usage: %s [scan-root]\n' "$0" >&2
  exit 2
fi
repo_root="$(cd "$repo_root" && pwd -P)"
status=0

while IFS= read -r -d '' path; do
  relative="${path#${repo_root}/}"
  lower="$(printf '%s' "$relative" | tr '[:upper:]' '[:lower:]')"
  prohibited=0
  case "$relative" in
    Backup-Feature-Plan.md|*/Backup-Feature-Plan.md|ClientData/*|*/ClientData/*|PrivateData/*|*/PrivateData/*)
      prohibited=1
      ;;
  esac
  case "$lower" in
    website/public/fonts/*|*/website/public/fonts/*|*.dmg|*.pkg|*.xcarchive|*.app|*.xpc|*.p8|*.p12|*.pem|*.mobileprovision|*.safetensors|*.gguf|*.onnx|*.mlmodel|*.mlmodelc|*.sqlite|*.sqlite3|*.db|.env|*/.env)
      prohibited=1
      ;;
  esac
  if (( prohibited != 0 )); then
    printf 'ERROR: prohibited artifact path: %s\n' "$relative" >&2
    status=1
  fi
done < <(
  find "$repo_root" \
    \( -path '*/.git' -o -path '*/.build' -o -path '*/DerivedData' -o -path '*/node_modules' -o -path '*/.next' -o -path '*/out' \) -prune \
    -o \( -type f -o -type l -o -type d \) -print0
)

if (( status != 0 )); then
  printf '%s\n' 'Prohibited artifact scan failed.' >&2
  exit 1
fi
printf '%s\n' 'Prohibited artifact scan passed.'
