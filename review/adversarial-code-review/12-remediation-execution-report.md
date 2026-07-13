# Remediation execution report

## 1. Identity, scope, and reading rule

| Item | Value |
|---|---|
| Historical review baseline | `main` at `24a802cb0ab763a225982813a7b1c374864bbdeb` |
| Remediation branch | `remediation/acr-program` |
| Execution date | 2026-07-13 |
| Pre-XPC-integration implementation snapshot | `815180c2fbf2ca6921e913923383cf13e20a215d` |
| Final integrated implementation snapshot | `f24c792179137557ae61f259f18a209c9790b345` |
| Evidence-only deliverable commit | The commit containing this report; resolve with `git log -1 --format=%H -- review/adversarial-code-review/12-remediation-execution-report.md` |
| Findings in scope | SA-ACR-001 through SA-ACR-015 |

The historical portions of documents `00` through `11` preserve the adversarial assessment of the historical review baseline; dated appendices record later remediation without retroactively changing that assessment. The exact final source SHA is fixed above. The initial XPC contract/follow-up RED commits are `2d91ed613fe0b82de0116ed635160e9fcc1708a9` and `945497a1ca94f41480018192582792fdf78a84bf`; the corresponding GREEN commits are `9874920c4b8ac94491b583569c4ba7c04e41497e` and `b656cdb0385d4db4bd29c0a32f75980dec4953d0`. Later RED/GREEN sequences bind release authorization to exact model content, load from a private descriptor-retained XPC snapshot, harden cleanup, require repository-owned signed-smoke evidence, and enforce a dedicated ephemeral isolated runner. The final portability sequences are RED `0a452dd` to GREEN `3a55987` for main-actor live-resize observers and RED `ddda8b6` to GREEN `f24c792` for deterministic output-warning navigation. Because a commit cannot embed its own final object ID, the evidence commit is self-locating by path.

The final source implementation closes or materially contains every locally remediable finding at the deterministic source-gate level. Final XPC/concurrency integration and the combined gates passed as recorded below. Current GitHub-owned hidden refs/caches remain outside local source control and were assigned by the repository owner to GitHub Support.

## 2. Outcome

The remediation changed the product from label-presence and best-effort safety checks to fail-closed, test-bound invariants:

1. Legal and document propositions require retained source support; short, unhydrated, unknown, value-conflicting, or limiting-language-conflicting evidence is unsupported or unverifiable rather than clean.
2. Drafting verification runs before renderer, filesystem, success audit, and file actions. A blocking result cannot become a normal downloadable artifact.
3. Network policy is evaluated for every redirect hop with explicit credential scope, bounded redirect count, and typed failure.
4. Billing context is derived from included evidence edges; unrelated client/rule context and fabricated or foreign source assignments cannot persist.
5. Diagnostic query identity uses a per-install keyed HMAC, and Release credential composition is Keychain-only.
6. Managed blobs, exports, drafts, and model installations use verified atomic replacement. Model registration requires a revision-bound manifest, required-file set, sizes, and hashes.
7. Hostile imports are type-, path-, containment-, and resource-bounded; shipping-version migration fixtures exercise integrity and recovery permanently.
8. macOS CI, product-claim validation, release preflight, and transaction rollback are fail-closed source controls. The release transaction binds artifacts to an exact source SHA, app/model evidence, and repository-owned signed-smoke result and was tested hermetically without publishing.
9. Remediation/recovery warnings are accessible, synchronized without silent test setup returns, and linked to executable product claims.
10. Hosted XPC operations bind authorization, exact model content, task admission, cancellation, and terminal delivery to the owning connection and request epoch. Release loads use verified private snapshots with bounded descriptor-anchored cleanup; the remaining same-UID pathname race is assigned to the mandatory isolated-runner boundary.
11. macOS window sizing no longer feeds continuous SwiftUI measurement changes back into window height/origin updates; live-resize callbacks synchronously re-enter the main actor, and the final 5/5 app/UI/XPC smoke includes drafting/output selectors that assert stable y-origin and height.

