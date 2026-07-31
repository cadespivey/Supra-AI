#!/usr/bin/env bash
# Hermetic gating tests for Scripts/cut-release.sh — the one-command release:
# preflight, version/changelog candidate, PR with babysat CI (bounded reruns of
# GitHub's "Set up job" infrastructure flakes only), merge, main-CI wait,
# dispatch, deployment-gate approval (auto unless --hold), and finish. Every
# GitHub, dispatch, finish, console, and process interaction goes through
# command shims recorded in a log; git runs against a fixture origin.
#
# Expected RED reason: Scripts/cut-release.sh does not exist yet, so every case
# exits with bash's missing-file status (127) instead of the expected behavior.
#
# Fixtures use non-default values (9.4.7 -> 9.4.8, build 941 -> 942, run ids
# 88001/88002/88003).
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cut="${repo_root}/Scripts/cut-release.sh"
failures=0

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

bin="${workdir}/bin"
state="${workdir}/state"
shim_log="${workdir}/shim.log"
mkdir -p "$bin" "$state"
: >"$shim_log"

# gh shim: run discovery/polling driven by per-run-id plans (space-separated
# tokens; "failure"/"success" mean completed with that conclusion; the last
# token repeats once a plan is exhausted).
cat >"${bin}/gh" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh %s\n' "$*" >>"${SHIM_LOG:?}"
plan_token() {
  local run_id="$1"
  local plan_variable="SHIM_RUN_${run_id}_PLAN"
  local plan="${!plan_variable:-success}"
  local counter_file="${SHIM_STATE:?}/plan-${run_id}"
  local count=0
  [[ -f "$counter_file" ]] && count="$(cat "$counter_file")"
  count=$((count + 1))
  printf '%s\n' "$count" >"$counter_file"
  local tokens=($plan)
  local index=$((count - 1))
  (( index >= ${#tokens[@]} )) && index=$(( ${#tokens[@]} - 1 ))
  printf '%s' "${tokens[$index]}"
}
run_json_for_token() {
  local run_id="$1" token="$2" sha="$3"
  case "$token" in
    stale) printf '{"databaseId":%s,"headSha":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","status":"completed","conclusion":"success","url":"https://example.invalid/runs/%s"}' "$run_id" "$run_id" ;;
    success) printf '{"databaseId":%s,"headSha":"%s","status":"completed","conclusion":"success","url":"https://example.invalid/runs/%s"}' "$run_id" "$sha" "$run_id" ;;
    failure) printf '{"databaseId":%s,"headSha":"%s","status":"completed","conclusion":"failure","url":"https://example.invalid/runs/%s"}' "$run_id" "$sha" "$run_id" ;;
    waiting) printf '{"databaseId":%s,"headSha":"%s","status":"waiting","conclusion":"","url":"https://example.invalid/runs/%s"}' "$run_id" "$sha" "$run_id" ;;
    *) printf '{"databaseId":%s,"headSha":"%s","status":"%s","conclusion":"","url":"https://example.invalid/runs/%s"}' "$run_id" "$sha" "$token" "$run_id" ;;
  esac
}
case "${1:-} ${2:-}" in
  'auth status') exit 0 ;;
  'pr create')
    printf 'https://example.invalid/pull/9\n'
    exit 0 ;;
  'pr merge') exit 0 ;;
  'run list')
    branch=''; workflow=''
    args=("$@")
    for (( i = 0; i < ${#args[@]}; i++ )); do
      [[ "${args[$i]}" == '--branch' ]] && branch="${args[$((i+1))]:-}"
      [[ "${args[$i]}" == '--workflow' ]] && workflow="${args[$((i+1))]:-}"
    done
    if [[ "$workflow" == *'production release'* || "$workflow" == *'rehearsal'* ]]; then
      run_id=88003
      sha='cccccccccccccccccccccccccccccccccccccccc'
    elif [[ "$branch" == 'main' ]]; then
      run_id=88002
      sha="${SHIM_MAIN_SHA:?}"
    else
      run_id=88001
      sha="${SHIM_BRANCH_SHA:?}"
    fi
    token="$(plan_token "list-${run_id}")"
    if [[ "$token" == 'absent' ]]; then
      printf '[]\n'
    else
      printf '[%s]\n' "$(run_json_for_token "$run_id" "$token" "$sha")"
    fi
    exit 0 ;;
  'run view')
    run_id="$3"
    if [[ " $* " == *" --json jobs"* ]]; then
      # A brace-laden default inside ${var:-...} mis-parses and appends a stray
      # brace to set values, so default explicitly.
      jobs_variable="SHIM_RUN_${run_id}_JOBS"
      jobs_value="${!jobs_variable:-}"
      [[ -n "$jobs_value" ]] || jobs_value='{"jobs":[]}'
      printf '%s\n' "$jobs_value"
      exit 0
    fi
    token="$(plan_token "view-${run_id}")"
    sha='dddddddddddddddddddddddddddddddddddddddd'
    printf '%s\n' "$(run_json_for_token "$run_id" "$token" "$sha")"
    exit 0 ;;
  'run rerun')
    exit 0 ;;
  'api '*)
    if [[ " $* " == *' --method POST '* || " $* " == *'-f state=approved'* ]]; then
      printf '[]\n'
    else
      printf '[{"environment":{"id":777001}}]\n'
    fi
    exit 0 ;;
