#!/usr/bin/env bash
set -euo pipefail

repo_root="${SUPRA_REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
inventory="${repo_root}/Scripts/list-local-packages.sh"
bash "$inventory" --verify

requested="${1:-}"
if (( $# > 1 )); then
  printf 'Usage: %s [package-name]\n' "$0" >&2
  exit 2
fi

status=0
while IFS= read -r package; do
  [[ -z "$package" ]] && continue
  if [[ -n "$requested" && "$requested" != "$package" ]]; then
    continue
  fi
  printf 'Testing Packages/%s\n' "$package"
  if ! swift test --package-path "${repo_root}/Packages/${package}" --parallel; then
    printf 'ERROR: package tests failed: %s\n' "$package" >&2
    status=1
    break
  fi
done < <(bash "$inventory")

if [[ -n "$requested" ]] && ! bash "$inventory" | grep -Fxq -- "$requested"; then
  printf 'ERROR: requested package is not in the fixed inventory: %s\n' "$requested" >&2
  exit 2
fi
exit "$status"
