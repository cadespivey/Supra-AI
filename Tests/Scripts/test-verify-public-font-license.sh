#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
guard="${repo_root}/Scripts/verify-public-font-license.sh"
failures=0

run_case() {
  local name="$1"
  local workdir="$2"
  local expected_status="$3"
  local expected_text="$4"
  local output_file
  local status

  output_file="$(mktemp)"
  if (cd "$workdir" && bash "$guard") >"$output_file" 2>&1; then
    status=0
  else
    status=$?
  fi

  if [[ "$status" -ne "$expected_status" ]]; then
    printf 'FAIL: %s: expected status %s, got %s\n' "$name" "$expected_status" "$status" >&2
    sed 's/^/  | /' "$output_file" >&2
    failures=$((failures + 1))
  elif ! grep -Fq -- "$expected_text" "$output_file"; then
    printf 'FAIL: %s: expected output to contain: %s\n' "$name" "$expected_text" >&2
    sed 's/^/  | /' "$output_file" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s\n' "$name"
  fi

  rm -f "$output_file"
}

# Repository mode: unchanged behavior scanning the tracked tree.
run_case \
  'repository mode passes on the clean tracked tree' \
  "$repo_root" \
  0 \
  'Public font license check passed.'

# Staged-artifact mode: the release transaction runs the guard inside a
# temporary website copy that is not a git repository (observed live in
# production run: "Website gate failed: post-build public font guard").
# Expected RED reason: the guard's first statement is git rev-parse
# --show-toplevel, which dies outside a repository before any scan runs.
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir -p "${stage}/public" "${stage}/out/_next"
printf '%s' '{}' >"${stage}/package-lock.json"
printf 'body{}' >"${stage}/out/site.css"
run_case \
  'staged artifact mode passes without a git repository' \
  "$stage" \
  0 \
  'Public font license check passed.'

printf 'synthetic' >"${stage}/out/Equity_A_Regular.woff2"
run_case \
  'staged artifact mode rejects an Equity-named font' \
  "$stage" \
  1 \
  'Equity font asset is prohibited'
rm -f "${stage}/out/Equity_A_Regular.woff2"

mkdir -p "${stage}/public/fonts"
printf 'synthetic' >"${stage}/public/fonts/anything.woff2"
run_case \
  'staged artifact mode rejects the public fonts path' \
  "$stage" \
  1 \
  'public font path is prohibited'
rm -rf "${stage}/public/fonts"

# node_modules content must not trip the staged scan (Next.js ships assets).
mkdir -p "${stage}/node_modules/some-pkg/fonts"
printf 'synthetic' >"${stage}/node_modules/some-pkg/fonts/vendor.woff2"
run_case \
  'staged artifact mode ignores node_modules' \
  "$stage" \
  0 \
  'Public font license check passed.'

if (( failures != 0 )); then
  printf 'Public font license guard tests failed: %d\n' "$failures" >&2
  exit 1
fi
printf '%s\n' 'All public font license guard tests passed.'
