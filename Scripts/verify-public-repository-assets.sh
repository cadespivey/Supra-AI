#!/usr/bin/env bash
set -euo pipefail

# Audit only public Git/GitHub metadata. This script intentionally never fetches,
# checks out, or downloads a repository blob or release asset.

usage() {
  cat <<'EOF'
Usage: Scripts/verify-public-repository-assets.sh [owner/repository]

Enumerates advertised public branches, tags, refs/pull/*/head refs, GitHub tree
metadata, and release asset names. Exits 1 for a prohibited path/object and 2
when the audit cannot complete. Set PUBLIC_ASSET_GITHUB_TOKEN to raise GitHub's
API rate limit; omit it for an unauthenticated public audit.
EOF
}

die() {
  printf 'ERROR: public repository metadata audit incomplete: %s\n' "$1" >&2
  exit 2
}

report() {
  printf 'ERROR: %s\n' "$1" >&2
  violations=$((violations + 1))
}

is_prohibited_object() {
  case "$1" in
    2977a86366333533d454e8362956dbc2ca273836|\
    339cc03e157d27ff9c05aa1398658156fc270a1d|\
    a534fdb77da59665064b2f3ece47d779bffde437|\
    592699d8db6504e287590d73cb202ba64bb587c1|\
    21ed50d81b3d39dc5fce11597c7949e79da7fe20|\
    a2427890de67fbc5ef37eaee8557308e08d25ec9)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_prohibited_path() {
  local path="$1"
  local lower_path

  case "$path" in
    website/public/fonts/*)
      return 0
      ;;
  esac

  lower_path="$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"
  case "$lower_path" in
    *equity*a*.woff|*equity*a*.woff2|*equity*a*.ttf|*equity*a*.otf|*equity*a*.eot|*equity*a*.ttc)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

derive_repository() {
  local remote

  if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
    printf '%s\n' "$GITHUB_REPOSITORY"
    return
  fi

  remote="$(git remote get-url origin 2>/dev/null)" || return 1
  remote="${remote%.git}"
  case "$remote" in
    https://github.com/*)
      printf '%s\n' "${remote#https://github.com/}"
      ;;
    git@github.com:*)
      printf '%s\n' "${remote#git@github.com:}"
      ;;
    *)
      return 1
      ;;
  esac
}

fetch_api() {
  local url="$1"
  local destination="$2"
  local token="${PUBLIC_ASSET_GITHUB_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}"
  local args

  args=(
    --fail
    --silent
    --show-error
    --location
    --header 'Accept: application/vnd.github+json'
    --header 'X-GitHub-Api-Version: 2022-11-28'
  )
  if [[ -n "$token" ]]; then
    args+=(--header "Authorization: Bearer ${token}")
  fi

  curl "${args[@]}" --output "$destination" "$url"
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi
if (( $# > 1 )); then
  usage >&2
  exit 2
fi

command -v git >/dev/null 2>&1 || die "git is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

repository="${1:-}"
if [[ -z "$repository" ]]; then
  repository="$(derive_repository)" || die "pass owner/repository or configure a GitHub origin"
fi
repository="${repository%.git}"
[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
  || die "repository must use owner/repository format"

fixture_dir="${PUBLIC_ASSET_FIXTURE_DIR:-}"
if [[ -n "$fixture_dir" && ! -d "$fixture_dir" ]]; then
  die "fixture directory does not exist: $fixture_dir"
fi
if [[ -z "$fixture_dir" ]]; then
  command -v curl >/dev/null 2>&1 || die "curl is required"
fi

temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT
raw_refs="${temporary_dir}/ls-remote.txt"
normalized_refs="${temporary_dir}/normalized-refs.txt"
mkdir -p "${temporary_dir}/trees"

if [[ -n "$fixture_dir" ]]; then
  [[ -f "${fixture_dir}/ls-remote.txt" ]] || die "fixture is missing ls-remote.txt"
  cp "${fixture_dir}/ls-remote.txt" "$raw_refs"
else
  remote_url="${PUBLIC_ASSET_REMOTE_URL:-https://github.com/${repository}.git}"
  git ls-remote "$remote_url" \
    'refs/heads/*' \
    'refs/tags/*' \
    'refs/pull/*/head' >"$raw_refs" \
    || die "git ls-remote failed for $remote_url"
fi

# Prefer the peeled commit for annotated tags. Ignore every advertised ref that
# is not a branch, tag, or pull-request head.
awk '
  $2 ~ /\^\{\}$/ {
    ref = $2
    sub(/\^\{\}$/, "", ref)
    peeled[ref] = $1
    next
  }
  $2 ~ /^refs\/heads\// || $2 ~ /^refs\/tags\// || $2 ~ /^refs\/pull\/[0-9]+\/head$/ {
    direct[$2] = $1
  }
  END {
    for (ref in direct) {
      sha = (ref in peeled) ? peeled[ref] : direct[ref]
      print sha "\t" ref
    }
  }
