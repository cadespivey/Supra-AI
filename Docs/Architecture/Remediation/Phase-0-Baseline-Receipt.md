# Phase 0 Baseline Receipt

**Captured:** 2026-08-13 (America/New_York)

**Receipt scope:** WP-0.1 measurement baseline plus explicitly identified gaps

**Development isolation:** `/private/tmp/supra-architecture-ux-r0.tDC5PB`

**Application launch:** Not performed

**Ordinary profile access:** Read-only inventory only; no application or migration opened the profile

This receipt freezes reproducible observations for the architecture and UX remediation
program. An **observation** describes a command result, source state, or read-only inventory at
the identified commit and toolchain. A **guarantee** exists only where a named, repeatable gate
has passed. A **pending** item has not been measured or proven. Build success, source
inspection, and an empty model registry are not substitutes for signed-runtime, live-footprint,
model-performance, migration, restore, or native-workflow qualification.

## 1. Repository and plan identity

| Item | Exact value | Classification |
|---|---|---|
| Isolated branch | `codex/architecture-ux-r0` | Observation |
| Current receipt HEAD | `bfd8b560f12ff05af04445a1cb0c1e5d59a83240` | Observation |
| Validated shared baseline (`origin/main`) | `22472816d3346a1bb4688c3a867b66fa61fb5ba4` | Observation |
| Public comparison tag (`v2.3.4`) | `c0a2648b4c65c066f85eb6bf6ae702f9aa779864` | Observation |
| Tag tree | `f10a398b3fb7c065412b6fe437828a231d54a7cd` | Observation |
| `origin/main` tree | `506a4f86bc252948ebacbc91d8ac28d9400427d8` | Observation |
| Master plan | `/Users/cadespivey/Library/Mobile Documents/com~apple~CloudDocs/Downloads/Supra Consolidated Architecture and UX Remediation Plan.md` | Observation |
| Master-plan revision | Revision 3; 1,522 lines; 21,267 words; 163,252 bytes | Observation |
| Master-plan SHA-256 | `5582d4da708d0dfb8ab7ba182da7f6130b35f9b8a10c2d89376ab172c9301bc5` | Observation |

The isolated HEAD contains two commits beyond the shared baseline:

1. `f44219c7` — RED gates for legal-research containment.
2. `bfd8b560` — GREEN matter-research egress and authority-output containment.

The master plan's validated baseline remains `22472816`; this receipt's test and build
measurements are for the isolated HEAD `bfd8b560` unless a row says otherwise.

## 2. Frozen `v2.3.4..origin/main` delta

| Measurement | Value |
|---|---:|
| Commits | 471 |
| Changed files | 270 |
| Insertions | 84,722 |
| Deletions | 1,864 |
| Binary-file entries in `--numstat` | 1 |
| Ordered commit-list SHA-256 | `a2aabefdbaaf46d37044710d4346606c10b28cfd4924ce6e2733392141bf7666` |
| Name-status SHA-256 | `6586b4bf0f7324f99226f6e30ce2ce454115e10291000c74e3d31127d0d2cd36` |
| Numstat SHA-256 | `e8bfa900c8e86892f4bc4fbe2ef845934693fbe20f6c8ee02453057d708be14b` |

Digest definitions:

```sh
git rev-list --reverse v2.3.4..origin/main | shasum -a 256
git diff --name-status v2.3.4..origin/main | shasum -a 256
git diff --numstat v2.3.4..origin/main | shasum -a 256
```

These figures freeze the size and identity of the unreleased range. The companion
`Next-Release-Delta-Manifest.yml` classifies every changed path and commit bucket by owner,
migration impact, native journey, intended disposition, and release evidence. The manifest's
verifier reconstructs this exact frozen range and rejects missing or duplicate coverage.

## 3. Measurement host and toolchain

