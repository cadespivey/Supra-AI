# Command and evidence log

This log records result summaries without secrets, restricted binaries, or client-like data. Commands ran from the detached clean worktree unless another location is stated.

## Baseline and environment

| Command | Result summary |
|---|---|
| `git fetch origin`; `git rev-parse HEAD origin/main`; `git status` | Reviewed `24a802cb0ab763a225982813a7b1c374864bbdeb`; fetched origin/main matched; detached worktree clean |
| `git worktree add --detach /tmp/supra-ai-acr-24a802c <sha>` | Fresh review worktree created |
| `sw_vers`; `uname -m`; `system_profiler SPHardwareDataType` | macOS 27.0 (26A5378j), arm64, Apple M4 Pro |
| `DEVELOPER_DIR=... xcodebuild -version`; `swift --version` | Xcode 27.0 beta 27A5194q; Swift 6.4 |
| `find Packages -maxdepth 2 -name Package.swift` | 14 packages enumerated |
| `rg registerMigration ...` | 54 migrations, v001–v054 |

## Builds and tests

| Command | Result summary |
|---|---|
| `DEVELOPER_DIR=... xcodebuild -workspace SupraAI.xcworkspace -scheme SupraAI -destination 'platform=macOS' clean build CODE_SIGNING_ALLOWED=NO` | `BUILD SUCCEEDED`; 0 project-source compiler warnings; destination/AppIntents/icon-script diagnostics |
| `DEVELOPER_DIR=... xcodebuild ... -configuration Release -destination 'platform=macOS,arch=arm64' build CODE_SIGNING_ALLOWED=NO` | Universal arm64/x86_64 `BUILD SUCCEEDED`; 1 project-source compiler warning at `MultilineField.swift:377` |
| `swift test` in every package | 990 tests, 986 pass, 0 fail, 4 skipped; exact matrix in `06-test-and-verification-matrix.md` |
| `xcodebuild ... test -only-testing:SupraAIUITests` | 3/3 passed in 80.157 s; xcresult under DerivedData test logs |
| Targeted `CitationCoverageTests/testCitedAnswerPasses` | Passed; confirms arbitrary resolved `[S1]` needs no review |
| Targeted `LegalResearchWorkflowTests/testInRangePacketLabelCountsAsACitation` | Passed; confirms bare `[A1]` counts as citation |
| Targeted `MatterDraftingControllerTests/testLetterBodyScanFlagsCitationsAndPlaceholders` | Passed; confirms successful artifact plus blocking notes |

The project-source compiler-warning count was 0 for the Debug build and 1 for Release. Dependency/tool diagnostics were repeated across package invocations and were not normalized into a single aggregate count; observed categories included deprecated ZIPFoundation watchOS v4 manifest support, a deprecated ZIPFoundation initializer in an export test, unused `try?` results in Store/Sessions code, and AppIntents metadata skipping. Warnings were not suppressed.

## Required test-methodology safeguards

The four documented greps ran over Swift test paths:

| Pattern | Result |
|---|---:|
| short `XCTAssertFalse(...contains(...))` candidates | 29 lines in 16 files; manually sampled |
| `guard ... else { return }` | 1 (`ResearchAuthoritiesUITests.swift:150`) |
| ignored/bare throwing operations | 413 broad candidates; predominantly setup/assert-throws mechanics |
| `contains("")` | 0 |

Additional inventory found six `XCTSkip*` call sites and fourteen test `Task.sleep` call sites.

## Targeted temporary adversarial probes

### Historical migrations

1. Detached worktrees were created at tags `v1.4.1` and `v2.0.0`.
2. Temporary Store tests created `/tmp/supra-acr-v1.4.1.sqlite` and `/tmp/supra-acr-v2.0.0.sqlite` with synthetic matter/chat/setting data.
3. A temporary current-main Store test copied and opened each fixture.
4. Both upgraded to v054, preserved seeded data, and passed integrity/foreign-key assertions.
5. `sqlite3` then confirmed FTS integrity and sampled orphan counts of zero.

### Matter isolation

A temporary `SupraSessionsTests` test indexed `CURRENT_MATTER_CANARY` and `OTHER_MATTER_CANARY` in separate matters. Document Q&A for the current matter included only the current canary in the model prompt and persisted source IDs only from that matter. Test passed.

### Billing isolation

A temporary `SupraSessionsTests` test created two matters with distinct client/rule canaries and one day's entry mentioning only the current matter. Captured prompt contained the unrelated client/rule; a model payload assigning the current entry ID to the unrelated matter persisted successfully. Test passed as a defect proof.

