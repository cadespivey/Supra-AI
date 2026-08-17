#!/usr/bin/env bash
# Hermetic gating tests for Scripts/release-preflight.sh's stale-tag handling.
#
# A persistent release runner reuses its checkout; when a prior run dies after
# tagging (or its workspace reset is skipped — a stop failure, a cancelled run,
# a run parked at the approval gate), a LOCAL-ONLY tag for an unpublished
# version survives into the next run, which dies at "release tag already
# exists locally". Observed live: signed rehearsal run 30275867763
# (2026-07-27) failed exactly there, 2h44m in. A local-only tag that is absent
# from origin and has no published GitHub release states no publication
# intent: preflight must prune it and continue. Every state that could
# represent a real publication — the tag present on origin, or a GitHub
# release existing for the version — must stay exactly as fatal as today.
# An ambiguous release lookup (authentication, transport, or API failure) is
# not proof of absence and must fail closed without deleting the local tag.
#
# Expected RED reason: release-preflight.sh has no prune path, so the
# local-only unpublished case exits 1 with "release tag already exists
# locally" instead of passing. The three fatal cases are standing guards,
# green at introduction by design: they pin the prune to the narrowest
# possible state.
#
# Fixtures use non-default values (version 9.4.7, build 941, prior appcast
# 9.4.6/940, ci run 73, repository synthetic/preflight).
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
scripts="${repo_root}/Scripts"
fixture_command="${repo_root}/Tests/Scripts/Fixtures/Release/mock-command.sh"
temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT
mock_bin="${temporary_dir}/bin"
mkdir -p "$mock_bin"
for command in credential-gate font-gate release-gate scope-gate gh; do
  ln -s "$fixture_command" "${mock_bin}/${command}"
done
mock_log="${temporary_dir}/preflight-commands.log"
: >"$mock_log"
failures=0

# Preflight defaults DEVELOPER_DIR to Xcode-beta (the release runner's
# toolchain); on hosts without it (CI images) fall back to the selected
# toolchain so the passing case can reach manifest generation.
if [[ -z "${DEVELOPER_DIR:-}" && ! -d '/Applications/Xcode-beta.app/Contents/Developer' ]]; then
  DEVELOPER_DIR="$(xcode-select -p)"
  export DEVELOPER_DIR
fi

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

make_source_repo() {
  local name="$1"
  SOURCE_REPO="${temporary_dir}/source-${name}"
  ORIGIN_REPO="${temporary_dir}/origin-${name}.git"
  mkdir -p \
    "${SOURCE_REPO}/Apps/SupraAI/SupraAI.xcodeproj" \
    "${SOURCE_REPO}/SupraAI.xcworkspace/xcshareddata/swiftpm" \
    "${SOURCE_REPO}/website/public" \
    "${SOURCE_REPO}/website/lib"
  printf '%s\n' \
    'MARKETING_VERSION = 9.4.7;' \
    'CURRENT_PROJECT_VERSION = 941;' \
    >"${SOURCE_REPO}/Apps/SupraAI/SupraAI.xcodeproj/project.pbxproj"
  printf '%s\n' \
    '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>' \
    '<!-- APPCAST_ITEMS: synthetic -->' \
    '<item><sparkle:version>940</sparkle:version><sparkle:shortVersionString>9.4.6</sparkle:shortVersionString></item>' \
    '</channel></rss>' >"${SOURCE_REPO}/website/public/appcast.xml"
  printf '%s\n' \
    'export const FALLBACK_RELEASE_TAG = "v9.4.6";' \
    'export const FALLBACK_RELEASE_VERSION = "9.4.6";' \
    >"${SOURCE_REPO}/website/lib/constants.ts"
  printf '%s\n' '{"pins":[],"version":3}' \
    >"${SOURCE_REPO}/SupraAI.xcworkspace/xcshareddata/swiftpm/Package.resolved"
  git -C "$SOURCE_REPO" init -q -b main
  git -C "$SOURCE_REPO" config user.name 'Preflight Test'
  git -C "$SOURCE_REPO" config user.email 'preflight-test@example.invalid'
  git -C "$SOURCE_REPO" add .
  git -C "$SOURCE_REPO" commit -qm 'source fixture'
  git clone -q --bare "$SOURCE_REPO" "$ORIGIN_REPO"
  git -C "$SOURCE_REPO" remote add origin "$ORIGIN_REPO"
  SOURCE_SHA="$(git -C "$SOURCE_REPO" rev-parse HEAD)"
}

