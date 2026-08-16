# Case File Review Retirement Receipt

**Captured:** 2026-08-13 (America/New_York)

**Validated implementation commit:** `30264243587e7997dc99a19741b85d6c2010f7ca`

**Branch:** `codex/architecture-ux-r0`

**Scope:** WP-1.5 removal, WP-3.1 cancellation-safety extraction, WP-4.7 absence audit,
WP-6.5 residue audit, and WP-6.6 post-removal corpus-ownership decision

**Master-plan SHA-256:**
`5582d4da708d0dfb8ab7ba182da7f6130b35f9b8a10c2d89376ab172c9301bc5`

This receipt records the completed removal of the named **Case File Review** product
capability. It does not retire ordinary research-result review, reviewed-authority state,
document-relation review, drafting review notes, citation-review requirements, Chat's **Review
a Draft**, generic `needsReview` states, or the retained corpus/exhaustive substrate.

## 1. Test-first history

The retirement was developed as observable RED contracts followed by a separate GREEN
implementation. The principal history is:

| Commit | Evidence or implementation |
|---|---|
| `a041caaa` | RED legacy queue-admission/relaunch contracts |
| `6f49462e` | GREEN retired Review queue containment |
| `78b2c633` | RED UI, retained-terms, schema, and exact-residue gates |
| `4124a59b` | RED exact smoke-manifest gate |
| `c2aba4af` | GREEN smoke-selector replacement |
| `6f7d57a0` | RED ordinary runtime cancellation/quarantine/recovery contracts |
| `bdeeb24e` | RED immutable/dormant v072-v073 schema and deletion-compatibility guards |
| `5fedbf7a` | RED cancellation identity/status/quiescence edge-case matrix |
| `30264243` | GREEN end-to-end product retirement and neutral runtime-safety owner |

The GREEN commit removed 15,643 lines and added 884 lines across 43 paths. It deleted the
Review views/controllers/export service, Store repository and records, app composition and
fixtures, Review-only runtime wrapper and model-reservation surfaces, Review-specific tests,
and the now-unowned tabular workbook renderer. It retained the compatibility and unrelated
review/corpus behavior named above.

## 2. Pre-removal quiescence

The companion `Case-File-Review-Quiescence-Receipt.md` records a read-only observation of the
ordinary profile before removal:

- no running Supra app or runtime service;
- zero `document_processing_jobs` rows;
- zero corpus run, partition, or partition-slice rows;
- owner schema endpoint `v072_harden_corpus_review_integrity`;
- no v073 Review schema objects, because the ordinary profile had not yet applied v073.

There was therefore no owner job to cancel or reservation to release. Synthetic queued,
paused, interrupted-active, failed, and completed compatibility fixtures independently prove
that legacy Review work cannot resume, call the runtime, reserve model work, or rewrite a
terminal row.

## 3. Shipping capability boundary

At the validated commit:

- the matter workspace contains exactly Chat, Research, Authorities, Saved Work, Documents,
  Billing, and Audit;
- no Case File Review tab, command, route, setup item, diagnostics status, help text, launch
  argument, accessibility identifier, controller, repository, export action, or runtime
  reservation remains in shipping scope;
- new `guided-review:` admission is rejected before a Store write;
- legacy identity is recognized by either the compatibility job-ID prefix or the decoded
  exhaustive request run key, so historical UUID job IDs cannot bypass retirement;
- bootstrap reconciles an interrupted active Review row to a quiescent state but never
  reactivates it, while a generic FIFO follower may still run;
- exact Review resume is rejected without Store mutation or runner invocation;
- failed and completed Review rows remain byte-identical across bootstrap;
- ordinary stream cancellation now confirms the exact task identity and terminal status;
  mismatched identity, failed status, active `notFound`, another active task, timeout, or
  transport failure quarantines new data-plane work until an owner-operated restart and
  confirmed-idle recovery;
- Advanced Diagnostics owns that recovery action; no Review-specific status is shown.

The compiled-scope verifier allows only exact, hash-pinned compatibility evidence. It scanned
640 shipping files, rejected every retired identifier outside the allowlist, and proved nine
retained ordinary-review/corpus concepts remain. Its adversarial fixture suite passed 9 of 9
cases, including a generic runner composition containing no retired Review token.

## 4. Immutable schema and owner-copy evidence

`Packages/SupraStore/Sources/SupraStore/Database/SupraMigrator.swift` remained byte-identical
through retirement. Its SHA-256 is:

`5ccb066b330581d21c541560edcd88bdbaab12326298b301a80663d81b2fe816`

Standing guards freeze the exact v072 closure, exact v073 closure, their order, migration-ID
sequence, resolved v072 raw-value semantics, and the DEBUG reset compatibility entries. The
final retirement endpoint remains `v073_create_case_file_review_projects`; no table-drop,
renumbering, reinterpretation, or destructive migration was added.

The owner-v072 drill used only a disposable copy:

| Item | Exact observation |
|---|---|
| Ordinary database | `/Users/cadespivey/Library/Application Support/ai.supra.SupraAI/SupraAI.sqlite` |
| Ordinary database SHA-256 before and after | `8dfa556e0768a3ab8711b3c517982bb64c11e0fd03e19ee3e417487f22081b76` |
| Disposable copy | `/private/tmp/supra-owner-v072-drill.q5j5X8/SupraAI.sqlite` |
| Copy SHA-256 before migration | same as the ordinary database |
| Copy SHA-256 after migration | `7f3482632080fb837b57d4778b064e845e0fbaa22c98076f92dd3a4c43b2f95d` |
| Pre-migration safety snapshot | `/private/tmp/supra-owner-v072-drill.q5j5X8/PreMigrationSnapshots/SupraAI-premigration-20260813-220240-606.sqlite` |
| Snapshot SHA-256 | `29cbf8e1323aa7c3db2d55a2a19574eb41a456d4db29b092e02e3f9346602cee` |

