#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ledger="$repo_root/Docs/Architecture/Remediation/Architecture-UX-Test-Ledger.yml"

fail() {
  echo "architecture/UX test ledger verification failed: $*" >&2
  exit 1
}

[[ -f "$ledger" ]] || fail "missing $ledger"

declared_plan_sha256="$(sed -nE 's/^canonical_plan_sha256: "([0-9a-f]{64})"$/\1/p' "$ledger")"
[[ "$declared_plan_sha256" =~ ^[0-9a-f]{64}$ ]] \
  || fail "ledger has no single valid canonical_plan_sha256"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/supra-architecture-ux-ledger.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

expected="$scratch/expected.txt"
actual="$scratch/actual.txt"

if [[ -n "${SUPRA_ARCHITECTURE_UX_PLAN:-}" ]]; then
  [[ -f "$SUPRA_ARCHITECTURE_UX_PLAN" ]] \
    || fail "SUPRA_ARCHITECTURE_UX_PLAN is not a file: $SUPRA_ARCHITECTURE_UX_PLAN"
  actual_plan_sha256="$(shasum -a 256 "$SUPRA_ARCHITECTURE_UX_PLAN" | awk '{print $1}')"
  [[ "$actual_plan_sha256" == "$declared_plan_sha256" ]] \
    || fail "canonical plan digest mismatch: expected $declared_plan_sha256, found $actual_plan_sha256"
  sed -n '/^## 14\. Consolidated test catalog/,/^## 15\./p' "$SUPRA_ARCHITECTURE_UX_PLAN" \
    | sed -nE 's/^\| ((T|DR)-[A-Z0-9-]+) \|.*$/\1/p' > "$expected"
else
  cat > "$expected" <<'EXPECTED_IDS'
T-DATA-COURT-01
T-DATA-COURT-02
T-DATA-COURT-03
T-DATA-PARTY-01
T-DATA-PARTY-02
T-DATA-MIGRATE-01
T-DATA-READY-01
T-DATA-READY-02
T-DATA-READY-03
T-UX-DELETE-01
T-UX-DELETE-02
T-UX-SETUP-01
T-WINDOW-01
T-WORK-CONTEXT-01
T-MUTATION-01
T-REVIEW-RETIRE-UI-01
T-REVIEW-RETIRE-JOB-01
T-REVIEW-TERMS-01
T-REVIEW-RETIRE-ARTIFACT-01
T-PUB-CHAT-01
T-PUB-CHAT-02
T-PUB-WORK-01
T-AUTH-01
T-AUTH-02
T-EGRESS-01
T-EGRESS-02
T-EGRESS-03
T-EGRESS-04
T-EGRESS-05
T-RESEARCH-PACKET-01
T-RESEARCH-PACKET-02
T-WORKFLOW-BUDGET-01
T-TOOL-AUTH-01
T-OUTCOME-01
T-WORKFLOW-MEMORY-01
T-HANDOFF-01
T-ATTACH-01
T-ATTACH-02
T-ART-01
T-ART-02
T-ART-03
T-RAG-CORPUS-01
T-RAG-EVAL-01
T-RAG-BASELINE-01
T-EMBED-STREAM-01
T-RAG-SCAN-01
T-RAG-SCAN-02
T-RAG-CACHE-01
T-RAG-CACHE-02
T-RAG-TRACE-01
T-RAG-TRACE-02
T-RAG-DEPENDENCY-01
DR-RAG-EXPERIMENT-01
T-RAG-RERANK-01
T-RAG-PARSER-01
T-RAG-CHUNK-01
T-RAG-EMBED-01
T-RAG-ANN-01
T-XPC-REVIEW-REMOVE-01
T-XPC-CANCEL-01
T-RUNTIME-SCHED-01
T-RUNTIME-SCHED-02
T-NO-MULTI-AGENT-01
T-RUNTIME-LIFECYCLE-01
T-RUNTIME-BIND-01
T-XPC-BUDGET-01
T-XPC-BUDGET-02
T-XPC-BUDGET-03
T-XPC-BUDGET-04
T-XPC-BUDGET-05
T-XPC-BUDGET-06
T-RUNTIME-KV-01
T-RUNTIME-SWITCH-01
T-STREAM-BUFFER-01
T-RUNTIME-RESIDENCY-01
T-RUNTIME-PRESSURE-01
T-RUNTIME-RESET-01
T-XPC-METHOD-01
T-PARITY-CHAT-01
T-PARITY-ENV-01
T-ARCH-EDGE-01
T-STORE-CAP-01
T-UI-PROJECTION-01
T-NET-AUDIT-01
T-OOXML-01
T-UTILITY-01
T-MARKDOWN-01
T-MIGRATION-01
T-REVIEW-RETIRE-CAP-01
T-REVIEW-RETIRE-SCHEMA-01
T-REVIEW-RETIRE-CLAIMS-01
T-REVIEW-RETIRE-SMOKE-01
DR-CORPUS-OWNER-01
DR-PACKAGE-01
T-IA-SIDEBAR-01
T-IA-MATTER-01
T-CHAT-UX-01
T-CHAT-UX-02
T-CHAT-UX-03
T-SETTINGS-01
T-TRUST-PATTERN-01
T-DRAFT-UX-01
T-SAVED-WORK-01
T-SAVED-WORK-02
T-RELATION-01
T-ERROR-01
T-RECOVERY-01
T-COMPONENT-01
T-TRUST-CONTRACT-01
T-A11Y-01
T-CONTRAST-01
T-TERMS-01
T-PUBLIC-RECORDS-01
EXPECTED_IDS
fi

sed -nE 's/^  - id: "((T|DR)-[A-Z0-9-]+)"$/\1/p' "$ledger" > "$actual"