### Redirect containment

A controlled two-loopback-server Foundation probe sent an initially policy-approved request that redirected to a distinct disallowed host. `URLSession` followed the redirect and received 200. The second server observed the request. Synthetic authorization was stripped on the host-changing redirect; no real token was used. A same-host/different-port variant also stripped the synthetic header. Unauthorized egress—not credential leakage—was reproduced.

### Temporary file lifecycle

Created temporarily:

- `Packages/SupraStore/Tests/SupraStoreTests/ACRFixtureExportTests.swift` in v1.4.1/v2.0.0 worktrees
- `Packages/SupraStore/Tests/SupraStoreTests/ACRUpgradeVerificationTests.swift` in current review worktree
- `Packages/SupraSessions/Tests/SupraSessionsTests/ACRMatterIsolationTests.swift`
- `Packages/SupraSessions/Tests/SupraSessionsTests/ACRBillingIsolationTests.swift`
- four synthetic `/tmp/supra-acr-*.sqlite` source/upgraded fixture files

All temporary Swift test files were removed with patches and each worktree returned clean before deliverables were written. Temporary databases and all detached review/tag worktrees were removed before handoff.

## Website, dependencies, and verification scripts

| Command | Result summary |
|---|---|
| `npm ci` | 362 packages installed; 2 moderate audit entries |
| `npm run lint` | Pass |
| `npm run typecheck` | Pass |
| `npm run build:pages` | Pass; 9 static routes generated |
| `npm audit --json` | PostCSS XSS advisory through Next 16.2.6; 0 high/critical |
| `bash Scripts/verify-model-ids.sh` | 26/26 Hugging Face repo IDs returned HTTP 200 |
| `bash Scripts/verify-public-font-license.sh` before/after build | Pass both times |
| `rg` over generated `website/out` | No Equity or embedded-font marker |

## Secrets, network, persistence, and code inventory

| Command | Result summary |
|---|---|
| `rg URLSession|URLRequest|NWConnection|WKWebView|Process` | Authorized client, Hugging Face, authority WKWebView, request constructors inventoried |
| `rg DatabaseQueue|DatabasePool|sqlite3` | Production opens located only in SupraStore |
| high-confidence secret regex scan of tree and reachable history | No key/token/private-key hit; only `.env.example` path in env-file inventory |
| `git lfs ls-files` | No LFS files reported |
| `git ls-files` for release/database/font/key binaries | No tracked DMG/ZIP/DB/font/key artifacts |
| `stat` on synthetic SQLite | Plain mode 0644 in `/tmp`; real container not measured |

No dedicated secret-scanner binary was present. The pattern scan did not print suspected values.

## Release and licensing evidence

| Command | Result summary |
|---|---|
| `shasum -a 256` on local v2.2.0 DMG/ZIP | DMG `cda84e...7a29`; ZIP `3dc060...2916` |
| `gh release view v2.2.0 --json assets...` | Public asset digests and sizes exactly matched local artifacts |
| `codesign --verify --deep --strict`; `codesign -d --verbose=4` | Valid Developer ID universal app; hardened runtime; stapled ticket |
| `codesign -d --entitlements` app/XPC | App and XPC sandbox true; app network/read-write/bookmark/Sparkle exceptions confirmed |
| `spctl -a ...` app and DMG | Both accepted as notarized Developer ID |
| `xcrun stapler validate` app and DMG | Pass |
| `hdiutil imageinfo/attach -readonly`; mounted file scan; detach | Image checksums verified; only app and Applications link; no restricted/font/db/key/dSYM files |
| `unzip -l/-Z1`; bundle `find`; binary `strings` filter | No prohibited/private asset; one AppleDouble icon entry; environment variable names only |
| `git rev-list --objects --all` and normal history path/hash scan | No Equity paths/known prohibited IDs in reachable local branch/tag history |
| `git ls-remote origin 'refs/pull/*/head'` | Public hidden PR refs still advertised |
| GitHub tree metadata for refs 39–50 | Each head contained six prohibited Equity font paths |

The restricted files themselves were never opened, downloaded, copied, or included in these deliverables.

## Final workspace checks

Before handoff:

- At initial review handoff, the primary checkout retained the pre-existing untracked `Backup-Feature-Plan.md` plus this review directory. The repository owner subsequently directed deletion of that plan; it is absent. The review directory is the evidence-only change layered on the immutable final source snapshot.
- Review and historical worktrees were checked clean after temporary test removal, then removed.
- Required artifacts and CSV schema/counts were validated programmatically.