| Item | Exact value |
|---|---|
| Hardware | MacBook Pro, `Mac16,7`, Apple M4 Pro |
| CPU | 14 physical / 14 logical cores, `arm64` |
| Unified memory | 51,539,607,552 bytes (48 GiB nominal) |
| macOS | 27.0, build `26A5406e` |
| Kernel | Darwin 27.0.0, `RELEASE_ARM64_T6041` |
| Xcode | 27.0, build `27A5194q` |
| Developer directory | `/Applications/Xcode-beta.app/Contents/Developer` |
| Swift | Apple Swift 6.4 (`swiftlang-6.4.0.20.104`, `clang-2100.3.20.102`) |
| Swift driver | 1.167 |
| Swift target | `arm64-apple-macosx27.0.0` |

Repository-facts verification observed exactly fourteen local packages, app version 2.3.4
(build 393), and migration identifiers `v001` through immutable
`v073_create_case_file_review_projects`. Product-claims verification passed with 54 claims at
the isolated HEAD. These script results are gates over their declared source inventories; they
are not runtime or publication guarantees.

## 4. Fixed fourteen-package test matrix

Command family:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  bash Scripts/test-all-packages.sh [package-name]
```

Each fixed-inventory package was selected through `Scripts/test-all-packages.sh`, which runs
`swift test --parallel`. Counts below come from the parallel runner's completed `[N/N]`
enumeration. Xcode 27 also printed a trailing Swift Testing compatibility summary of “0 tests
in 0 suites”; that separate summary does not replace the 2,336 enumerated XCTest executions.

| Package | Tests executed | Failures | Wall time (s) | Post-run `.build` KiB | Post-run `.build` MiB |
|---|---:|---:|---:|---:|---:|
| SupraCore | 99 | 0 | 10.65 | 142,468 | 139.1 |
| SupraDesignSystem | 21 | 0 | 7.53 | 131,576 | 128.5 |
| SupraDiagnostics | 5 | 0 | 8.95 | 156,788 | 153.1 |
| SupraDocuments | 278 | 0 | 15.42 | 338,384 | 330.5 |
| SupraDrafting | 58 | 0 | 11.33 | 250,296 | 244.4 |
| SupraDraftingCore | 15 | 0 | 9.44 | 153,600 | 150.0 |
| SupraExports | 62 | 0 | 10.20 | 239,172 | 233.6 |
| SupraNetworking | 41 | 0 | 29.32 | 716,708 | 699.9 |
| SupraResearch | 326 | 0 | 79.69 | 775,612 | 757.4 |
| SupraRuntimeClient | 14 | 0 | 9.77 | 159,872 | 156.1 |
| SupraRuntimeInterface | 29 | 0 | 9.64 | 171,308 | 167.3 |
| SupraSessions | 1,033 | 0 | 87.21 | 1,176,708 | 1,149.1 |
| SupraStore | 315 | 0 | 50.65 | 730,124 | 713.0 |
| SupraTestKit | 40 | 0 | 33.14 | 1,160,704 | 1,133.5 |
| **Total** | **2,336** | **0** | **372.94** | **6,302,488** | **6,154.8 (6.01 GiB)** |

Before this run, every package `.build` directory was absent except `SupraSessions`, which
used 1,177,368 KiB. Package wall time includes dependency resolution/build work encountered by
that package invocation; resolver time was not isolated as an independent stopwatch.

### Dependency-lock integrity

The before and after SHA-256 values matched for all ten tracked `Package.resolved` files.
`git diff --quiet -- '*Package.resolved'` was clean after the matrix.

| Lockfile | Before and after SHA-256 |
|---|---|
| `Apps/SupraAI/SupraAI.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` | `469061f969fadbe183af2b0e947de6ba20dfb07321a584449a87abcdf10d54dd` |
| `Packages/SupraDocuments/Package.resolved` | `576b9ed0d6ce0c93ebea83340e0fc85eac0bbdecf17f4c07ae8b3592554f70ba` |
| `Packages/SupraDrafting/Package.resolved` | `293931b10116b605d2706aa20abfa8789faa979cb72ba2e4b58f2b7cb4dd4206` |
| `Packages/SupraExports/Package.resolved` | `64cf93991360c98bd057825a21f825dc96b08812ec6e59e3d128c1b186109ade` |
| `Packages/SupraNetworking/Package.resolved` | `5dc695990468dcc4b34eb62648b2fe573b8cf5632581bb8b79b2615aa2e86583` |
| `Packages/SupraResearch/Package.resolved` | `576fdf70308ec3aba525660eb859ec84bf9275446d66f6a213ce201e9269fa28` |
| `Packages/SupraSessions/Package.resolved` | `1bef6b294ded02b1404b1de8391ffc332c3dfcf443d2edca1078b621b0574ab1` |
| `Packages/SupraStore/Package.resolved` | `ab70967e1e7d6e9f3079a4ec36c6674ea5e5edca039abac4091661b10471324b` |
| `Packages/SupraTestKit/Package.resolved` | `ff9582cdf4417e49ca4e5d8c92fe14b783a5643c185d0debe7fd37261ca2db1e` |
| `SupraAI.xcworkspace/xcshareddata/swiftpm/Package.resolved` | `8d2d67077ce2de9ff91860f213b4d9c1c59fb3f3271393727408e3114fac8597` |

**Gate result:** all fourteen package commands returned success, 2,336 intended tests were
enumerated, zero failures were reported, no lockfile drift occurred, and the worktree remained
clean at the end of the measurement.

## 5. App and XPC build measurements

The clean-cache measurements used fresh DerivedData directories; the incremental measurements
repeated the same workspace/scheme/configuration build against those directories. The command
shape was:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  /usr/bin/time -l xcodebuild \
  -workspace SupraAI.xcworkspace -scheme SupraAI \
  -configuration <Debug-or-Release> \
  -derivedDataPath <recorded-path> build
```

