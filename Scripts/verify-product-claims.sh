#!/usr/bin/env bash
set -euo pipefail

repo_root="${SUPRA_REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
repo_root="$(cd "$repo_root" && pwd -P)"
claims_file="${SUPRA_CLAIMS_FILE:-${repo_root}/Docs/Verified-Product-Claims.yml}"
temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT
parsed_claims="${temporary_dir}/claims.tsv"
status=0

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  status=1
}

[[ -f "$claims_file" ]] || {
  printf 'ERROR: verified product claims inventory is missing: %s\n' "$claims_file" >&2
  exit 1
}

# Parse the intentionally flat YAML subset and validate every required field before
# shell code consumes it. A malformed or partially specified claim fails closed.
if ! awk '
  function scalar(line, value, first, last) {
    value = line
    sub(/^[^:]+:[[:space:]]*/, "", value)
    first = substr(value, 1, 1)
    last = substr(value, length(value), 1)
    if ((first == "\"" && last == "\"") || (first == "\047" && last == "\047")) {
      value = substr(value, 2, length(value) - 2)
    }
    return value
  }
  function required(value, name) {
    if (value == "") {
      printf "ERROR: claim %s missing required field %s\n", id, name > "/dev/stderr"
      invalid = 1
    }
  }
  function emit() {
    if (id == "") return
    invalid = 0
    required(topic, "topic")
    required(wording, "wording")
    required(owner, "owner")
    required(code_anchor, "code_anchor")
    required(verification, "verification")
    required(ci_job, "ci_job")
    required(applicable_version, "applicable_version")
    required(last_reviewed, "last_reviewed")
    required(publication_anchor, "publication_anchor")
    if (!invalid) {
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
        id, topic, wording, owner, code_anchor, verification, ci_job, \
        applicable_version, last_reviewed, publication_anchor
    } else {
      failed = 1
    }
  }
  /^  - id:/ {
    emit()
    id = scalar($0)
    topic = wording = owner = code_anchor = verification = ci_job = ""
    applicable_version = last_reviewed = publication_anchor = ""
    next
  }
  /^    topic:/ { topic = scalar($0); next }
  /^    wording:/ { wording = scalar($0); next }
  /^    owner:/ { owner = scalar($0); next }
  /^    code_anchor:/ { code_anchor = scalar($0); next }
  /^    verification:/ { verification = scalar($0); next }
  /^    ci_job:/ { ci_job = scalar($0); next }
  /^    applicable_version:/ { applicable_version = scalar($0); next }
  /^    last_reviewed:/ { last_reviewed = scalar($0); next }
  /^    publication_anchor:/ { publication_anchor = scalar($0); next }
  END {
    emit()
    if (failed) exit 1
  }
' "$claims_file" >"$parsed_claims"; then
  exit 1
fi

claim_count="$(wc -l <"$parsed_claims" | tr -d ' ')"
if (( claim_count < 20 )); then
  fail "claims inventory is incomplete: expected at least 20 claims, found ${claim_count}"
fi

duplicate_ids="$(cut -f1 "$parsed_claims" | LC_ALL=C sort | uniq -d)"
[[ -z "$duplicate_ids" ]] || fail "duplicate claim ID: $(printf '%s' "$duplicate_ids" | head -1)"

required_topics=(
  package-count migration-count supported-releases product-version
  on-device-processing egress-paths egress-payloads credential-sources
  redirect-behavior entitlements data-at-rest citation-semantics
  drafting-gates billing-exclusions model-downloads telemetry
  release-provenance query-logging file-access public-assets
)
for topic in "${required_topics[@]}"; do
  awk -F '\t' -v topic="$topic" '$2 == topic { found = 1 } END { exit(found ? 0 : 1) }' "$parsed_claims" \
    || fail "required claim topic is missing: ${topic}"
done