preflight() {
  local source_repo="$1"
  local expected_sha="$2"
  local output="$3"
  env \
    PATH="${mock_bin}:$PATH" \
    MOCK_RELEASE_LOG="$mock_log" \
    MOCK_CI_HEAD_SHA="${MOCK_CI_HEAD_SHA:-$expected_sha}" \
    SUPRA_PROTECTED_RELEASE_ENVIRONMENT=1 \
    SUPRA_RELEASE_TESTING=1 \
    SUPRA_GH_COMMAND="${mock_bin}/gh" \
    SUPRA_CREDENTIAL_GATE_COMMAND="${mock_bin}/credential-gate" \
    SUPRA_FONT_GUARD_COMMAND="${mock_bin}/font-gate" \
    SUPRA_RELEASE_GATE_COMMAND="${mock_bin}/release-gate" \
    SUPRA_SCOPE_GATE_COMMAND="${mock_bin}/scope-gate" \
    bash "${scripts}/release-preflight.sh" \
      --repo-root "$source_repo" \
      --repository synthetic/preflight \
      --version 9.4.7 \
      --build 941 \
      --expected-sha "$expected_sha" \
      --ci-run-id 73 \
      --output "$output"
}

# --- Case 1: local-only tag for an unpublished version is pruned -------------
# Expected RED reason: no prune path exists, so this exits 1 with "release tag
# already exists locally" instead of pruning and passing.
make_source_repo local-only
git -C "$SOURCE_REPO" tag v9.4.7
prune_output="${temporary_dir}/prune-pass.log"
prune_manifest="${temporary_dir}/prune-preflight.json"
prune_status=0
preflight "$SOURCE_REPO" "$SOURCE_SHA" "$prune_manifest" >"$prune_output" 2>&1 || prune_status=$?
if [[ "$prune_status" -ne 0 ]] \
  || ! grep -Fq 'Release source preflight passed for v9.4.7' "$prune_output"; then
  fail 'local-only unpublished tag did not prune and pass preflight'
  sed 's/^/  | /' "$prune_output" >&2
else
  printf '%s\n' 'PASS: local-only unpublished tag prunes and preflight passes'
fi
if ! grep -Fq 'Pruned stale local-only release tag v9.4.7' "$prune_output"; then
  fail 'prune pass did not report the pruned tag'
fi
# Wire-proof, scoped to the exact fatal output: the default refusal must be
# absent from the passing run.
if grep -Fq 'already exists' "$prune_output"; then
  fail 'prune pass still emitted a tag-already-exists refusal'
fi
if git -C "$SOURCE_REPO" show-ref --verify --quiet refs/tags/v9.4.7; then
  fail 'stale local tag survived the prune'
else
  printf '%s\n' 'PASS: stale local tag is actually deleted'
fi
if [[ -f "$prune_manifest" ]]; then
  jq -e --arg sha "$SOURCE_SHA" '
    .source.sha == $sha and .release.version == "9.4.7" and
    .release.build == "941" and .ciRuns[0].id == "73" and
    .gates.sourceValidation == "reused-exact-sha-ci"
  ' "$prune_manifest" >/dev/null \
    || fail 'prune-pass manifest did not bind SHA/version/build/CI'
else
  fail 'prune pass did not create its manifest'
fi

# --- Case 2: ambiguous release lookup fails closed before pruning ------------
# Expected RED reason: the current preflight treats every nonzero
# `gh release view` result as "release absent", deletes the local tag, and
# continues. The mock's non-not-found failure therefore destroys the sentinel
# tag and reaches a passing preflight instead of returning this refusal.
make_source_repo local-lookup-error
git -C "$SOURCE_REPO" tag v9.4.7
lookup_error_output="${temporary_dir}/local-lookup-error.log"
lookup_error_status=0
MOCK_RELEASE_LOOKUP_ERROR=1 preflight "$SOURCE_REPO" "$SOURCE_SHA" \
  "${temporary_dir}/local-lookup-error.json" >"$lookup_error_output" 2>&1 \
  || lookup_error_status=$?
if [[ "$lookup_error_status" -ne 1 ]] \
  || ! grep -Fq 'unable to confirm GitHub release state' "$lookup_error_output"; then
  fail 'ambiguous GitHub release lookup did not fail closed before pruning'
  sed 's/^/  | /' "$lookup_error_output" >&2
else
  printf '%s\n' 'PASS: ambiguous GitHub release lookup fails closed'
