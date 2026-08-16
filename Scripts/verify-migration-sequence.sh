#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
migration_source="${1:-${repo_root}/Packages/SupraStore/Sources/SupraStore/Database}"
if (( $# > 1 )) || [[ ! -f "$migration_source" && ! -d "$migration_source" ]]; then
  printf 'Usage: %s [migration-source-file-or-directory]\n' "$0" >&2
  exit 2
fi

temporary_file="$(mktemp)"
trap 'rm -f "$temporary_file"' EXIT
if [[ -f "$migration_source" ]]; then
  grep -oE 'registerMigration\("v[0-9]{3}_[A-Za-z0-9_]+"' "$migration_source" \
    | sed -E 's/.*"v([0-9]{3})_.*/\1/' >"$temporary_file" || true
else
  while IFS= read -r -d '' migration_file; do
    grep -oE 'registerMigration\("v[0-9]{3}_[A-Za-z0-9_]+"' "$migration_file" || true
  done < <(find "$migration_source" -type f -name 'SupraMigration*.swift' -print0 | LC_ALL=C sort -z) \
    | sed -E 's/.*"v([0-9]{3})_.*/\1/' \
    | LC_ALL=C sort >"$temporary_file"
fi

if [[ ! -s "$temporary_file" ]]; then
  printf 'ERROR: no shipping migrations found in %s\n' "$(basename "$migration_source")" >&2
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