This is not yet a production-release authorization. Section 7 lists the external and signed-release qualifications that remain.

## 3. Conservative finding disposition

| Finding | Disposition | Source evidence | Residual qualification |
|---|---|---|---|
| SA-ACR-001 | **External — GitHub Support (preventive controls remediated)** | Metadata-only asset audit, repository/Pages/release gates: `393b382`, `db7846f`, `50388c3` | No claim that GitHub's existing hidden refs/caches are deleted or garbage-collected. |
| SA-ACR-002 | **Mitigated — code remediated; attorney review pending** | Fail-closed legal support and shared corpus: `efc007a`, `ec94b2d`, `64508f9`, `ead5f71`, `2b9d548` | Corpus remains `pending_attorney_review`; code cannot establish good-law or professional sufficiency. |
| SA-ACR-003 | **Mitigated — code remediated; attorney review pending** | Proposition support, untrusted-source fencing, scoped repair/provenance: `ec71d32` through `539acab` | Same attorney-domain boundary as SA-ACR-002. |
| SA-ACR-004 | **Remediated** | Pre-render blocking: `365c3e4`, `47d7243`; accessible recovery/window stability: `aadd058`, `05c488e`, `073fe65`, `19e06b4`, `e8ac6cd`; main-actor/navigation portability: `0a452dd`, `3a55987`, `ddda8b6`, `f24c792`; final smoke 5/5 with vertical subset 2/2 | Source defect and deterministic regression gate are closed. This is not attorney approval or broad accessibility certification. |
| SA-ACR-005 | **Remediated** | Redirect/credential matrix and transport implementation: `c3e733f` through `5a5dda3` | Live provider redirect chains were not exercised with production credentials. |
| SA-ACR-006 | **Remediated** | Durable writer and managed-blob integrity: `dac7062`, `0df306a`, `c25ad59`, `63cf63f` | Production-scale/container fault behavior remains broader operational qualification. |
| SA-ACR-007 | **Remediated** | Evidence-derived billing scope: `130f28e`, `b15d9af` | User review remains required for intentionally ambiguous/multi-matter evidence. |
| SA-ACR-008 | **Remediated** | Shared formula-safe tabular exports: `84cf953`, `6465a9b` | No claim of exhaustive interoperability across every spreadsheet application/version. |
| SA-ACR-009 | **Remediated** | Atomic export/draft persistence: `59bf19a`, `aa3a6c6` | Disk/device failures outside injected deterministic cases remain operational risk. |
| SA-ACR-010 | **Remediated — real-weight qualification remains limited** | Revision-bound manifests/artifact verification: `7450644`, `a0cc04a`; content/snapshot RED: `417511c`, `2b45a14`, `f9ffea3`, `a387a19`; GREEN: `1c4e5fa`, `67749f4`, `e1d60b5`, `fce83eb` | No protected real weights, long generation, or production memory-pressure qualification. |
| SA-ACR-011 | **Remediated** | Hostile import boundary corpus and bounded implementation: `a735fdb`, `ad9730c` | Large multilingual OCR/parser corpora remain additional robustness work. |
| SA-ACR-012 | **Mitigated — source controls complete; live rulesets and signed rehearsal pending** | CI/transaction gates: `26b9de8`, `f1d12b7`, `abb24b0`, `1a04b46`, `4acd069`; signed-smoke/isolation RED: `629e72d`, `24d8538`, `183162b`, `22d9c1d`, `0e34bde`, `090b04b`, `f45b5dc`, `bb17895`, `51fb861`, `d795f57`; GREEN: `4cdd40c`, `89473ef`, `66d6c6e`, `6929764`, `f7feae6`, `c54acf9`, `f009d9d` | Protected GitHub rulesets/environment, isolated runner, and signed/notarized release rehearsal are external. |
| SA-ACR-013 | **Remediated** | Shipping-version upgrade/snapshot/recovery matrix: `d1ad3c1`, `d7fb385` | Fixtures are synthetic, not consented production databases. |
| SA-ACR-014 | **Remediated** | Versioned executable claims and drift fixtures: `d7def2e`, `4e08203`, `815180c`, `fce83eb` | Final verification passed 21 claims across 14 packages with migration v057; this remains a required future release gate. |
| SA-ACR-015 | **Remediated** | Per-install HMAC fingerprinting: `8245011`, `91356f2` | Diagnostic correlation intentionally changes when the install key rotates. |

