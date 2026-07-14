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
for command_path in git gh; do release_require_command "$command_path"; done
release_load_git_signing_identity "$repo_root"

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

pr_url="$(gh pr create --repo "$repository" --base main --head "$branch" \
  --title "Withdraw appcast for v${version}" \
  --body "Emergency rollback for source \`${source_sha}\`. Reason: ${reason}. The release was returned to draft before this protected revert was requested.")"
abandon_pull_request() {
  gh pr close "$pr_url" --repo "$repository" --delete-branch \
    --comment 'Appcast rollback attempt failed before merge; this pull request is superseded.' \
    >/dev/null 2>&1 || true
}
if ! release_wait_for_required_checks "$pr_url" "$repository"; then
  abandon_pull_request
  release_die 'required checks did not pass for the rollback pull request'
fi
if ! gh pr merge "$pr_url" --repo "$repository" --merge --delete-branch; then
  abandon_pull_request
  release_die 'rollback pull request merge failed'
fi
merge_commit="$(gh pr view "$pr_url" --repo "$repository" --json state,mergeCommit \
  --jq 'select(.state == "MERGED") | .mergeCommit.oid')"
release_validate_sha "$merge_commit"
if [[ -n "$output" ]]; then
  mkdir -p "$(dirname "$output")"
  printf '%s\n' "$merge_commit" >"$output"
fi
printf 'Appcast rollback merged through protected review for v%s at %s.\n' "$version" "$merge_commit"
