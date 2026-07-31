#!/usr/bin/env bash
# Hermetic gating tests for Scripts/release-rehearsal-required.sh — the
# deterministic signed-rehearsal scope verdict.
#
# The runbook requires a signed rehearsal before the next production release
# whenever release machinery changed since the last green signed run. That
# decision has been doc-plus-judgment only, and it over-triggers: orchestration
# scripts (cut-release, dispatch, finish, preflight) consume only git/GitHub
# state, are fully covered by the hermetic harnesses in protected CI, and a
# green rehearsal exercises none of their fail-paths anyway — yet each edit
# re-armed a ~2h rehearsal. The helper classifies the diff since the last
# green signed run: only signed-output machinery (scripts whose inputs are
# real signing/notarization/packaging tool behavior, the release workflows,
# entitlements, provisioning) re-arms the rehearsal.
#
# Exit-code contract (fail-safe by construction): exit 0 means NO rehearsal is
# required — the only "proceed" signal; ANY nonzero exit (a REQUIRED verdict,
# a usage error, an unresolvable baseline, release_die) means rehearse first.
# A crash can therefore never read as permission to skip.
#
# Expected RED reason: Scripts/release-rehearsal-required.sh does not exist,
# so every invocation exits 127 — the exit-0 cases fail outright and the
# nonzero cases fail their required-output assertions.
#
# Fixtures use non-default values (synthetic repos under mktemp, baseline
# sentinel file contents 'fixture-v1'/'fixture-v2', mock green SHA from the
# fixture repo itself).
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
scripts="${repo_root}/Scripts"
helper="${scripts}/release-rehearsal-required.sh"
temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT
mock_bin="${temporary_dir}/bin"
mkdir -p "$mock_bin"
failures=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

run_case() {
  local name="$1"
  local expected_status="$2"
  local expected_text="$3"
  shift 3
  local output="${temporary_dir}/case-${RANDOM}.log"
  local result=0
  "$@" >"$output" 2>&1 || result=$?
  if [[ "$result" -ne "$expected_status" ]]; then
    fail "${name}: expected status ${expected_status}, got ${result}"
    sed 's/^/  | /' "$output" >&2
  elif ! grep -Fq -- "$expected_text" "$output"; then
    fail "${name}: expected output to contain: ${expected_text}"
    sed 's/^/  | /' "$output" >&2
  else
    printf 'PASS: %s\n' "$name"
  fi
  LAST_CASE_OUTPUT="$output"
}

make_fixture_repo() {
  local name="$1"
  FIXTURE_REPO="${temporary_dir}/fixture-${name}"
  mkdir -p \
    "${FIXTURE_REPO}/Scripts/lib" \
    "${FIXTURE_REPO}/.github/workflows" \
    "${FIXTURE_REPO}/Apps/SupraAI/SupraAI" \
    "${FIXTURE_REPO}/Apps/SupraAI/SupraAI.xcodeproj" \
    "${FIXTURE_REPO}/Docs"
  printf '%s\n' 'fixture-v1' >"${FIXTURE_REPO}/Scripts/release.sh"
  printf '%s\n' 'fixture-v1' >"${FIXTURE_REPO}/Scripts/publish-release-transaction.sh"
  printf '%s\n' 'fixture-v1' >"${FIXTURE_REPO}/Scripts/publish-release-appcast.sh"
  printf '%s\n' 'fixture-v1' >"${FIXTURE_REPO}/Scripts/rollback-release-appcast.sh"
  printf '%s\n' 'fixture-v1' >"${FIXTURE_REPO}/Scripts/cut-release.sh"
  printf '%s\n' 'fixture-v1' >"${FIXTURE_REPO}/Scripts/lib/release-common.sh"
  printf '%s\n' 'fixture-v1' >"${FIXTURE_REPO}/.github/workflows/release.yml"
  printf '%s\n' 'fixture-v1' >"${FIXTURE_REPO}/Apps/SupraAI/SupraAI/AppMain.swift"
  printf '%s\n' 'fixture-v1' >"${FIXTURE_REPO}/Apps/SupraAI/SupraAI/SupraAI.entitlements"
  printf '%s\n' 'fixture-v1' >"${FIXTURE_REPO}/Apps/SupraAI/SupraAI.xcodeproj/project.pbxproj"
  printf '%s\n' 'fixture-v1' >"${FIXTURE_REPO}/Docs/notes.md"
  git -C "$FIXTURE_REPO" init -q -b main
  git -C "$FIXTURE_REPO" config user.name 'Rehearsal Scope Test'
  git -C "$FIXTURE_REPO" config user.email 'rehearsal-scope@example.invalid'
  git -C "$FIXTURE_REPO" add .
  git -C "$FIXTURE_REPO" commit -qm 'baseline: last green signed run'
  BASE_SHA="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"
}