fi
git -C "$SOURCE_REPO" show-ref --verify --quiet refs/tags/v9.4.7 \
  || fail 'ambiguous release lookup pruned the local tag'

# --- Case 3: release-read permission is proven before accepting a 404 --------
# Expected RED reason: preflight checks generic repository metadata but never
# probes the releases collection, so this permission denial is not observed;
# the tag-endpoint 404 is accepted as absence and the local tag is deleted.
make_source_repo release-permission-denied
git -C "$SOURCE_REPO" tag v9.4.7
permission_output="${temporary_dir}/release-permission-denied.log"
permission_status=0
MOCK_RELEASE_PERMISSION_DENIED=1 preflight "$SOURCE_REPO" "$SOURCE_SHA" \
  "${temporary_dir}/release-permission-denied.json" >"$permission_output" 2>&1 \
  || permission_status=$?
if [[ "$permission_status" -ne 1 ]] \
  || ! grep -Fq 'unable to confirm GitHub release read permission' "$permission_output"; then
  fail 'missing release-read permission did not fail closed before pruning'
  sed 's/^/  | /' "$permission_output" >&2
else
  printf '%s\n' 'PASS: release-read permission is required before tag lookup'
fi
git -C "$SOURCE_REPO" show-ref --verify --quiet refs/tags/v9.4.7 \
  || fail 'release-read permission failure pruned the local tag'

# --- Case 4 (standing guard): local tag + published release stays fatal ------
# The prune must never fire when a GitHub release exists for the version even
# though the tag is absent from origin — that state is a real publication.
make_source_repo local-published
git -C "$SOURCE_REPO" tag v9.4.7
published_output="${temporary_dir}/local-published.log"
published_status=0
MOCK_RELEASE_EXISTS=1 preflight "$SOURCE_REPO" "$SOURCE_SHA" \
  "${temporary_dir}/local-published.json" >"$published_output" 2>&1 || published_status=$?
if [[ "$published_status" -ne 1 ]] \
  || ! grep -Fq 'release tag already exists locally' "$published_output"; then
  fail 'local tag with a published release did not stay fatal'
  sed 's/^/  | /' "$published_output" >&2
else
  printf '%s\n' 'PASS: local tag with a published release stays fatal'
fi
git -C "$SOURCE_REPO" show-ref --verify --quiet refs/tags/v9.4.7 \
  || fail 'fatal published-release case pruned the local tag anyway'

# --- Case 5 (standing guard): local tag also on origin stays fatal -----------
make_source_repo local-and-origin
git -C "$SOURCE_REPO" tag v9.4.7
git -C "$SOURCE_REPO" push --quiet origin v9.4.7
origin_local_output="${temporary_dir}/local-and-origin.log"
origin_local_status=0
preflight "$SOURCE_REPO" "$SOURCE_SHA" \
  "${temporary_dir}/local-and-origin.json" >"$origin_local_output" 2>&1 || origin_local_status=$?
if [[ "$origin_local_status" -ne 1 ]] \
  || ! grep -Fq 'release tag already exists locally' "$origin_local_output"; then
  fail 'local tag that is also on origin did not stay fatal'
  sed 's/^/  | /' "$origin_local_output" >&2
else
  printf '%s\n' 'PASS: local tag that is also on origin stays fatal'
fi
git -C "$SOURCE_REPO" show-ref --verify --quiet refs/tags/v9.4.7 \
  || fail 'fatal on-origin case pruned the local tag anyway'

# --- Case 6 (standing guard): origin-only tag stays fatal --------------------
make_source_repo origin-only
git -C "$ORIGIN_REPO" update-ref refs/tags/v9.4.7 "$SOURCE_SHA"
origin_only_output="${temporary_dir}/origin-only.log"
origin_only_status=0
preflight "$SOURCE_REPO" "$SOURCE_SHA" \
  "${temporary_dir}/origin-only.json" >"$origin_only_output" 2>&1 || origin_only_status=$?
if [[ "$origin_only_status" -ne 1 ]] \
  || ! grep -Fq 'release tag already exists on origin' "$origin_only_output"; then
  fail 'origin-only tag did not stay fatal'
  sed 's/^/  | /' "$origin_only_output" >&2
else
  printf '%s\n' 'PASS: origin-only tag stays fatal'
fi

if (( failures != 0 )); then
  printf 'Release preflight stale-tag tests failed: %d\n' "$failures" >&2
  exit 1
fi
printf '%s\n' 'All release preflight stale-tag tests passed.'
