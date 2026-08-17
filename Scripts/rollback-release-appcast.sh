#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Scripts/lib/release-common.sh
source "${root}/Scripts/lib/release-common.sh"

usage() {
  printf '%s\n' \
    'Usage: rollback-release-appcast.sh --repo-root PATH --repository OWNER/REPO --commit SHA --source-sha SHA --version X.Y.Z --reason TEXT [--output FILE]' >&2
  exit 2
}

repo_root=''; repository=''; commit=''; source_sha=''; version=''; reason=''; output=''
while (( $# > 0 )); do
  case "$1" in
    --repo-root) repo_root="${2:-}"; shift 2 ;;
    --repository) repository="${2:-}"; shift 2 ;;
    --commit) commit="${2:-}"; shift 2 ;;
    --source-sha) source_sha="${2:-}"; shift 2 ;;
    --version) version="${2:-}"; shift 2 ;;
    --reason) reason="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -d "$repo_root" && -n "$reason" && ${#reason} -le 500 ]] || usage
repo_root="$(cd "$repo_root" && pwd -P)"
release_validate_repository "$repository"
release_validate_sha "$commit"
release_validate_sha "$source_sha"
release_validate_version "$version"
release_require_protected_environment
for command_path in git gh jq; do release_require_command "$command_path"; done
release_load_git_signing_identity "$repo_root"
gh_command="$(release_resolve_command_override SUPRA_GH_COMMAND gh)"

git -C "$repo_root" fetch --no-tags origin main
git -C "$repo_root" merge-base --is-ancestor "$commit" origin/main \
  || release_die 'appcast commit is not reachable from origin/main'
changed_paths="$(git -C "$repo_root" diff-tree --no-commit-id --name-only -r "$commit" | LC_ALL=C sort)"
[[ "$changed_paths" == $'website/lib/constants.ts\nwebsite/public/appcast.xml' ]] \
  || release_die 'refusing to revert a commit outside the appcast publication boundary'

suffix="${GITHUB_RUN_ID:-$(date -u +'%Y%m%d%H%M%S')}"
branch="release/rollback-v${version}-${suffix}"
worktree="$(mktemp -d)"
worktree_added=0
cleanup() {
  if (( worktree_added != 0 )); then
    git -C "$repo_root" worktree remove --force "$worktree" >/dev/null 2>&1 || true
  fi
  rm -rf "$worktree"
}
trap cleanup EXIT

git -C "$repo_root" worktree add -q -b "$branch" "$worktree" origin/main
worktree_added=1
GIT_AUTHOR_NAME="$RELEASE_GIT_NAME" GIT_AUTHOR_EMAIL="$RELEASE_GIT_EMAIL" \
GIT_COMMITTER_NAME="$RELEASE_GIT_NAME" GIT_COMMITTER_EMAIL="$RELEASE_GIT_EMAIL" \
  git -C "$worktree" -c "user.signingkey=${RELEASE_GIT_SIGNING_KEY}" \
    -c "gpg.format=${RELEASE_GIT_SIGNING_FORMAT}" revert -S --no-edit "$commit"
git -C "$worktree" -c credential.https://github.com.helper='!gh auth git-credential' \
  push origin "HEAD:refs/heads/${branch}"
rollback_sha="$(git -C "$worktree" rev-parse HEAD)"
"$gh_command" workflow run 'Protected macOS CI' --repo "$repository" --ref "$branch" \
  || release_die 'unable to dispatch narrow rollback validation'
poll_seconds="${SUPRA_RELEASE_CHECK_POLL_SECONDS:-15}"
status=''; conclusion=''; rollback_run=''
for (( attempt = 0; attempt < 60; attempt++ )); do
  runs="$("$gh_command" run list --repo "$repository" --branch "$branch" \
    --workflow 'Protected macOS CI' --json databaseId,headSha,status,conclusion,url --limit 10)" \
    || release_die 'unable to list rollback validation runs'
  selected="$(jq --arg sha "$rollback_sha" '[.[] | select(.headSha == $sha)][0] // empty' <<<"$runs")"
  if [[ -n "$selected" ]]; then
    status="$(jq -r '.status // empty' <<<"$selected")"
    conclusion="$(jq -r '.conclusion // empty' <<<"$selected")"
    rollback_run="$(jq -r '.databaseId // empty' <<<"$selected")"
    if [[ "$status" == 'completed' ]]; then
      if [[ "$conclusion" != 'success' ]]; then
        release_die 'narrow rollback validation failed'
        exit 1
      fi
      break
    fi
  fi
  sleep "$poll_seconds"
done
[[ -n "$rollback_run" && "$status" == 'completed' && "$conclusion" == 'success' ]] \
  || release_die 'narrow rollback validation did not complete'
git -C "$worktree" -c credential.https://github.com.helper='!gh auth git-credential' \
  push origin "${rollback_sha}:refs/heads/main" \
  || release_die 'validated rollback could not fast-forward main'
git -C "$worktree" -c credential.https://github.com.helper='!gh auth git-credential' \
  push origin --delete "$branch" >/dev/null 2>&1 || true
if [[ -n "$output" ]]; then
  mkdir -p "$(dirname "$output")"
  printf '%s\n' "$rollback_sha" >"$output"
fi
printf 'Appcast rollback fast-forwarded for v%s at %s (CI run %s).\n' "$version" "$rollback_sha" "$rollback_run"
