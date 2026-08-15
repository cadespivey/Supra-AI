#!/usr/bin/env bash
set -euo pipefail

repo_root="${SUPRA_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ledger="${repo_root}/Docs/Architecture/Remediation/Release-Scope-Ledger.yml"
architecture_ledger="${repo_root}/Docs/Architecture/Remediation/Architecture-UX-Test-Ledger.yml"
require_owner_approval=0
if [[ "${1:-}" == "--require-owner-approval" ]]; then
  require_owner_approval=1
  shift
fi
if (( $# != 0 )); then
  printf 'Usage: %s [--require-owner-approval]\n' "$0" >&2
  exit 2
fi
[[ -f "$ledger" ]] || { printf 'release scope ledger is missing: %s\n' "$ledger" >&2; exit 1; }
[[ -f "$architecture_ledger" ]] || { printf 'architecture test ledger is missing: %s\n' "$architecture_ledger" >&2; exit 1; }

ruby -ryaml - "$ledger" "$architecture_ledger" "$require_owner_approval" <<'RUBY'
path, architecture_path, require_approval = ARGV
data = YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: false)
architecture = YAML.safe_load(File.read(architecture_path), permitted_classes: [], permitted_symbols: [], aliases: false)
abort "invalid release scope schema" unless data["schema_version"] == 1
abort "invalid canonical plan digest" unless data["canonical_plan_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/)
abort "release scope and architecture ledger plan digests differ" unless data["canonical_plan_sha256"] == architecture["canonical_plan_sha256"]

expected_findings = (1..9).map { |n| format("P-%02d", n) } +
  (1..20).map { |n| format("A-%02d", n) } +
  (1..7).map { |n| format("RAG-%02d", n) } +
  (1..20).map { |n| format("UX-%02d", n) }
expected_work_packages = {
  0 => 1..5, 1 => 1..6, 2 => 1..6, 3 => 1..5,
  4 => 1..7, 5 => 1..7, 6 => 1..7,
}.flat_map { |phase, range| range.map { |n| "WP-#{phase}.#{n}" } }

allowed_dispositions = Array(data["allowed_dispositions"])
expected_dispositions = %w[
  must_implement_before_next_public_release
  must_decide_before_release_no_change_may_satisfy
  explicitly_deferred
  moot_through_review_retirement
]
abort "release scope disposition inventory drifted" unless allowed_dispositions == expected_dispositions
allowed_closures = %w[
  implementation_green
  implementation_green_owner_gate_pending
  implementation_green_release_artifact_pending
  implementation_green_owner_and_release_gates_pending
  no_change_recorded
  retired
  deferred
]

validate = lambda do |key, expected|
  rows = Array(data[key])
  ids = rows.map { |row| row["id"].to_s }
  abort "#{key} contains duplicate IDs" unless ids.uniq.length == ids.length
  missing = expected - ids
  extra = ids - expected
  abort "#{key} inventory mismatch; missing=#{missing.join(',')} extra=#{extra.join(',')}" unless missing.empty? && extra.empty?
  rows.each do |row|
    id = row["id"]
    abort "#{id} has invalid disposition" unless allowed_dispositions.include?(row["disposition"])
    abort "#{id} has invalid closure" unless allowed_closures.include?(row["closure"])
    abort "#{id} has blank evidence" if row["evidence"].to_s.strip.empty?
    if row["disposition"] == "must_decide_before_release_no_change_may_satisfy"
      abort "#{id} decision is unresolved" unless row["closure"] == "no_change_recorded"
    end
    if row["disposition"] == "moot_through_review_retirement"
      abort "#{id} retirement disposition is not closed" unless row["closure"] == "retired"
    end
  end
end
validate.call("findings", expected_findings)
validate.call("work_packages", expected_work_packages)

approval = data.fetch("approval")
status = approval["status"]
abort "invalid scope approval status" unless %w[pending_owner_approval approved].include?(status)
owner_acceptance = data.fetch("owner_acceptance")
owner_gates = Array(owner_acceptance["gates"])
expected_owner_gates = %w[
  target-operating-model-walkthrough
  synthetic-rag-judgments
  installed-rag-artifacts
  rag-thresholds-and-resource-envelope
  backup-restore-drill
]
owner_gate_ids = owner_gates.map { |gate| gate["id"].to_s }
abort "owner acceptance gate inventory drifted" unless owner_gate_ids == expected_owner_gates
abort "owner acceptance gate IDs are duplicated" unless owner_gate_ids.uniq.length == owner_gate_ids.length
owner_gates.each do |gate|
  abort "#{gate['id']} has blank status" if gate["status"].to_s.strip.empty?
  abort "#{gate['id']} has blank evidence" if gate["evidence"].to_s.strip.empty?
end
acceptance_status = owner_acceptance["status"]
abort "invalid owner acceptance status" unless %w[pending satisfied].include?(acceptance_status)
all_owner_gates_satisfied = owner_gates.all? { |gate| gate["status"] == "satisfied" }
abort "owner acceptance is marked satisfied with pending gates" if acceptance_status == "satisfied" && !all_owner_gates_satisfied
if status == "approved"
  abort "approved scope has no owner" if approval["approved_by"].to_s.strip.empty?
  abort "approved scope has no timestamp" if approval["approved_at"].to_s.strip.empty?
  abort "approved scope retains pending owner acceptance gates" unless acceptance_status == "satisfied" && all_owner_gates_satisfied
  owner_pending_rows = (Array(data["findings"]) + Array(data["work_packages"])).select do |row|
    row["closure"].to_s.include?("owner")
  end
  abort "approved scope retains owner-pending closures: #{owner_pending_rows.map { |row| row['id'] }.join(',')}" unless owner_pending_rows.empty?
elsif require_approval == "1"
  abort "release scope lacks repository-owner approval"
end
if require_approval == "1" && (acceptance_status != "satisfied" || !all_owner_gates_satisfied)
  abort "release scope retains pending owner acceptance gates"
end

puts "Release scope ledger verified: #{expected_findings.length} findings, #{expected_work_packages.length} work packages, approval=#{status}, owner_acceptance=#{acceptance_status}."
RUBY