expected_count="$(wc -l < "$expected" | tr -d '[:space:]')"
actual_count="$(wc -l < "$actual" | tr -d '[:space:]')"
[[ "$expected_count" -gt 0 ]] || fail "canonical source produced zero IDs"
[[ "$actual_count" -gt 0 ]] || fail "ledger contains zero IDs"

expected_duplicates="$(LC_ALL=C sort "$expected" | uniq -d)"
actual_duplicates="$(LC_ALL=C sort "$actual" | uniq -d)"
[[ -z "$expected_duplicates" ]] || fail "canonical source contains duplicate IDs: $expected_duplicates"
[[ -z "$actual_duplicates" ]] || fail "ledger contains duplicate IDs: $actual_duplicates"

LC_ALL=C sort -u "$expected" > "$scratch/expected.sorted"
LC_ALL=C sort -u "$actual" > "$scratch/actual.sorted"
missing="$(comm -23 "$scratch/expected.sorted" "$scratch/actual.sorted")"
extra="$(comm -13 "$scratch/expected.sorted" "$scratch/actual.sorted")"
[[ -z "$missing" ]] || fail "ledger is missing IDs: $missing"
[[ -z "$extra" ]] || fail "ledger has extra IDs: $extra"

awk '
function trim(value) {
  gsub(/^[[:space:]]+/, "", value)
  gsub(/[[:space:]]+$/, "", value)
  return value
}
function unquote(value) {
  value = trim(value)
  if (value ~ /^".*"$/) {
    value = substr(value, 2, length(value) - 2)
  }
  return value
}
function blank(value) {
  value = trim(value)
  return value == "" || value == "\"\"" || value == "\047\047" || value == "null" || value == "~"
}
function finish_record(    i, key, status, pending, implemented) {
  if (!in_record) return

  split("id finding_or_invariant owner_work_package owner_phase target selected_test_command wire_fixture expected_red_reason forbidden_default_or_side_effect required_native_evidence required_hosted_evidence required_artifact_evidence dependencies status", required, " ")
  for (i in required) {
    key = required[i]
    if (!(key in values) || blank(values[key])) {
      print "record " record_id " has blank required field: " key > "/dev/stderr"
      failures = 1
    }
  }

  status = unquote(values["status"])
  if (status != "red" && status != "green" && status != "green_containment" && status != "standing_guard_green" && status != "decision_pending") {
    print "record " record_id " has invalid status: " status > "/dev/stderr"
    failures = 1
  }

  pending = ("pending_test_path" in values) && !blank(values["pending_test_path"])
  implemented = ("implemented_test_path" in values) && !blank(values["implemented_test_path"])
  if ((pending ? 1 : 0) + (implemented ? 1 : 0) != 1) {
    print "record " record_id " must have exactly one nonblank pending_test_path or implemented_test_path" > "/dev/stderr"
    failures = 1
  }
  if (status == "red" && !pending) {
    print "record " record_id " status " status " requires pending_test_path" > "/dev/stderr"
    failures = 1
  }
  if ((status == "green" || status == "green_containment" || status == "standing_guard_green") && !implemented) {
    print "record " record_id " status " status " requires implemented_test_path" > "/dev/stderr"
    failures = 1
  }

  record_count += 1
}
BEGIN {
  failures = 0
  record_count = 0
  in_record = 0
}
/^  - id: / {
  finish_record()
  delete values
  in_record = 1
  line = $0
  sub(/^  - /, "", line)
  colon = index(line, ":")
  values["id"] = substr(line, colon + 1)
  record_id = unquote(values["id"])
  next
}
in_record && /^    [a-z_]+:/ {
  line = $0
  sub(/^    /, "", line)
  colon = index(line, ":")
  key = substr(line, 1, colon - 1)
  if (key in values) {
    print "record " record_id " has duplicate field: " key > "/dev/stderr"
    failures = 1
  }
  values[key] = substr(line, colon + 1)
}
END {
  finish_record()
  if (record_count == 0) {
    print "ledger parser found zero records" > "/dev/stderr"
    failures = 1
  }
  exit failures
}
' "$ledger" || fail "one or more records have invalid or blank required fields"

if [[ -n "${SUPRA_ARCHITECTURE_UX_PLAN:-}" ]]; then
  ruby - "$SUPRA_ARCHITECTURE_UX_PLAN" "$ledger" <<'RUBY' \
    || fail "ledger finding text differs from canonical Section 14"
require "yaml"

plan_path, ledger_path = ARGV
plan = File.read(plan_path)
section = plan[/^## 14\. Consolidated test catalog.*?(?=^## 15\.)/m]
abort "canonical Section 14 was not found" unless section

expected = {}
section.each_line do |line|
  match = line.match(/^\| ((?:T|DR)-[A-Z0-9-]+) \| (.*) \|\s*$/)
  next unless match
  abort "duplicate canonical gate #{match[1]}" if expected.key?(match[1])
  expected[match[1]] = match[2].strip
end

ledger = YAML.safe_load(
  File.read(ledger_path),
  permitted_classes: [],
  permitted_symbols: [],
  aliases: false
)
actual = ledger.fetch("tests").to_h do |record|
  [record.fetch("id"), record.fetch("finding_or_invariant")]
end

mismatches = expected.keys.sort.each_with_object([]) do |id, rows|
  next if expected[id] == actual[id]
  rows << "#{id}: expected #{expected[id].inspect}; found #{actual[id].inspect}"
end
abort mismatches.join("\n") unless mismatches.empty?
RUBY
fi

if [[ "$expected_count" -ne "$actual_count" ]]; then
  fail "canonical count $expected_count does not match ledger count $actual_count"
fi

echo "Architecture/UX test ledger verified: $actual_count canonical IDs, no duplicates/missing/extra IDs, required fields and statuses valid."