## Remediation verification — 2026-07-13

This section is separate from the historical review log above. It records final remediation evidence produced on `remediation/acr-program`. The initial integrated record was produced at `19e06b451cd585f7b7b360ea916e992339b46845`; the final release-hardening rerun below was produced from clean source snapshot `fce83ebf462c76b60203eb9ccb5db4ed00c7a0de`. The evidence-only commit is the commit containing this report and is resolved with `git log -1 --format=%H -- review/adversarial-code-review/12-remediation-execution-report.md`.

### Initial integrated evidence

| Command / evidence | Result summary |
|---|---|
| `git rev-parse HEAD` before the initial integrated gates | `19e06b451cd585f7b7b360ea916e992339b46845`. |
| Three targeted remediation/accessibility UI selectors | 3/3 passed: `testLegacyBillingWarningAnnouncesReviewAndUnavailableExport`, `testLegacyOutputWarningAnnouncesStatusAndUnavailableExport`, and `testBlockedDraftIsAnnouncedWithoutFileActions`. xcresult: `/tmp/SupraAI-FINAL-UI-WARNFIX-2/Logs/Test/Test-SupraAI-2026.07.13_09-34-25--0400.xcresult`. One Xcode internal QoS priority-inversion runtime warning; zero project-source warnings; four MLX dependency parse warnings. |
| Two targeted XPC UI selectors | 2/2 passed: `testHostedBoundaryLifecycle` and `testSwitchBindingAndKeyboardTraversal`; lifecycle assertion 20/20. xcresult: `/tmp/SupraAI-FINAL-SOURCE-XPC/Logs/Test/Test-SupraAI-2026.07.13_09-37-12--0400.xcresult`. No test runtime warning; zero project-source diagnostics; four MLX parse warnings, AppIntents metadata messages, and one Xcode/MLX graph warning. |
| `Scripts/verify-runtime-xpc-boundary.sh` | Passed the embedded signed-boundary source/entitlement gate. |
| XPC ownership, cancellation, and model-directory controls | Invalid/nil grants, missing identities, same-path replacement, containment escape, foreign cancellation, reused IDs, reservation-before-admission, reconnect, and concurrent load/unload cases passed. App-signer stale persistent bookmarks require reauthorization; cross-signer stale resolution is accepted only with active scope, canonical containment/existence, and matching device/inode identity. This does not claim content-hash protection against in-place shard mutation. |
| `bash Tests/Scripts/test-macos-ci-gates.sh` | 18/18 integration-hook cases passed. |
| `bash Scripts/verify-migration-sequence.sh`; `DEVELOPER_DIR=... bash Scripts/run-shipping-migration-fixtures.sh` | Migration sequence 57/57 from v001 through v057; shipping fixtures 5/5 passed with zero failures. Fixtures are synthetic. |
| `DEVELOPER_DIR=... bash Scripts/build-macos-app.sh Debug`; same command with `Release` | Both unsigned app and embedded-XPC builds passed with zero project-source warnings. Each log contains four MLX dependency warnings and two AppIntents metadata warnings. Logs: `/var/folders/sm/f_hldqys7m10_0nddgs0n3fc0000gn/T/SupraAI-Debug.xcodebuild.log` and `/var/folders/sm/f_hldqys7m10_0nddgs0n3fc0000gn/T/SupraAI-Release.xcodebuild.log`. |
| RuntimeClient TSan and ASan | 4/4 passed under each sanitizer at the initial integrated snapshot `19e06b451cd585f7b7b360ea916e992339b46845`; this was not rerun at `fce83eb`. |
| Hosted lifecycle TSan | 1/1 passed at the initial integrated snapshot with no sanitizer finding. xcresult: `/var/folders/sm/f_hldqys7m10_0nddgs0n3fc0000gn/T/SupraAI-XPC-thread-50164/Logs/Test/Test-SupraAI-2026.07.13_09-45-24--0400.xcresult`. |
| Hosted lifecycle ASan | 1/1 passed at the initial integrated snapshot with no sanitizer finding. xcresult: `/var/folders/sm/f_hldqys7m10_0nddgs0n3fc0000gn/T/SupraAI-XPC-address-51847/Logs/Test/Test-SupraAI-2026.07.13_09-46-50--0400.xcresult`. |
| Hosted lifecycle UBSan | Excluded after an attempted run: the embedded XPC failed to link because `___ubsan_handle_*` runtime symbols were unresolved; no test executed and no pass is claimed. xcresult: `/var/folders/sm/f_hldqys7m10_0nddgs0n3fc0000gn/T/SupraAI-XPC-undefined-53443/Logs/Test/Test-SupraAI-2026.07.13_09-48-48--0400.xcresult`. |