### Clean-cache builds

| Configuration | Result | Real (s) | User (s) | Sys (s) | Max RSS (bytes) | DerivedData | App bundle | Standalone XPC bundle |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Debug | Success | 110.21 | 381.10 | 52.03 | 3,189,227,520 | 2.2G | 141M | 64M |
| Release | Success | 239.13 | 1,170.69 | 65.75 | 2,645,606,400 | 3.8G | 166M | 73M |

- Debug DerivedData: `/private/tmp/supra-phase0-derived-bfd8b560`
- Release DerivedData: `/private/tmp/supra-phase0-release-bfd8b560`
- Release dependency graph: 64 resolved targets.
- Debug app launcher executable: 40,136 bytes; the adjacent
  `SupraAI.debug.dylib` containing the Debug app implementation: 76,868,512 bytes.
- Debug standalone XPC executable: 63,664,448 bytes.
- Release app executable at clean-build capture: 93,225,192 bytes.
- Release standalone XPC executable at clean-build capture: 73,049,440 bytes.
- Bundle and DerivedData sizes are the human-readable `du` observations recorded at capture;
  they are not byte-exact archive or download sizes.

### Incremental builds

| Configuration | Result | Real (s) | User (s) | Sys (s) | Max RSS (bytes) |
|---|---|---:|---:|---:|---:|
| Debug | Success | 2.85 | 2.38 | 0.65 | 332,972,032 |
| Release | Success | 2.89 | 2.43 | 0.68 | 354,861,056 |

These are build-process measurements. They do not measure launched app/XPC footprint, model
residency, KV cache, vectors, first-token latency, throughput, or signed/notarized runtime
behavior.

## 6. Release link maps and `-why_live` classification

### Shipping-setting link-map capture

A Release build with `LD_GENERATE_MAP_FILE=YES` succeeded. The following arm64 maps were
recorded immediately after that build, before later diagnostic overrides regenerated the same
DerivedData paths:

