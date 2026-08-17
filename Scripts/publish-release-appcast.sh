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
for command in git gh jq xmllint; do release_require_command "$command"; done
release_load_git_signing_identity "$repo_root"
gh_command="$(release_resolve_command_override SUPRA_GH_COMMAND gh)"

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
metadata_sha="$(git -C "$worktree" rev-parse HEAD)"
"$gh_command" workflow run 'Protected macOS CI' --repo "$repository" --ref "$branch" \
  || release_die 'unable to dispatch narrow appcast validation'

poll_seconds="${SUPRA_RELEASE_CHECK_POLL_SECONDS:-15}"
metadata_run=''
status=''
conclusion=''
for (( attempt = 0; attempt < 60; attempt++ )); do
  runs="$("$gh_command" run list --repo "$repository" --branch "$branch" \
    --workflow 'Protected macOS CI' --json databaseId,headSha,status,conclusion,url --limit 10)" \
    || release_die 'unable to list appcast validation runs'
  selected="$(jq --arg sha "$metadata_sha" '[.[] | select(.headSha == $sha)][0] // empty' <<<"$runs")"
  if [[ -n "$selected" ]]; then
    status="$(jq -r '.status // empty' <<<"$selected")"
    conclusion="$(jq -r '.conclusion // empty' <<<"$selected")"
    metadata_run="$(jq -r '.databaseId // empty' <<<"$selected")"
    if [[ "$status" == 'completed' ]]; then
      if [[ "$conclusion" != 'success' ]]; then
        release_die 'narrow appcast validation failed'
        exit 1
      fi
      break
    fi
  fi
  sleep "$poll_seconds"
done
[[ -n "$metadata_run" && "$status" == 'completed' && "$conclusion" == 'success' ]] \
  || release_die 'narrow appcast validation did not complete'

# The validated metadata commit itself advances main. No PR merge commit and no
# second general application run are created.
git -C "$worktree" -c credential.https://github.com.helper='!gh auth git-credential' \
  push origin "${metadata_sha}:refs/heads/main" \
  || release_die 'validated appcast commit could not fast-forward main'
git -C "$worktree" -c credential.https://github.com.helper='!gh auth git-credential' \
  push origin --delete "$branch" >/dev/null 2>&1 || true

mkdir -p "$(dirname "$output")"
printf '%s\n' "$metadata_sha" >"$output"
printf 'Validated appcast fast-forwarded to main at %s (CI run %s).\n' "$metadata_sha" "$metadata_run"