The `Status` column in `05-findings-index.csv` is the machine-readable source of these dispositions. It may be strengthened only by adding the evidence specified here; it must not be weakened to make a release gate pass.

## 4. RED/GREEN implementation ledger

| Control group | RED evidence | GREEN evidence | Safety property established |
|---|---|---|---|
| Public-asset prevention | `393b382` | `db7846f`, `50388c3` | Known prohibited paths/hashes and generated public artifacts fail closed without retrieving restricted binaries. |
| Verification provenance | `5b25918` | `3a12f4b` | Legacy and new outputs carry explicit support state and revalidation semantics. |
| Redirect policy | `c3e733f`, `9868732`, `2d133747`, `de29d957`, `9137454`, `a23747c`, `50ee9c4`, `e66e695`, `53cf0be` | `5a5dda3` | Every hop is authorized; disallowed origins receive no request; credential forwarding is scoped. |
| Billing isolation | `130f28e` | `b15d9af` | Prompt and persistence cannot cross beyond the included evidence graph. |
| Fingerprints and credentials | `8245011`, `10982f6` | `91356f2`, `1587aa4` | Diagnostics are pseudonymous per install; Release keys are Keychain-sourced. |
| Durable writer/blobs/exports | `dac7062`, `c25ad59`, `59bf19a` | `0df306a`, `63cf63f`, `aa3a6c6` | Success is reported only after synchronized, verified, atomic replacement. |
| Document support | `ec71d32`, `478acc7`, `71c47ad`, `821fa66`, `5d5c9dc`, `85a955b` | `094bc09`, `539acab` | Citation labels cannot substitute for proposition support; critical values and limitations remain bound. |
| Drafting | `365c3e4` | `47d7243` | Blocking content reaches neither renderer nor normal artifact/file actions. |
| Legal support/corpus | `efc007a`, `64508f9` | `ec94b2d`, `ead5f71`, `2b9d548` | Short/unhydrated authority and value conflicts fail closed against shared deterministic cases. |
| CSV hardening | `84cf953` | `6465a9b` | Every untrusted tabular cell uses the shared formula-safe encoder. |
| Existing-user recovery | `0527a73` | `8a6c942` | Affected prior output is visibly review-required with audited recovery commands. |
| Model manifests | `7450644` | `a0cc04a` | Nonmanifest, floating-revision, truncated, wrong-size/hash, or escaping model content cannot load. |
| Shipping migrations | `d1ad3c1` | `d7fb385` | Supported-version upgrades require verified snapshot/recovery and database integrity. |
| macOS CI | `26b9de8`, `f1d12b7` | `abb24b0` | Package inventory, Swift/app/UI/migrations/security/site controls are encoded as required jobs. |
| Hostile imports | `a735fdb` | `ad9730c` | Import traversal, symlink, type confusion, and resource exhaustion fail deterministically. |
| Release transaction | `1a04b46` | `4acd069` | Preflight is SHA-bound; failure before publication leaves no public release; postpublication failure has rollback semantics. |
| 2.2.1 candidate and signed smoke | `24d7416`, `50e82f7`, `4414dfc`, `71ba271`, `a43745a`, `feb2529`, `629e72d`, `24d8538`, `183162b`, `22d9c1d`, `0e34bde`, `090b04b`, `f45b5dc`, `bb17895`, `51fb861`, `d795f57` | `e8e8be2`, `7983602`, `e051c78`, `4cdd40c`, `89473ef`, `66d6c6e`, `6929764`, `f7feae6`, `c54acf9`, `f009d9d` | Version/build coherence, repository-owned signed-app/XPC execution, strict reproducible evidence, post-smoke app revalidation, and exact isolated-runner policy fail closed before publication. |
| Claims/accessibility | `aadd058`, `d7def2e`, `d05062f`, `e3a28c5` | `05c488e`, `4e08203`, `815180c`, `073fe65`, `19e06b4`, `e8ac6cd`, `fce83eb` | Exact claims are versioned/test-linked; warning/recovery surfaces and smoke hooks fail closed; final vertical-window selectors pass. |
| Window observer actor portability | `0a452dd` | `3a55987` | All three live-resize callbacks synchronously re-enter the main actor without unstructured-task ordering or lifetime changes; the scoped gate prevents regression. |
| Deterministic output-warning navigation | `ddda8b6` | `f24c792` | The smoke requires the output row to exist and be hittable, then exercises the production navigation path and destination deterministically under local Xcode 27 and GitHub Xcode 16.4. Direct synthesized-click coverage remains an explicit limitation. |
| XPC/concurrency | `2d91ed6`, `945497a` | `9874920`, `b656cdb` | Hosted boundary identity, origin-specific bookmark handling, connection-bound cancellation, reservation/admission, exactly-once terminal delivery, reconnect/load races, and 20/20 lifecycle iterations passed. TSan/ASan passed; UBSan and real-weight resource qualifications remain explicit limitations. |
| Content-bound XPC snapshots | `417511c`, `2b45a14`, `f9ffea3`, `a387a19` | `1c4e5fa`, `67749f4`, `e1d60b5`, `fce83eb` | Release load copies and rehashes the exact revision-bound tree, attests the fingerprint through XPC, retains descriptors through use, and performs bounded descriptor-anchored cleanup. Same-UID pathname races remain an isolated-runner qualification. |