| Product | Absolute map path | SHA-256 at capture | Bytes | Lines |
|---|---|---|---:|---:|
| App | `/private/tmp/supra-phase0-release-bfd8b560/Build/Intermediates.noindex/SupraAI.build/Release/SupraAI.build/SupraAI-LinkMap-normal-arm64.txt` | `acec64acc4f79f2ad4e56781bff4fb99abf493aa4a037251761dcc787c9322e0` | 29,466,645 | 217,185 |
| XPC | `/private/tmp/supra-phase0-release-bfd8b560/Build/Intermediates.noindex/SupraAI.build/Release/SupraRuntimeService.build/SupraRuntimeService-LinkMap-normal-arm64.txt` | `f1ad63a210e6c30119137a59fb0d8750db0ba722f78cc4e153954b12a4110037` | 17,482,992 | 154,777 |

The paths are temporary evidence locations, not durable repository artifacts. At receipt
authoring time, the valid `DEAD_CODE_STRIPPING=YES` diagnostic build described below had
regenerated them. Their then-current identities were:

| Product | Diagnostic-map SHA-256 | Bytes | Lines |
|---|---|---:|---:|
| App | `1355cb428377fadc5bbbd05b5a37edec92d0666459e5eed212bbf1298a0cce6b` | 36,706,557 | 326,703 |
| XPC | `c40d84fd994ae1827117c1467c175f235c346b345100f2237190b41460ea7481` | 22,606,452 | 200,606 |

### `-why_live` attempts

| Attempt | Result | Evidence classification |
|---|---|---|
| Linker flag `-Wl,-why_live` with no symbol | Failed because Apple `ld` requires a symbol argument; the surfaced Foundation-path failure was a malformed linker invocation consequence. | **Invalid; non-evidence.** It says nothing about live symbols or dependency necessity. |
| Symbol argument with the existing Release setting `DEAD_CODE_STRIPPING=NO` | Build succeeded but emitted no retention explanation. | **Invalid for liveness conclusions; non-evidence.** `-why_live` needs dead stripping to perform the relevant analysis. |
| `DEAD_CODE_STRIPPING=YES` plus `-Wl,-why_live,_$s9SupraCore28CorpusAnalysisSnapshotMemberV9memberKeySSvg` | Diagnostic build succeeded and reported, for the app and XPC architectures, that the symbol was retained from `/private/tmp/.../Build/Products/Release/SupraCore.o`. | **Valid symbol probe.** It proves this symbol's diagnostic retention chain and a working invocation only. |

The valid probe deliberately overrides the shipping Release setting. It does **not** prove that
shipping Release uses dead stripping, that a package/target is removable, that every linked
symbol is necessary, or that the diagnostic bundle equals a release candidate.

## 7. Current source-derived navigation and window baseline

This is a source observation at `bfd8b560`, not a native visual-journey result.

- Top-level `AppRoute` values and visible source labels, in order: `globalChats` / **Global
  Chats**, `scratchpad` / **ScratchPad**, `publicRecords` / **Public Records**, `models` /
  **Models**, `diagnostics` / **Diagnostics**, and `settings` / **Settings**.
- Matters are dynamic primary-sidebar selections rather than an `AppRoute`; **Recycle Bin** is
  a separate pinned sidebar selection.
- Default shell selection: Global Chats.
- Matter tabs, in order: **Chat**, **Research**, **Authorities**, **Outputs**, **Review**,
  **Documents**, **Billing**, and **Audit**. The local `@State` default is Chat.
- Main `NavigationSplitView` minimum width: 880 points. Detail minimum: 640 by 420 points.
- Scene declaration: `WindowGroup` with a default size of 1,100 by 720 points. No production
  single-`Window` restriction is declared.
- The current `WindowGroup`/New Window affordance conflicts with decision D-12's target of one
  supported main `Window`. This is a recorded remediation gap, not an implicit approval of
  multiwindow behavior.

Case File Review remains present in this pre-retirement tab inventory. The inventory is not a
claim that it should remain or that it is qualified.

## 8. Installed-model observation

The ordinary profile was not launched. A read-only inventory observed:

