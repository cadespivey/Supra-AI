#!/usr/bin/env bash
set -euo pipefail

repo_root="${SUPRA_REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
repo_root="$(cd "$repo_root" && pwd -P)"

mode="${1:---verify-baseline}"
if (( $# > 1 )) || [[ "$mode" != "--verify-baseline" && "$mode" != "--performance" && "$mode" != "--performance-release-gate" ]]; then
  printf '%s\n' 'usage: bash Scripts/run-benchmarks.sh [--verify-baseline|--performance|--performance-release-gate]' >&2
  exit 2
fi

temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT
current_report="${temporary_dir}/current.json"
current_normalized="${temporary_dir}/current-normalized.json"
baseline_normalized="${temporary_dir}/baseline-normalized.json"
proposal_manifest="${repo_root}/TestData/Benchmarks/threshold-proposals.json"
baseline_path="$(jq -er '.baselinePath' "$proposal_manifest")"
baseline_report="${repo_root}/${baseline_path}"

if [[ "$mode" == "--performance" || "$mode" == "--performance-release-gate" ]]; then
  performance_report="${temporary_dir}/performance.json"
  performance_thresholds="${repo_root}/TestData/Benchmarks/performance-thresholds.json"
  performance_arguments=(
    --check-performance
    --report "$performance_report"
    --thresholds "$performance_thresholds"
  )
  if [[ "$mode" == "--performance-release-gate" ]]; then
    performance_arguments+=(--require-owner-approval)
  fi
  (
    cd "${repo_root}/Packages/SupraTestKit"
    swift run SupraBench --performance --output "$performance_report"
    swift run SupraBench "${performance_arguments[@]}"
  )
  jq '{
    protocolVersion: .run.protocolVersion,
    repositorySHA: .run.repositorySHA,
    hardwareIdentifier: .run.hardwareIdentifier,
    operatingSystem: .run.operatingSystem,
    xcodeVersion: .run.xcodeVersion,
    swiftVersion: .run.swiftVersion,
    thermalState: .run.thermalState,
    scales: [.scales[] | {
      documentCount,
      fastRetrievalP50Milliseconds,
      fastRetrievalP95Milliseconds,
      deepRetrievalP50Milliseconds: .retrievalP50Milliseconds,
      deepRetrievalP95Milliseconds: .retrievalP95Milliseconds,
      ledgerWriteP50Milliseconds,
      ledgerWriteP95Milliseconds,
      structureWriteP50Milliseconds,
      structureWriteP95Milliseconds,
      documentsPerMinute,
      mebibytesPerSecond,
      peakRSSMiB
    }],
    incremental
  }' "$performance_report"
  exit 0
fi

(
  cd "${repo_root}/Packages/SupraTestKit"
  swift run SupraBench --deterministic --output "$current_report"
  swift test --filter BenchmarkBaselineContractTests
)

jq -S 'del(.run.generatedAt, .run.repositorySHA)' "$current_report" >"$current_normalized"
jq -S 'del(.run.generatedAt, .run.repositorySHA)' "$baseline_report" >"$baseline_normalized"
if ! cmp -s "$baseline_normalized" "$current_normalized"; then
  printf '%s\n' 'ERROR: deterministic benchmark drifted from the frozen baseline' >&2
  diff -u "$baseline_normalized" "$current_normalized" >&2 || true
  exit 1
fi

jq '{
  schemaVersion,
  sourceSHA: .run.repositorySHA,
  fixtureSHA256: .run.corpusManifestSHA256,
  measured: [.metrics[] | .measurements[] | select(.status == "measured") | {name, value}],
  notApplicableCount: ([.metrics[] | select(all(.measurements[]; .status == "not_applicable"))] | length)
}' "$current_report"
printf '%s\n' 'Deterministic document benchmark matches the frozen baseline.'