Every implementation group retained a separately observable RED contract before the GREEN change. The historical review package was not used as a substitute for executable regression tests.

## 5. Verification evidence

### Evidence already produced at the pre-XPC snapshot

| Gate | Result |
|---|---|
| Release transaction failure-injection suite | 32/32 passed; hermetic/mock only; no external state changed. |
| Product-claim wrapper | Passed normal, package-drift, wording-drift, and missing-owner cases. |
| Product claims | 20 claims, 14 packages, migration v057 passed at that snapshot. |
| Website | License checks, install, lint, typecheck, static build, and postbuild license check passed; two moderate registry audit findings remain documented. |
| Focused model/matter tests | `ModelAutoAssignLoadTests` 5/5 and four affected matter sort/pin tests passed. |
| App Debug build | Succeeded after claims/accessibility integration. |
| Billing remediation UI | Passed. |
| Output remediation UI before window-restoration integration | Safety state and labels were present, but the test failed because the restored split view was offscreen and Reverify was not hittable. This is explicitly not a pass. |
| Patch hygiene | `git diff --check` passed. |

### Final integrated verification record

Release-hardening commands ran with HEAD fixed at `fce83ebf462c76b60203eb9ccb5db4ed00c7a0de`; final portability and integrated smoke verification ran at `f24c792179137557ae61f259f18a209c9790b345`. Local app commands selected the Xcode beta through `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`; GitHub app builds used Xcode 16.4. Exact xcresult/log paths contain no secrets or client-like data. Sanitizer evidence explicitly remains associated with the earlier snapshot on which it ran.

```sh
bash Tests/Scripts/test-macos-ci-gates.sh
bash Tests/Scripts/test-verify-product-claims.sh
bash Tests/Scripts/test-release-transaction.sh
bash Scripts/verify-release-protection.sh
bash Scripts/verify-repo-facts.sh
bash Scripts/verify-product-claims.sh
bash Scripts/verify-migration-sequence.sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer bash Scripts/run-shipping-migration-fixtures.sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer bash Scripts/test-all-packages.sh
bash Scripts/test-website.sh
git diff --check
```

