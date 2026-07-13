# Test and verification matrix

## Build and suite baseline

| Target/package | Result | Tests | Passed | Failed | Skipped | Approx. wall time | Warnings / gap |
|---|---|---:|---:|---:|---:|---:|---|
| Debug app + XPC clean build | Pass | — | — | — | — | Not retained | Multiple destination notice; AppIntents metadata skip; icon script always runs |
| Release app + XPC universal build | Pass | — | — | — | — | ~129 s | Swift actor-isolation warning at `MultilineField.swift:377`; AppIntents metadata skip |
| SupraCore | Pass | 65 | 65 | 0 | 0 | 1.01 s | Independent |
| SupraDesignSystem | Pass | 9 | 9 | 0 | 0 | 1.18 s | Independent; some timing-based drop tests |
| SupraDiagnostics | Pass | 5 | 5 | 0 | 0 | 1.25 s | Narrow redaction/evaluator scope |
| SupraDocuments | Pass | 34 | 34 | 0 | 0 | 1.39 s | Hostile/resource parser matrix incomplete |
| SupraDrafting | Pass | 24 | 24 | 0 | 0 | 1.58 s | Demand-letter production path bypasses structured firewall |
| SupraDraftingCore | Pass | 14 | 14 | 0 | 0 | 1.02 s | Independent |
| SupraExports | Pass | 61 | 61 | 0 | 0 | 1.39 s | ZIPFoundation deprecated manifest/API warnings observed on full build |
| SupraNetworking | Pass | 18 | 18 | 0 | 0 | 2.74 s | No redirect-hop test |
| SupraResearch | Pass | 252 | 249 | 0 | 3 | 8.98 s | Live CFPB/SEC/NLRB tests opt-in; defect-encoding citation test |
| SupraRuntimeClient | Pass | 4 | 4 | 0 | 0 | 1.60 s | Uses injected XPC service, not real process crash/restart |
| SupraRuntimeInterface | Pass | 4 | 4 | 0 | 0 | 1.56 s | Codec only |
| SupraSessions | Pass | 418 | 418 | 0 | 0 | 28.47 s | Broad suite; several sleeps; legal/drafting tests encode unsafe semantics |
| SupraStore | Pass | 79 | 79 | 0 | 0 | 5.70 s | Fresh schema strong; shipping-version migrations absent |
| SupraTestKit | Pass | 3 | 2 | 0 | 1 | 3.41 s | Live CourtListener skipped; PDF framework emitted a diagnostic |
| App UI tests | Pass | 3 | 3 | 0 | 0 | 80.16 s test time | One helper silently returns when its command URL is nil |
| Website lint/typecheck/static build | Pass | — | — | — | — | <4 s after install | `npm audit`: 2 moderate findings through PostCSS/Next |

Package total: **990 executed, 986 passed, 0 failed, 4 skipped**. Every package can be invoked independently, though several rely on local package dependencies and resolved third-party caches/downloads.

## Workflow and subsystem coverage

