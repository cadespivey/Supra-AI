# Hardware-Aware Model Fit — Implementation Spec

Goal: help the user pick local models that match their Mac. Detect hardware,
classify each catalog model as **green / yellow / red** for this machine, and
explain expected **depth, accuracy, and speed**. Surface it in the download,
role-assignment, and registered-model flows, and rewrite the Settings token copy
into something a non-engineer can act on.

Decisions locked: (1) plan-first; (2) red (over-budget) models **warn but still
allow** "Download anyway" — never hard-blocked. Hardware is read silently (no
macOS permission or prompt is required for any of it).

---

## Codex review updates / implementation guardrails

These changes fold in the code review and the BGE-M3 investigation from this
session. They should be treated as part of the implementation plan, not optional
notes.

- Keep the `HardwareProfile` value type small and stable in SupraCore, but put the
  platform probe in SupraSessions or the app target behind `#if canImport(Metal)`.
  That avoids forcing Metal into the core model package and keeps the pure model
  type easy to test.
- Treat chip/tier/P-core sysctl values as best-effort hints. `hw.model` is usually
  a machine identifier, not a reliable "Pro/Max/Ultra" string, so unknown values
  must degrade gracefully rather than lying or crashing.
- `RuntimeMetrics` has a `peakMemoryMb` field, but the current MLX runtime does not
  populate it. Either implement real peak-memory capture in the runtime phase or
  keep peak memory as an estimate until that exists.
- Prefer the existing store layer for persisted runtime measurements. There is
  already a `runtime_profiles` table and generation metrics are already persisted;
  only use an `AppSettings` map if the implementer explicitly chooses the lighter
  tradeoff and documents why.
- Fix embedding model reliability before polishing fit UI. The current curated
  BGE-M3 entry points at the original PyTorch/ONNX Hugging Face repo, which can
  download successfully but cannot load in the MLX embedding runtime because there
  is no `.safetensors` checkpoint.
- Nomic Embed Text v1.5 is a second, different embedding failure: the repo has
  `model.safetensors` and `model_type: "nomic_bert"`, but its config advertises
  `max_position_embeddings: 2048` while the safetensors checkpoint contains no
  `position_embeddings` weights. The pinned MLX Nomic loader creates that optional
  layer when `max_position_embeddings > 0`, so load verification can fail even after
  a repo passes the simple "model_type + safetensors" preflight.
- Preserve the locked product decision for text models: red/over-budget models warn
  but remain downloadable. For unsupported embedding repos with no `.safetensors`,
  fail before download/load because they cannot work with this runtime.

## 0. Embedding-model reliability prerequisite

Root cause A from this session: `EmbeddingModelCatalog` currently offers BGE-M3 from
`BAAI/bge-m3`. That repo contains `pytorch_model.bin`, ONNX, and `.pt` files, but no
`.safetensors` weights. The pinned `mlx-swift-lm` loader only loads `.safetensors`,
so the UI reports a generic "The MLX model could not be loaded" after a large,
apparently successful download.

Root cause B from this session: `EmbeddingModelCatalog` also offers
`nomic-ai/nomic-embed-text-v1.5`. That repo does include `model.safetensors` and
`model_type: "nomic_bert"`, but the safetensors header has no
`position_embeddings` tensor while `config.json` says `max_position_embeddings: 2048`.
The current `NomicBertConfiguration` / `NomicEmbedding` path treats that config value
as a signal to instantiate `embeddings.position_embeddings`, so `model.update(...,
verify: [.all])` can fail on missing weights.

Tasks:

- Change the curated BGE-M3 embedding entry to an MLX/safetensors repo, preferably
  `mlx-community/bge-m3-mlx-4bit` unless there is a deliberate product reason to
  choose fp16. Keep dimensions at 1024 and runtime family `xlm-roberta`; update the
  display name/notes to make the 4-bit MLX variant clear.
- Remove or demote Nomic v1.5 from the curated list until the loader mismatch is
  handled. Acceptable fixes:
  - patch the downloaded local `config.json` for `nomic_bert` checkpoints that have
    no `position_embeddings` tensor so `max_position_embeddings` is 0 before load; or
  - fix/wrap the Nomic loader so it only creates absolute position embeddings when
    matching weights exist; or
  - replace it with a verified MLX/safetensors Nomic-family repo whose `model_type`
    is already supported by `MLXEmbedders`.
  Do not leave `nomic-ai/nomic-embed-text-v1.5` as an enabled curated option unless a
  runtime test-load passes.
