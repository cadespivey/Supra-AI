#!/usr/bin/env bash
# Hermetic gating tests for Scripts/release-dispatch.sh — the developer-side
# command that verifies candidate readiness, starts the release runner, and
# dispatches the protected release workflow bound to origin/main's exact SHA
# and its green Protected macOS CI run.
#
# All GitHub, audit, and runner interactions go through command shims recorded
# in a log; the git origin is a local fixture repository. Nothing contacts the
# network.
#
# Expected RED reason: Scripts/release-dispatch.sh does not exist yet, so every
# case exits with bash's missing-file status (127) instead of the expected
# behavior.
#
# Fixtures use non-default values (9.4.7 / 941, run ids 770001/770002, never a
# real candidate), so a pass cannot come from echoing live repository state.
# The dispatch call is wire-proofed by absence: it must NOT forward version or
# build inputs — the reviewed commit is the only statement of those.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
dispatch="${repo_root}/Scripts/release-dispatch.sh"
failures=0

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

bin="${workdir}/bin"
runner_home="${workdir}/runner"
shim_log="${workdir}/shim.log"
mkdir -p "$bin" "$runner_home"
: >"$shim_log"

cat >"${bin}/gh" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh %s\n' "$*" >>"${SHIM_LOG:?}"
case "${1:-}" in
  auth)
    case "${2:-}" in
      status) exit 0 ;;
      token) printf 'shim-token\n'; exit 0 ;;
    esac
    exit 0 ;;
  release)
    exit "${SHIM_RELEASE_VIEW_STATUS:-1}" ;;
  run)
    if [[ "${2:-}" == list ]]; then
      if [[ "$*" == *'Protected macOS CI'* ]]; then
        printf '%s\n' "${SHIM_CI_RUNS:?}"
      else
        printf '%s\n' "${SHIM_DISPATCHED_RUNS:?}"
      fi
    fi
    exit 0 ;;
  api)
    if [[ "${2:-}" == */actions/runners ]]; then
      printf '%s\n' "${SHIM_RUNNERS_JSON:?}"
    fi
    exit 0 ;;
  workflow)
    exit 0 ;;
esac
exit 0
SHIM

cat >"${bin}/asset-audit" <<'SHIM'
#!/usr/bin/env bash
printf 'audit %s\n' "$*" >>"${SHIM_LOG:?}"
exit "${SHIM_AUDIT_STATUS:-0}"
SHIM

cat >"${bin}/runner-stop" <<'SHIM'
#!/usr/bin/env bash
printf 'runner-stop\n' >>"${SHIM_LOG:?}"
exit 0
SHIM

cat >"${runner_home}/run.sh" <<'SHIM'
#!/usr/bin/env bash
# The SHIM_LOG marker is written before stdout so that once the dispatcher
# sees run.log become non-empty, the marker is already in the ordering log.
printf 'runner-start\n' >>"${SHIM_LOG:?}"
printf 'fixture listener online\n'
exit 0
SHIM
chmod +x "${bin}/gh" "${bin}/asset-audit" "${bin}/runner-stop" "${runner_home}/run.sh"

# Fixture origin repository whose reviewed metadata says 9.4.7 (build 941).
seed="${workdir}/seed"
origin="${workdir}/origin.git"
clone="${workdir}/clone"
mkdir -p "${seed}/Apps/SupraAI/SupraAI.xcodeproj"
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
git -C "$seed" init --quiet --initial-branch=main
git -C "$seed" -c user.name=fixture -c user.email=fixture@example.invalid add -A
git -C "$seed" -c user.name=fixture -c user.email=fixture@example.invalid \
  commit --quiet -m 'fixture candidate'
git clone --quiet --bare "$seed" "$origin"
git clone --quiet "$origin" "$clone"
sha="$(git -C "$clone" rev-parse HEAD)"

ci_runs_green='[{"databaseId":770001,"headSha":"'"$sha"'","conclusion":"success","status":"completed"}]'
ci_runs_red='[{"databaseId":770001,"headSha":"'"$sha"'","conclusion":"failure","status":"completed"}]'
runners_online='{"runners":[{"name":"fixture-runner","status":"online","busy":false,"labels":[{"name":"self-hosted"},{"name":"supra-release"},{"name":"supra-release-isolated"}]}]}'
runners_offline='{"runners":[]}'
dispatched_runs='[{"databaseId":770002,"status":"waiting","url":"https://github.com/example/fixture/actions/runs/770002","createdAt":"2099-01-01T00:00:00Z"}]'

dispatch_status=0
dispatch_output="${workdir}/output.txt"