The earlier integrated execution ran the combined legacy output/billing and drafting accessibility selectors, the hosted real-XPC selector pair with 20 consecutive lifecycle iterations, and sanitizer gates. Release hardening at `fce83eb` separately reran the content-bound hosted lifecycle and both window-stability selectors. At the final SHA, the combined app/UI/XPC smoke passed all five selected tests, and the exact-head CI reran all packages plus Debug and Release app/XPC builds. Exact commands and outcomes are recorded in `11-command-and-evidence-log.md`; unavailable or excluded tools are not represented as passes.

| Final gate | Evidence |
|---|---|
| Final integrated source SHA | `f24c792179137557ae61f259f18a209c9790b345` |
| Earlier remediation/accessibility selectors | Output/billing 2/2 and drafting 1/1 passed in `/tmp/SupraAI-FINAL-UI-WARNFIX-2/Logs/Test/Test-SupraAI-2026.07.13_09-34-25--0400.xcresult`. The bundle contains one Xcode internal QoS runtime warning; this evidence belongs to the earlier integrated snapshot. |
| Final app/UI/XPC smoke | 5/5 passed at `f24c792`, including the 2/2 drafting/output vertical-window subset and both hosted XPC selectors. xcresult: `/tmp/SupraAI-FULL-SMOKE-f24c792.xcresult`; one Xcode-internal QoS priority-inversion warning remains recorded. |
| Release-hardening content-bound hosted lifecycle | 1/1 passed at `fce83eb` with the exact fingerprint attested through XPC. xcresult: `/tmp/SupraAI-XPC-GREEN-FINAL/Logs/Test/Test-SupraAI-2026.07.13_13-52-41--0400.xcresult`. The earlier full selector pair passed 2/2 with lifecycle 20/20 before the snapshot-cleanup-only commits. |
| XPC identity, content binding, and cleanup | Signed-boundary gate passed. Invalid grants, identity mismatch/replacement, containment escape, and content mismatch are rejected. Release load uses a reverified private snapshot retained through generation/unload; descriptor-anchored cleanup tests passed 15/15. Same-UID mutate/restore and unlink races remain isolated-runner threats. |
| macOS CI, facts, claims, and migrations | Exact-head [protected macOS CI run 29275806317](https://github.com/cadespivey/Supra-AI/actions/runs/29275806317) passed 22/22 jobs; model-catalog run `29275806331` passed. Hook mutation suite passed; repository facts passed for 2.2.1 build 387; claims wrapper passed; 21 claims/14 packages/v057; migration sequence 57/57. |
| All package suites | 14/14 package suites passed with zero failures. |
| Shipping migration fixtures | 5/5 passed with zero failures; synthetic-fixture limitation retained. |
| Debug and Release builds | The exact final source passed unsigned Debug and Release app/XPC builds under GitHub's Xcode 16.4 jobs. A local Xcode 27 Debug app/XPC build also succeeded as part of the final smoke. No changed-source compiler failure occurred. |
| Website and product-claim gates | Final-source website gate and claims gates passed. Website registry audit retained two moderate transitive Next/PostCSS findings and no high/critical finding. |
| Hermetic release transaction | All current cases passed, including strict signed evidence and isolated-runner policy mutations; no external release state changed. |
| Sanitizers | At the earlier integrated snapshot, RuntimeClient 4/4 passed under TSan and ASan and hosted lifecycle 1/1 passed under each. UBSan was attempted but excluded because the XPC link could not resolve `___ubsan_handle_*`; no UBSan pass is claimed. Sanitizers were not rerun at `f24c792`. |
| CSV/deliverable validation and patch hygiene | 13 files/13 manifest entries; CSV 15 columns × 15 data rows with unique contiguous IDs; SA-ACR-004 Status-only disposition edit; `git diff --check` and staged `git diff --cached --check` pass. |

## 6. Existing-user and recovery behavior

- Outputs created under the former label-presence semantics are not silently upgraded to clean. They are visibly marked for review and expose reverify/regenerate actions.
- Drafting failures return a sanitized blocking state without a normal file URL or Open/Reveal/Share/export action.
- Billing evidence that cannot be assigned safely remains review-required/unassigned; the model cannot invent an evidence edge and persist it.
- Legacy unmanifested or corrupt models are not treated as complete; the safe response is verified redownload/quarantine, not partial load.
- Managed-blob, export, and migration failures preserve the prior valid artifact/database and present an auditable recovery path.
- Accessibility tests must find warning meaning, verification state, and unavailable actions without relying on color alone or silently returning when setup fails.

## 7. External prerequisites and limitations

The following are deliberately not represented as completed:

1. **GitHub Support:** deletion/garbage collection of the already-public hidden pull-request refs and caches. Repository controls prevent recurrence and audit metadata without downloading the restricted files.
2. **Attorney approval:** approval of the proposition-support threshold, pinpoint rules, corpus expectations, good-law/jurisdiction semantics, and user-facing legal warnings.
3. **Protected GitHub configuration:** required live rulesets/checks, protected release environment, dedicated ephemeral `supra-release-isolated` Apple Silicon runner, release credentials, and protected model resources. The smoke driver itself is repository-owned reviewed code, not a secret override.
4. **Signed release candidate:** Developer ID signing, real embedded XPC/model smoke, notarization, stapling, Gatekeeper, ZIP/DMG inspection, Sparkle signature/appcast/install, public digest recheck, and rollback for the exact remediated SHA.
5. **Real model weights/resources:** protected-weight load, long generation, cancellation under compute, switching, peak RSS, and memory-pressure qualification.
6. **Live providers/credentials:** production authentication, provider schema/rate-limit behavior, and real redirect chains.
7. **Broad certification:** production-data migration, exhaustive hostile parser/OCR corpora, full accessibility certification, Instruments, and the UBSan configuration that failed to link the embedded XPC in this Xcode beta toolchain.

## 8. Release decision

**Do not publish solely because the source remediation branch is green.** Local smoke and exact-head CI evidence are complete for `f24c792179137557ae61f259f18a209c9790b345`, with the UBSan/linker and resource limitations stated rather than counted as passes. A release owner may qualify candidate 2.2.1 build 387 only after the applicable attorney-domain, protected-infrastructure, real-weight/resource, and Developer ID signed/notarized prerequisites above are satisfied. Existing public refs remain with GitHub Support as directed by the repository owner.

SA-ACR-001's existing public-ref state is tracked through GitHub Support rather than re-audited or mutated by this execution. That ownership decision does not permit removing the preventive font/path/hash guards from CI, Pages, or release preflight.

## 9. Final handoff checklist

- [x] Record the integrated XPC pairs and both final window/CI portability RED/GREEN pairs.
- [x] Record the full verified source SHA.
- [x] Record exact final results, counts, xcresult/log paths, warnings, and exclusions.
- [x] Change SA-ACR-004 to `Remediated` in this report and only its `Status` field in `05-findings-index.csv`.
- [x] Record XPC, sanitizer, identity, signing, and real-weight/resource limitations in `10-open-questions-and-limitations.md`.
- [x] Validate 15 CSV columns, 15 data rows, 15 fields per row, and unique contiguous SA-ACR-001…015 IDs. No immutable historical CSV baseline is claimed; the intentional machine-readable edit is SA-ACR-004's Status.
- [x] Run unstaged and staged patch-hygiene checks and verify the evidence commit contains the intended `review/adversarial-code-review/` artifacts only.
- [x] Make the evidence commit self-locating by report path and use `remediation/acr-program` as the requested push target without creating a release.
