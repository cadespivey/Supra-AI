#!/usr/bin/env bash
# Deterministic signed-rehearsal scope verdict, replacing the hand-applied
# "any machinery change re-arms a rehearsal" reading of the runbook policy.
#
#   bash Scripts/release-rehearsal-required.sh                # derive baseline
#   bash Scripts/release-rehearsal-required.sh --base SHA     # explicit baseline
#
# The baseline is the last green signed run (production release or signed
# rehearsal); when --base is omitted it is derived via gh. The verdict
# classifies every path changed since the baseline:
#
# - SIGNED-OUTPUT machinery re-arms the rehearsal: scripts whose inputs are
#   real signing/notarization/packaging tool behavior (build, sign, smoke,
#   artifact verification, appcast preparation), the release workflows,
#   entitlements, ExportOptions, runner provisioning, and the shared library
#   they all source. A green rehearsal proves this happy path against the
#   real tools — hermetic mocks cannot.
#
# - HERMETICALLY COVERED machinery does not: orchestration and gate scripts
#   (cut-release, dispatch, finish, preflight, this script) consume only
#   git/GitHub state, are exercised fail-closed by the Tests/Scripts
#   harnesses in protected CI, and a green rehearsal exercises none of their
#   fail-paths anyway.
#
# - PRODUCTION-ONLY PUBLISH PATH machinery does not either, for a structural
#   reason: Scripts/release.sh under --no-publish exits before it would
#   invoke the publish transaction, so a rehearsal is incapable of reaching
#   publish-release-transaction.sh, publish-release-appcast.sh, or
#   rollback-release-appcast.sh — a REQUIRED verdict for them would demand a
#   rehearsal that cannot exercise them. Their only coverage is the hermetic
#   suite Tests/Scripts/test-release-transaction.sh; the verdict says so on
#   a distinct output line rather than pretending a rehearsal would help.
#
# - Anything else machinery-shaped but unclassified fails safe to REQUIRED.
#
# Exit-code contract (fail-safe by construction): exit 0 is the ONLY signal
# that no rehearsal is required. A REQUIRED verdict, a usage error, an
# unresolvable baseline, or any crash exits nonzero — a failure can never
# read as permission to skip the rehearsal.
#
# Toolchain changes (Xcode, Sparkle tools, signing identities) never appear
# in a repository diff; the runbook still requires a rehearsal for those.
set -euo pipefail

script_root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Scripts/lib/release-common.sh
source "${script_root}/Scripts/lib/release-common.sh"

usage() {
  printf 'Usage: release-rehearsal-required.sh [--base SHA] [--repo-root PATH]\n' >&2
  exit 2
}

base=''
repo_root=''
while (( $# > 0 )); do
  case "$1" in
    --base) base="${2:-}"; shift 2 ;;
    --repo-root) repo_root="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
if [[ -z "$repo_root" ]]; then
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || release_die 'release-rehearsal-required must run inside the repository checkout'
fi
[[ -d "$repo_root" ]] || usage

release_require_command git
release_require_command jq
gh_command="$(release_resolve_command_override SUPRA_GH_COMMAND gh)"

