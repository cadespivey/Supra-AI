#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Scripts/lib/release-common.sh
source "${root}/Scripts/lib/release-common.sh"

usage() {
  printf '%s\n' \
    'Usage: emergency-release-rollback.sh --repo-root PATH --repository OWNER/REPO --version X.Y.Z --source-sha SHA --appcast-commit SHA --reason TEXT' >&2
  exit 2
}

repo_root=''; repository=''; version=''; source_sha=''; appcast_commit=''; reason=''
while (( $# > 0 )); do
  case "$1" in
    --repo-root) repo_root="${2:-}"; shift 2 ;;
    --repository) repository="${2:-}"; shift 2 ;;
    --version) version="${2:-}"; shift 2 ;;
    --source-sha) source_sha="${2:-}"; shift 2 ;;
    --appcast-commit) appcast_commit="${2:-}"; shift 2 ;;
    --reason) reason="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -d "$repo_root" && -n "$reason" && ${#reason} -le 500 ]] || usage
repo_root="$(cd "$repo_root" && pwd -P)"
release_validate_repository "$repository"
release_validate_version "$version"
release_validate_sha "$source_sha"
release_validate_sha "$appcast_commit"
release_require_protected_environment
release_require_command gh
release_require_command jq

tag="v${version}"
gh release edit "$tag" --repo "$repository" --draft

temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT
rollback_commit_file="${temporary_dir}/rollback-commit.txt"
bash "${root}/Scripts/rollback-release-appcast.sh" \
  --repo-root "$repo_root" --repository "$repository" --commit "$appcast_commit" \
  --source-sha "$source_sha" --version "$version" --reason "$reason" \
  --output "$rollback_commit_file"
rollback_commit="$(tr -d '[:space:]' <"$rollback_commit_file")"
release_validate_sha "$rollback_commit"

deploy_json="$(gh run list --repo "$repository" --workflow deploy-website.yml \
  --commit "$rollback_commit" --json databaseId,headSha,conclusion,status --limit 10)"
deploy_run_id="$(jq -r --arg sha "$rollback_commit" '[.[] | select(.headSha == $sha)][0].databaseId // empty' <<<"$deploy_json")"
[[ "$deploy_run_id" =~ ^[1-9][0-9]*$ ]] \
  || release_die 'rollback website deployment was not created'
gh run watch "$deploy_run_id" --repo "$repository" --exit-status

incident_dir="${repo_root}/build/release/incidents"
mkdir -p "$incident_dir"
jq -n \
  --arg recordedAt "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --arg tag "$tag" --arg source "$source_sha" --arg appcastCommit "$appcast_commit" \
  --arg rollbackCommit "$rollback_commit" --arg reason "$reason" \
  '{schemaVersion: 1, recordedAt: $recordedAt, status: "withdrawn",
    tag: $tag, sourceSha: $source, appcastCommit: $appcastCommit,
    rollbackCommit: $rollbackCommit, reason: $reason, privilegedContentRecorded: false}' \
  >"${incident_dir}/${tag}-withdrawal.json"

printf 'Release %s is draft and appcast rollback %s is deployed.\n' "$tag" "$rollback_commit"