' "$raw_refs" | LC_ALL=C sort -k2,2 >"$normalized_refs"

[[ -s "$normalized_refs" ]] || die "no public branches, tags, or pull-request heads were advertised"

violations=0
ref_count=0
tree_count=0

while IFS=$'\t' read -r sha ref; do
  [[ "$sha" =~ ^[0-9a-fA-F]{40}$ ]] || die "invalid object ID advertised for $ref"
  tree_file="${temporary_dir}/trees/${sha}.json"
  ref_count=$((ref_count + 1))

  if [[ ! -f "$tree_file" ]]; then
    if [[ -n "$fixture_dir" ]]; then
      fixture_tree="${fixture_dir}/trees/${sha}.json"
      [[ -f "$fixture_tree" ]] || die "fixture is missing tree metadata for $sha"
      cp "$fixture_tree" "$tree_file"
    else
      fetch_api \
        "https://api.github.com/repos/${repository}/git/trees/${sha}?recursive=1" \
        "$tree_file" \
        || die "GitHub tree request failed for $ref ($sha)"
    fi

    jq -e '
      (.truncated == false) and
      (.tree | type == "array") and
      all(.tree[]; (.path | type == "string") and (.sha | type == "string") and (.type | type == "string"))
    ' "$tree_file" >/dev/null \
      || die "tree metadata is missing or truncated for $ref ($sha)"
    tree_count=$((tree_count + 1))
  fi

  while IFS=$'\t' read -r object_id path; do
    if is_prohibited_path "$path"; then
      report "prohibited path in ${ref}:${path}"
    fi
    if is_prohibited_object "$object_id"; then
      report "known prohibited object ${object_id} in ${ref}:${path}"
    fi
  done < <(jq -r '.tree[] | select(.type == "blob") | [.sha, .path] | @tsv' "$tree_file")
done <"$normalized_refs"

release_count=0
page=1
while :; do
  releases_file="${temporary_dir}/releases-${page}.json"
  if [[ -n "$fixture_dir" ]]; then
    if (( page > 1 )); then
      break
    fi
    [[ -f "${fixture_dir}/releases.json" ]] || die "fixture is missing releases.json"
    cp "${fixture_dir}/releases.json" "$releases_file"
  else
    fetch_api \
      "https://api.github.com/repos/${repository}/releases?per_page=100&page=${page}" \
      "$releases_file" \
      || die "GitHub releases request failed on page $page"
  fi

  jq -e '
    (type == "array") and
    all(.[]; (.tag_name | type == "string") and (.assets | type == "array") and all(.assets[]; .name | type == "string"))
  ' "$releases_file" >/dev/null \
    || die "GitHub release metadata is not an array on page $page"
  page_size="$(jq 'length' "$releases_file")"
  release_count=$((release_count + page_size))

  while IFS=$'\t' read -r tag asset_name; do
    if is_prohibited_path "$asset_name"; then
      report "prohibited release asset name: release ${tag} asset ${asset_name}"
    fi
  done < <(jq -r '.[] | .tag_name as $tag | .assets[]? | [$tag, .name] | @tsv' "$releases_file")

  if [[ -n "$fixture_dir" || "$page_size" -lt 100 ]]; then
    break
  fi
  page=$((page + 1))
done

if (( violations != 0 )); then
  printf 'Public repository asset metadata check failed with %d violation(s).\n' "$violations" >&2
  exit 1
fi

printf 'Public repository asset metadata check passed. Inspected %d advertised refs, %d unique trees, and %d releases without fetching blobs or assets.\n' \
  "$ref_count" "$tree_count" "$release_count"