esac
exit 0
SHIM

cat >"${bin}/dispatch" <<'SHIM'
#!/usr/bin/env bash
printf 'dispatch %s\n' "$*" >>"${SHIM_LOG:?}"
exit "${SHIM_DISPATCH_STATUS:-0}"
SHIM

cat >"${bin}/finish" <<'SHIM'
#!/usr/bin/env bash
printf 'finish %s\n' "$*" >>"${SHIM_LOG:?}"
if [[ "${SHIM_FINISH_STATUS:-0}" == '0' ]]; then
  printf 'Release v9.4.8 is published and verified.\n'
fi
exit "${SHIM_FINISH_STATUS:-0}"
SHIM

cat >"${bin}/console-check" <<'SHIM'
#!/usr/bin/env bash
printf 'console-check\n' >>"${SHIM_LOG:?}"
exit "${SHIM_CONSOLE_LOCKED:-0}"
SHIM

cat >"${bin}/caffeinate" <<'SHIM'
#!/usr/bin/env bash
printf 'caffeinate\n' >>"${SHIM_LOG:?}"
exec sleep 3600
SHIM

cat >"${bin}/pgrep" <<'SHIM'
#!/usr/bin/env bash
printf 'pgrep %s\n' "$*" >>"${SHIM_LOG:?}"
exit "${SHIM_RUNNER_RUNNING:-1}"
SHIM
chmod +x "${bin}/gh" "${bin}/dispatch" "${bin}/finish" "${bin}/console-check" \
  "${bin}/caffeinate" "${bin}/pgrep"

# Fixture repository: reviewed metadata 9.4.7 (941) and a Keep-a-Changelog file.
make_fixture() {
  seed="${workdir}/seed-${RANDOM}"
  origin="${workdir}/origin-${RANDOM}.git"
  clone="${workdir}/clone-${RANDOM}"
  mkdir -p "${seed}/Apps/SupraAI/SupraAI.xcodeproj" "${seed}/Scripts"
  {
    printf '// !$*UTF8*$!\n{\n'
    for configuration in AppDebug AppRelease XPCDebug XPCRelease; do
      printf '\t\t\tbuildSettings = {\n'
      printf '\t\t\t\tCONFIGURATION = %s;\n' "$configuration"
      printf '\t\t\t\tCURRENT_PROJECT_VERSION = 941;\n'
      printf '\t\t\t\tMARKETING_VERSION = 9.4.7;\n'
      printf '\t\t\t};\n'
    done
    printf '}\n'
  } >"${seed}/Apps/SupraAI/SupraAI.xcodeproj/project.pbxproj"
  printf '# Changelog\n\nIntro text.\n\n## [Unreleased]\n\n### Added\n\n- Pending entry.\n\n## [9.4.7] - 2099-01-01\n\n### Fixed\n\n- Old entry.\n' \
    >"${seed}/CHANGELOG.md"
  git -C "$seed" init --quiet --initial-branch=main
  git -C "$seed" -c user.name=fixture -c user.email=fixture@example.invalid add -A
  git -C "$seed" -c user.name=fixture -c user.email=fixture@example.invalid \
    commit --quiet -m 'fixture candidate'
  git clone --quiet --bare "$seed" "$origin"
  git clone --quiet "$origin" "$clone"
  git -C "$clone" config user.name fixture
  git -C "$clone" config user.email fixture@example.invalid
  fixture_main_sha="$(git -C "$clone" rev-parse HEAD)"
}