### Final 2.2.1 and signed-smoke hardening rerun

| Command / evidence | Result summary |
|---|---|
| `git rev-parse HEAD` before final gates | `fce83ebf462c76b60203eb9ccb5db4ed00c7a0de`; source changes were clean and only evidence-document edits remained outside the source inputs. |
| `bash Scripts/verify-repo-facts.sh` | Passed: 3 targets, 14 packages, app 2.2.1 build 387, XPC build 387. |
| `DEVELOPER_DIR=... bash Scripts/test-all-packages.sh` | All 14/14 package suites passed with zero failures; `SupraRuntimeInterface` passed 27/27 and `SupraSessions` passed 493/493. |
| `bash Tests/Scripts/test-macos-ci-gates.sh` | All current integration-hook mutation cases passed. |
| `bash Tests/Scripts/test-verify-product-claims.sh`; `bash Scripts/verify-product-claims.sh` | Wrapper normal/mutation cases passed; 21 claims across 14 packages passed with latest migration v057. |
| `bash Tests/Scripts/test-release-transaction.sh`; `bash Scripts/verify-release-protection.sh` | All current hermetic release-transaction, rollback, signed-evidence, and isolated-runner policy cases passed. No tag, release, upload, setting, public ref, or live appcast state changed. |
| Migration gates | Migration sequence 57/57 and shipping migration fixtures 5/5 passed with zero failures; fixtures remain synthetic. |
| Final content-bound hosted lifecycle selector | 1/1 passed at the final SHA with the exact model fingerprint attested through XPC. xcresult: `/tmp/SupraAI-XPC-GREEN-FINAL/Logs/Test/Test-SupraAI-2026.07.13_13-52-41--0400.xcresult`. The earlier full hosted selector pair passed 2/2 before the final snapshot-cleanup-only hardening commits. |
| Final vertical-window regression selectors | 2/2 passed: `testBlockedDraftIsAnnouncedWithoutFileActions` and `testLegacyOutputWarningAnnouncesStatusAndUnavailableExport`. Both assert stable window y-origin and height. xcresult: `/tmp/SupraAI-XPC-GREEN-FINAL/Logs/Test/Test-SupraAI-2026.07.13_13-56-21--0400.xcresult`; one Xcode internal QoS runtime warning remains recorded. |
| XPC content binding and snapshot cleanup | Exact canonical fields, tree hash, and fingerprint are bound into authorization; the private snapshot is reverified after load and retained through generation/unload. Snapshot tests passed 15/15, including descriptor-anchored deletion and bounded retry. Same-UID pathname mutation/cleanup races remain isolated-runner threats rather than claimed closed. |
| Current Debug and Release build evidence | The current Debug app/XPC built as part of the hosted test. A fresh and incremental universal unsigned Release app/XPC build succeeded at `/tmp/supra-content-bound-release`. Xcode emitted known dependency/AppIntents diagnostics; no new changed-source compiler failure occurred. |
| `bash Scripts/test-website.sh` | Pre/post public-font guards, `npm ci`, lint, typecheck, static build, and audit threshold passed. Registry audit reported two moderate transitive Next/PostCSS findings and no high/critical finding; the offered forced fix was breaking and was not applied. |
| CSV/deliverable validation and patch hygiene | 13 files match 13 manifest entries; CSV has 15 headers and 15 data rows, 15 fields per row, and unique contiguous SA-ACR-001…015 IDs. SA-ACR-004's Status is the intentional disposition edit. `git diff --check` and staged `git diff --cached --check` pass. |

### Evidence boundaries

- Current GitHub hidden pull-request refs/caches are not a local verification gate for this execution; the repository owner assigned existing public objects to GitHub Support. Preventive source controls remain mandatory.
- No real release, tag, appcast, upload, GitHub setting, or public ref was mutated during remediation verification.
- No attorney approval, real protected model weight, production credential/provider, live protected ruleset, dedicated ephemeral isolated runner/private model mount, hostile Developer ID peer, forced service kill/relaunch, or Developer ID signed/notarized remediated release candidate was available. These are release qualifications, not silently inferred successes.