- Add an embedding compatibility preflight before download, similar in spirit to
  the text model preflight in `ModelDownloadController`:
  - Fetch `config.json` and verify `model_type` is in the MLX embedding registry
    (`bert`, `roberta`, `xlm-roberta`, `distilbert`, `nomic_bert`, `qwen3`,
    `gemma3`, `gemma3_text`, `gemma3n`).
  - List repo files and require at least one `.safetensors` file.
  - Read the safetensors header (range request is enough) and verify basic
    config/weight consistency for the selected family. At minimum, catch the Nomic
    mismatch: `model_type == "nomic_bert"`, `max_position_embeddings > 0`, and no
    `position_embeddings` tensor.
  - If the repo only has PyTorch/ONNX/`.pt` weights, fail with an actionable message
    such as: "This repo is a PyTorch/ONNX checkpoint and cannot be loaded by the
    MLX embedding runtime. Choose an MLX/safetensors variant."
  - If the repo has safetensors but fails a family-specific structural check, fail
    with an actionable message that names the mismatch instead of registering it as
    downloaded and then showing the generic MLX load error.
- Filter embedding downloads to the files the runtime can actually use where safe:
  tokenizer assets (`tokenizer.json`, vocab/merges, SentencePiece `.model` files),
  config/pooling files, and `*.safetensors`. Preserve nested files such as
  `1_Pooling/config.json` when present; do not download `.bin`, `.pt`, or ONNX
  weights for MLX-only embedding use.
- Add a post-download validation gate before selecting/registering as usable. It can
  be a static compatibility check plus immediate runtime test-load; either way,
  "Downloaded X. Verifying it below..." should never turn into a permanent curated
  option that repeatedly fails with the same generic message.
- Surface technical runtime failures. `DocumentIntelligenceSetupController` should
  keep `response.error.technicalDetails` available in the setup/load result, and the
  Models or Diagnostics UI should expose it behind a detail affordance instead of
  collapsing everything to the generic user-facing string.
- Add tests:
  - Curated BGE-M3 points to an MLX/safetensors repo.
  - Nomic v1.5 is either removed/demoted from curated choices or has an explicit,
    tested compatibility fix that allows a runtime test-load to pass.
  - A stub embedding repo with `config.json` + `pytorch_model.bin` is rejected before
    download/load.
  - A stub embedding repo with supported `model_type` + `.safetensors` is accepted.
  - A stub `nomic_bert` repo with `max_position_embeddings > 0` and no
    `position_embeddings` tensor is rejected or patched before registration.
  - Runtime technical details are retained for display/logging.

## 1. Hardware probe — `HardwareProfile`

New value type in **SupraCore** (Foundation-only data model). Put the actual probe
in **SupraSessions** or the app target as `HardwareProfileProbe` /
`HardwareProfileController`, with Metal-specific calls behind `#if canImport(Metal)`.

```swift
public struct HardwareProfile: Sendable, Equatable {
    public let physicalMemoryBytes: UInt64        // ProcessInfo.physicalMemory
    public let safeWorkingSetBytes: UInt64        // Metal ceiling or conservative fallback
    public let freeDiskBytes: Int64?              // models volume, important-usage capacity
    public let osVersion: OperatingSystemVersion  // ProcessInfo
    public let chipName: String?                  // sysctl / uname best effort
    public let chipTier: ChipTier                 // .base/.pro/.max/.ultra/.intel/.unknown
    public let performanceCoreCount: Int?         // sysctl hw.perflevel0.physicalcpu
}

public enum ChipTier: Sendable { case intel, base, pro, max, ultra, unknown }
```

Sources (all free, no entitlement):
- RAM: `ProcessInfo.processInfo.physicalMemory`
- **MLX ceiling**: `MTLCreateSystemDefaultDevice()?.recommendedMaxWorkingSetSize` — the
  amount the GPU can safely allocate (~70–75% of RAM). This is the number that
  actually predicts an MLX out-of-memory, so it's the primary budget, not raw RAM.
  If Metal is unavailable or returns 0, fall back to a conservative fraction of RAM
  (for example 70%) and mark the source as estimated in the reason string if needed.