run_dispatch() {
  local extra_env=()
  while (( $# > 0 )) && [[ "$1" != '--' ]]; do
    extra_env+=("$1")
    shift
  done
  [[ "${1:-}" == '--' ]] && shift
  : >"$shim_log"
  dispatch_status=0
  (
    cd "$clone" && env \
      SUPRA_RELEASE_TESTING=1 \
      SUPRA_GH_COMMAND="${bin}/gh" \
      SUPRA_ASSET_AUDIT_COMMAND="${bin}/asset-audit" \
      SUPRA_RUNNER_STOP_COMMAND="${bin}/runner-stop" \
      SUPRA_RUNNER_HOME="$runner_home" \
      SUPRA_RELEASE_CHECK_POLL_SECONDS=0 \
      SHIM_LOG="$shim_log" \
      SHIM_CI_RUNS="$ci_runs_green" \
      SHIM_RUNNERS_JSON="$runners_online" \
      SHIM_DISPATCHED_RUNS="$dispatched_runs" \
      ${extra_env[@]+"${extra_env[@]}"} \
      bash "$dispatch" --repository example/fixture "$@"
  ) >"$dispatch_output" 2>&1 || dispatch_status=$?
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
  local name="$1"
  local expected="$2"
  if [[ "$dispatch_status" -eq "$expected" ]]; then
    printf 'PASS: %s\n' "$name"
  else
    printf 'FAIL: %s: expected status %s, got %s\n' "$name" "$expected" "$dispatch_status" >&2
    sed 's/^/  | /' "$dispatch_output" >&2
    failures=$((failures + 1))
  fi
}

log_line_number() {
  grep -n -- "$1" "$shim_log" | head -1 | cut -d: -f1
}

# --- Happy path: production dispatch ---------------------------------------
run_dispatch
expect_status 'production dispatch succeeds against a ready candidate' 0
expect 'dispatch targets the production workflow' \
  grep -Fq 'gh workflow run Protected production release' "$shim_log"
expect 'dispatch binds the exact origin/main SHA' \
  grep -Fq -- "-f expected_sha=${sha}" "$shim_log"
expect 'dispatch binds the discovered green CI run' \
  grep -Fq -- '-f ci_run_id=770001' "$shim_log"
expect 'dispatch does not forward a version input' \
  bash -c "! grep -Fq -- '-f version=' '$shim_log'"
expect 'dispatch does not forward a build input' \
  bash -c "! grep -Fq -- '-f build=' '$shim_log'"
expect 'dispatch starts the release runner' \
  grep -Fq 'runner-start' "$shim_log"
expect 'operator sees the reviewed version intent' \
  grep -Fq '9.4.7' "$dispatch_output"
expect 'operator sees the reviewed build intent' \
  grep -Fq '941' "$dispatch_output"
expect 'operator is told to approve the environment' \
  grep -Fiq 'approve' "$dispatch_output"
expect 'operator sees the dispatched run URL' \
  grep -Fq 'actions/runs/770002' "$dispatch_output"

audit_line="$(log_line_number '^audit ')"
runner_line="$(log_line_number '^runner-start$')"
dispatch_line="$(log_line_number '^gh workflow run ')"
expect 'audit runs before the runner starts' \
  test -n "$audit_line" -a -n "$runner_line" -a "$audit_line" -lt "$runner_line"
expect 'runner starts before the workflow is dispatched' \
  test -n "$dispatch_line" -a "$runner_line" -lt "$dispatch_line"

# --- Rehearsal flag ---------------------------------------------------------
run_dispatch -- --rehearsal
expect_status 'rehearsal dispatch succeeds' 0
expect 'rehearsal targets the rehearsal workflow' \
  grep -Fq 'gh workflow run Protected signed release rehearsal' "$shim_log"

# --- Readiness failures (checked before the runner ever starts) -------------
run_dispatch SHIM_CI_RUNS="$ci_runs_red" --
expect_status 'missing green CI run fails closed' 1
expect 'missing green CI run is named' \
  grep -Fq 'green Protected macOS CI' "$dispatch_output"
expect 'missing green CI run does not dispatch' \
  bash -c "! grep -Fq 'gh workflow run' '$shim_log'"
expect 'missing green CI run does not start the runner' \
  bash -c "! grep -Fq 'runner-start' '$shim_log'"

run_dispatch SHIM_RELEASE_VIEW_STATUS=0 --
expect_status 'existing release fails closed' 1
expect 'existing release is named' \
  grep -Fq 'already published or reserved' "$dispatch_output"
expect 'existing release does not dispatch' \
  bash -c "! grep -Fq 'gh workflow run' '$shim_log'"

run_dispatch SHIM_AUDIT_STATUS=3 --
expect_status 'failing public-asset audit fails closed' 1
expect 'failing audit is named' \
  grep -Fq 'public-asset audit' "$dispatch_output"
expect 'failing audit does not dispatch' \
  bash -c "! grep -Fq 'gh workflow run' '$shim_log'"
expect 'failing audit does not start the runner' \
  bash -c "! grep -Fq 'runner-start' '$shim_log'"

# --- Runner that never comes online: stop it again, do not dispatch ---------
run_dispatch SHIM_RUNNERS_JSON="$runners_offline" --
expect_status 'runner that never comes online fails closed' 1
expect 'offline runner is named' \
  grep -Fiq 'online' "$dispatch_output"
expect 'offline runner is stopped again' \
  grep -Fq 'runner-stop' "$shim_log"
expect 'offline runner does not dispatch' \
  bash -c "! grep -Fq 'gh workflow run' '$shim_log'"

# --- Existing tag (mutates the fixture origin; keep last) -------------------
git --git-dir="$origin" tag v9.4.7
run_dispatch
expect_status 'existing release tag fails closed' 1
expect 'existing tag is named' \
  grep -Fq 'release tag already exists' "$dispatch_output"
expect 'existing tag does not dispatch' \
  bash -c "! grep -Fq 'gh workflow run' '$shim_log'"

if (( failures > 0 )); then
  printf '%s\n' 'Release dispatch tests failed.' >&2
  exit 1
fi
printf '%s\n' 'Release dispatch tests passed.'