commit_change() {
  local path="$1"
  printf '%s\n' 'fixture-v2' >"${FIXTURE_REPO}/${path}"
  git -C "$FIXTURE_REPO" add -A
  git -C "$FIXTURE_REPO" commit -qm "change ${path}"
}

verdict() {
  bash "$helper" --repo-root "$FIXTURE_REPO" --base "$BASE_SHA"
}

required_verdict='VERDICT: signed rehearsal REQUIRED'
not_required_verdict='VERDICT: no signed rehearsal required'
toolchain_reminder='invisible to this diff'
production_only_listing='production-only publish path'

# --- Signed-output machinery re-arms the rehearsal ---------------------------
make_fixture_repo transaction-driver
commit_change Scripts/release.sh
run_case \
  'changing the release transaction driver requires a rehearsal' \
  1 "$required_verdict" verdict
grep -Fq 'Scripts/release.sh' "$LAST_CASE_OUTPUT" \
  || fail 'required verdict does not name the triggering path'
grep -Fq "$toolchain_reminder" "$LAST_CASE_OUTPUT" \
  || fail 'required verdict omits the toolchain-invisibility reminder'

make_fixture_repo workflow
commit_change .github/workflows/release.yml
run_case \
  'changing the release workflow requires a rehearsal' \
  1 "$required_verdict" verdict

make_fixture_repo shared-lib
commit_change Scripts/lib/release-common.sh
run_case \
  'changing the shared release library requires a rehearsal' \
  1 "$required_verdict" verdict

make_fixture_repo entitlements
commit_change Apps/SupraAI/SupraAI/SupraAI.entitlements
run_case \
  'changing app entitlements requires a rehearsal' \
  1 "$required_verdict" verdict

# --- Fail-safe: unclassified machinery-shaped paths re-arm -------------------
make_fixture_repo unclassified
commit_change Scripts/release-mystery.sh
run_case \
  'an unclassified release-machinery script fails safe to required' \
  1 "$required_verdict" verdict
grep -Fq 'unclassified' "$LAST_CASE_OUTPUT" \
  || fail 'fail-safe verdict does not say the path is unclassified'

# --- Production-only publish path does not re-arm ----------------------------
# Scripts/release.sh under --no-publish exits before it would invoke
# Scripts/publish-release-transaction.sh (release.sh, publish gate), so a
# rehearsal is STRUCTURALLY INCAPABLE of exercising the publish/rollback
# scripts; their only real coverage is the hermetic suite
# Tests/Scripts/test-release-transaction.sh. They must not re-arm a rehearsal,
# but the verdict must stay honest by listing them under a distinct
# production-only heading.
#
# Expected RED reason: the helper still classifies these scripts as
# signed-output machinery, so each run exits 1 with the REQUIRED verdict —
# the exit-0 expectation and the production-only listing assertion both fail.
make_fixture_repo publish-transaction
commit_change Scripts/publish-release-transaction.sh
run_case \
  'changing only the publish transaction does not require a rehearsal' \
  0 "$production_only_listing" verdict
grep -Fq 'Scripts/publish-release-transaction.sh' "$LAST_CASE_OUTPUT" \
  || fail 'production-only listing does not name the publish transaction script'
grep -Fq "$not_required_verdict" "$LAST_CASE_OUTPUT" \
  || fail 'publish-transaction-only run omits the not-required verdict'
# Wire-proof, scoped to the exact opposite verdict line: the REQUIRED verdict
# must be absent when only the rehearsal-unreachable publish path changed.
grep -Fq "$required_verdict" "$LAST_CASE_OUTPUT" \
  && fail 'publish-transaction-only run still printed the REQUIRED verdict'

make_fixture_repo appcast-rollback
commit_change Scripts/rollback-release-appcast.sh
run_case \
  'changing only the appcast rollback does not require a rehearsal' \
  0 "$production_only_listing" verdict