- Free disk: `URL(fileURLWithPath: modelsDir).resourceValues(forKeys:
  [.volumeAvailableCapacityForImportantUsageKey])` — measured on the *models
  directory's* volume (the user can relocate it), not the boot volume.
- OS: `ProcessInfo.processInfo.operatingSystemVersion`
- Chip: best-effort sysctl/uname values. Tier parsing should prefer strings that
  explicitly contain "Pro", "Max", or "Ultra"; otherwise use `.base` only when Apple
  Silicon is known, and `.unknown` when the evidence is weak. P-core count comes
  from `hw.perflevel0.physicalcpu` when present.

Computed once at launch, cached, exposed via a `@Published var hardware` on a tiny
`HardwareProfileController` (MainActor) the views read. Re-read free disk on demand
(it changes as models download), keep the rest cached.

### Why not "processor speed"
On Apple Silicon, clock speed is nearly irrelevant to local LLM throughput — it's
governed by **unified-memory size + memory bandwidth + GPU-core count**, which track
the chip *tier* (base < Pro < Max < Ultra). So the speed estimate keys off `chipTier`
× model active-params, and is replaced by **measured** tok/s after first run
(§4). We surface "Apple M2 Pro" as the label, not a GHz number.

---

## 2. Structured model metadata

Extend `CatalogModel` (SupraSessions) with structured fields so fit is computable
instead of parsed from prose. Backfill all 11 curated entries; keep `notes` for the
human sentence.

```swift
public struct CatalogModel {
    // existing: repoID, displayName, approxSizeGB, notes
    public let totalParamsB: Double        // e.g. 30, 32, 8
    public let activeParamsB: Double        // MoE active params (== total for dense)
    public let quantBits: Int               // 4, 6, 8
    public let nativeContextTokens: Int     // model's real max context (e.g. 32_768)
    public let depthScore: Int              // editorial 1–5 (reasoning capability)
    public let accuracyScore: Int           // editorial 1–5 (factual/citation recall at this quant)
}
```

