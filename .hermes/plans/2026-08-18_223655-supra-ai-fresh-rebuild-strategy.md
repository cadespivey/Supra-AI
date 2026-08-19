# Supra AI Evidence-Aware Assistant Rebuild Plan

> **For Hermes:** Use subagent-driven-development and test-driven-development skills to implement this plan task-by-task after Phase 0 decisions are approved.

**Goal:** Replace Supra AI’s refusal-first chat and over-coupled document pipeline with a best-available-evidence assistant while preserving the macOS framework, local-first data model, and general UI/UX.

**Architecture:** Keep the SwiftUI shell, design system, persistence, runtime isolation, and specialized deterministic workflows. Rebuild assistant orchestration as a new vertical slice behind a feature flag, using typed application context, optional retrieved evidence, and an explicit response-basis model. Make extracted/lexically searchable text usable immediately; treat embeddings as a rebuildable background enhancement.

**Tech Stack:** Swift 6, SwiftUI/AppKit, Swift Package Manager, GRDB/SQLite FTS, existing runtime client/XPC boundary, XCTest/Swift Testing.

---

## 1. Recommendation

Do **not** restart from an empty repository. Perform a **selective inside-out rebuild**:

1. Preserve the app shell and general UI/UX.
2. Preserve durable user data and migrations.
3. Preserve model execution isolation and local-first privacy boundaries.
4. Preserve deterministic workflows where exactness is the feature: matter metadata, billing IDs, filing fields, and exported artifacts.
5. Replace chat orchestration, evidence policy, response contracts, and semantic-readiness coupling.
6. Introduce the replacement beside the existing path, compare behavior, and then delete the old path.

A wholesale rewrite would discard the strongest parts of the current product and create data-migration risk. A narrow refactor inside `GlobalChatController` would retain the current coupling and assumptions. The correct middle path is a new assistant core with adapters into existing capabilities.

## 2. Current-State Findings

### Preserve

- Native SwiftUI macOS shell and interaction design.
- Independent `SupraDesignSystem` package.
- Local-first persistence and managed document blobs.
- Runtime/model isolation through `SupraRuntimeInterface` and `SupraRuntimeClient`.
- Typed matter records and canonical matter identity.
- Exact billing, drafting, export, backup, recovery, and audit workflows.
- Strong automated tests and package-boundary enforcement.

### Replace or simplify

- `Packages/SupraSessions/Sources/SupraSessions/GlobalChatController.swift` is a multi-thousand-line coordinator covering routing, retrieval, legal research, egress, generation, verification, persistence, and UI state.
- `Apps/SupraAI/SupraAI/AppEnvironment.swift` is also a multi-thousand-line composition root with substantial feature and test-fixture logic.
- `SupraSessions` depends on almost every product package, making it both application layer and service locator.
- `RefusalContract`, `RefusalOutcomeGate`, typed grounded generation, fail-closed retrieval, and citation verification can convert useful qualified output into refusal.
- Matter chat lacks one simple always-present typed context packet. Stored facts such as matter numbers are not first-class answer evidence.
- Grounded chat requests semantic readiness (`requiresSemanticIndex: true`), so extracted and lexically useful text may be excluded when embeddings are unavailable.
- Retrieval revalidates extensive readiness and lineage state in the hot path. Embeddings are treated as document truth rather than a replaceable ranking cache.
- Many tests freeze implementation contracts that should disappear with the old path.

## 3. Product Policy: Best Available Evidence

Adopt this rule:

> Answer from the best available basis. Prefer and expose authoritative evidence, but do not refuse solely because authoritative evidence is absent.

### Response basis levels

1. **Application record** — deterministic values stored by Supra AI: matter number, client ID, docket number, parties, court selection, document inventory.
2. **Attached or stored document** — retrieved passages with document/page/section locators.
3. **Verified authority or public source** — CourtListener or another approved source with visible metadata.
4. **General knowledge** — model parametric knowledge, clearly labeled as uncited/general and not represented as verified current law.
5. **Inference** — a conclusion drawn from evidence, explicitly labeled as inference.

Several basis levels may coexist in one answer. Show a concise basis summary by default and expandable source details rather than forcing every sentence into citation-heavy prose.

### Refusal policy

Prefer partial answer plus limitation. Hard-stop only when:

- the request is unsafe or prohibited;
- the user requests an exact quotation or stored fact that cannot be found;
- a consequential deterministic workflow requires missing or ambiguous fields;
- a generated quotation/citation fails verification and cannot be removed without destroying the answer.

Do not hard-stop merely because:

- retrieval returns no hits;
- no embedding model is installed;
- remote research is unavailable;
- the model can provide a general framework but not verified current jurisdiction-specific law.

For unverified current or jurisdiction-specific law, provide a marked general overview, state what was not verified, and offer research as the next action.

## 4. Target Architecture

Create a new package, tentatively `Packages/SupraAssistant`, rather than adding more behavior to `SupraSessions`.

