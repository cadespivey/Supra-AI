#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
migrator="${1:-${repo_root}/Packages/SupraStore/Sources/SupraStore/Database/SupraMigrator.swift}"
if (( $# > 1 )) || [[ ! -f "$migrator" ]]; then
  printf 'Usage: %s [SupraMigrator.swift]\n' "$0" >&2
  exit 2
fi

temporary_file="$(mktemp)"
trap 'rm -f "$temporary_file"' EXIT
grep -oE 'registerMigration\("v[0-9]{3}_[A-Za-z0-9_]+"' "$migrator" \
  | sed -E 's/.*"v([0-9]{3})_.*/\1/' >"$temporary_file" || true

if [[ ! -s "$temporary_file" ]]; then
  printf 'ERROR: no shipping migrations found in %s\n' "$(basename "$migrator")" >&2
  exit 1
fi

expected=1
count=0
while IFS= read -r raw_number; do
  number=$((10#$raw_number))
  if (( number != expected )); then
    printf 'ERROR: migration sequence gap: expected v%03d, found v%03d\n' "$expected" "$number" >&2
    exit 1
  fi
  expected=$((expected + 1))
  count=$((count + 1))
done <"$temporary_file"

latest=$((expected - 1))
printf 'Migration sequence passed: v001 through v%03d (%d migrations).\n' "$latest" "$count"
