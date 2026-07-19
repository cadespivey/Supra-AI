#!/usr/bin/env bash
# Gating tests for Scripts/reviewed-release-metadata.sh — the single reader of
# reviewed release metadata (MARKETING_VERSION / CURRENT_PROJECT_VERSION) used
# by the protected release workflows and the developer dispatch script. The
# reviewed commit is the sole statement of release intent, so the reader must
# fail closed on disagreeing targets and non-release-shaped values.
#
# Expected RED reason: Scripts/reviewed-release-metadata.sh does not exist yet,
# so every case exits with bash's missing-file status (127) instead of the
# expected status and output.
#
# Fixtures use non-default values (9.4.7 / 941, never a real candidate), so a
# pass cannot come from echoing live repository state.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
metadata="${repo_root}/Scripts/reviewed-release-metadata.sh"
failures=0

# expected_exact non-empty => stdout must equal it byte-for-byte (guards the
# happy path against passing via error text that merely contains the value).
run_case() {
  local name="$1"
  local expected_status="$2"
  local expected_text="$3"
  local expected_exact="$4"
  shift 4
  local output_file status
  output_file="$(mktemp)"
  if bash "$metadata" "$@" >"$output_file" 2>&1; then
    status=0
  else
    status=$?
  fi
  if [[ "$status" -ne "$expected_status" ]]; then
    printf 'FAIL: %s: expected status %s, got %s\n' "$name" "$expected_status" "$status" >&2
    sed 's/^/  | /' "$output_file" >&2
    failures=$((failures + 1))
  elif [[ -n "$expected_exact" && "$(cat "$output_file")" != "$expected_exact" ]]; then
    printf 'FAIL: %s: expected exact output %s\n' "$name" "$expected_exact" >&2
    sed 's/^/  | /' "$output_file" >&2
    failures=$((failures + 1))
  elif [[ -n "$expected_text" ]] && ! grep -Fq -- "$expected_text" "$output_file"; then
    printf 'FAIL: %s: expected output to contain: %s\n' "$name" "$expected_text" >&2
    sed 's/^/  | /' "$output_file" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s\n' "$name"
  fi
  rm -f "$output_file"
}

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

write_project() {
  local path="$1"
  local app_version="$2"
  local app_build="$3"
  local xpc_version="$4"
  local xpc_build="$5"
  {
    printf '// !$*UTF8*$!\n{\n'
    for pair in "app:${app_version}:${app_build}" "xpc:${xpc_version}:${xpc_build}"; do
      local version="${pair#*:}"; version="${version%%:*}"
      local build="${pair##*:}"
      for configuration in Debug Release; do
        printf '\t\t\tbuildSettings = {\n'
        printf '\t\t\t\tCONFIGURATION = %s;\n' "$configuration"
        printf '\t\t\t\tCURRENT_PROJECT_VERSION = %s;\n' "$build"
        printf '\t\t\t\tMARKETING_VERSION = %s;\n' "$version"
        printf '\t\t\t};\n'
      done
    done
    printf '}\n'
  } >"$path"
}

coherent="${workdir}/coherent.pbxproj"
write_project "$coherent" 9.4.7 941 9.4.7 941

run_case 'coherent project yields the single marketing version' \
  0 '' '9.4.7' "$coherent" version
run_case 'coherent project yields the single build number' \
  0 '' '941' "$coherent" build

mixed_version="${workdir}/mixed-version.pbxproj"
write_project "$mixed_version" 9.4.7 941 9.4.8 941
run_case 'disagreeing marketing versions fail closed' \
  1 'disagree' '' "$mixed_version" version

mixed_build="${workdir}/mixed-build.pbxproj"
write_project "$mixed_build" 9.4.7 941 9.4.7 942
run_case 'disagreeing build numbers fail closed' \
  1 'disagree' '' "$mixed_build" build

two_part="${workdir}/two-part.pbxproj"
write_project "$two_part" 9.4 941 9.4 941
run_case 'two-part marketing version is not release-shaped' \
  1 'not release-shaped' '' "$two_part" version

zero_build="${workdir}/zero-build.pbxproj"
write_project "$zero_build" 9.4.7 0 9.4.7 0
run_case 'zero build number is not release-shaped' \
  1 'not release-shaped' '' "$zero_build" build

empty="${workdir}/empty.pbxproj"
printf '{\n}\n' >"$empty"
run_case 'project without version metadata fails closed' \
  1 'not found' '' "$empty" version

run_case 'missing project file fails closed' \
  1 'missing' '' "${workdir}/does-not-exist.pbxproj" version

run_case 'unknown key is a usage error' \
  2 'Usage' '' "$coherent" tag

if (( failures > 0 )); then
  printf '%s\n' 'Reviewed release metadata tests failed.' >&2
  exit 1
fi
printf '%s\n' 'Reviewed release metadata tests passed.'
