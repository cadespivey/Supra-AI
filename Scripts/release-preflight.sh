#!/usr/bin/env bash
set -euo pipefail

script_root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Scripts/lib/release-common.sh
source "${script_root}/Scripts/lib/release-common.sh"

usage() {
  printf '%s\n' \
    'Usage: release-preflight.sh --repo-root PATH --repository OWNER/REPO --version X.Y.Z --build N --expected-sha SHA --ci-run-id ID --output FILE' >&2
  exit 2
}

repo_root=''
repository=''
version=''
build=''
expected_sha=''
ci_run_id=''
output=''
while (( $# > 0 )); do
  case "$1" in
    --repo-root) repo_root="${2:-}"; shift 2 ;;
    --repository) repository="${2:-}"; shift 2 ;;
    --version) version="${2:-}"; shift 2 ;;
    --build) build="${2:-}"; shift 2 ;;
    --expected-sha) expected_sha="${2:-}"; shift 2 ;;
    --ci-run-id) ci_run_id="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -d "$repo_root" && -n "$output" && "$ci_run_id" =~ ^[1-9][0-9]*$ ]] || usage
repo_root="$(cd "$repo_root" && pwd -P)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
release_validate_repository "$repository"
release_validate_version "$version"
release_validate_build "$build"
release_validate_sha "$expected_sha"
release_require_protected_environment
for command in git jq shasum xcodebuild swift; do
  release_require_command "$command"
done

gh_command="$(release_resolve_command_override SUPRA_GH_COMMAND gh)"
credential_gate="$(release_resolve_command_override SUPRA_CREDENTIAL_GATE_COMMAND "${script_root}/Scripts/verify-release-credentials.sh")"
font_gate="$(release_resolve_command_override SUPRA_FONT_GUARD_COMMAND "${script_root}/Scripts/verify-public-font-license.sh")"
release_gate="$(release_resolve_command_override SUPRA_RELEASE_GATE_COMMAND "${script_root}/Scripts/run-release-gates.sh")"
for command_path in "$gh_command" "$credential_gate" "$font_gate" "$release_gate"; do
  release_require_resolvable_command "$command_path" 'release preflight'
done

[[ -z "$(git -C "$repo_root" status --porcelain=v1 --untracked-files=all)" ]] \
  || release_die 'working tree is not clean'

branch="$(git -C "$repo_root" symbolic-ref --quiet --short HEAD 2>/dev/null)" \
  || release_die 'release checkout must not be detached'
[[ "$branch" == 'main' ]] || release_die 'release checkout is not main'

head_sha="$(git -C "$repo_root" rev-parse --verify HEAD)"
[[ "$head_sha" == "$expected_sha" ]] || release_die 'HEAD does not match expected release SHA'

origin_line="$(git -C "$repo_root" ls-remote --heads origin refs/heads/main 2>/dev/null)" \
  || release_die 'unable to read origin/main'
origin_sha="$(printf '%s\n' "$origin_line" | awk 'NR == 1 {print $1}')"
[[ "$origin_sha" == "$head_sha" ]] || release_die 'HEAD does not equal origin/main'

tag="v${version}"
if git -C "$repo_root" show-ref --verify --quiet "refs/tags/${tag}"; then
  release_die 'release tag already exists locally'
fi
remote_tag="$(git -C "$repo_root" ls-remote --tags origin "refs/tags/${tag}" "refs/tags/${tag}^{}" 2>/dev/null)" \
  || release_die 'unable to inspect origin release tags'
[[ -z "$remote_tag" ]] || release_die 'release tag already exists on origin'

"$gh_command" auth status >/dev/null 2>&1 || release_die 'GitHub release authentication is unavailable'
if "$gh_command" release view "$tag" --repo "$repository" >/dev/null 2>&1; then
  release_die 'release version is already published or reserved'
fi
"$gh_command" api "repos/${repository}" --silent >/dev/null 2>&1 \
  || release_die 'unable to confirm GitHub release state'

ci_json="$("$gh_command" run view "$ci_run_id" --repo "$repository" \
  --json headSha,conclusion,workflowName,url)" \
  || release_die 'unable to inspect protected CI run'
ci_sha="$(jq -r '.headSha // empty' <<<"$ci_json")"
ci_conclusion="$(jq -r '.conclusion // empty' <<<"$ci_json")"
ci_workflow="$(jq -r '.workflowName // empty' <<<"$ci_json")"
ci_url="$(jq -r '.url // empty' <<<"$ci_json")"
[[ "$ci_sha" == "$head_sha" ]] || release_die 'protected CI run is not bound to the release SHA'
[[ "$ci_conclusion" == 'success' ]] || release_die 'protected CI run is not successful'
[[ "$ci_workflow" == 'Protected macOS CI' ]] || release_die 'CI run is not the protected macOS workflow'

