# Implementation Spec — `motionToDismiss` vertical slice

> **Companion to** `Docs/Drafting-Catalog-SPEC.md` (design) and `Docs/Drafting-Impl-
> NoticeAppearance-SPEC.md` (the shared slice types: `DraftKind`, `Slot*`, `HouseStyleSheet`,
> `DocumentModel`, closing-block models, `Renderer`, `DraftPipeline`; shared supporting types &
> the reconciled `Renderer`/`Verifier` protocols in `Drafting-Impl-CoreTypes-SPEC.md`). This doc specifies
> only the **deltas** `motionToDismiss` adds: **generation, the authority firewall,
> verification + repair, and the elements/heading contract.** Sample data is fictional.

`motionToDismiss`: `renderShell = .courtFL`, `skeleton = .houseMotionFL`,
`blockType = .contract`, **`assertsLegalAuthority = true`**. It reuses the notice's renderer
and pipeline shell, and adds the four things the notice didn't exercise.

---

## 0. What this slice adds over the notice
1. **Generation (§8.9)** — section-by-section, a deterministically-assembled layered prompt,
   firewall-gated. The notice was pure slot-fill; the motion writes argument prose.
2. **Authority firewall (§8.2/§8.9 decision B)** — CourtListener retrieval-augmented cites
   with a `[cite]` fallback; the model never invents authority.
3. **Per-section verification + repair (§8.2)** — the gates that apply to an `Auth` kind, and
   the failure-type→repair taxonomy.
4. **Elements + heading contract (§8.10)** — the MTD's required sections (deterministic) and
   the element-completeness advisory check.
Render deltas (point headings, numbered facts, dated "Respectfully submitted:") are already
expressible in `DocumentModel.BodyBlock`/`SignatureBlockModel`; the renderer handles them
(see the SupraExports impl spec).

---

## 1. New types

### 1.1 Generation (`Pipeline/Generator.swift`)
```swift
public protocol Generator {
    /// One section at a time (design §8.2/§8.9). Returns prose + the cites it actually used.
    func generate(_ parts: PromptParts) async throws -> GeneratedSection
}
public struct PromptParts: Sendable {                 // assembled deterministically by the harness
    public var taskInstruction: String                // engine prompt template, §8.9/§17 (versioned)
    public var voice: VoiceContext?                   // AssistantProfile voice — NIL for Auth kinds (§8.6)
    public var sectionContract: SectionRequirement    // required content + skeleton shape (CRAC) for THIS section
    public var facts: [GroundedFact]                  // matter facts w/ [S#] labels — the ONLY fact source (§8.6)
    public var authorities: [VerifiedAuthority]       // from authority-finding; may be empty → model writes [cite]
    public var precedent: StructureTemplate?          // firm's abstracted skeleton/boilerplate (§15.5), fact-free; nil for the slice (§15.5 not yet built)
    public var decoding: Decoding                     // .grounded (≈greedy) for Auth sections
}
public struct GeneratedSection: Sendable {
    public var blocks: [BodyBlock]                    // pointHeading / paragraph(s)
    public var citesUsed: [CitationRef]               // each must map to a VerifiedAuthority or be a [cite] placeholder
    public var assertedFacts: [FactRef]               // each must carry an [S#] tracing to `facts`
}
public enum Decoding: Sendable { case grounded, creative }  // grounded: temp≈0 (like DocumentQA); creative: /draft route
```
Generation runs **per section** (the `houseMotionFL` sequence, §1.4); after each, the
Verifier (§1.3) runs before the next is generated.

### 1.2 Authority firewall (`Authority/`)
```swift
public protocol CitatorClient {                       // the ONE network call (public cite strings only, §8.2/§8.9)
    func find(proposition: ScrubbedProposition) async -> [CitatorHit]   // CourtListener; network errors return []
    func validate(_ cite: CitationRef) async -> CiteValidity            // exists / good-law (best-effort); errors return .unknown
}
public struct ScrubbedProposition: Sendable { public let text: String } // legal issue ONLY — matter facts/identity stripped
public struct CitatorHit: Sendable { public let cite: CitationRef; public let snippet: String; public let onPointScore: Double }
public enum CiteValidity: Sendable { case confirmed, unknown, badFormat }

/// Decision B: try to find authority; if inadequate/inconclusive → [cite] placeholder. Never invent.
public struct AuthorityResolver {
    let citator: CitatorClient
    public func resolve(_ proposition: ScrubbedProposition, threshold: Double) async -> AuthorityOutcome {
        let hits = await citator.find(proposition: proposition)
        guard let best = hits.max(by: { $0.onPointScore < $1.onPointScore }),
              best.onPointScore >= threshold else { return .placeholder }   // erring → placeholder (default)
        return .cite(VerifiedAuthority(cite: best.cite, snippet: best.snippet, source: .courtListener))
    }
}
public enum AuthorityOutcome: Sendable { case cite(VerifiedAuthority), placeholder }
public struct VerifiedAuthority: Sendable { public let cite: CitationRef; public let snippet: String; public let source: AuthSource }
public enum AuthSource: Sendable { case courtListener, userSupplied }   // NEVER `.model`
```
**Invariant (test-enforced, §7):** every `CitationRef` in output is either backed by a
`VerifiedAuthority` (real retrieved doc) or is the literal `[cite]` placeholder. No model-
originated cite string ever reaches a draft.

