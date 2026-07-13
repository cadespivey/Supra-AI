#!/usr/bin/env bash
set -euo pipefail

repo_root="${SUPRA_REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

list_expected() {
  cat <<'PACKAGES'
SupraCore
SupraDesignSystem
SupraDiagnostics
SupraDocuments
SupraDrafting
SupraDraftingCore
SupraExports
SupraNetworking
SupraResearch
SupraRuntimeClient
SupraRuntimeInterface
SupraSessions
SupraStore
SupraTestKit
PACKAGES
}

if [[ "${1:-}" != "--verify" ]]; then
  if (( $# != 0 )); then
    printf 'Usage: %s [--verify]\n' "$0" >&2
    exit 2
  fi
  list_expected
  exit 0
fi
if (( $# != 1 )); then
  printf 'Usage: %s [--verify]\n' "$0" >&2
  exit 2
fi

temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT
expected="${temporary_dir}/expected.txt"
actual="${temporary_dir}/actual.txt"
list_expected | LC_ALL=C sort >"$expected"

if [[ ! -d "${repo_root}/Packages" ]]; then
  printf 'ERROR: package directory not found: Packages\n' >&2
  exit 1
fi

find "${repo_root}/Packages" -mindepth 2 -maxdepth 2 -name Package.swift -type f -print0 \
  | while IFS= read -r -d '' manifest; do
      basename "$(dirname "$manifest")"
    done \
  | LC_ALL=C sort -u >"$actual"

status=0
while IFS= read -r package; do
  [[ -z "$package" ]] && continue
  printf 'ERROR: missing local package: %s\n' "$package" >&2
  status=1
done < <(comm -23 "$expected" "$actual")
while IFS= read -r package; do
  [[ -z "$package" ]] && continue
  printf 'ERROR: unlisted local package: %s\n' "$package" >&2
  status=1
done < <(comm -13 "$expected" "$actual")

if (( status != 0 )); then
  printf '%s\n' 'Local package inventory failed. Update the fixed inventory and CI matrix in the same reviewed change.' >&2
  exit 1
fi

count="$(wc -l <"$actual" | tr -d ' ')"
[[ "$count" == "14" ]] || {
  printf 'ERROR: expected 14 local packages, found %s\n' "$count" >&2
  exit 1
}
printf '%s\n' 'Local package inventory passed: 14 packages.'
