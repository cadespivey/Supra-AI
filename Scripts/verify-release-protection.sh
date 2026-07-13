#!/usr/bin/env bash
set -euo pipefail

repo_root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
if (( $# > 1 )) || [[ ! -d "$repo_root" ]]; then
  printf 'Usage: %s [repository-root]\n' "$0" >&2
  exit 2
fi
repo_root="$(cd "$repo_root" && pwd -P)"
status=0

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  status=1
}

required_files=(
  .github/CODEOWNERS
  .github/workflows/macos-ci.yml
  .github/workflows/security-scheduled.yml
  .github/workflows/release.yml
  .github/workflows/release-rehearsal.yml
  .github/workflows/emergency-release-rollback.yml
  Docs/Release-Protection.md
  Scripts/release.sh
  Scripts/release-preflight.sh
  Scripts/verify-release-version-state.sh
  Scripts/publish-release-transaction.sh
  Scripts/emergency-release-rollback.sh
)
for relative in "${required_files[@]}"; do
  [[ -f "${repo_root}/${relative}" ]] || fail "release protection file is missing: ${relative}"
done

codeowners="${repo_root}/.github/CODEOWNERS"
if [[ -f "$codeowners" ]]; then
  for protected_path in '/.github/workflows/' '/Scripts/release.sh' '/Scripts/*release*.sh' \
    '/Docs/Verified-Product-Claims.yml' '/SECURITY.md'; do
    grep -Fq "$protected_path" "$codeowners" \
      || fail "CODEOWNERS omits protected path: ${protected_path}"
  done
fi

release_workflow="${repo_root}/.github/workflows/release.yml"
rehearsal_workflow="${repo_root}/.github/workflows/release-rehearsal.yml"
rollback_workflow="${repo_root}/.github/workflows/emergency-release-rollback.yml"
if [[ -f "$release_workflow" ]]; then
  grep -Fq 'environment: production-release' "$release_workflow" \
    || fail 'release workflow is not bound to production-release'
  grep -Fq 'runs-on: [self-hosted, macOS, ARM64, supra-release, supra-release-isolated]' \
    "$release_workflow" \
    || fail 'release workflow is not bound to the isolated release runner'
  grep -Fq 'SUPRA_RELEASE_ISOLATED_RUNNER: "1"' "$release_workflow" \
    || fail 'release workflow does not attest the isolated release runner'
  grep -Fq 'Scripts/release.sh' "$release_workflow" || fail 'release workflow omits the protected entrypoint'
  grep -Fq -- '--expected-sha' "$release_workflow" || fail 'release workflow is not bound to an expected source SHA'
  grep -Fq -- '--ci-run-id' "$release_workflow" || fail 'release workflow is not bound to protected CI evidence'
  grep -Fq 'secrets.SUPRA_RELEASE_GITHUB_TOKEN' "$release_workflow" \
    || fail 'release workflow lacks the protected non-recursive GitHub identity'
fi
if [[ -f "$rehearsal_workflow" ]]; then
  grep -Fq 'environment: production-release' "$rehearsal_workflow" \
    || fail 'signed rehearsal is not bound to production-release'
  grep -Fq 'runs-on: [self-hosted, macOS, ARM64, supra-release, supra-release-isolated]' \
    "$rehearsal_workflow" \
    || fail 'signed rehearsal is not bound to the isolated release runner'
  grep -Fq 'SUPRA_RELEASE_ISOLATED_RUNNER: "1"' "$rehearsal_workflow" \
    || fail 'signed rehearsal does not attest the isolated release runner'
  grep -Fq -- '--no-publish' "$rehearsal_workflow" \
    || fail 'signed rehearsal does not explicitly disable publication'
fi
if [[ -f "$rollback_workflow" ]]; then
  grep -Fq 'environment: production-release' "$rollback_workflow" \
    || fail 'emergency rollback is not bound to production-release'
  grep -Fq 'Scripts/emergency-release-rollback.sh' "$rollback_workflow" \
    || fail 'emergency rollback workflow omits the protected rollback entrypoint'
  grep -Fq 'secrets.SUPRA_RELEASE_GITHUB_TOKEN' "$rollback_workflow" \
    || fail 'emergency rollback lacks the protected non-recursive GitHub identity'
fi

macos_workflow="${repo_root}/.github/workflows/macos-ci.yml"
if [[ -f "$macos_workflow" ]]; then
  for job in inventory swift-packages app-build app-smoke migration-fixtures website security dependency-review; do
    grep -Eq "^  ${job}:" "$macos_workflow" || fail "required main protection job is missing: ${job}"
  done
fi

scheduled="${repo_root}/.github/workflows/security-scheduled.yml"
if [[ -f "$scheduled" ]]; then
  grep -Eq '^[[:space:]]+schedule:' "$scheduled" || fail 'weekly security workflow has no schedule'
  grep -Fq 'Scripts/verify-public-repository-assets.sh' "$scheduled" \
    || fail 'weekly workflow omits read-only public-ref metadata check'
  grep -Fq 'Scripts/verify-model-ids.sh' "$scheduled" \
    || fail 'weekly workflow omits model metadata check'
  grep -Fq 'npm audit --audit-level=high' "$scheduled" \
    || fail 'weekly workflow omits dependency audit'
fi

release_script="${repo_root}/Scripts/release.sh"
if [[ -f "$release_script" ]]; then
  for call in release-preflight.sh verify-release-artifacts.sh publish-release-transaction.sh; do
    grep -Fq "$call" "$release_script" || fail "release entrypoint omits required stage: ${call}"
  done
  grep -Fq 'SUPRA_RELEASE_ISOLATED_RUNNER' "$release_script" \
    || fail 'release entrypoint does not require the isolated release runner'
  grep -Fq 'no GitHub release, tag, upload, appcast, push, or deployment was attempted' "$release_script" \
    || fail 'signed rehearsal has no explicit non-publication terminal state'
fi

if grep -Rqs -- '--admin' \
  "${repo_root}/.github/workflows/release.yml" \
  "${repo_root}/.github/workflows/release-rehearsal.yml" \
  "${repo_root}/.github/workflows/emergency-release-rollback.yml" \
  "${repo_root}/Scripts/release.sh" \
  "${repo_root}/Scripts/publish-release-appcast.sh" \
  "${repo_root}/Scripts/rollback-release-appcast.sh"; then
  fail 'release automation contains a permanent branch-protection bypass'
fi

if (( status != 0 )); then
  printf '%s\n' 'Release protection verification failed.' >&2
  exit 1
fi
printf '%s\n' 'Release protection verification passed.'
