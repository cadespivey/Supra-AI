#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
verifier="${repo_root}/Scripts/verify-release-scope-ledger.sh"
ledger="${repo_root}/Docs/Architecture/Remediation/Release-Scope-Ledger.yml"
architecture_ledger="${repo_root}/Docs/Architecture/Remediation/Architecture-UX-Test-Ledger.yml"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/supra-release-scope-test.XXXXXX")"
trap 'rm -r -- "$scratch"' EXIT
failures=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

run_fixture() {
  local root="$1"
  shift
  SUPRA_REPO_ROOT="$root" bash "$verifier" "$@"
}

make_fixture() {
  local name="$1"
  FIXTURE_ROOT="${scratch}/${name}"
  mkdir -p "${FIXTURE_ROOT}/Docs/Architecture/Remediation"
  cp "$ledger" "${FIXTURE_ROOT}/Docs/Architecture/Remediation/Release-Scope-Ledger.yml"
  cp "$architecture_ledger" "${FIXTURE_ROOT}/Docs/Architecture/Remediation/Architecture-UX-Test-Ledger.yml"
}

mutate_fixture() {
  local mode="$1"
  local path="${FIXTURE_ROOT}/Docs/Architecture/Remediation/Release-Scope-Ledger.yml"
  ruby -ryaml - "$path" "$mode" <<'RUBY'
path, mode = ARGV
data = YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: false)
approval = data.fetch("approval")
approval["status"] = "approved"
approval["approved_by"] = "synthetic-owner"
approval["approved_at"] = "owner-approved-2026-08-15"
if %w[satisfied-gates fully-approved].include?(mode)
  acceptance = data.fetch("owner_acceptance")
  acceptance["status"] = "satisfied"
  acceptance.fetch("gates").each { |gate| gate["status"] = "satisfied" }
end
if mode == "fully-approved"
  (data.fetch("findings") + data.fetch("work_packages")).each do |row|
    row["closure"] = case row["closure"]
    when "implementation_green_owner_gate_pending"
      "implementation_green"
    when "implementation_green_owner_and_release_gates_pending"
      "implementation_green_release_artifact_pending"
    else
      row["closure"]
    end
  end
end
File.write(path, YAML.dump(data))
RUBY
}

if ! run_fixture "$repo_root" >/dev/null; then
  fail 'pending repository ledger did not pass structural verification'
fi
pending_output="${scratch}/pending-owner.log"
if run_fixture "$repo_root" --require-owner-approval >"$pending_output" 2>&1 \
    || ! grep -Fq 'release scope lacks repository-owner approval' "$pending_output"; then
  fail 'pending repository ledger did not fail the release-only owner gate'
fi

make_fixture pending-gates
mutate_fixture pending-gates
pending_gates_output="${scratch}/pending-gates.log"
if run_fixture "$FIXTURE_ROOT" --require-owner-approval >"$pending_gates_output" 2>&1 \
    || ! grep -Fq 'approved scope retains pending owner acceptance gates' "$pending_gates_output"; then
  fail 'top-level approval bypassed pending owner acceptance gates'
fi

make_fixture pending-closures
mutate_fixture satisfied-gates
pending_closures_output="${scratch}/pending-closures.log"
if run_fixture "$FIXTURE_ROOT" --require-owner-approval >"$pending_closures_output" 2>&1 \
    || ! grep -Fq 'approved scope retains owner-pending closures' "$pending_closures_output"; then
  fail 'satisfied acceptance inventory bypassed owner-pending work-package closures'
fi

make_fixture fully-approved
mutate_fixture fully-approved
if ! run_fixture "$FIXTURE_ROOT" --require-owner-approval >/dev/null; then
  fail 'fully satisfied synthetic owner scope did not pass the release-only gate'
fi

if (( failures != 0 )); then
  printf 'Release scope ledger tests failed: %d\n' "$failures" >&2
  exit 1
fi
printf '%s\n' 'Release scope ledger tests passed.'