| Workflow or subsystem | Existing tests and quality | Missing tests | Manual/automated validation performed | Failure cases tested | Remaining uncertainty | Recommended merge gate |
|---|---|---|---|---|---|---|
| Launch/store initialization | Store creation, fallback, backup controllers; good unit coverage | Real corrupt/read-only/full-disk app launch; concurrent launch; fallback-store recovery | Debug/UI launch; code trace | Unknown migration safety, missing backup destination | Real user-facing failure/recovery | Signed app launch matrix with corrupt/read-only DB |
| Migration/data integrity | Fresh v054 schema and backup tests; toy pre-migration snapshot tests | Shipping database fixtures in permanent suite | Temporary v1.4.1 and v2.0.0 fixtures migrated; SQLite/FK/FTS/orphan checks passed | Unknown migration, snapshot failures in unit suite | Historical nulls/duplicates/large DBs | SA-ACR-013 matrix |
| Matter lifecycle/isolation | Store/controller tests for chats, folders, delete/restore, tag search | Cross-matter source/output/billing property tests | Temporary two-matter document-Q&A canary passed; billing canary failed | Missing matter/move, delete cascades | Embedding/global cache and concurrent stale UI paths | Cross-matter corpus across every repository/controller |
| Global chat/slash routing | Extensive route/controller tests | Real model routing and all command whitespace/cancel permutations | Static trace and full Sessions suite | Missing model, no result, failed stream, restart packet | Live XPC/model behavior | Route contract table plus real-XPC smoke |
| Model management | Catalog, compatibility, resume, routing tests | Nonzero corruption, hash/revision drift, path containment, disk-full | Model IDs live-verified; code/test trace found four-byte checkpoint trusted | Zero-byte resume, list failure, unsupported model | Real multi-GB download and MLX load | SA-ACR-010 integrity manifest tests |
| XPC runtime | Codec and injected service streaming tests | Real service crash/reconnect, audit-token client validation, memory pressure, bookmark/raw path | Build/entitlement/static review | Interrupted stream and cancellation unit paths | Actual sandbox file access and model lifetime | Signed app/XPC crash-and-recover smoke |
| Legal research | 252 Research tests plus broad Sessions workflows | Proposition support for short sources, negative treatment, real pagination/schema drift | Targeted unsafe `[A1]` test passed; model IDs and code traced | Zero results, failures, jurisdiction, quote cases in suite | Live provider behavior and attorney accuracy | SA-ACR-002 cited-proposition corpus |
| Legal citation verification | Existence, quote, jurisdiction, overlap tests | Tri-state support and all cited-authority hydration | Targeted defect test and execution trace | Out-of-range labels, substantial unrelated text | Short/unavailable sources | Block on unsupported and unverifiable propositions |
| Connectors/network | Request construction, exact initial hosts, key redaction, rate limits | Redirect chains, ports, 307 replay, response limits for all connectors | Controlled redirect probe; source inventory | Plain HTTP, lookalikes, embedded credentials, wrong initial token host | DNS/TLS/platform redirect variations | SA-ACR-005 local redirect matrix |
| Document import/storage | Happy path, duplicate content, unsupported type, corrupt DOCX | Atomic copy, source mutation, symlinks/aliases, huge/nested formats, MIME mismatch | Code trace and storage checks | Unsupported/corrupt fixtures | Disk/full/cancel/crash boundary | SA-ACR-006/011 hostile import suite |
| OCR/extraction | Basic PDF/image/Office/EML and local corpus | Large/scanned/mixed/language/rotation/resource bomb | Package tests and TestKit corpus | Corrupt DOCX, legacy formats | OCR quality/per-page isolation | Bounded hostile corpus; nightly resource tests |
| Index/embedding/retrieval | Chunk/FTS/duplicate/readiness/retrieval tests | Embedding-model changes, interrupted vector batches, deletion race | Matter-scope canary and FTS integrity | Unindexed gate, cancellation queue | Real embeddings absent | Two-matter mixed-model interruption test |
| Document Q&A | Q&A persistence, versioning, citation labels, readiness | Proposition support and prompt injection | Targeted label-only test; two-matter canary | Missing/unresolved cite and no results | Real local model injection response | SA-ACR-003 injection/support gate |
| Structured outputs | Versioning/repair/source-set tests | Concurrent edits, old schema corpus, warning propagation all exports | Code/test trace | Repair failure and incomplete structure | Multiwindow/concurrent mutation | Immutable source/warning version contract |
| Drafting | Deterministic notice and OOXML tests; extensive style wire proofs | Blocking demand prose before file creation; model fact provenance | Targeted test generated a successful blocked artifact | Empty claim, profile missing, cited/free-text placeholders | Attorney template compatibility | SA-ACR-004 file-content/UI gate |
| OOXML/exports | XML escaping, structure, billing CSV/LEDES tests | Atomic fault injection; document CSV formulas; metadata/path scan per format | Release bundle and source inspection | Malformed shell in limited tests | Office interoperability and disk failures | SA-ACR-008/009 export fault matrix |
| ScratchPad/billing | Strong date/rounding/edit/export and `#Note` tests | Evidence-to-matter validation and fabricated source IDs | `#Note` tests passed; temporary cross-matter probe reproduced contamination | Locked/empty day, invalid codes/date | Multi-matter work and attorney review UX | SA-ACR-007 two-client canary |
| Logging/diagnostics/audit | Key/header/path redaction tests | Dictionary attack, audit-write failure completeness, crash reports | Static query fingerprint review; secret scan | Blocked/approved request logs | OS crash/log surfaces | Keyed fingerprint tests and audit fault injection |
| Settings/configuration | Many persistence/wiring tests | Machine-readable inventory of every env/UI setting | Static `.env`, settings, key-store trace | Some invalid values | Release/debug divergence | Settings coverage manifest |
| Website/release/licensing | Website workflow and model-ID workflow | Swift CI, public hidden-ref check, full release preflight | Lint/typecheck/build, pre/post font guard, signed artifact inspection, public digests, hidden refs | Local tree/artifact clean; remote ref failure | GitHub caches/forks; current-main artifact not rebuilt/notarized | SA-ACR-001/012 release gate |
| Accessibility/macOS UX | Three UI flows including tab order | VoiceOver warnings, keyboard all flows, high contrast, large text, error announcements | UI suite passed | Limited tab-order checks | Broad accessibility conformance | Accessibility smoke suite for blocking warnings |

## Test-first methodology audit

- Required static greps found 29 short negative `contains` assertions in 16 files. Manual sampling showed mostly meaningful wire proofs, but these are a review queue rather than proof of compliance.
- One prohibited silent guard exists: `ResearchAuthoritiesUITests.swift:150` returns if the command URL is absent; the write on line 151 is also `try?`. It can suppress the intended tab-selection action.
- The broad ignored-`try` grep returned 413 lines, mostly fixture setup and intentional throwing assertions; it is too noisy to be an automated pass/fail gate without classification.
- `contains("")` returned zero hits.
- Six `XCTSkip*` call sites exist; four live tests skipped in this run due missing opt-in/credentials.
- Fourteen test `Task.sleep` call sites create timing/flakiness exposure.
- High-value counterexamples are currently encoded as green: a bare `[A1]` counts as cited, an arbitrary `[S1]` answer needs no review, and a demand letter with blocking prose still returns a file.
- Git history contains some explicit expected-RED/test-first work, but current semantic assertions—not commit order—remain the controlling evidence.