- Database: `/Users/cadespivey/Library/Application Support/ai.supra.SupraAI/SupraAI.sqlite`.
- `models`: zero rows.
- `document_embedding_models`: zero rows.
- Managed text-model directory:
  `/Users/cadespivey/Library/Application Support/ai.supra.SupraAI/Models` — exists, zero model
  subdirectories/manifests, 0 KiB observed.
- Managed embedding-model directory:
  `/Users/cadespivey/Library/Application Support/ai.supra.SupraAI/EmbeddingModels` — exists,
  zero model subdirectories/manifests, 0 KiB observed.

This proves only that the Store registries and app-managed directories were empty at the
read-only observation time. It does not prove that no external model folders exist, that a
runtime process has never loaded a model, or that model download/load/switch paths work. No
active embedding-model identifier could be recorded from an empty registry.

### 8.1 Correction: sandboxed shipping-profile model inventory

The Section 8 observation inspected the non-sandboxed Application Support path, not the
shipping app's sandbox container. It therefore does not describe the installed shipping-profile
models. A read-only correction on 2026-08-15 observed the actual roots at
`~/Library/Containers/ai.supra.SupraAI/Data/Library/Application Support/ai.supra.SupraAI/Models`
and `EmbeddingModels`, containing four chat-model directories and six embedding-model
directories respectively.

The shipping-profile Store already selected `mlx-community/Qwen3-32B-4bit` for chat and
`mlx-community/Qwen3-Embedding-4B-4bit-DWQ` for embeddings. Both selected trees have managed
manifests. Full-tree verification with `Scripts/smoke-model-tool.swift fingerprint` succeeded:

- chat revision `bcaaf7f538adf166c1080a2befdb4f6019f66639`, canonical fingerprint
  `00445d9be9b7e3cd38f258a13df2952ac00a23280d7aa50e4f8fa0613b966766`;
- embedding revision `b5d88f1fe49b50d2ac01b4692ca2d387f14f9c72`, canonical fingerprint
  `691c8406fa1abf039f26ffbaa2b4613cb94f85026597675a3c73a07ef7c5d454`.

This correction is an installed-artifact identity and integrity receipt. It does not replace the
pending native control run, resource measurements, model-switch exercise, or Release-runtime
qualification. The original mistaken observation is retained above so the correction remains
auditable rather than silently rewriting history.

## 9. Pending evidence and explicit non-guarantees

The following Phase 0 evidence remains **pending**:

- launched app, XPC, and combined idle/current/peak physical footprint;
- model-load and model-switch peaks, including combined text/embedding residency and pressure
  behavior;
- cold/warm generation and embedding behavior, time to first token, latency, throughput, KV
  residency, vector-scan bytes, and active embedding-model verification;
- current protected-CI wall time and exact hosted required-check evidence for this HEAD;
- owner-signed synthetic restore drill: successful restore/reopen, forced activation failure
  with verified safety rollback, and unsupported-future-schema rejection;
- signed Release runtime, native visual journeys, notarization, packaging, and publication
  qualification.

Consequently, this receipt guarantees only the named deterministic gates that actually ran:
the repository facts and product-claims inventories, the fixed fourteen-package matrix with
the counts above, dependency-lock stability across that matrix, and the recorded source/build
observations. It does not authorize package removal, topology changes, a live migration,
profile reset, Case File Review schema deletion, release publication, or performance claims.

## 10. Refresh rules

Refresh this receipt, or append a dated successor, whenever any of the following changes:

- master-plan bytes or revision;
- `origin/main`, branch HEAD, toolchain, OS, or hardware;
- package inventory, dependency locks, migration endpoint, or controlled claims;
- app/XPC link settings, target graph, bundle composition, model artifacts, route/window
  contract, or resource measurements.

Never overwrite an earlier observation to make a new result appear continuous. Record the new
HEAD, exact command shape, selected-test count, artifact digest, and whether the evidence is an
observation, a passed guarantee, a failure, or still pending.