# Scripts whose inputs are real signing/notarization/packaging tool behavior,
# plus everything that shapes the signed artifact or the publish path.
path_is_signed_output_machinery() {
  case "$1" in
    Scripts/release.sh|\
    Scripts/prepare-release-appcast.sh|\
    Scripts/create-preflight-manifest.sh|\
    Scripts/sign-release-manifest.swift|\
    Scripts/build-macos-app.sh|\
    Scripts/run-signed-release-smoke.sh|\
    Scripts/smoke-model-tool.swift|\
    Scripts/verify-release-artifacts.sh|\
    Scripts/verify-release-artifact-contents.sh|\
    Scripts/verify-signed-runtime-smoke-result.sh|\
    Scripts/verify-entitlements.sh|\
    Scripts/verify-release-credentials.sh|\
    Scripts/lib/release-common.sh|\
    Scripts/provision-release-runner.sh|\
    Scripts/ExportOptions.plist|\
    .github/workflows/release.yml|\
    .github/workflows/release-rehearsal.yml|\
    Apps/*.entitlements) return 0 ;;
  esac
  return 1
}

# Production-only publish path: release.sh --no-publish exits before the
# publish transaction is invoked, so a rehearsal is structurally incapable of
# exercising these scripts. They do not re-arm a rehearsal; their only
# coverage is the hermetic suite Tests/Scripts/test-release-transaction.sh,
# and the verdict lists them on a distinct line to keep that honest.
path_is_production_only_publish() {
  case "$1" in
    Scripts/publish-release-transaction.sh|\
    Scripts/publish-release-appcast.sh|\
    Scripts/rollback-release-appcast.sh) return 0 ;;
  esac
  return 1
}

# Orchestration and gate scripts that consume only git/GitHub state and are
# exercised fail-closed by the hermetic Tests/Scripts harnesses in protected
# CI. A green rehearsal exercises none of their fail-paths.
path_is_hermetically_covered() {
  case "$1" in
    Scripts/cut-release.sh|\
    Scripts/release-dispatch.sh|\
    Scripts/release-finish.sh|\
    Scripts/release-preflight.sh|\
    Scripts/release-rehearsal-required.sh|\
    Scripts/reset-release-runner.sh|\
    Scripts/reviewed-release-metadata.sh|\
    Scripts/emergency-release-rollback.sh|\
    .github/workflows/emergency-release-rollback.yml|\
    Scripts/verify-release-version-state.sh|\
    Scripts/verify-release-protection.sh) return 0 ;;
  esac
  return 1
}

# Anything machinery-shaped that the two explicit lists do not classify.
path_is_machinery_shaped() {
  case "$1" in
    Scripts/*release*|\
    Scripts/lib/*|\
    Scripts/*appcast*|\
    Scripts/*sign*|\
    Scripts/*smoke*|\
    Scripts/*runner*|\
    .github/workflows/release*) return 0 ;;
  esac
  return 1
}

# The release cut routinely changes only these two reviewed version settings.
# Every other project-file edit can shape the archive, entitlements, signing,
# build phases, or the signed-smoke host, so it fails safe to REQUIRED.
pbxproj_has_only_routine_version_changes() {
  local path="$1"
  local project_diff=''
  local changed_line=''
  local setting_line=''
  local saw_change=0

  project_diff="$(git -C "$repo_root" diff --unified=0 "${base}...HEAD" -- "$path")" \
    || return 1
  while IFS= read -r changed_line; do
    case "$changed_line" in
      '--- '*|'+++ '*) continue ;;
      -*) setting_line="${changed_line:1}" ;;
      +*) setting_line="${changed_line:1}" ;;
      *) continue ;;
    esac
    saw_change=1
    if [[ "$setting_line" =~ ^[[:space:]]*(CURRENT_PROJECT_VERSION|MARKETING_VERSION)[[:space:]]*= ]]; then
      continue
    fi
    return 1
  done <<<"$project_diff"
  (( saw_change == 1 ))
}

baseline_source='--base'
if [[ -z "$base" ]]; then
  derived="$(
    for workflow in 'Protected production release' 'Protected signed release rehearsal'; do
      "$gh_command" run list --workflow "$workflow" \
        --json headSha,conclusion,createdAt --limit 20 2>/dev/null \
        | jq -r '.[] | select(.conclusion == "success") | [.createdAt, .headSha] | @tsv' \
        2>/dev/null || true
    done | LC_ALL=C sort -r | awk 'NR == 1 {print $2}'
  )"
  [[ -n "$derived" ]] \
    || release_die 'could not determine the last green signed run; pass --base SHA explicitly (fail-safe: treat the rehearsal as required until a verdict exists)'
  base="$derived"
  baseline_source='last green signed run'
fi

git -C "$repo_root" rev-parse --verify --quiet "${base}^{commit}" >/dev/null \
  || release_die "unable to resolve the rehearsal baseline ${base} in ${repo_root}"

head_sha="$(git -C "$repo_root" rev-parse HEAD)"
changed_paths="$(git -C "$repo_root" diff --name-only "${base}...HEAD")" \
  || release_die 'unable to diff the rehearsal baseline against HEAD'

required_paths=()
covered_paths=()
publish_only_paths=()
routine_project_paths=()
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  if path_is_signed_output_machinery "$path"; then
    required_paths+=("$path")
  elif path_is_production_only_publish "$path"; then
    publish_only_paths+=("$path")
  elif path_is_hermetically_covered "$path"; then
    covered_paths+=("$path")
  elif path_is_machinery_shaped "$path"; then
    required_paths+=("${path} (unclassified release machinery — fail-safe)")
  elif [[ "$path" == *.pbxproj ]]; then
    if pbxproj_has_only_routine_version_changes "$path"; then
      routine_project_paths+=("$path")
    else
      required_paths+=("${path} (non-version project configuration changed)")
    fi
  fi
done <<<"$changed_paths"

printf 'Signed-rehearsal scope check\n'
printf '  baseline: %s (%s)\n' "$base" "$baseline_source"
printf '  head:     %s\n' "$head_sha"

if (( ${#covered_paths[@]} > 0 )); then
  printf '  machinery covered by hermetic harnesses (does not re-arm the rehearsal):\n'
  printf '    - %s\n' "${covered_paths[@]}"
fi
if (( ${#publish_only_paths[@]} > 0 )); then
  printf '  production-only publish path (a rehearsal cannot exercise these; hermetic coverage is the only coverage):\n'
  printf '    - %s\n' "${publish_only_paths[@]}"
fi
if (( ${#routine_project_paths[@]} > 0 )); then
  printf '  routine project version metadata (does not re-arm the rehearsal):\n'
  printf '    - %s\n' "${routine_project_paths[@]}"
fi

if (( ${#required_paths[@]} > 0 )); then
  printf 'VERDICT: signed rehearsal REQUIRED — signed-output machinery changed since the baseline:\n'
  printf '    - %s\n' "${required_paths[@]}"
  printf 'Reminder: toolchain changes (Xcode, Sparkle tools, signing identities) are invisible to this diff and also require a rehearsal.\n'
  exit 1
fi

printf 'VERDICT: no signed rehearsal required — no signed-output machinery changed since the baseline.\n'
printf 'Reminder: toolchain changes (Xcode, Sparkle tools, signing identities) are invisible to this diff and still require a rehearsal.\n'
exit 0
