#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Scripts/lib/release-common.sh
source "${root}/Scripts/lib/release-common.sh"

usage() {
  printf '%s\n' \
    'Usage: publish-release-appcast.sh --repo-root PATH --repository OWNER/REPO --source-sha SHA --version X.Y.Z --appcast FILE --constants FILE --output FILE' >&2
  exit 2
}

repo_root=''; repository=''; source_sha=''; version=''; appcast=''; constants=''; output=''
while (( $# > 0 )); do
  case "$1" in
    --repo-root) repo_root="${2:-}"; shift 2 ;;
    --repository) repository="${2:-}"; shift 2 ;;
    --source-sha) source_sha="${2:-}"; shift 2 ;;
    --version) version="${2:-}"; shift 2 ;;
    --appcast) appcast="${2:-}"; shift 2 ;;
    --constants) constants="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -d "$repo_root" && -f "$appcast" && -f "$constants" && -n "$output" ]] || usage
repo_root="$(cd "$repo_root" && pwd -P)"
release_validate_repository "$repository"
release_validate_sha "$source_sha"
release_validate_version "$version"
release_require_protected_environment
for command in git gh xmllint; do release_require_command "$command"; done
release_load_git_signing_identity "$repo_root"

xmllint --noout "$appcast" >/dev/null 2>&1 || release_die 'prepared appcast is invalid XML'
grep -Fq "<sparkle:shortVersionString>${version}</sparkle:shortVersionString>" "$appcast" \
  || release_die 'prepared appcast version mismatch'
grep -Fq "FALLBACK_RELEASE_TAG = \"v${version}\"" "$constants" \
  || release_die 'prepared website release constants mismatch'
[[ -z "$(git -C "$repo_root" status --porcelain=v1 --untracked-files=all)" ]] \
  || release_die 'appcast publication requires a clean checkout'
[[ "$(git -C "$repo_root" rev-parse HEAD)" == "$source_sha" ]] \
  || release_die 'appcast publication checkout is not the release source SHA'

git -C "$repo_root" fetch --no-tags origin main
[[ "$(git -C "$repo_root" rev-parse origin/main)" == "$source_sha" ]] \
  || release_die 'origin/main moved after release preflight'

suffix="${GITHUB_RUN_ID:-$(date -u +'%Y%m%d%H%M%S')}"
branch="release/appcast-v${version}-${suffix}"
worktree="$(mktemp -d)"
worktree_added=0
cleanup() {
  if (( worktree_added != 0 )); then
    git -C "$repo_root" worktree remove --force "$worktree" >/dev/null 2>&1 || true
  fi
  rm -rf "$worktree"
}
trap cleanup EXIT

git -C "$repo_root" worktree add -q -b "$branch" "$worktree" "$source_sha"
worktree_added=1
cp "$appcast" "${worktree}/website/public/appcast.xml"
cp "$constants" "${worktree}/website/lib/constants.ts"
git -C "$worktree" add -- website/public/appcast.xml website/lib/constants.ts
changed_paths="$(git -C "$worktree" diff --cached --name-only)"
[[ "$changed_paths" == $'website/lib/constants.ts\nwebsite/public/appcast.xml' \
  || "$changed_paths" == $'website/public/appcast.xml\nwebsite/lib/constants.ts' ]] \
  || release_die 'appcast publication branch contains unexpected changes'
GIT_AUTHOR_NAME="$RELEASE_GIT_NAME" GIT_AUTHOR_EMAIL="$RELEASE_GIT_EMAIL" \
GIT_COMMITTER_NAME="$RELEASE_GIT_NAME" GIT_COMMITTER_EMAIL="$RELEASE_GIT_EMAIL" \
  git -C "$worktree" -c "user.signingkey=${RELEASE_GIT_SIGNING_KEY}" \
    -c "gpg.format=${RELEASE_GIT_SIGNING_FORMAT}" commit -S -m "Publish appcast for v${version}"
git -C "$worktree" -c credential.https://github.com.helper='!gh auth git-credential' \
  push origin "HEAD:refs/heads/${branch}"

pr_url="$(gh pr create --repo "$repository" --base main --head "$branch" \
  --title "Publish appcast for v${version}" \
  --body "Protected release transaction for source \`${source_sha}\`. Review is required; this PR contains only the validated appcast and fallback constants.")"
gh pr checks "$pr_url" --repo "$repository" --required --watch --interval 10
gh pr merge "$pr_url" --repo "$repository" --merge --delete-branch
merge_commit="$(gh pr view "$pr_url" --repo "$repository" --json state,mergeCommit \
  --jq 'select(.state == "MERGED") | .mergeCommit.oid')"
release_validate_sha "$merge_commit"

mkdir -p "$(dirname "$output")"
printf '%s\n' "$merge_commit" >"$output"
printf 'Validated appcast merged through protected review at %s.\n' "$merge_commit"