grep -Fq 'Scripts/rollback-release-appcast.sh' "$LAST_CASE_OUTPUT" \
  || fail 'production-only listing does not name the appcast rollback script'
grep -Fq "$not_required_verdict" "$LAST_CASE_OUTPUT" \
  || fail 'appcast-rollback-only run omits the not-required verdict'
grep -Fq "$required_verdict" "$LAST_CASE_OUTPUT" \
  && fail 'appcast-rollback-only run still printed the REQUIRED verdict'

# Standing guard (expected to pass at RED and at GREEN by design): the
# reclassification above must not swallow Scripts/release.sh itself — its
# build/sign/notarize path IS exactly what a rehearsal exercises.
make_fixture_repo publish-guard
commit_change Scripts/release.sh
run_case \
  'standing guard: the release driver itself still requires a rehearsal' \
  1 "$required_verdict" verdict

# --- Hermetically covered orchestration does not re-arm ----------------------
make_fixture_repo orchestration
commit_change Scripts/cut-release.sh
run_case \
  'changing orchestration only does not require a rehearsal' \
  0 "$not_required_verdict" verdict
grep -Fq 'Scripts/cut-release.sh' "$LAST_CASE_OUTPUT" \
  || fail 'not-required verdict does not list the hermetically covered machinery'
# Wire-proof, scoped to the exact opposite verdict line: the REQUIRED verdict
# must be absent from a not-required run.
grep -Fq "$required_verdict" "$LAST_CASE_OUTPUT" \
  && fail 'not-required run still printed the REQUIRED verdict'
grep -Fq "$toolchain_reminder" "$LAST_CASE_OUTPUT" \
  || fail 'not-required verdict omits the toolchain-invisibility reminder'

# --- Product code and routine metadata do not re-arm -------------------------
make_fixture_repo product
commit_change Apps/SupraAI/SupraAI/AppMain.swift
commit_change Apps/SupraAI/SupraAI.xcodeproj/project.pbxproj
commit_change Docs/notes.md
run_case \
  'product code, pbxproj, and docs changes do not require a rehearsal' \
  0 "$not_required_verdict" verdict
grep -Fq 'review signing-setting diffs' "$LAST_CASE_OUTPUT" \
  || fail 'pbxproj change did not print the signing-settings review note'

make_fixture_repo unchanged
run_case \
  'an unchanged tree does not require a rehearsal' \
  0 "$not_required_verdict" verdict

# --- Fail-safe error paths ---------------------------------------------------
make_fixture_repo bad-base
BASE_SHA='zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz'
run_case \
  'an unresolvable baseline fails safe with a nonzero exit' \
  1 'unable to resolve the rehearsal baseline' verdict

# --- Baseline auto-derivation from the last green signed run -----------------
cat >"${mock_bin}/gh" <<'MOCK'
#!/usr/bin/env bash
if [[ "${MOCK_GH_FAIL:-0}" == '1' ]]; then
  exit 1
fi
printf '[{"headSha":"%s","conclusion":"success","createdAt":"2026-07-19T18:28:00Z"}]\n' \
  "${MOCK_GREEN_SHA:?}"
MOCK
chmod +x "${mock_bin}/gh"

derive_verdict() {
  env \
    SUPRA_RELEASE_TESTING=1 \
    SUPRA_GH_COMMAND="${mock_bin}/gh" \
    MOCK_GREEN_SHA="$BASE_SHA" \
    bash "$helper" --repo-root "$FIXTURE_REPO"
}

make_fixture_repo derive
commit_change Scripts/cut-release.sh
run_case \
  'omitting --base derives the baseline from the last green signed run' \
  0 "$not_required_verdict" derive_verdict

derive_verdict_gh_down() {
  env \
    SUPRA_RELEASE_TESTING=1 \
    SUPRA_GH_COMMAND="${mock_bin}/gh" \
    MOCK_GREEN_SHA="$BASE_SHA" \
    MOCK_GH_FAIL=1 \
    bash "$helper" --repo-root "$FIXTURE_REPO"
}

run_case \
  'an underivable baseline fails safe and asks for --base' \
  1 'pass --base' derive_verdict_gh_down

if (( failures != 0 )); then
  printf 'Rehearsal-scope verdict tests failed: %d\n' "$failures" >&2
  exit 1
fi
printf '%s\n' 'All rehearsal-scope verdict tests passed.'
