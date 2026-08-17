#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cut="$repo_root/Scripts/cut-release.sh"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
bin="$workdir/bin"
mkdir -p "$bin"
shim_log="$workdir/shim.log"

cat >"$bin/gh" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh %s\n' "$*" >>"${SHIM_LOG:?}"
if [[ "${1:-} ${2:-}" == 'auth status' ]]; then exit 0; fi
if [[ "${1:-} ${2:-}" == 'workflow run' ]]; then exit 0; fi
if [[ "${1:-} ${2:-}" == 'run list' ]]; then
  if [[ "$*" == *'Protected macOS CI'* ]]; then
    sha="$(git rev-parse HEAD)"
    conclusion="${SHIM_CI_CONCLUSION:-success}"
    printf '[{"databaseId":88001,"headSha":"%s","status":"completed","conclusion":"%s","url":"https://example.invalid/ci"}]\n' "$sha" "$conclusion"
  else
    printf '[{"databaseId":88003,"status":"in_progress","conclusion":null,"url":"https://example.invalid/release"}]\n'
  fi
  exit 0
fi
exit 0
SHIM
cat >"$bin/dispatch" <<'SHIM'
#!/usr/bin/env bash
printf 'dispatch %s\n' "$*" >>"${SHIM_LOG:?}"
SHIM
cat >"$bin/finish" <<'SHIM'
#!/usr/bin/env bash
printf 'finish %s\n' "$*" >>"${SHIM_LOG:?}"
SHIM
cat >"$bin/console-check" <<'SHIM'
#!/usr/bin/env bash
exit "${SHIM_CONSOLE_STATUS:-0}"
SHIM
cat >"$bin/caffeinate" <<'SHIM'
#!/usr/bin/env bash
sleep 30
SHIM
cat >"$bin/pgrep" <<'SHIM'
#!/usr/bin/env bash
exit "${SHIM_RUNNER_STATUS:-1}"
SHIM
chmod +x "$bin"/*

failures=0
expect() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then printf 'PASS: %s\n' "$label"; else printf 'FAIL: %s\n' "$label" >&2; failures=$((failures + 1)); fi
}

make_fixture() {
  seed="$workdir/seed-$RANDOM"
  origin="$workdir/origin-$RANDOM.git"
  clone="$workdir/clone-$RANDOM"
  mkdir -p "$seed/Apps/SupraAI/SupraAI.xcodeproj"
  {
    printf '// !$*UTF8*$!\n{\n'
    for configuration in AppDebug AppRelease XPCDebug XPCRelease; do
      printf '\tbuildSettings = { CONFIGURATION = %s;\n' "$configuration"
      printf '\t\tCURRENT_PROJECT_VERSION = 941;\n'
      printf '\t\tMARKETING_VERSION = 9.4.7;\n\t};\n'
    done
    printf '}\n'
  } >"$seed/Apps/SupraAI/SupraAI.xcodeproj/project.pbxproj"
  printf '# Changelog\n\n## [Unreleased]\n\n## [9.4.7] - 2099-01-01\n' >"$seed/CHANGELOG.md"
  git -C "$seed" init -q -b main
  git -C "$seed" config user.name fixture
  git -C "$seed" config user.email fixture@example.invalid
  git -C "$seed" add .
  git -C "$seed" commit -qm base
  git clone -q --bare "$seed" "$origin"
  git clone -q "$origin" "$clone"
  git -C "$clone" config user.name fixture
  git -C "$clone" config user.email fixture@example.invalid
  notes="$workdir/notes-$RANDOM.md"
  printf 'A user-facing fix.\n' >"$notes"
  : >"$shim_log"
}

run_cut() {
  ci_conclusion="$1"
  shift
  status=0
  output="$workdir/output-$RANDOM"
  (
    cd "$clone"
    env PATH="$bin:$PATH" SHIM_LOG="$shim_log" SUPRA_RELEASE_TESTING=1 \
      SUPRA_GH_COMMAND="$bin/gh" SUPRA_DISPATCH_COMMAND="$bin/dispatch" \
      SUPRA_FINISH_COMMAND="$bin/finish" SUPRA_CONSOLE_CHECK_COMMAND="$bin/console-check" \
      SUPRA_CAFFEINATE_COMMAND="$bin/caffeinate" SUPRA_PGREP_COMMAND="$bin/pgrep" \
      SUPRA_RUNNER_HOME="$workdir/runner" SUPRA_RELEASE_CHECK_POLL_SECONDS=0 \
      SHIM_CI_CONCLUSION="$ci_conclusion" \
      bash "$cut" "$@"
  ) >"$output" 2>&1 || status=$?
}

make_fixture
printf 'dirty\n' >"$clone/dirty"
run_cut success --patch --notes-file "$notes"
expect 'dirty checkout is refused before GitHub' test "$status" -eq 1
expect 'dirty checkout performs no GitHub calls' test ! -s "$shim_log"

make_fixture
run_cut success --patch
expect 'missing notes are refused' test "$status" -eq 1

make_fixture
run_cut success --patch --notes-file "$notes"
expect 'single-pass production cut succeeds' test "$status" -eq 0
expect 'release commit fast-forwards main' bash -c "git --git-dir='$origin' show main:Apps/SupraAI/SupraAI.xcodeproj/project.pbxproj | grep -q 'MARKETING_VERSION = 9.4.8;'"
expect 'release notes land on main' bash -c "git --git-dir='$origin' show main:CHANGELOG.md | grep -q '## \[9.4.8\]'"
expect 'metadata branch is deleted' bash -c "! git --git-dir='$origin' show-ref --verify --quiet refs/heads/release/9.4.8"
expect 'one change-aware CI run is dispatched' bash -c "test \"\$(grep -c 'gh workflow run Protected macOS CI' '$shim_log')\" -eq 1"
expect 'no pull request is created or merged' bash -c "! grep -q 'gh pr ' '$shim_log'"
expect 'owner approval is not repeated through the API' bash -c "! grep -q 'pending_deployments\|state=approved' '$shim_log'"
expect 'release transaction is dispatched and finished' bash -c "grep -q '^dispatch' '$shim_log' && grep -q '^finish --run 88003' '$shim_log'"

make_fixture
run_cut failure --patch --notes-file "$notes"
expect 'failed exact-SHA validation blocks main' test "$status" -eq 1
expect 'failed validation does not dispatch a release' bash -c "! grep -q '^dispatch' '$shim_log'"

make_fixture
run_cut success --rehearsal
expect 'explicit rehearsal remains available' test "$status" -eq 0
expect 'rehearsal creates no metadata commit' bash -c "git --git-dir='$origin' show main:Apps/SupraAI/SupraAI.xcodeproj/project.pbxproj | grep -q 'MARKETING_VERSION = 9.4.7;'"
expect 'rehearsal uses rehearsal dispatch and finish' bash -c "grep -q '^dispatch --rehearsal' '$shim_log' && grep -q '^finish --rehearsal --run 88003' '$shim_log'"

(( failures == 0 )) || { printf 'Cut-release tests failed: %s\n' "$failures" >&2; exit 1; }
printf '%s\n' 'Cut-release tests passed.'