### 1.3 Verification + repair (`Pipeline/Verifier.swift`, extended)
```swift
// VerificationResult, GateFailure, Gate, and RepairStrategy live in CoreTypes because
// noticeAppearance and letterDemand also need the shared gate/follow-up vocabulary.
// Motion adds the Auth-section gate mapping below.
```
**Gate → strategy map** (constant): `contract → regenerate(2)`; `citationFormat →
deterministicFix`; `ruleConformance → deterministicFix` (or `regenerate` for limit overflow);
`authorityValidity → stripToPlaceholderAndFlag`; `factProvenance → stripToPlaceholderAndFlag`;
`elementCompleteness → stripToPlaceholderAndFlag` (advisory). The repair loop runs only the
`regenerate` bucket in a bounded loop; the others apply once and flag.

**Per-`Auth`-section checks:**
- **contract** — the section's required sub-content present (`SectionRequirement`).
- **factProvenance** — every `GeneratedSection.assertedFacts` traces to a `facts` `[S#]`; untraced → strip + flag.
- **citation/authority** — every `citesUsed` is a `VerifiedAuthority` or `[cite]`; run `CitatorClient.validate`; unconfirmed → flag (never auto-verified).
- **ruleConformance** — format floor (§4) + required recitals (e.g. the MTD invokes a 1.140(b) ground).
- **elementCompleteness** (§8.10) — advisory: did the argument address the ground's required showing.

### 1.4 Skeleton + contracts (`Kinds/MotionToDismiss.swift`)
```swift
let houseMotionFL: [SectionDef] = [
    .init(id: .introduction,    generate: true,  decoding: .grounded),
    .init(id: .statementOfFacts, generate: true, decoding: .grounded, numbering: .numberedFacts),
    .init(id: .memorandumOfLaw, generate: false), // section heading only; argument lives in the points below
    .init(id: .argument,        generate: true,  decoding: .grounded, repeatPer: .ground, headingLevel: 1, skeletonShape: .crac),
    .init(id: .conclusion,      generate: true,  decoding: .grounded, headingLevel: 1, isWhereforePoint: true),
]
```
- **Statement of Facts** → `BodyBlock.numberedAllegation` (design §4: number at margin, text at 0.5″).
- **Argument points** → `BodyBlock.pointHeading(level: 1, numeral: "I."…)`, one per **ground**
  (the user-supplied `grounds` slot), each a CRAC mini-argument. Sub-points (`A.`,`B.`) are
  `pointHeading(level: 2…)`.
- **Conclusion** → the **final** point heading (`III.` etc., design §4) + a WHEREFORE paragraph.
- **Section labels** `STATEMENT OF FACTS` / `MEMORANDUM OF LAW` → centered **bold** `sectionHeading`
  (not underlined — golden-confirmed); `CONCLUSION` is instead the final roman `pointHeading`. Every
  point heading carries `<w:spacing w:after="240"/>` (12-pt gap to its body — SupraExports §4.3).

`HeadingContract.required = [.caption, .title, .introduction, .statementOfFacts,
.memorandumOfLaw, .argument, .conclusion, .signature, .certificateOfService]`.

`ElementsLibrary` (design §8.10 — jurisdiction-pack data, app-maintained, never model-derived):
```swift
public struct ElementsLibrary: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public let key: String            // "breachOfContract", "mtd.failToStateClaim"
        public let jurisdiction: String   // "FL" / "MAJORITY"
        public let elements: [Element]
        public let primaryCites: [String] // independently-stated; bar-prep is only a dev-time seed (§8.10 caveat)
    }
    public struct Element: Codable, Sendable { public let name: String; public let note: String; public let authority: String? }
}
```

### 1.5 Slot deltas
Adds over the notice: `grounds` (`.list(.text)`, `.userPrompt`, **required** — the irreducible
input, the only thing the draft-first hybrid asks for, §8.1 Z). In implementation, normalize free-text
grounds into a curated `MotionGroundSpec` (`key`, `displayName`, `elementKeys`, deterministic
authority-query templates); the model must not invent authority-search propositions. `reliefSought` (`.text`,
`.userPrompt`, optional, default "dismiss the Complaint with prejudice"); `respondingTo`
(`.text`, `.matterMetadata` — the pleading attacked). Matter **facts** are not a single slot —
they are retrieved per section (`DocumentRetrievalService`) into `PromptParts.facts`.