notes="${workdir}/notes.md"
printf '### Fixed\n\n- A user-facing fix.\n' >"$notes"

cut_status=0
cut_output="${workdir}/output.txt"

run_cut() {
  local extra_env=()
  while (( $# > 0 )) && [[ "$1" != '--' ]]; do
    extra_env+=("$1")
    shift
  done
  [[ "${1:-}" == '--' ]] && shift
  : >"$shim_log"
  rm -f "${state}"/plan-* 2>/dev/null || true
  cut_status=0
  (
    cd "$clone" && env \
      SUPRA_RELEASE_TESTING=1 \
      SUPRA_RELEASE_CHECK_POLL_SECONDS=0 \
      SUPRA_CUT_MAX_CI_POLLS=8 \
      SUPRA_GH_COMMAND="${bin}/gh" \
      SUPRA_DISPATCH_COMMAND="${bin}/dispatch" \
      SUPRA_FINISH_COMMAND="${bin}/finish" \
      SUPRA_CONSOLE_CHECK_COMMAND="${bin}/console-check" \
      SUPRA_CAFFEINATE_COMMAND="${bin}/caffeinate" \
      SUPRA_PGREP_COMMAND="${bin}/pgrep" \
      SHIM_LOG="$shim_log" \
      SHIM_STATE="$state" \
      SHIM_MAIN_SHA="$fixture_main_sha" \
      SHIM_BRANCH_SHA='branch-sha-unused' \
      ${extra_env[@]+"${extra_env[@]}"} \
      bash "$cut" "$@"
  ) >"$cut_output" 2>&1 || cut_status=$?
}

expect() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'PASS: %s\n' "$name"
  else
    printf 'FAIL: %s\n' "$name" >&2
    failures=$((failures + 1))
  fi
}

expect_status() {
  local name="$1" expected="$2"
  if [[ "$cut_status" -eq "$expected" ]]; then
    printf 'PASS: %s\n' "$name"
  else
    printf 'FAIL: %s: expected status %s, got %s\n' "$name" "$expected" "$cut_status" >&2
    sed 's/^/  | /' "$cut_output" >&2
    failures=$((failures + 1))
  fi
}

log_line_number() {
  grep -n -- "$1" "$shim_log" | head -1 | cut -d: -f1
}

# NOTE: cut-release's MAIN-CI waits are SHA-aware: right after a merge, the
# newest completed run on main belongs to the PREVIOUS commit, and accepting
# it hands dispatch a SHA it must refuse (observed live on the third
# rehearsal). The candidate-branch wait stays newest-run (the branch is fresh
# and exclusive); dispatch and the protected transaction remain the fail-closed
# exact-SHA gates either way.

# --- Preflight: a dirty tree is refused before any GitHub interaction -------
make_fixture
printf 'scratch\n' >"${clone}/dirty.txt"
run_cut -- --patch --notes-file "$notes"
expect_status 'dirty tree is refused' 1
expect 'dirty tree is named' grep -Fiq 'clean' "$cut_output"
expect 'dirty tree performs no GitHub calls' \
  bash -c "! grep -q '^gh ' '$shim_log'"

# --- Preflight: production cut requires release notes ------------------------
make_fixture
run_cut -- --patch
expect_status 'missing notes file is refused' 1
expect 'missing notes are named' grep -Fiq 'notes' "$cut_output"

# --- Preflight: a locked console is refused (the v2.3.2 notary failure) -----
make_fixture
run_cut SHIM_CONSOLE_LOCKED=1 -- --patch --notes-file "$notes"
expect_status 'locked console is refused' 1
expect 'locked console is named' grep -Fiq 'console' "$cut_output"

# --- Preflight: an already-running runner is refused -------------------------
make_fixture
run_cut SHIM_RUNNER_RUNNING=0 -- --patch --notes-file "$notes"
expect_status 'running release runner is refused' 1
expect 'running runner is named' grep -Fiq 'runner' "$cut_output"

# --- Happy path: candidate, babysat CI, merge, dispatch, approve, finish ----
make_fixture
# The transaction plan models GitHub's REAL run lifecycle: a freshly
# dispatched run reports 'queued' (or 'requested'/'pending') BEFORE 'waiting'.
# (Fixture revised in RED: the first live rehearsal hit exactly this — the
# approval loop treated the pre-waiting status as "already past the gate",
# broke without approving, and finish watched an unapproved run for hours.)
run_cut \
  "SHIM_RUN_list-88001_PLAN=success" \
  "SHIM_RUN_list-88002_PLAN=success" \
  "SHIM_RUN_list-88003_PLAN=queued waiting in_progress" \
  "SHIM_RUN_view-88003_PLAN=in_progress success" \
  -- --patch --notes-file "$notes"
expect_status 'one-command production cut succeeds' 0
expect 'candidate version was bumped on the release branch' \
  bash -c "git -C '$origin' show 'release/9.4.8:Apps/SupraAI/SupraAI.xcodeproj/project.pbxproj' | grep -q 'MARKETING_VERSION = 9.4.8;'"
expect 'candidate build was bumped on the release branch' \
  bash -c "git -C '$origin' show 'release/9.4.8:Apps/SupraAI/SupraAI.xcodeproj/project.pbxproj' | grep -q 'CURRENT_PROJECT_VERSION = 942;'"
expect 'changelog entry was written from the notes file' \
  bash -c "git -C '$origin' show 'release/9.4.8:CHANGELOG.md' | grep -q '## \[9.4.8\]' && git -C '$origin' show 'release/9.4.8:CHANGELOG.md' | grep -q 'A user-facing fix'"
# Keep-a-Changelog ordering: the release entry lands BELOW [Unreleased] and
# above the previous version. Expected RED reason: insertion targets the first
# '## [' header, which is [Unreleased], so the release lands above it.
expect 'changelog entry lands below Unreleased and above the prior version' \
  bash -c "git -C '$origin' show 'release/9.4.8:CHANGELOG.md' \
    | grep -E '^## \[' | head -3 | tr '\n' ' ' \
    | grep -Eq 'Unreleased.*\[9\.4\.8.*\[9\.4\.7'"
expect 'deployment gate was auto-approved' \
  grep -Eq 'gh api .*-f state=approved' "$shim_log"
expect 'finish received the transaction run id' \
  grep -Eq 'finish .*--run 88003' "$shim_log"
expect 'operator sees the live verdict' \
  grep -Fq 'is live' "$cut_output"
pr_line="$(log_line_number 'gh pr create')"
merge_line="$(log_line_number 'gh pr merge')"
dispatch_line="$(log_line_number '^dispatch')"
approve_line="$(log_line_number '\-f state=approved')"
finish_line="$(log_line_number '^finish')"
expect 'orchestration order is pr -> merge -> dispatch -> approve -> finish' \
  bash -c "test -n '$pr_line' -a -n '$merge_line' -a -n '$dispatch_line' -a -n '$approve_line' -a -n '$finish_line' \
    && test '$pr_line' -lt '$merge_line' -a '$merge_line' -lt '$dispatch_line' \
    && test '$dispatch_line' -lt '$approve_line' -a '$approve_line' -lt '$finish_line'"

# --- Infrastructure flake: "Set up job" failures rerun (bounded), then pass --
make_fixture
setup_flake_jobs='{"jobs":[{"name":"Document benchmark deterministic gates","conclusion":"failure","steps":[{"name":"Set up job","conclusion":"failure"}]}]}'
run_cut \
  "SHIM_RUN_list-88001_PLAN=failure success" \
  "SHIM_RUN_88001_JOBS=${setup_flake_jobs}" \
  "SHIM_RUN_list-88002_PLAN=success" \
  "SHIM_RUN_list-88003_PLAN=in_progress" \
  "SHIM_RUN_view-88003_PLAN=success" \
  -- --patch --notes-file "$notes"
expect_status 'setup-job flake is rerun and the cut proceeds' 0
expect 'flaked run was rerun' grep -Fq 'gh run rerun 88001 --failed' "$shim_log"

# --- Real CI failure: no rerun, no merge, no dispatch ------------------------
make_fixture
real_failure_jobs='{"jobs":[{"name":"Swift package - SupraCore","conclusion":"failure","steps":[{"name":"Test fixed package","conclusion":"failure"}]}]}'
run_cut \
  "SHIM_RUN_list-88001_PLAN=failure" \
  "SHIM_RUN_88001_JOBS=${real_failure_jobs}" \
  -- --patch --notes-file "$notes"
expect_status 'a real CI failure aborts the cut' 1
expect 'real failure is not rerun' \
  bash -c "! grep -Fq 'gh run rerun' '$shim_log'"
expect 'real failure blocks the merge' \
  bash -c "! grep -Fq 'gh pr merge' '$shim_log'"
expect 'real failure blocks the dispatch' \
  bash -c "! grep -q '^dispatch' '$shim_log'"

# --- Bounded reruns: a persistent flake cannot loop forever ------------------
make_fixture
run_cut \
  "SHIM_RUN_list-88001_PLAN=failure failure failure" \
  "SHIM_RUN_88001_JOBS=${setup_flake_jobs}" \
  SUPRA_CUT_FLAKE_RERUNS=1 \
  -- --patch --notes-file "$notes"
expect_status 'persistent flakes exhaust the rerun budget and abort' 1
expect 'rerun budget is bounded' \
  bash -c "test \"\$(grep -c 'gh run rerun' '$shim_log')\" -eq 1"

# --- --hold: no auto-approval; the gate is waited out ------------------------
make_fixture
run_cut \
  "SHIM_RUN_list-88001_PLAN=success" \
  "SHIM_RUN_list-88002_PLAN=success" \
  "SHIM_RUN_list-88003_PLAN=queued waiting in_progress" \
  "SHIM_RUN_view-88003_PLAN=success" \
  -- --patch --notes-file "$notes" --hold
expect_status 'held cut succeeds after manual approval' 0
expect 'held cut never auto-approves' \
  bash -c "! grep -Eq 'gh api .*-f state=approved' '$shim_log'"
expect 'held cut tells the operator where to approve' \
  grep -Fiq 'approve' "$cut_output"

# --- --rehearsal: no candidate, dispatch and finish in rehearsal mode --------
make_fixture
# The main plan leads with a completed-green run for the WRONG sha (the
# pre-merge run): the wait must poll past it to the matching one. Expected RED
# reason: the wait accepts the newest completed run regardless of headSha, so
# only ONE main run-list call is recorded.
run_cut \
  "SHIM_RUN_list-88002_PLAN=stale success" \
  "SHIM_RUN_list-88003_PLAN=waiting in_progress" \
  "SHIM_RUN_view-88003_PLAN=success" \
  -- --rehearsal
expect_status 'rehearsal cut succeeds' 0
expect 'rehearsal polls past a stale main CI run' \
  bash -c "test \"\$(grep -c 'run list --branch main' '$shim_log')\" -ge 2"
expect 'rehearsal dispatches in rehearsal mode' \
  grep -Eq '^dispatch .*--rehearsal' "$shim_log"
# One command means WAITING, not failing fast: the first live rehearsal
# dispatched seconds after its own prerequisite fix merged to main and died on
# "no green Protected macOS CI run exists for origin/main". Rehearsal mode must
# wait for green main CI before dispatching, exactly like the production path.
# Expected RED reason: rehearsal mode performs no CI wait, so no main run-list
# call precedes the dispatch.
rehearsal_main_ci_line="$( { grep -n -- 'run list --branch main' "$shim_log" || true; } | head -1 | cut -d: -f1)"
rehearsal_dispatch_line="$( { grep -n -- '^dispatch' "$shim_log" || true; } | head -1 | cut -d: -f1)"
expect 'rehearsal waits for green main CI before dispatching' \
  test -n "$rehearsal_main_ci_line" -a -n "$rehearsal_dispatch_line" \
    -a "$rehearsal_main_ci_line" -lt "$rehearsal_dispatch_line"
expect 'rehearsal finishes in rehearsal mode' \
  grep -Eq '^finish .*--rehearsal' "$shim_log"
expect 'rehearsal opens no pull request' \
  bash -c "! grep -Fq 'gh pr create' '$shim_log'"
expect 'rehearsal leaves the version untouched' \
  bash -c "git -C '$origin' show 'main:Apps/SupraAI/SupraAI.xcodeproj/project.pbxproj' | grep -q 'MARKETING_VERSION = 9.4.7;'"

if (( failures > 0 )); then
  printf '%s\n' 'Cut-release tests failed.' >&2
  exit 1
fi
printf '%s\n' 'Cut-release tests passed.'