The disposable copy applied exact v073, reached the expected endpoint, passed
`integrity_check`, had zero foreign-key violations, retained all 61 pre-existing
non-Review/non-migration table counts and selected settings values, created the seven dormant
Review compatibility tables with zero rows, and reopened deterministically three times. The
ordinary database remained at v072 and was never opened through production migration code.

This owner profile contains no matter, document, output, audit, or managed-blob business rows.
The drill is therefore valid owner-shape and settings-preservation evidence, not a claim of a
rich business-row restore fixture. Synthetic file-backed tests separately retain a nondefault
dormant v073 project and verify exact rows, schema, indexes, triggers, foreign keys, deletion
degradation, integrity, and repeated reopen without a public Review API.

## 5. Artifact and model preservation

Retirement introduced no profile-reset, migration-drop, export-cleanup, model-cleanup, or
filesystem-sweep operation. A standing guard drives interrupted retired-job bootstrap while
nondefault `review-export-713.csv`, `review-export-719.xlsx`, and shared model
`model-727.safetensors` bytes exist, then proves every file remains present and byte-exact. No
ordinary database, backup, exported CSV/XLSX file, or installed model path was deleted or
rewritten. The Review exporter can no longer create new files, but existing files remain
ordinary user-owned filesystem artifacts. A model binary referenced by another role remains
governed by the existing identity/reference checks; retirement does not authorize its removal.

This is a source-retirement guarantee and an observed no-mutation receipt. It is not an
inventory of every external export or model location on every Mac.

## 6. Post-removal corpus ownership decision

The Release app constructs `DocumentProcessingQueue` without a
`CorpusAnalysisQueueRunner`. There is no shipping app composition reference to
`CorpusAnalysisQueueRunner.live` or `ExhaustiveListTask`; a submitted generic corpus job fails
with runner-unavailable before model work. The retained Store/Sessions corpus and exhaustive
types remain tested package-level substrate and immutable compatibility, not an advertised
shipping exhaustive-review workflow.

Accordingly:

- Review-v2 queue composition and callability are absent;
- there are zero concrete non-Review shipping consumers of the retained exhaustive runner;
- the threshold of two shared shipping consumers is not met;
- **no corpus/workflow coordinator extraction is justified**;
- removing the retained generic substrate would require a separate owner decision and its own
  RED/compatibility evidence.

Three verified claims that had described uncomposed exhaustive behavior as production were
removed. `ARCHITECTURE.md` now states the package-only boundary literally.

## 7. Qualification results

All results below were captured at exact implementation commit
`30264243587e7997dc99a19741b85d6c2010f7ca` with Xcode 27.0 (`27A5194q`) and Swift 6.4.

### Fixed fourteen-package matrix

| Package | Executed | Failures |
|---|---:|---:|
| SupraCore | 99 | 0 |
| SupraDesignSystem | 21 | 0 |
| SupraDiagnostics | 5 | 0 |
| SupraDocuments | 272 | 0 |
| SupraDrafting | 58 | 0 |
| SupraDraftingCore | 15 | 0 |
| SupraExports | 62 | 0 |
| SupraNetworking | 41 | 0 |
| SupraResearch | 326 | 0 |
| SupraRuntimeClient | 12 | 0 |
| SupraRuntimeInterface | 29 | 0 |
| SupraSessions | 1,004 | 0 |
| SupraStore | 305 | 0 |
| SupraTestKit | 53 | 0 |
| **Total** | **2,302** | **0** |

The count is the parallel runner's enumerated XCTest set. Xcode also emits a separate Swift
Testing compatibility line reporting zero tests in zero suites; it does not replace the 2,302
enumerated executions.

### App, XPC, and deterministic gates

| Gate | Result |
|---|---|
| Expanded signed Debug app/XPC smoke | 22 executed, 0 failures |
| Smoke XCTest time / observer time | 454.915 s / 461.898 s |
| Release app and XPC build, arm64, signing disabled | `BUILD SUCCEEDED` |
| RuntimeSafetyClient focused suite | 7 executed, 0 failures |
| Retired queue/artifact compatibility suite | 7 executed, 0 failures |
| Retirement residue verifier | PASS; 640 shipping files, nine retained concepts |
| Retirement verifier adversarial fixtures | 9/9 PASS |
| Product-claims verifier and meta-tests | PASS; 43 claims, 14 packages, v073 |
| macOS CI manifest meta-gate | PASS |
| Repository facts, delta manifest, and architecture/UX ledger verifiers | PASS |
| Worktree after qualification | clean |

The native smoke result includes exact remaining-tab/reflow checks, retained ordinary-review
ownership, shared deletion confirmation, and the owned runtime-recovery surface. Its result
bundle was:

`/Users/cadespivey/Library/Developer/Xcode/DerivedData/SupraAI-dgsvapfzuupywvafzgsmdfkmfldi/Logs/Test/Test-SupraAI-2026.08.13_17-53-27--0400.xcresult`

The Release command was:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -workspace SupraAI.xcworkspace -scheme SupraAI \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO build
```

## 8. Conclusion and limits

The named Case File Review product is retired end to end at the validated commit. Dormant
v073 compatibility remains openable but unreachable through shipping product APIs. The
ordinary owner profile was not mutated. Existing external exports, models, backups, migration
history, and unrelated attorney-review workflows were not retired.

This receipt does not authorize deleting dormant schema, historical rows, external artifacts,
models, backups, or the ordinary profile. It does not qualify a signed/notarized publication,
and it does not convert package-only corpus code into a supported shipping capability. Those
remain separate release or owner decisions.