---

## 2. The motion flow (`DraftPipeline`, generation path)
```
resolve slots (grounds from user; caption/identity auto) 
  → assemble caption + title (deterministic)
  → for each SectionDef where generate:
        facts        = retrieve(matter, section)            // [S#]-labelled, the only fact source
        authorityQueries = MotionGroundSpec.propositions(for: grounds, section: section) // deterministic templates, not model-invented
        authorities  = for each authorityQuery: AuthorityResolver.resolve(scrub(authorityQuery))  // CourtListener or [cite]
        precedent    = structureTemplate(kind, firm)        // §15.5, fact-free
        parts        = PromptParts(taskInstruction: template(kind, section), voice: nil /*Auth*/, …)
        section      = Generator.generate(parts)
        result       = await verifier.verify(.section(section, requirement: parts.sectionContract,
                                  facts: facts, authorities: authorities), kind: kind, style: style)  // CoreTypes VerifyUnit
        apply repair per GateFailure.repair (bounded regenerate; else strip+flag)
        append section.blocks → DocumentModel.body
  → assemble signature (respectfullySubmitted = serviceDate) + certificate
  → PreFileGate.check
  → Renderer.render
```
Cross-references (re-allege ¶¶) are symbolic, resolved at render (design §8.11) — not written
by the model.

---

## 3. Acceptance criteria (design §16)

### 3.1 Golden-file (render fidelity)
Fixture: a fixed `DocumentModel` for the 2-ground MTD from the design renders (Statement of
Facts as 5 numbered ¶s; points `I.`/`II.` with `A.`/`B.` sub-points; `III. CONCLUSION` +
WHEREFORE; dated "Respectfully submitted:"; cert) + `HouseStyleSheet.defaultFL`. Golden
`document.xml` asserts: numbered facts (number at margin, text `firstLine 0`/hang to 0.5″);
**point-heading hanging indent** per level (`I.` at margin/text 0.5″; `A.` at 0.5″/text 1.0″)
via the `ind left=n·720 hanging=720` + tab-stop construct in **SupraExports §4.3** (no
numeral-box hack); "Respectfully submitted: July 21, 2026" left, `firstLine 720`; multi-page footer.

### 3.2 Leakage / safety fixtures (the most important — design §16.1)
- **Authority never invented:** stub `CitatorClient.find` to return `[]` for a proposition →
  assert the generated section contains a literal `[cite]`, never a fabricated reporter cite.
  Stub it to return an on-point hit → assert the section cites *that* hit's `CitationRef`, and
  that `AuthSource != .model`.
- **Fact firewall:** load a `StructureTemplate`/exemplar seeded with a distinctive fake fact
  ("the Vandelay contract dated 1/8/2099"); generate for a *different* matter; assert the fake
  fact does **not** appear in output **and** that any attempt was caught by the `factProvenance`
  gate (→ `[fact?]` + flag), per §15.5's two-guard design.
- **Scrub:** assert `ScrubbedProposition` sent to the citator contains no party names / matter
  facts (only the legal proposition) — the §8.9 confidentiality line.

### 3.3 Verification / repair fixtures
- A section asserting a fact with no `[S#]` → `factProvenance` failure → output has `[fact?]`,
  a `.advisory` follow-up, and **no regeneration occurred** (assert the model was called once).
- A missing required section → `contract` failure → `regenerate` (≤2) then escalate.
- A malformed cite → `citationFormat` → `deterministicFix` (reformatted, not re-rolled).

### 3.4 Eval-rubric stub (design §16.1 / §17 — advisory)
For a held-out (matter, ground) set: did each argument point address the ground's
`ElementsLibrary` elements; zero untraced facts; zero invented cites. Tracked, **not** an
acceptance blocker (attorney review is, §16.2).

---

## 4. Open decisions / risks
1. **`onPointScore` threshold** (AuthorityResolver) — start conservative (high bar → more
   `[cite]` placeholders); tune later. A placeholder beats a mis-supported cite.
2. **Retrieval granularity for `facts`** — per-section retrieval vs. whole-matter once; affects
   context budget. Lean per-section (keeps prompts small, §8.9).
3. **Point-heading OOXML hanging indent** — RESOLVED in SupraExports §4.3 (`ind left=n·720
   hanging=720` + a tab stop at `n·720`; manual numerals, not `w:numPr`). No negative-`firstLine`
   or numeral-box hack needed; still golden-locked against Word/Pages.
4. **Which local model tier** generates argument vs. slot-fill (`ModelRouter` roles) — argument
   → legal-reasoning model; affects latency. Out of slice; note for the exports/runtime wiring.

**Done = the render golden matches, the authority/fact leakage fixtures pass, and the
repair-taxonomy fixtures fire.** That proves the generation + firewall layer on the same
renderer the notice validated.