while IFS=$'\t' read -r id topic wording owner code_anchor verification ci_job applicable_version last_reviewed publication_anchor; do
  for relative in "$code_anchor" "$verification" "$publication_anchor"; do
    if [[ "$relative" == /* || "$relative" == *..* ]]; then
      fail "claim ${id} uses a non-repository anchor: ${relative}"
    elif [[ ! -e "${repo_root}/${relative}" ]]; then
      fail "claim ${id} anchor is missing: ${relative}"
    fi
  done

  if [[ "$last_reviewed" != 20[0-9][0-9]-[01][0-9]-[0-3][0-9] ]]; then
    fail "claim ${id} has an invalid last-reviewed date: ${last_reviewed}"
  fi

  if [[ -f "${repo_root}/${publication_anchor}" ]] \
      && ! grep -Fq -- "$wording" "${repo_root}/${publication_anchor}"; then
    fail "claim ${id} approved wording is absent from publication anchor: ${publication_anchor}"
  fi

  workflow_name="${ci_job%%/*}"
  job_name="${ci_job#*/}"
  workflow="${repo_root}/.github/workflows/${workflow_name}.yml"
  if [[ "$workflow_name" == "$job_name" || ! -f "$workflow" ]]; then
    fail "claim ${id} names an invalid CI job: ${ci_job}"
  elif ! grep -Eq "^  ${job_name}:" "$workflow"; then
    fail "claim ${id} CI job is missing: ${ci_job}"
  fi
done <"$parsed_claims"

claim_expected() {
  local target="$1"
  awk -v target="$target" '
    function scalar(line, value, first, last) {
      value = line
      sub(/^[^:]+:[[:space:]]*/, "", value)
      first = substr(value, 1, 1)
      last = substr(value, length(value), 1)
      if ((first == "\"" && last == "\"") || (first == "\047" && last == "\047")) {
        value = substr(value, 2, length(value) - 2)
      }
      return value
    }
    /^  - id:/ { id = scalar($0); next }
    /^    expected:/ && id == target { print scalar($0); exit }
  ' "$claims_file"
}

package_expected="$(claim_expected REPO-PACKAGE-INVENTORY)"
package_actual="$(bash "${repo_root}/Scripts/list-local-packages.sh" | wc -l | tr -d ' ')"
[[ -n "$package_expected" ]] || fail 'package inventory claim has no expected value'
[[ "$package_expected" == "$package_actual" ]] \
  || fail "package inventory claim expected ${package_expected}, executable inventory is ${package_actual}"

migrator="${repo_root}/Packages/SupraStore/Sources/SupraStore/Database/SupraMigrator.swift"
migration_expected="$(claim_expected STORE-MIGRATION-SEQUENCE)"
migration_actual="$(grep -oE 'registerMigration\("v[0-9]{3}_[A-Za-z0-9_]+' "$migrator" | tail -1 | sed -E 's/registerMigration\("//')"
[[ -n "$migration_expected" ]] || fail 'migration sequence claim has no expected value'
[[ "$migration_expected" == "$migration_actual" ]] \
  || fail "migration claim expected ${migration_expected}, executable latest migration is ${migration_actual}"
bash "${repo_root}/Scripts/verify-migration-sequence.sh" "$migrator" >/dev/null || status=1

migration_manifest="${repo_root}/Packages/SupraStore/Tests/SupraStoreTests/Fixtures/ShippingMigrations/manifest.json"
command -v jq >/dev/null 2>&1 || { printf '%s\n' 'ERROR: jq is required' >&2; exit 2; }
manifest_current="$(jq -r '.currentMigration' "$migration_manifest")"
[[ "$manifest_current" == "$migration_expected" ]] \
  || fail "shipping fixture manifest is stale: ${manifest_current}; expected ${migration_expected}"
supported_expected="$(claim_expected STORE-SUPPORTED-UPGRADES)"
supported_actual="$(jq -r '.supportedVersions | join(",")' "$migration_manifest")"
[[ "$supported_expected" == "$supported_actual" ]] \
  || fail "supported release claim drifted: ${supported_actual}"

version_expected="$(claim_expected RELEASE-CURRENT-VERSION)"
version_actual="$(sed -nE 's|.*<sparkle:shortVersionString>([^<]+)</sparkle:shortVersionString>.*|\1|p' "${repo_root}/website/public/appcast.xml" | head -1)"
[[ "$version_expected" == "$version_actual" ]] \
  || fail "release-version claim expected ${version_expected}, appcast is ${version_actual}"

bash "${repo_root}/Scripts/verify-entitlements.sh" >/dev/null || status=1

if git -C "$repo_root" grep --untracked -qE \
    'TelemetryDeck|SentrySDK|FirebaseAnalytics|AmplitudeSwift|Mixpanel|PostHog|SegmentAnalytics' \
    -- Apps Packages; then
  fail 'an analytics or telemetry client marker exists in application source'
fi

retired_claims=(
  'The only time information leaves your Mac'
  'Because nothing you do leaves your Mac'
  'The only network calls are CourtListener'
  'The only network egress is explicit'
  'Every generated cite is checked'
  'unverified citations appear as visible placeholders'
  'keys are free and stored only in your Keychain'
  'migration list (`v001` … `v049`)'
)
public_copy=(
  README.md ARCHITECTURE.md SECURITY.md CONTRIBUTING.md .env.example
  Apps/SupraAI/SupraAI/SettingsView.swift
  website/app website/components
)
for phrase in "${retired_claims[@]}"; do
  if grep -RqsF -- "$phrase" "${public_copy[@]/#/${repo_root}/}"; then
    fail "retired absolute product wording remains: ${phrase}"
  fi
done

if (( status != 0 )); then
  printf '%s\n' 'Product claims verification failed.' >&2
  exit 1
fi

printf 'Product claims verification passed: %d claims, %s packages, %s.\n' \
  "$claim_count" "$package_actual" "$migration_actual"