- `depthScore` / `accuracyScore` are **editorial** (hand-set per model), seeded from a
  baseline (size + quant), then tuned — e.g. 8-bit > 6-bit > 4-bit on accuracy; the
  existing `notes` already encode this judgment ("4-bit disproportionately degrades
  long-tail factual recall"). These are intrinsic to the model, **not** hardware-dependent.
- Speed is **not** stored here — it's derived/measured per machine (§4).

User-added custom models (not in the catalog) have no metadata. For those: infer
`totalParamsB`/`quantBits` from the repo name when possible (regex `(\d+)B`,
`(\d+)bit`); otherwise show a neutral "Unknown fit — depends on your Mac" state
rather than a false green.

---

## 3. Fit classifier — `ModelFit`

In SupraSessions. Pure function of `(CatalogModel, HardwareProfile)`.

```swift
public enum FitLevel: Sendable { case green, yellow, red, unknown }

public struct ModelFit: Sendable {
    public let level: FitLevel
    public let estimatedLoadBytes: UInt64    // weights + KV @ default ctx + overhead
    public let estimatedPeakBytes: UInt64    // weights + KV @ native ctx + overhead
    public let headline: String              // "Runs smoothly" / "Tight fit — will be slow" / "Won't run well here"
    public let reason: String                // the popover/inline explanation
    public let blockingDiskShortfallBytes: Int64?  // > 0 if download won't fit
}
```

### Memory estimate
- weights ≈ `approxSizeGB` (quantized weights map ~1:1 into unified memory)
- KV cache ≈ `2 · nLayers · nKVHeads · headDim · ctxTokens · 2 bytes` — we don't have
  per-model dims in-app, so approximate with a published-rule heuristic scaled by
  `totalParamsB` and context (a small table: ~0.5–2 GB at 32K for these sizes). KV is
  the swing factor between "loads fine" and "OOMs on a long matter," so it must be in
  the estimate, not ignored.
- overhead ≈ 2 GB (runtime + Metal scratch)

### Thresholds (against `safeWorkingSetBytes`, the Metal ceiling)
- **green**: `estimatedPeakBytes ≤ 0.8 · safeWorkingSet` AND disk OK AND OS ≥ floor
- **yellow**: `estimatedLoadBytes ≤ safeWorkingSet` but peak exceeds the green margin
  (loads, but long context pressures memory / will be slow), OR free disk is < 1.5×
  the download, OR chip tier is low for this model size (slow but functional)
- **red**: `estimatedLoadBytes > safeWorkingSet` (won't fit even at default context →
  heavy swap or load failure), OR OS below floor
- **unknown**: custom model with no inferable metadata

Calibration: `RuntimeMetrics` already includes a `peakMemoryMb` slot, but the
current MLX controller does not populate it. This phase must either add real
peak-memory capture in `MLXModelController` or explicitly defer peak calibration.
After a successful load with a real peak value, store the observed peak per model
and prefer it over the estimate next time so the classifier self-corrects to the
actual machine.

---

## 4. Speed rating (depth/accuracy/speed meters)

- **Depth** = `depthScore`, **Accuracy** = `accuracyScore` — intrinsic, shown as
  5-step meters, hardware-independent.
- **Speed** — two states:
  - *Estimate* (before first run): `chipTier` baseline tok/s × scale(activeParamsB,
    quantBits), bucketed to a 1–5 meter. Labeled "estimated."
  - *Measured* (after first run): real `tokensPerSecond` from `RuntimeMetrics`,
    persisted per model, bucketed to the same scale. Labeled "measured" (as in the
    mockup). Also drives the "~N tok/s on your Mac" line and the Settings time readout.

Persistence: prefer the existing store shape rather than inventing parallel app
settings if the repository work is reasonable. `RuntimeProfileRecord` and the
`runtime_profiles` table already exist, and generation sessions already persist
per-run metrics. The implementer can either add the missing repository/query path
for "latest observed performance per repo" or, if intentionally choosing a lighter
implementation, document why an `AppSettings` map keyed by `repoID` is acceptable.
In either case, persist `{ tokensPerSecond, peakMemoryMb?, measuredAt }` wherever
`generate()` returns metrics.

---

## 5. UI surfaces

### 5a. Capability banner (shared component `SystemCapabilityBanner`)
One row: chip icon · "Your Mac · Apple M2 Pro" · "32 GB unified memory · 184 GB free
· macOS 15.2" · "Ratings tuned to this Mac" pill. Shown at the top of the download
sheet and the Models tab so the *basis* for every rating is always visible.

### 5b. `ModelFitBadge` (shared)
Colored dot + one-line label (`Runs smoothly` / `Tight fit — will be slow` /
`Won't run well here` / `Fit depends on your Mac`). Colors use the semantic system
tints (success/warning/danger), not hardcoded — works in light/dark.

### 5c. Download sheet (`ModelDownloadSheet`, ModelsView.swift)
Per curated row: add the fit badge + a one-line "17 GB · needs ~22 GB RAM · 32K
context · ~38 tok/s on your Mac" sub-line + the depth/accuracy/speed meters. Sort
green→yellow→red so the best matches surface first. For **red**: show the inline
warning box with the reason; the button becomes "Download anyway" (locked decision —
never disabled). For **yellow**: badge + reason on tap, normal Download button.

### 5d. Role-assignment & registered-models rows
`ModelRoleAssignmentRow` and `ModelRow` get the compact `ModelFitBadge` so fit
follows the model after download, not just at acquisition — e.g. flag a model that's
assigned to a role but too heavy for this Mac.

### 5e. Detail popover (optional, hangs off the badge)
Tap the badge → popover with required vs available RAM, disk, OS, and the
depth/accuracy/speed meters with the estimated-vs-measured note. Keeps the row sparse
while making the "why" one click away.

---

## 6. Settings rewrite (SettingsView.swift, Generation Defaults)

Replace the single "≈¾ of a word per token" caption (line 49) with a richer,
hardware-aware explainer around the existing **Max output tokens** stepper:

- **What it is**: "A token is roughly ¾ of a word. 1,000 tokens ≈ 750 words ≈ 1½
  pages."
- **Context window** (new line, reads the active model's `nativeContextTokens`):
  "This model reads up to **32K tokens (~24,000 words)** of matter text + question at
  once; longer inputs get trimmed."
- **Live time readout** (reads measured/estimated tok/s): "At your Mac's ~38 tok/s,
  this setting is up to **~N seconds** per answer." Updates as the stepper moves.
- Keep the existing accuracy caveat ("doesn't change accuracy").

This turns the abstract token number into depth (how much output), speed (how long
on *this* Mac), and the context limit — the three things the user asked for.

---

## 7. File-by-file change list

New:
- `Packages/SupraCore/Sources/SupraCore/HardwareProfile.swift` — value type + enums
- `Packages/SupraSessions/Sources/SupraSessions/HardwareProfileProbe.swift` — platform probe helpers
- `Packages/SupraSessions/Sources/SupraSessions/ModelFit.swift` — classifier
- `Packages/SupraSessions/Sources/SupraSessions/HardwareProfileController.swift` — `@Published` wrapper
- `Packages/SupraSessions/Sources/SupraSessions/EmbeddingModelCompatibility.swift` — embedding repo preflight
- `Packages/SupraStore/Sources/SupraStore/Repositories/RuntimeProfileRepository.swift` — if using the existing `runtime_profiles` table
- `Apps/SupraAI/SupraAI/Components/SystemCapabilityBanner.swift`
- `Apps/SupraAI/SupraAI/Components/ModelFitBadge.swift` (+ meters + detail popover)

Edited:
- `…/SupraSessions/ModelCatalog.swift` — add fields, backfill 11 entries
- `…/SupraSessions/EmbeddingModelCatalog.swift` — point curated BGE-M3 at MLX/safetensors variant, and remove/demote or compatibility-fix Nomic v1.5 before offering it
- `…/SupraSessions/EmbeddingModelDownloadController.swift` — compatibility preflight + download filtering
- `…/SupraSessions/ModelLibrary.swift` (or chat completion path) — persist measured perf
- `…/SupraStore/.../RuntimeProfileRecord` / repository usage — read/write latest perf helper
- `Apps/SupraAI/SupraAI/DocumentIntelligenceSetupController.swift` — retain/display runtime technical details
- `Apps/SupraAI/SupraRuntimeService/MLXModelController.swift` — only if implementing real peak-memory capture
- `Apps/SupraAI/SupraRuntimeService/MLXEmbeddingModelController.swift` or local config-patch code — only if fixing Nomic by adapting the load path instead of removing it
- `Apps/SupraAI/SupraAI/ModelsView.swift` — banner, badges, meters, sort, warn-and-allow
- `Apps/SupraAI/SupraAI/SettingsView.swift` — Generation Defaults copy + live readouts

Tests:
- Embedding model preflight rejects PyTorch/ONNX-only repos and accepts supported `.safetensors` repos
- Curated BGE-M3 catalog entry targets an MLX/safetensors repo
- Curated Nomic v1.5 is not offered unless its config/weight mismatch is patched and a runtime test-load passes
- Safetensors-header compatibility catches the Nomic case: `max_position_embeddings > 0` with no `position_embeddings` tensor
- Runtime technical details survive the setup-controller path for display/logging
- `ModelFit` thresholds (green/yellow/red boundary cases, disk shortfall, OS floor)
- `HardwareProfile` parse helpers (chip tier from brand strings; B/bit regex for
  custom repos)
- Runtime perf persistence/query path returns the latest observed tok/s and optional peak memory for a repo
- A UI smoke check in the existing `SupraAIUITests` harness that the banner + a badge
  render in the download sheet under `-uiTestMode`.

## 8. Phasing (suggested commit order)
0. Embedding reliability: BGE-M3 MLX/safetensors catalog fix, Nomic v1.5 remove/demote
   or compatibility fix, full curated-entry structural sweep, embedding preflight,
   download filtering, technical error visibility, and focused tests
1. `HardwareProfile` value type + probe/controller + unit tests (no fit UI yet)
2. `CatalogModel` metadata backfill + `ModelFit` classifier + tests
3. Capability banner + fit badges in the download sheet (warn-and-allow for text models)
4. Depth/accuracy/speed meters + measured-perf persistence + detail popover
5. Badges in role-assignment / registered-model rows
6. Settings Generation-Defaults rewrite with live time/context readouts

Each phase is independently shippable and reviewable.