### Pure core types

- `AssistantQuery`: text, history, matter scope, attachments, selected mode.
- `ApplicationContext`: typed facts from the Store; exact IDs are never embedded merely to retrieve them.
- `EvidenceItem`: ID, kind, title, locator, excerpt/value, provenance, timestamp.
- `EvidenceBundle`: application facts plus optional document and authority evidence.
- `ResponseBasis`: application record, document, authority, general knowledge, inference.
- `AssistantResponse`: answer, basis summary, evidence references, limitations, suggested actions.
- `AssistantMode`: `automatic`, `general`, `matter`, `documents`, `research`.

### Provider boundaries

- `ApplicationContextProvider`
- `DocumentEvidenceProvider`
- `AuthorityEvidenceProvider`
- `AssistantGenerator`
- `ResponseValidator`
- `AssistantOrchestrator`

The generator must answer the actual question, use supplied evidence when relevant, cite only supplied evidence IDs, mark material general knowledge/inference, never invent application facts/quotes/citations, and answer what it can when evidence is incomplete.

The validator should remove or flag unsupported citations. It should not require a canonical refusal string or convert an otherwise useful mixed answer into refusal.

## 5. Document Pipeline Simplification

### Capability states

Use practical capabilities rather than one “fully ready” gate:

- `imported`
- `textAvailable`
- `lexicallySearchable`
- `semanticEnhanced`
- `failed(reason)`

A document is usable at `textAvailable` or `lexicallySearchable`. Embeddings improve ranking but do not define whether the document is valid evidence.

### Simplified flow

1. Import managed blob.
2. Extract normalized text and locators.
3. Commit chunks and FTS rows atomically.
4. Mark lexically searchable.
5. Queue optional embeddings.
6. Store embeddings as a disposable versioned cache for one active model.
7. Rebuild semantic data after model/chunker changes without invalidating text.

Preserve immutable blobs, extraction revisions, stable locators, resumable processing, FTS, deterministic inventory answers, visible failures, source previews, and open-at-location behavior.

Remove from the hot path universal semantic gating, whole-snapshot semantic-readiness verification, internal cryptographic receipts that protect no external trust boundary, and refusal caused only by semantic unavailability.

## 6. Phased Implementation

### Phase 0: Lock behavior with an evaluation corpus

**Create:**
- `Docs/Assistant-Rebuild-Decision.md`
- `Packages/SupraAssistant/Tests/SupraAssistantTests/Fixtures/assistant-evaluation-v1.json`

Build 30–50 representative prompts covering exact app facts, document inventory/content, general legal concepts without sources, current/jurisdiction-specific law, mixed-basis questions, unavailable embeddings, no retrieval hits, unavailable research, fabricated source IDs, and exact quotations.

For each case define acceptable basis levels, required facts, prohibited claims, whether a partial answer is required, and whether refusal is permitted.

**Gate:** Approve the basis taxonomy and refusal policy before production code.

### Phase 1: Create isolated assistant contracts

**Create:**
- `Packages/SupraAssistant/Package.swift`
- `Packages/SupraAssistant/Sources/SupraAssistant/AssistantQuery.swift`
- `Packages/SupraAssistant/Sources/SupraAssistant/Evidence.swift`
- `Packages/SupraAssistant/Sources/SupraAssistant/AssistantResponse.swift`
- `Packages/SupraAssistant/Sources/SupraAssistant/AssistantProtocols.swift`
- matching tests in `Packages/SupraAssistant/Tests/SupraAssistantTests/`

Keep this package independent of Store, Documents, Networking, and runtime implementations.

### Phase 2: Make application facts first-class evidence

**Create:**
- `Packages/SupraSessions/Sources/SupraSessions/SupraAssistantApplicationContextAdapter.swift`
- `Packages/SupraSessions/Tests/SupraSessionsTests/SupraAssistantApplicationContextAdapterTests.swift`

Build evidence directly from `MatterRecord` and `MatterIdentitySnapshot`: matter name, internal/client matter IDs, docket number, court/jurisdiction state, structured parties, and approved fields. Exact fields should not require embeddings or model extraction.

**Acceptance:** “What is the matter number?” succeeds without documents, embeddings, or network and displays “Supra AI matter record” as basis.

### Phase 3: Add lexical-first document evidence

**Modify:**
- `Packages/SupraSessions/Sources/SupraSessions/DocumentRetrievalService.swift`
- `Packages/SupraSessions/Sources/SupraSessions/DocumentIndexingService.swift`
- `Packages/SupraSessions/Sources/SupraSessions/DocumentProcessingQueue.swift`
- relevant `SupraSessions` tests
- `SupraStore` readiness persistence only where necessary

Return valid FTS/chunk results when semantic vectors are absent. If vectors exist, use them to rerank or supplement. Return capability/limitation metadata rather than fail-closed “not fully ready” errors.

**Acceptance:** A freshly extracted document is queryable before embedding completes.

### Phase 4: Implement orchestrator and validator