"$credential_gate" >/dev/null || release_die 'release credential gate failed'
"$font_gate" >/dev/null || release_die 'public font gate failed'
SUPRA_RELEASE_REPOSITORY="$repository" "$release_gate" >/dev/null \
  || release_die 'release integration gate failed'

current_appcast="${repo_root}/website/public/appcast.xml"
project_metadata="${repo_root}/Apps/SupraAI/SupraAI.xcodeproj/project.pbxproj"
[[ -f "$project_metadata" ]] || release_die 'reviewed app/XPC version metadata is missing'
marketing_values="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION = ([^;]+);/\1/p' "$project_metadata" | LC_ALL=C sort -u)"
build_values="$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION = ([^;]+);/\1/p' "$project_metadata" | LC_ALL=C sort -u)"
[[ "$marketing_values" == "$version" ]] \
  || release_die 'reviewed app/XPC marketing versions do not match requested release'
[[ "$build_values" == "$build" ]] \
  || release_die 'reviewed app/XPC build numbers do not match requested release'
if [[ -f "$current_appcast" ]]; then
  current_build="$(sed -nE 's|.*<sparkle:version>([0-9]+)</sparkle:version>.*|\1|p' "$current_appcast" | head -1)"
  if [[ "$current_build" =~ ^[0-9]+$ ]] && (( build <= current_build )); then
    release_die "release build must be greater than the published appcast build (${current_build})"
  fi
  if grep -Fq "<sparkle:shortVersionString>${version}</sparkle:shortVersionString>" "$current_appcast"; then
    release_die 'release version already exists in the appcast'
  fi
fi

tree_sha="$(git -C "$repo_root" rev-parse --verify HEAD^{tree})"
xcode_version="$(xcodebuild -version | tr '\n' ';' | sed 's/;*$//')"
swift_version="$(swift --version | tr '\n' ';' | sed 's/;*$//')"
generated_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

locks_json="$({
  find -s "$repo_root" -name Package.resolved \
    -not -path '*/.build/*' -not -path '*/DerivedData/*' -print | while IFS= read -r lock; do
      relative="${lock#${repo_root}/}"
      jq -n --arg path "$relative" --arg sha256 "$(release_sha256 "$lock")" \
        '{path: $path, sha256: $sha256}'
    done
} | jq -s 'sort_by(.path)')"

mkdir -p "$(dirname "$output")"
temporary_output="$(mktemp "$(dirname "$output")/.release-preflight.XXXXXX")"
trap 'rm -f "$temporary_output"' EXIT
jq -n \
  --arg generatedAt "$generated_at" \
  --arg repository "$repository" \
  --arg branch "$branch" \
  --arg sha "$head_sha" \
  --arg tree "$tree_sha" \
  --arg originMain "$origin_sha" \
  --arg version "$version" \
  --arg build "$build" \
  --arg tag "$tag" \
  --arg xcode "$xcode_version" \
  --arg swift "$swift_version" \
  --arg ciID "$ci_run_id" \
  --arg ciWorkflow "$ci_workflow" \
  --arg ciURL "$ci_url" \
  --argjson locks "$locks_json" \
  '{
    schemaVersion: 1,
    manifestKind: "supra-release-source-preflight",
    generatedAt: $generatedAt,
    repository: $repository,
    source: {branch: $branch, sha: $sha, tree: $tree, originMain: $originMain},
    release: {version: $version, build: $build, tag: $tag},
    reviewedBuildMetadata: {marketingVersion: $version, currentProjectVersion: $build},
    toolchain: {xcode: $xcode, swift: $swift},
    dependencyLocks: $locks,
    ciRuns: [{id: $ciID, workflow: $ciWorkflow, headSha: $sha, conclusion: "success", url: $ciURL}],
    gates: {credentials: "passed", publicFont: "passed", releaseIntegration: "passed"}
  }' >"$temporary_output"

jq -e '
  .schemaVersion == 1 and
  .manifestKind == "supra-release-source-preflight" and
  (.source.sha | test("^[0-9a-f]{40}$")) and
  (.release.build | test("^[1-9][0-9]*$")) and
  (.dependencyLocks | type == "array") and
  (.ciRuns | length == 1)
' "$temporary_output" >/dev/null || release_die 'generated source preflight manifest is invalid'

mv -f "$temporary_output" "$output"
trap - EXIT
printf 'Release source preflight passed for %s at %s.\n' "$tag" "$head_sha"
