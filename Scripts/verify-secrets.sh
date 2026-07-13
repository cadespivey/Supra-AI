#!/usr/bin/env bash
set -euo pipefail

scan_root="${1:-${SUPRA_REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}}"
if (( $# > 1 )) || [[ ! -d "$scan_root" ]]; then
  printf 'Usage: %s [scan-root]\n' "$0" >&2
  exit 2
fi
scan_root="$(cd "$scan_root" && pwd -P)"
status=0
secret_pattern='(-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----|A(KIA|SIA)[A-Z0-9]{16}|gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-(proj-|live-)?[A-Za-z0-9_-]{20,}|hf_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{20,})'

while IFS= read -r -d '' path; do
  relative="${path#${scan_root}/}"
  [[ "$relative" == "Scripts/verify-secrets.sh" ]] && continue
  if grep -Iq . "$path" 2>/dev/null && LC_ALL=C grep -Eq "$secret_pattern" "$path"; then
    printf 'ERROR: possible secret in: %s\n' "$relative" >&2
    status=1
  fi
done < <(
  find "$scan_root" \
    \( -path '*/.git' -o -path '*/.build' -o -path '*/DerivedData' -o -path '*/node_modules' -o -path '*/.next' -o -path '*/out' \) -prune \
    -o -type f -size -5M -print0
)

if (( status != 0 )); then
  printf '%s\n' 'Secret scan failed. Findings report paths only; values are intentionally suppressed.' >&2
  exit 1
fi
printf '%s\n' 'Secret scan passed.'