**Create:**
- `Packages/SupraSessions/Sources/SupraSessions/SupraAssistantOrchestrator.swift`
- `Packages/SupraSessions/Sources/SupraSessions/SupraAssistantGeneratorAdapter.swift`
- `Packages/SupraSessions/Sources/SupraSessions/SupraAssistantResponseValidator.swift`
- focused and fixture-driven tests

Flow:

1. Assemble scoped application context every time.
2. Select optional evidence providers.
3. Run independent providers concurrently with bounded timeouts.
4. Generate from available evidence.
5. Convert provider failures into limitations.
6. Validate citations/quotes.
7. Persist the response envelope.

Do not port canonical refusal parsing into V2.

### Phase 5: Integrate behind a feature flag

**Modify:**
- `Apps/SupraAI/SupraAI/AppEnvironment.swift`
- `Apps/SupraAI/SupraAI/GlobalChatsView.swift`
- `Apps/SupraAI/SupraAI/Matters/MatterWorkspaceView.swift`
- existing source/message presentation components

Add temporary `assistantPipelineV2`. Preserve composer, transcript, workspace, navigation, and source-opening interactions.

Add:

- basis badge: Matter record, Documents, Verified authority, General knowledge;
- expandable source cards;
- concise limitation line;
- mode menu: Automatic, General, Matter, Documents, Research.

Modes guide evidence collection; they do not force refusal when a provider is unavailable.

### Phase 6: Side-by-side evaluation

Compare pipelines on:

- useful-answer rate;
- unwarranted-refusal rate;
- exact app-fact accuracy;
- fabricated source/citation rate;
- attribution accuracy;
- time to first token and total latency;
- behavior without embeddings/network.

**Release gate:** V2 materially reduces unwarranted refusals, preserves exact app-fact accuracy, and introduces no fabricated citations. Manually review legal-risk cases.

### Phase 7: Remove old policy and collapse complexity

After the gate:

- reduce `GlobalChatController` to a facade or remove its chat ownership;
- remove `RefusalContract`, `RefusalOutcomeGate`, canonical refusal parsing, and policy-only tests;
- remove obsolete strict-grounding branches;
- simplify readiness receipts/semantic lineage no longer required;
- update `ARCHITECTURE.md`, `ROADMAP.md`, and package graph policy;
- split `AppEnvironment` into smaller composition modules after migration stabilizes.

Do not delete the old path before side-by-side comparison.

## 7. Tests and Validation

### Observed baseline on 2026-08-18

The repository suite was run with:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer bash Scripts/test-all-packages.sh
```

It completed package runs but exited 1 in `SupraTestKit`: `BenchmarkFixtureContractTests.testBenchmarkManifestDeclaresOnlyDecodableSyntheticArtifacts` found undeclared or missing corpus files. The test source itself labels T-BEN-01/T-BEN-02 as expected RED scaffolding. Treat this as an existing baseline, not an assistant-rebuild regression. Either complete that fixture separately or exclude documented expected-RED benchmark contracts from the green integration gate.

### Commands

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path Packages/SupraAssistant
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path Packages/SupraSessions
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path Packages/SupraStore
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path Packages/SupraDocuments
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer bash Scripts/test-all-packages.sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer bash Scripts/build-macos-app.sh
```

Manually test no embedding model, embedding in progress, no network, metadata-only matter, documents without semantic index, verified authority, mixed basis, and synthetic fabricated citation output.

## 8. Risks and Tradeoffs

- **Legal risk:** General knowledge may be mistaken for current law. Mitigate with visible basis/limitations and stricter exact/current claim handling, not blanket refusal.
- **UI clutter:** Default to concise badges and expandable details.
- **Migration scope:** First project new capabilities over existing tables; remove schema only after V2 proves itself.
- **Dual-path cost:** Temporary complexity buys measurable comparison and safer migration.
- **Over-generalization:** Keep exact blockers in drafting/export/billing where missing data makes an artifact invalid.
- **Test inertia:** Preserve genuine safety tests but delete tests that only freeze canonical refusal text or semantic gating.

## 9. Decisions Before Implementation

1. Is general legal knowledge enabled by default or after one-time acknowledgment?
2. Which claims require verified authority: current law, jurisdiction-specific law, exact quotes, deadlines?
3. Is “General knowledge” always badged or only when no grounded evidence is present?
4. Does remote research start automatically or require explicit action because of network egress?
5. Which matter fields may be sent through generation versus answered deterministically?
6. Is one active embedding model sufficient, with vectors treated as disposable cache?

## 10. First Milestone

Build one narrow matter-chat vertical slice:

- answer stored matter identifiers deterministically;
- answer document questions with lexical retrieval;
- answer general questions from model knowledge when no source is available;
- show one basis badge and expandable sources;
- never fabricate source IDs;
- degrade gracefully without embeddings or network.

This directly tests the new product philosophy without rewriting drafting, research, billing, storage, or the application shell.
