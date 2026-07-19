#!/usr/bin/env bash
# Static gates for the protected release workflow dispatch surface.
#
# The reviewed commit on main is the single statement of release version
# intent: the workflows must derive version/build from the checked-out Xcode
# project via Scripts/reviewed-release-metadata.sh instead of accepting
# hand-typed version/build dispatch inputs, which add only mismatch failure
# modes. The SHA and CI bindings (expected_sha, ci_run_id) remain explicit
# operator inputs.
#
# Expected RED reason: release.yml and release-rehearsal.yml still declare
# version/build workflow_dispatch inputs and do not invoke
# Scripts/reviewed-release-metadata.sh.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
failures=0

check() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'PASS: %s\n' "$name"
  else
    printf 'FAIL: %s\n' "$name" >&2
    failures=$((failures + 1))
  fi
}

check_absent() {
  local name="$1"
  local pattern="$2"
  local file="$3"
  if grep -Eq -- "$pattern" "$file"; then
    printf 'FAIL: %s\n' "$name" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s\n' "$name"
  fi
}

for workflow in release release-rehearsal; do
  file="${repo_root}/.github/workflows/${workflow}.yml"
  [[ -f "$file" ]] || { printf 'FAIL: %s.yml is missing\n' "$workflow" >&2; failures=$((failures + 1)); continue; }

  # Wire-proof by absence: the old hand-typed dispatch surface must be gone.
  check_absent "${workflow}: no version dispatch input" '^      version:' "$file"
  check_absent "${workflow}: no build dispatch input" '^      build:' "$file"
  check_absent "${workflow}: no inputs.version reference" 'inputs\.version' "$file"
  check_absent "${workflow}: no inputs.build reference" 'inputs\.build' "$file"

  check "${workflow}: keeps the expected_sha input" grep -Eq '^      expected_sha:' "$file"
  check "${workflow}: keeps the ci_run_id input" grep -Eq '^      ci_run_id:' "$file"

  check "${workflow}: derives version from reviewed metadata" \
    grep -Eq 'Scripts/reviewed-release-metadata\.sh[^#]*version' "$file"
  check "${workflow}: derives build from reviewed metadata" \
    grep -Eq 'Scripts/reviewed-release-metadata\.sh[^#]*build' "$file"
  check "${workflow}: reads the reviewed Xcode project" \
    grep -Fq 'Apps/SupraAI/SupraAI.xcodeproj/project.pbxproj' "$file"

  # The protected entrypoint contract is unchanged.
  check "${workflow}: still passes --version to release.sh" grep -Fq -- '--version' "$file"
  check "${workflow}: still passes --build to release.sh" grep -Fq -- '--build' "$file"
  check "${workflow}: still binds --expected-sha" grep -Fq -- '--expected-sha' "$file"
  check "${workflow}: still binds --ci-run-id" grep -Fq -- '--ci-run-id' "$file"
done

check 'rehearsal still disables publication' \
  grep -Fq -- '--no-publish' "${repo_root}/.github/workflows/release-rehearsal.yml"

if grep -Fq -- '--no-publish' "${repo_root}/.github/workflows/release.yml"; then
  printf 'FAIL: production release must not carry --no-publish\n' >&2
  failures=$((failures + 1))
else
  printf 'PASS: production release does not carry --no-publish\n'
fi

if (( failures > 0 )); then
  printf '%s\n' 'Release workflow dispatch input gates failed.' >&2
  exit 1
fi
printf '%s\n' 'Release workflow dispatch input gates passed.'
