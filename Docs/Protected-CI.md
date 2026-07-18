# Protected CI policy

`Protected macOS CI` is the deterministic pull-request gate for application changes. It
runs on a trusted GitHub-hosted macOS runner without release, signing, model-provider, or
API credentials. Signing and notarization belong only in the protected release environment.

The required branch-protection checks are:

- Repository inventory and gate tests
- all 14 `Swift package - <name>` matrix entries
- unsigned Debug and Release app/XPC builds
- App UI and hosted XPC smoke
- Shipping migration fixtures
- Document benchmark deterministic gates
- Website lint, build, audit, and asset guards
- Secrets, entitlements, artifacts, models, and public metadata
- Dependency review for pull requests

The inventory is intentionally duplicated in `Scripts/list-local-packages.sh` and the
workflow matrix. `Scripts/verify-repo-facts.sh` compares them, so adding or removing a
package requires an explicit review of both. The migration verifier derives the latest
registered version and enforces a contiguous sequence; it does not pin a stale migration
number.

Live Hugging Face and public GitHub metadata checks are read-only and run on the scheduled
security workflow. Pull requests run their offline or synthetic counterparts so an
unrelated provider outage—or GitHub Support work on an existing hidden ref—cannot bypass or
silently weaken the preventive gates. No workflow may fetch a prohibited public blob.

Document-ingestion quality has a separate credential-free scheduled workflow,
`.github/workflows/benchmarks.yml`, plus the pull-request
`Document benchmark deterministic gates` job. Both run the SHA-frozen deterministic
baseline and the fixed 10/50/200-document performance protocol on `macos-15`. The
deterministic pass imports and indexes the synthetic corpus, exercises retrieval and
matter-isolation probes, validates the baseline/threshold ledger, and fails if the canonical
report drifts after removing only the run timestamp and current checkout SHA. The performance
pass records fast/deep retrieval, exhaustive-ledger and structure-write p50/p95, import/index
throughput, peak RSS, and one-document incremental rows/bytes/work. It immediately fails when
incremental work touches any unaffected document.

Statistical B-PERF bands remain `pending_owner_approval`. Pending runs capture measurements
and enforce deterministic safety only; `Scripts/run-benchmarks.sh
--performance-release-gate` fails closed until the repo owner records the memory ceiling and
incremental wall-time band, approves the default 10% latency/throughput proposals, and names
the approver/date. Once approved, comparisons are valid only when hardware identifier, macOS,
Xcode, Swift, thermal state, and protocol exactly match the recorded baseline. GitHub-hosted
runs therefore remain safety gates unless they match the approved release-candidate environment.

## Third-party Action pins and licenses

Every `uses:` reference is pinned to the full commit SHA reviewed on 2026-07-13. All listed
actions are published under the MIT License. Renovation requires reviewing the upstream diff and
license, updating this table and the SHA references together, and passing
`Scripts/verify-repo-facts.sh`.

| Action | Reviewed revision | Upstream tag | License |
| --- | --- | --- | --- |
| `actions/checkout` | `34e114876b0b11c390a56381ad16ebd13914f8d5` | `v4` | MIT |
| `actions/setup-node` | `49933ea5288caeca8642d1e84afbd3f7d6820020` | `v4` | MIT |
| `actions/configure-pages` | `983d7736d9b0ae728b81ab479565c72886d7745b` | `v5` | MIT |
| `actions/upload-pages-artifact` | `7b1f4a764d45c48632c6b24a0339c27f5614fb0b` | `v4` | MIT |
| `actions/deploy-pages` | `d6db90164ac5ed86f2b6aed7e0febac5b3c0c03e` | `v4` | MIT |
| `actions/dependency-review-action` | `2031cfc080254a8a887f58cffee85186f0e49e48` | `v4.9.0` | MIT |

Release, signed-rehearsal, tag, and emergency-withdrawal controls are documented in
[`Release-Protection.md`](Release-Protection.md). Run
`Scripts/verify-release-protection.sh` to verify that the repository-owned half of those
controls has not drifted; attach live GitHub ruleset and environment evidence separately.
