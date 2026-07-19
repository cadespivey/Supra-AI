# Drafting Catalog — Specification

> **Status:** Design catalog plus reconciliation notes. The implementation specs are authoritative for code-level signatures and golden-locked renderer details; this catalog supplies product/design context.
> **Home module:** `Packages/SupraDrafting` (logic, with shared types in `Packages/SupraDraftingCore`) + `Packages/SupraExports` (Layer 1 renderer).
> **Confidentiality:** This spec contains only abstract document-family taxonomy and
> building-block design. It contains **no client content, party names, facts, or
> verbatim work product**. The source corpus (`~/Documents/Drafts`,
> `~/Documents/Law Library`) was read only to reverse-engineer structure and is not
> reproduced here.
> **No baked-in identity:** No firm or personal identifying information — attorney or
> client names, Bar numbers, emails, phone numbers, firm name/address, company
> identifiers — is embedded in this guidance, in the canonical formats, or in any model
> resource. All such data is supplied by the **user** at render time via neutral slots
> (from `AssistantProfile` / matter data). See §8.6.

---

## 1. Purpose

Decompose the firm's existing work product into reusable, locally-executed drafting
building blocks that Supra's own pipeline can invoke. The goal is **app-orchestrated
assembly**, not model-driven tool-calling: the user selects a document kind, and the
app deterministically runs `precedent → skeleton → generate → validate → render`.

LLM generation runs on the local MLX runtime. No Claude/cloud LLM API is in the drafting path. The sole permitted network exception is an optional public-authority lookup (CourtListener) using scrubbed legal proposition/citation strings only; offline or inconclusive lookup falls back to `[cite]`.

---

## 2. Architecture — three layers, adapted for Supra

The design adopts a three-layer separation (format / reasoning / grounding), with
several Supra-specific adaptations.

| Layer | Responsibility | Determinism | Supra home |
|---|---|---|---|
| **1. Render shell** | The physical document: caption, font, numbered ¶s, point headings, signature block, certificate of service, letterhead | Deterministic (no LLM) | `SupraExports` |
| **2. Analytical skeleton** | The reasoning structure inside the body (IRAC / CRAC / house motion structure) | LLM, contract-validated | `SupraDrafting` + existing `StructuredOutput` system |
| **3. Precedent grounding** | Mirror the firm's own filed examples of that exact type | Retrieval (local) | `DocumentRetrievalService` + catalog index |

### Adaptation A — app-orchestrated, not model-dispatched
Local models are unreliable at function-calling. The model only writes prose; the
*harness* decides which shell, skeleton, and precedent to use. This matches the
existing `StructuredOutputController` flow (generate → analyze → repair).

### Adaptation B — structure / fact / identity firewall (non-negotiable)
Precedent grounding must **never** dump a prior filing's full text into the prompt as
context — that reintroduces the confabulation bug already closed in 1.5.0
(`matter-chat-grounding`) and the writing-samples-leak rule
(`style-exemplars-voice-only`). Precedent splits into channels:

- **Structure & voice channel** — extract the *skeleton* (heading sequence, CRAC
  rhythm, boilerplate phrasing) from filed examples. Safe to mirror.
- **Fact channel** — the *only* source of facts is the current matter's documents,
  retrieved and cited, gated by a `CitationCoverage`-style check that flags any
  specific fact (name / date / dollar / holding) not traceable to *this* matter.
- **Identity channel** — names, Bar numbers, emails, firm/company identifiers are
  **never** baked into guidance or canonical formats; they are user-supplied slots
  filled at render time (§8.6). The firm's own templates contain real attorney
  identities — those are stripped to slots on ingest, never carried into the model.
- **Authority channel** — legal authority (case/statute citations) is sourced **like
  facts**, never written from the model's weights — the failure mode behind the
  AI-fabricated-citation sanctions (*Mata v. Avianca* and its progeny). In an `Auth` kind
  the model emits only citations drawn from a verified source or the user's
  exemplars-as-candidates (then checked, §8.2), or leaves a bracketed `[cite]` slot for the
  attorney. It does **not** invent authority.

This maps directly onto the existing `StructuredOutputType.assertsLegalAuthority`
property: every draft kind that asserts authority inherits mandatory citation review (§8.2).

### Adaptation C — jurisdiction-scoped, precedent-optional
Shells, skeletons, and binding-rules are scoped per jurisdiction. **Current scope:
Florida STATE only** (Georgia and MDFL/federal deferred — §8.7). Precedent grounding is *optional
augmentation*: where a jurisdiction has little or no corpus (Georgia, when it arrives),
the system runs on shell + skeleton + binding-rules pack + user-uploaded exemplars,
leaning on interactive follow-ups to fill gaps. See §8.4–8.7.

### Adaptation D — content sources vs. format authority (kept separate)
Two different kinds of source material feed two different layers and must not be
conflated:
- **Content / elements sources** — secondary sources and practice guides (e.g. the
  Lexis-imported templates) supply *what must be in* a document: required elements of a
  cause of action, procedural prerequisites, statutory recitals. They feed **Layer 2**
  (the analytical skeleton + a required-elements/procedural checklist). Their
  **typography is not authoritative** and is discarded.
- **Format / typography authority** — the *user's own filed work product* (house style)
  is the sole basis for formatting: styles, numbering, indentation, headings, component
  layout. It feeds **Layer 1** (§4 Typography).

A Lexis template therefore informs *what to say*, never *how it looks*; the house style
informs *how it looks*; and the matter supplies *the facts*. See §8.4.

---

## 3. Building-block taxonomy

Each document family resolves to exactly one of three block types.

| Block type | When to use | Existing analog |
|---|---|---|
| **Routed drafting skill** | Free-form, voice-driven, varies every time | `/draft` route, `LegalPromptTemplates.draftingSystemPrompt` |
| **Structured-output contract** | Stable skeleton with required sections to validate/repair | `StructuredOutputContract` + `draftingSkeleton` |
| **Service pipeline** | Machine-checkable fields (dates, numbered items, party slots, cert of service) | `BillingDraftService` (LEDES) |

**Decision rule:**
- Has hard, checkable fields or is essentially a fill-in form → **service pipeline**.
- Has a stable analytical skeleton to enforce → **structured-output contract**.
- Genuinely free-form and stylistic → **routed drafting skill**.

---

## 4. Render shells (Layer 1)

Format authority is the **user's own filed work product (house style)** — the
named-style, real-e-filing-language templates and filed drafts — **not** the
secondary-source (Lexis-imported) templates, whose typography is discarded (Adaptation
D). The v1 renderer is programmatic WordprocessingML/OPC, not `NSAttributedString → .docx`:
the caption, signature, footer, and heading constructs are golden-locked and require exact
OOXML control. No cloud renderer is required.

| Shell | Covers | Source templates |
|---|---|---|
| `courtFL` | FL state filings: caption block, TNR 12, numbered allegation ¶s, `I.A.1.a.i.` outline headings, signature block, certificate of service, no letterhead | `Pleadings/`, `Motions/`, `Notices/`, etc. |
| `courtMDFL` | M.D./S.D. Fla. federal filings (FRCP 7.1, removal, federal caption, CM/ECF) | **deferred** — out of v1 (FL-state-only); hooks retained; `MDFL Pleading - *.dotx` |
| `courtGA` | GA Superior/State court filings: GA caption, Uniform Superior Court Rules format | **deferred** — out of current FL-first scope; no GA templates in corpus |
| `letterhead` | Branded letter shell (demand, C&D, correspondence) | `Letters & Correspondence/` |
| `internalMemo` | Privileged internal memo — TO/FROM/RE, not for filing | `Practice Tools/Memos/` |
| `chronologyTable` | Chronology / chart layout | (derived; `factChronologyTable` exists) |
| `agreement` | Transactional: title block, recitals, numbered articles, signature/notary blocks, exhibits | `Construction/AIA`, transactional drafts |

### Caption is a structured component, not styled prose
The caption is a dedicated, parameterized render primitive — **never** generated prose
or naive paragraph styling — emitted as a **2-column borderless table** beneath a
centered court-header paragraph. Confirmed **house caption rules** (the user's filed
standard overrides the Lexis/template variants):
- **Left cell** = party block; **right cell** = `CASE NO.` then `DIVISION`. **No `)`
  delimiter column** — the template `)` ladder is dropped.
- **Two-up via a 2-cell table** (`table-layout: fixed`): left cell and right cell are
  each one-half of the usable page width. The firm-zero locked geometry is total width
  **9360 twips** with grid **`[4680, 4680]`**. There is **no buffer/spacer column**; the
  earlier 3-cell / 360-twip spacer design was rejected by the round-tripped Word goldens.
- **Single-spaced**, with **one blank line between parties and on each side of `v.`**.
  Each party name and its designation ("Plaintiff,"/"Defendant,") sit on consecutive
  single-spaced lines; the **closing rule beneath the party block extends to the
  ½-page mark and terminates in `/`** (marking where the column stops).
- **Right cell**: `CASE NO.` and `DIVISION` on **consecutive lines, no blank between
  them**, top-aligned.
- Slots: court header, **party block** (generated from the party & alignment model §8.8,
  with compound designations for counterclaim/crossclaim/third-party postures), case
  number, division, judge. Where a user exemplar
  exists, mirror its exact column widths (§8.4); otherwise the house default above
  governs. This remains the hardest Layer-1 fidelity point (§11).

### courtFL typography & body conventions (one court filing house style sheet)
The rules in this subsection apply to **courtFL court filings**, not every render shell.
`letterhead`, `agreement`, `internalMemo`, and other shells have their own shell-specific
spacing, page-number, and typography rules; demand letters, for example, are single-spaced
block letters with no court caption/COS and no v1 page footer.

The corpus shows heavy drift here — ~15 overlapping named Word styles
(`Heading1`/`Title`/`TitleMixedCase`/`TitleCaps`/`TitleCapsUL`/`TitleUL`/`Title2UL`/…)
and indents scattered across 360/720/1080/1440/1800/2160 twips. All of it normalizes to
**one house style sheet** with a small, fixed set of levels:

- **Paragraph numbering.** Pleadings use **manually numbered allegation paragraphs** —
  averments in **consecutively numbered paragraphs**, each "limited as far as
  practicable to a statement of a single set of circumstances" (Fla. R. Civ. P.
  **1.110(f)**, confirmed against the 2026-04-01 rules) — rendered as deterministic
  text, **not** Word auto-lists (the corpus is 380 manual `1.`/`2.` ¶s
  vs. 17 auto-numbered). Motions, briefs, memos, and letters use **unnumbered prose
  paragraphs** organized by point headings. Numbering mode is therefore a property of
  the `DraftKind` (pleadings = numbered allegations; everything else = unnumbered).
  Numbered paragraphs place the **number at the left margin with the text beginning at
  the 0.5″ tab** (wrapped lines return to the margin) — the same alignment for pleading
  allegations and a motion's numbered Statement of Facts.
- **Heading hierarchy.** One canonical outline scheme — **`I.` → `A.` → `1.` → `a.` →
  `i.`** (Roman, capital letter, arabic, lowercase letter, lowercase roman) — mapped to
  heading levels 1–5. The ~15 legacy styles collapse onto these five levels. Point
  headings in motions/briefs sit at level 1 (`I.`), each carrying a CRAC/CREAC argument.
  Each heading uses a **0.5″ hanging indent** with the numeral/letter in the hang: per
  level, the numeral is indented `(level−1)×0.5″` and the text begins at `level×0.5″`,
  and any wrapped line aligns under the *text* — `I.` at the left margin / text at 0.5″;
  `A.` at 0.5″ / text at 1.0″; `1.` at 1.0″ / text at 1.5″; and so on. (Render note: the
  numeral box must reset its own `text-indent` so the hang doesn't drag the numeral left.)
  The
  **Conclusion is the final point heading**, carrying the next capital Roman numeral
  (e.g. `III.`) in sequence — not a separate centered heading.
- **Indentation ladder.** A defined ladder keyed to outline depth (e.g. body 0.5",
  level-2 1.0", level-3 1.5"), replacing the ad-hoc 360–2160-twip spread. Exact values
  are lifted from the house style, never invented.
- **Paragraph indent & spacing.** Every body paragraph carries a **0.5″ first-line
  indent**. **Body text is double-spaced**, but **every blank separation is exactly one
  single 12-pt line** — after a title line (NOTICE OF APPEARANCE, CERTIFICATE OF SERVICE,
  etc.) and between paragraphs there is one single-spaced blank line, **not a double
  gap**. Exceptions that are single-spaced: the **certificate-of-service body + its
  recipient/service list** (the COS is not double-spaced) and the **signature block**
  (§12.1–12.2).
- **Page numbers.** **Suppressed on page 1**; from page 2 on, the number sits in the
  **footer, centered, current page only** (the bare number) — satisfying the 2.520(a)(2)
  consecutive-numbering requirement without printing a "1" on the first page.
- **Base typography.** Split the **rule-mandated floor** from **house-style choices**.
  Mandated by Fla. R. Gen. Prac. & Jud. Admin. **2.520(a)** ✓: letter size (8½×11),
  **≥12-pt font**, **≥1-inch margins all sides**, **consecutively numbered pages** (+ a
  3"×3" blank top-right on page 1 for documents to be recorded). House-style on top of
  that floor: the specific font face (e.g. Times New Roman) and line spacing (e.g.
  double-spaced filings). A single `HouseStyleSheet` source of truth applies both, never
  per-template; the renderer must never drop below the 2.520(a) floor.

Implementation: a single `HouseStyleSheet` (level → font / indent / numbering) consumed
by the Layer-1 renderer, with the heading scheme and numbering mode as render
parameters. Where a user exemplar exists, its style sheet is mirrored (§8.4); otherwise
the house default governs.

---

## 5. Analytical skeletons (Layer 2)

Skeleton is an explicit **parameter** of a draft kind (not "composed by hand each
time"), so the contract can validate it came out right.

| Skeleton | Shape | Used by |
|---|---|---|
| `irac` | Issue → Rule → Application → Conclusion | single-ground motions, analysis memos |
| `crac` | Conclusion → Rule → Application → Conclusion (per point heading) | motions, oppositions |
| `creac` | Conclusion → Rule → Explanation → Application → Conclusion | briefs, memos of law |
| `houseMotionFL` | Introduction → Statement of Facts → Memorandum of Law (CRAC point headings) → Conclusion/Relief → signature → cert of service | FL motions/responses |
| `countPerClaim` | Jurisdiction/Venue/Parties → Facts → Count I…N (elements) → Prayer | complaints, counterclaims |
| `perRequest` | Numbered request items / per-request objection map | discovery requests & responses |
| `clauseAssembly` | Recitals → assembled clauses from library → signature/exhibits | transactional agreements |
| `chronology` | Date-ordered event rows with source locators | timelines, designations |
| `none` | Pure slot-fill form (no reasoning) | notices, proposed orders, affidavits |

Every section additionally terminates in a **verification gate** (§8.2) that runs
before the next section is drafted or the document is assembled.

---

## 6. Document catalog

Proposed identifiers use a `DraftKind` enum (see §9). "Auth" = `assertsLegalAuthority`
(triggers mandatory citation review). "Template" = a matching `.dotx` exists.

### 6A. Litigation — Pleadings (`courtFL` / `courtMDFL`)

| DraftKind | Skeleton | Block | Auth | Template | Key slots |
|---|---|---|---|---|---|
| `complaint` | countPerClaim | contract | ✓ (elements) | ✓ | parties, jurisdiction, venue, counts, facts |
| `complaintLien` (ch. 713 foreclosure) | countPerClaim | contract | ✓ | ✓ | lien claim, statutory elements |
| `petitionDiscovery` (pure bill) | countPerClaim | contract | ✓ | — | grounds, relief |
| `answer` | per-paragraph admit/deny | service | partial | ✓ | mirror complaint ¶s, affirmative defenses |
| `counterclaim` / `crossclaim` / `thirdPartyComplaint` | countPerClaim | contract | ✓ | ✓ | claims, parties |
| `replyAffirmativeDefenses` | per-paragraph | service | — | ✓ | mirror defenses |

### 6B. Litigation — Motions & responses (`courtFL`, `houseMotionFL`)

| DraftKind | Skeleton | Block | Auth | Template | Notes |
|---|---|---|---|---|---|
| `motionToDismiss` (12(b)(6)/venue/PJ/SMJ/forum) | houseMotionFL (argument points use CRAC) | contract + precedent | ✓ | ✓ ×6 | flagship; ground-specific variants |
| `motionSummaryJudgment` | crac + Statement of Material Facts (service) | contract + service | ✓ | ✓ ×3 | SMF is a separate checkable artifact |
| `motionToCompel` (rogs/production/depo) | crac | contract + precedent | ✓ | ✓ ×3 | + good-faith conferral recital |
| `motionInLimine` | crac | contract | ✓ | ✓ | trial |
| `motionProtectiveOrder` | crac | contract | ✓ | ✓ | |
| `motionFees` (entitlement + amount) | crac + fee schedule | contract + service | ✓ | — | + reasonableness affidavit link |
| `motionSanctions` | crac | contract | ✓ | — | |
| `motionCompelArbitration` | crac | contract + precedent | ✓ | — | |
| `motionRoutine` (continue, extend, enlarge, remote testimony, withdraw, substitute) | short | service/contract | — | ✓ | low-reasoning, mostly slot-fill |
| `motionWritGarnishment` | statutory | service | partial | — | + statutory notices |
| `motionResponse` / `opposition` | crac mirroring movant | contract + precedent | ✓ | — | structure mirrors the motion answered |

> **MSJ note (Rule 1.510, eff. 2026-04-01):** FL applies the **federal** summary-judgment
> standard (1.510(a)). The movant must **serve supporting factual positions with the
> motion** (1.510(c)(5)) — this is the "statement of material facts" artifact — and the
> nonmovant responds no later than **40 days** after service. Time to file: any time after
> 20 days from commencement (1.510(b)). Encode these as MSJ slots/deadlines.

### 6C. Litigation — Briefs (`courtFL` / `courtMDFL`, `creac`)

| DraftKind | Skeleton | Block | Auth | Notes |
|---|---|---|---|---|
| `brief` (claim construction, JMOL, Markman, appellate, reply, supplemental authority) | creac | contract + precedent | ✓ | large context budget; precedent-mirroring most valuable here |

### 6D. Litigation — Notices, orders, affidavits, stipulations (mostly `none`)

| DraftKind | Skeleton | Block | Auth | Template | Key slots |
|---|---|---|---|---|---|
| `noticeAppearance` | none | service | — | ✓ | counsel, party represented, bar no. |
| `noticeHearing` | none | service | — | ✓ | motion, date/time, judge, duration, method |
| `noticeServingDiscovery` | none | service | — | ✓ | discovery served, date |
| `noticeMisc` (settlement, dismissal, foreign judgment, subpoena, removal) | none | service | — | ✓ | variant-specific |
| `rule71Statement` (MDFL corporate disclosure / interested parties) | none | service | — | ✓ | `courtMDFL` |
| `proposedOrder` | none | service | — | ✓ ×4 | mirrors the motion's relief |
| `affidavit` / `declaration` / `verification` | none + verification block | service | — | ✓ ×7 | affiant, statements, notary |
| `affidavitSpecialized` (contractor final payment, attorney-fee reasonableness) | none + statutory recitals | service | partial | ✓ | |
| `stipulation` (dismissal, extend time, protective order) | none/short | service | — | ✓ ×8 | parties, terms |

### 6E. Litigation — Discovery (`courtFL`, `perRequest`)

| DraftKind | Skeleton | Block | Auth | Template | Notes |
|---|---|---|---|---|---|
| `discoveryInterrogatories` | perRequest | service | — | ✓ | numbered-item generator |
| `discoveryRFP` | perRequest | service | — | ✓ | |
| `discoveryRFA` | perRequest | service | — | ✓ | |
| `discoveryResponse` (rogs/RFP/RFA) | per-request objection map | service | — | ✓ | boilerplate objections + substantive answers |
| `initialDisclosures` | sectioned | service | — | ✓ | |
| `subpoena` (duces tecum / trial / depo) | none | service | — | ✓ ×8 | |
| `privilegeLog` | table | service | — | — | chart output |

### 6F. Litigation — Letters (`letterhead`)

| DraftKind | Skeleton | Block | Auth | Template | Notes |
|---|---|---|---|---|---|
| `letterDemand` | none (voice) | routed drafting | — | ✓ | high frequency; voice-driven |
| `letterDemandStatutory` (ch. 558, §190.026, intent-to-sue, HOA pre-suit) | statutory checklist | drafting + service gate | partial | ✓ | must hit statutory required content |
| `letterCeaseDesist` | none | routed drafting | — | ✓ | |
| `letterPreservation` (litigation hold) | checklist | drafting + service | — | ✓ | |
| `letterGeneral` (OC, client, expert, mediator) | none | routed drafting | — | ✓ ×20 | |

### 6G. Work product — internal memos (`internalMemo`, not for filing)

| DraftKind | Skeleton | Block | Auth | Notes |
|---|---|---|---|---|
| `memoLegal` / `memoOfLaw` | creac | contract + precedent | ✓ | research memo |
| `memoAnalysis` (strategy, MSJ analysis) | irac/flexible | contract | ✓ | |
| `memoFact` (pre-deposition, production review) | chronology/flexible | contract | — | facts only |

### 6H. Trial & evidentiary (`courtFL`)

| DraftKind | Skeleton | Block | Auth | Template | Notes |
|---|---|---|---|---|---|
| `witnessExhibitList` | table | service | — | — | |
| `pretrialStatement` | sectioned | contract | partial | ✓ | |
| `statementOfIssues` (law/fact, uncontested facts) | sectioned | contract | partial | — | |
| `voirDire` | list | contract/template | — | ✓ | |
| `expertDisclosure` | sectioned | service | — | — | |
| `depoDesignations` | table | service | — | — | designations + objections/counters |
| `trialOutline` (opening/direct/cross) | outline | routed drafting | — | — | |
| `mediationStatement` | persuasive sectioned | contract | ✓ | — | confidential |
| `juryInstructions` / `verdictForm` | per-instruction | contract/service | ✓ | — | (friend's catalog) |

### 6I. Chronology / charts (`chronologyTable`)

| DraftKind | Skeleton | Block | Auth | Existing |
|---|---|---|---|---|
| `chronology` (timeline of events) | chronology | service | — | maps to `factChronologyTable` |
| `claimConstructionChart` | table | service | — | — |
| `documentIndex` | table | service | — | — |

### 6J. Transactional — agreements (`agreement`, `clauseAssembly`) — see §7

| DraftKind | Block | Notes |
|---|---|---|
| `agreementSettlement` / `agreementRelease` | service + clause library | full / mutual / scoped-release variants |
| `agreementNDA` | service + clause library | |
| `agreementEmployment` (confidentiality, termination + release) | service + clause library | |
| `agreementConstruction` (MSA, GC–sub federal/non-federal, subcontract, change order, qualifying agent, limited warranty) | service + clause library | AIA-style; federal vs. non-federal variants |
| `agreementServices` (e.g. fractional CFO) | service + clause library | |
| `agreementCorporate` (LLC formation) | service + clause library | |

### 6K. Spanish-language / bilingual — OUT OF SCOPE
**Dropped (2026-06-25): no translation feature.** The Spanish-language client docs in the
corpus are not a build target. If ever needed, they'd be a separate localization layer, not
part of this catalog.

---

## 7. Transactional sub-architecture (new scope)

Agreements are an **assembly** problem, not a generation problem: the operative terms are
pre-vetted clauses selected and slot-filled, then checked for internal consistency — the
model **selects**, it does not free-write the terms. Block type: **service pipeline** with a
clause-assembly stage (closer to `BillingDraftService` than to a prose contract).

**Clause library.** Tagged, versioned, slotted clauses:
`{ id · tag (release.mutual, indemnity.broad, governing-law.fl, confidentiality.standard…)
· text-with-slots · definedTermsUsed · selecting params · jurisdiction · version ·
provenance }`. **Source (Decision A):** firm-derived — extracted from the firm's own
transactional corpus (NDAs, MSAs, settlements, subcontracts) via the §15-style derivation
(tag + slot the firm's clauses; **strip party-specifics/identity to slots**, firewall §8.6)
— with **optional app-shipped FL default clauses** as a seed so a firm with no transactional
corpus isn't stuck. Clauses are firm config, like the `HouseStyleSheet`.

**Assembly pipeline:** select clauses (deal type + params) → slot-fill (parties / dates /
amounts / governing law, from matter + user via §8.1) → assemble → **deterministic
consistency passes** → flag issues to the §8.1 follow-up queue → render.

**Deterministic consistency passes** (linters, not LLM):
- **Defined-terms registry** — every capitalized defined term declared once and used
  consistently; flags undefined-but-used and defined-but-unused.
- **Party-role consistency** — one source of truth for Buyer/Seller/etc. (the transactional
  analog of the §8.8 party model), validated across the whole document.
- **Exhibit/schedule cross-ref** — every referenced exhibit/schedule exists, and vice versa.

**Alternatives / fallbacks.** Per clause type the library holds variants keyed to
negotiation posture (mutual vs. one-way indemnity; broad vs. scoped release), selected by
deal params or user choice — not a single canonical (mirrors the playbook idea in the
`legal:review-contract` skill).

**Model role (Decision B) — assembly-first.** Clauses are pre-vetted library text, selected
and slot-filled deterministically. The model writes or adapts a clause **only when the
library has no fit**, and **any model-written or model-altered clause is flagged for
attorney review** (advisory, §8.1) — it never silently free-generates operative terms,
because a changed indemnity or release scope is a liability (the same reason authority is
firewalled in §8.9 / #2).

---

## 8. Cross-cutting machinery

### 8.1 Slot model & intake (interactive follow-ups)
**Slot schema.** A slot is a typed, sourced field: `{ name · type (string / date /
party-ref / enum / money / list / citation) · source · required (incl. *conditionally*
required) · validation · provenance · state (derived vs. confirmed) }`. Each `DraftKind`
**declares its slot set** (formalizing the "key slots" column in §6).

**Auto-resolution by source — the app asks for as little as possible:**
- **Matter metadata + party model (§8.8)** → caption, parties, case no., court, division.
- **`AssistantProfile`** → identity: firm, attorney, Bar no., emails, address (per-firm).
- **Matter documents** → facts, carrying `[S#]` provenance (firewall, §8.6).
- **Elements library / binding-rules pack (§8.10)** → required recitals, deadlines.
- **User** → only the irreducible inputs *only they know*: relief sought, the ground(s),
  tone, a hearing date.

**Interaction model — hybrid, draft-first (Decision Z).** Auto-fill everything the slot
model can derive; ask up-front *only* for the few inputs a coherent first draft genuinely
requires (you can't write an MTD without its ground). For everything else, **draft
immediately and drop a placeholder** (`[relief]`, `[cite]`, `[fact?]`) rather than refuse —
a draft with holes beats a wall of questions (consistent with the §8.9 `[cite]` posture).
Hard-blocks are reserved for the handful of things a draft literally cannot render without
(parties/court — which come from the matter, so rarely missing).

**Follow-up queue — one mechanism for every "ask."** All of the spec's scattered
"prompt the user" moments are a single typed queue, each item carrying a **severity**
(**blocking** = must answer to proceed · **advisory** = draft proceeds, resolve before
filing):
- missing required slot · **conflict** (§8.4 exemplar-vs-rule) · **verify** (§8.2
  unconfirmed citation, §8.10 likely-missing element) · **confirm derived** (a party-model
  compound designation, an auto-pulled fact).

Asks surface up-front (must-haves), in-flight (gate-raised), and are **consolidated at the
pre-file gate** (§8.3) — the existing "needs review" clearinghouse, so nothing slips through.

### 8.2 Per-section verification (required on every section)
Every section of every draft terminates in a verification pass **before the next
section is drafted or the document is assembled** — not just one gate at the end. Each
section's verifier runs:
- **Contract check** — required content for that section present (its heading contract).
- **Citation & authority check** — distinct from fact provenance (below): (i) **format**
  — cites are well-formed and no legal assertion is left uncited (local, parser); (ii)
  **validity** — existence, accurate quotation, and good-law status **cannot be checked
  offline**, so emitted/candidate cites are looked up against **CourtListener** (public
  citation *string* only — never matter content; the one network call in an otherwise-local
  path, carrying no confidential data, consistent with the existing
  `retrievedFromCourtListener` status) and anything the lookup can't confirm is **flagged
  for mandatory human verification**. The app never self-marks a cite "verified," and
  authority is sourced, never invented (§2 Authority channel / §8.6).
- **Rule conformance** — section obeys the binding-rules pack for its jurisdiction
  (format, required recitals, page/word limits).
- **Fact provenance** — every fact traces to a current-matter document; untraceable
  facts flagged (firewall).
- **Conflict resolution** — any unresolved exemplar-vs-rule conflict (§8.4) is raised.

Implemented via the existing `legalVerify` / `legalCritique` routes + `CitationCoverage`.
**Repair is keyed to the failure type** — three buckets, never a single re-roll-until-it-
passes loop:
- **Regenerate** (structural/format only) — a missing required section; a page/word-limit
  overflow (regenerate-to-tighten). **Bounded to 2 passes** (as `StructuredOutputController`
  already does); if still failing, escalate to the §8.1 follow-up queue.
- **Deterministic fix** (mechanical, no LLM) — reformat a malformed citation; add a missing
  required recital/format element from the rules pack.
- **Strip → placeholder + flag** (substantive) — an unsupported fact → `[fact?]`; an
  unverifiable authority → `[cite]`; an element shortfall (§8.10) → advisory flag. These are
  **never re-rolled**: re-running the model to make a fact-provenance or authority check
  "pass" launders a hallucination, so the failure is removed to a placeholder and flagged,
  not regenerated. Conflicts (§8.4) are a user follow-up, not a repair.

Per-section status is shown so the user sees exactly where review is needed, rather than
discovering it only at the end.

### 8.3 Pre-file checklist gate
A final whole-document gate, after all sections verify: caption complete? signature
block present? certificate of service attached (filings)? statutory required content
present (`*Statutory` kinds)? defined terms consistent (transactional)? Failures block
export and surface to the user, mirroring the `CitationCoverage` "requires review"
banner. This is also where the **§8.1 follow-up queue consolidates** — every unresolved
advisory (conflicts, unverified citations, likely-missing elements, open placeholders) is
listed here for the attorney to clear before export.

### 8.4 Drafting-basis precedence & conflict resolution
Drafting inputs feed two channels — **content** (what the document must say/contain) and
**format** (how it looks) — ranked separately. Cross-channel conflicts are resolved
**interactively, never silently**.

**Content / elements channel** (what must be in the document):
1. **Binding authority** — required elements, procedural prerequisites, and statutory
   recitals from rules/statutes/controlling law for the jurisdiction.
2. **Secondary sources / practice guides** (e.g. Lexis-imported templates) — checklists
   of elements and procedural requirements. Content only; **formatting discarded** (Adaptation D).
3. **User exemplar / firm precedent** — the section ordering and reusable phrasing the
   user actually uses.
4. **Matter facts** — supplied only by the current matter's documents (§8.6).

**Format channel** (how it looks):
1. **Binding authority** — mandatory format the court enforces (caption, line
   numbering, page/word limits, presence of required certificate/recital).
2. **User exemplar → house style sheet** (§4 Typography) — the formatting basis: styles,
   numbering, indentation, headings, component layout. Secondary-source templates are
   **not** a format input.
3. **House default style sheet** — fallback where no exemplar exists (e.g. Georgia).

Identity (names, Bar numbers, emails, firm/company) is in **neither** channel as baked
content — it is always a user-supplied slot (§8.6).

Conflict policy, by dimension:
- **Formatting** — the **exemplar is the basis** (a filed exemplar already embodies
  accepted court formatting). The binding-rules pack runs only as a backstop *check*
  and prompts solely on a **material** difference — page/word-limit overflow, a missing
  mandatory certificate or recital, a prohibited section. Cosmetic differences (font,
  spacing, minor caption variation) are **not** prompted; the exemplar wins. Where no
  exemplar exists (Georgia initially), the rules pack + template shell govern
  formatting directly.
- **Substance** (case law, legal standard) — the exemplar's authorities are treated as
  *candidates*; suspect items (superseded, out-of-jurisdiction) or a standard that
  mismatches the matter's jurisdiction **always** prompt: keep / replace / verify.
- **Facts & identity** — the exemplar is **never** a fact or identity source; its
  parties, dates, holdings, and any attorney/firm identifiers are quarantined. Facts
  come only from the current matter; identity comes only from user-supplied slots
  (§8.6); both run through the §8.2 checks.

"Material" = a difference that would risk rejection or non-compliance, as opposed to
cosmetic.

This generalizes the firewall rather than weakening it: the exemplar is an explicit,
user-chosen precedent source for the *structure* channel, with the *fact* channel
unchanged.

### 8.5 User-uploaded exemplars (building the library)
Users can upload their own work product, tagged to a `DraftKind` + jurisdiction, to
serve as the drafting basis for that kind. This is how the **Georgia** (and later
other-state) library is built, since the firm's existing corpus is almost entirely
Florida. Design consequences:
- **Precedent is optional augmentation, not a hard dependency.** When no exemplar or
  corpus exists for a (kind × jurisdiction) — the initial GA state — the system falls
  back to template shell + skeleton + binding-rules pack and leans harder on
  interactive follow-ups.
- Uploaded exemplars feed **two parallel extractions**, both quarantining facts and identity
  to slots (§8.6): **format** → the `HouseStyleSheet` (§15.1–15.4), and **content structure
  & voice** → per-kind **structure templates** (§15.5). These are distinct artifacts — the
  style sheet is geometry; the structure template is skeleton + reusable boilerplate.
  (Secondary-source / practice-guide uploads instead feed the content/elements checklist —
  §8.4 — and contribute neither formatting nor structure.) Stored per matter or firm-wide.
- Over time the user curates a per-jurisdiction exemplar set, improving output without
  ever loosening the fact firewall.

### 8.6 Voice / fact / identity (firewall, restated)
- `AssistantProfile` writing samples → **voice/tone channel only** (style & register —
  **never a fact or authority source**). Permitted for `letter*` and `trialOutline`; the
  channel carries `toneOnly`. **The gate is *grounded-ness*, not `Auth`:** a kind can be
  non-`Auth` yet **grounded** — a demand `letter*` recites matter facts — so where voice is
  on *and* the document is grounded, the **fact-provenance check (§8.2) still runs**. That
  check, not the absence of voice, is what prevents sample-derived facts from leaking. Voice
  is **never** enabled for `Auth` kinds (see `style-exemplars-voice-only`).
- Precedent skeletons and uploaded exemplars → structure/format channel.
- Facts → matter documents only (fact-provenance check, §8.2).
- **Authority → sourced, never invented.** Case/statute cites come from a verified lookup
  (CourtListener, public string only) or user-supplied candidates, or are left as `[cite]`
  slots; every `Auth`-kind cite carries a verify state until human-confirmed (§8.2).
- **Identity → user-supplied slots only.** Attorney/firm/client names, Bar numbers,
  emails, phone, firm name/address, and company identifiers are filled at render time
  from `AssistantProfile` (signature/firm block) and matter data — **never** embedded in
  a template, canonical format, or model resource. Signature blocks, certificates of
  service, and notary blocks are emitted as neutral slot scaffolds; the corpus's real
  attorney identities are stripped on ingest.

### 8.7 Jurisdiction model
Render shell, skeleton, and binding-rules pack are all **jurisdiction-scoped**. **Current
scope: Florida STATE only** — the FL state rules/statutes are now fully grounded (Rules of
Civil Procedure eff. 2026-04-01; Rules of Gen. Prac. & Jud. Admin. eff. 2026-01-01; Fla.
Stat. chs. 55, 77, 117, 713). **Two jurisdictions are deferred** (architectural hooks
retained, neither built for v1): **MDFL / federal** — a separate jurisdiction pack (FRCP +
per-district M.D./S.D. Fla. local rules + federal caption / CM-ECF closing blocks; local
rules change regularly, so confirmed at draft time) — and **Georgia** (GA Superior/State
caption + Uniform Rules + a GA rules pack + user-built exemplars). The order between the two
is **open** (federal-next vs. GA-next). Each new jurisdiction = a shell set + a rules pack +
(optionally) exemplars.

### 8.8 Party & alignment model (multi-party / counterclaim / crossclaim / third-party)
Complex case structures are driven by a single **party & alignment model** — the
litigation analog of §7's transactional party-role consistency, and the source of truth
the caption, the role slots, and the service routing all read from. Three parts:

1. **Party registry** — every party recorded once (`id`, name, type, base role:
   plaintiff / defendant / third-party / nonparty), in caption order. Identity is
   user-supplied slots (§8.6).
2. **Claim/alignment graph** — each claim records its type and who asserts it against
   whom: complaint (Plaintiff → Defendant); **counterclaim** (Defendant → opposing party
   — Fla. R. Civ. P. **1.170(a)** compulsory / **(b)** permissive); **crossclaim**
   (co-party → co-party, 1.170(g)); **third-party complaint** (Defendant → a new
   Third-Party Defendant — **1.180**, leave not required if filed ≤20 days after serving
   the original answer, otherwise on motion).
3. **Derived compound designations** — each party's caption/role label is *computed* from
   the graph, never hand-typed: a counterclaiming defendant becomes
   "Defendant / Counter-Plaintiff" and the plaintiff "Plaintiff / Counter-Defendant"; a
   crossclaiming defendant "Defendant / Crossclaim-Plaintiff"; the added party
   "Third-Party Defendant." Being derived, the same designation flows consistently into
   the caption, the title ("DEFENDANT / COUNTER-PLAINTIFF'S MOTION …"), and every body
   reference.

What it feeds:
- **Caption render (§4)** — the left-cell party block is generated from the registry +
  designations; the third-party block appends below the main parties. For many parties,
  an **abbreviated caption** (lead party + "et al.") with a full party list is a render
  option.
- **Role slots** — titles and body party references pull compound roles from the model,
  so the moving/served party is always labeled correctly.
- **Service routing (§12.2 / §13)** — a party newly **added** by a third-party complaint
  (1.180) or counterclaim/crossclaim joinder (**1.250(c)**) is served as **original
  process** (summons + complaint, return of service under 1.070(b)) — **not** a 2.516
  certificate. The model flags new parties so the renderer never auto-appends a cert to
  their first service.

Validation it enforces: **compulsory-counterclaim check** (1.170(a) — flag a known
transaction-related claim against an opposing party that isn't pleaded, a waiver risk);
**third-party leave** (1.180 — require the leave branch when filed >20 days after the
original answer); **designation consistency** (every party reference uses its derived
compound role; singular/plural matches party count, tying into the §12.1 representation
line). This makes `complaint` / `answer` / `counterclaim` / `crossclaim` /
`thirdPartyComplaint` (§6A) instances over a shared party model rather than isolated
templates — scaling from "Plaintiff v. Defendant" to a multi-party counter/cross/
third-party posture without re-deriving the caption by hand.

### 8.9 Generation / prompt assembly
The `generate` step (pipeline-wise, between slot intake §8.1 and per-section verification
§8.2) is the only step that writes prose, and it runs **section by section** — each section
generated, verified, then the next. Service-pipeline kinds barely invoke it (slot-fill +
deterministic assembly, à la `BillingDraftService`); the real work is in `contract` and
routed-drafting kinds (motions, briefs, memos, letters).

**Layered prompt** — the harness assembles each section's prompt deterministically
(app-orchestrated, Adaptation A); the firewall gates which layers a given kind may use:
1. **Task + voice** — the section task; house voice from `AssistantProfile` only where
   permitted (letters/outlines, never `Auth` kinds — §8.6).
2. **Structure** — the section's required content (heading contract + the content-channel
   required-elements checklist, Adaptation D) and the skeleton shape (e.g. CRAC).
3. **Facts** — retrieved matter facts for this section, carrying `[S#]` labels; the *only*
   fact source (§8.6).
4. **Authority** — retrieved cites or `[cite]` slots (authority-finding below).
5. **Precedent** — the firm's section-ordering/phrasing as an *abstracted skeleton*, never
   the exemplar's text (§8.4 structure channel).

Extends existing infra (`StructuredOutputPromptBuilder` `{{context}}`,
`ModelRouter`/`LegalPromptTemplates`, `composedAssistantPrompt`); the new parts are the
section loop, the multi-channel grounding, and the firewall gating.

**Prompt templates are ENGINE, not firm config (decision A).** App-authored and versioned —
part of controlled generation/safety behavior. Firms tune *output* via the `HouseStyleSheet`
(format), exemplars (structure/voice), and identity — never by editing raw prompts (§14.1).

**Authority-finding — retrieval-augmented, placeholder fallback (decision B).** When an
`Auth` section needs authority for a proposition, the step **attempts to find it via
CourtListener** (reusing the existing retrieval / `retrievedFromCourtListener` path). The
query is built from the **legal proposition only, scrubbed of matter facts/identity** (the
§8.6 confidentiality line — only public content leaves the device). The cite always comes
from a **real retrieved document, never the model's weights** — this is what eliminates the
fabrication risk. If the retrieval is **inadequate or inconclusive** (nothing on point, not
clearly good law, or a weak proposition-match), the step falls back to a `[cite]`
**placeholder** for the attorney. Erring toward the placeholder is the default — a
placeholder beats a mis-supported cite — and the "adequate vs. inconclusive" bar is a
conservative tunable. Anything inserted still runs the §8.2 validity check and carries a
verify state until human-confirmed.

**Decoding.** Grounded/`Auth` sections run **low-temperature / near-greedy** (faithful, no
embellishment — like the existing `DocumentQA` temp-0); voice kinds (demand letters) use
creative sampling (the `/draft` route). The section-by-section loop keeps each prompt's
context small; reasoning-heavy sections route to the legal-reasoning model, slot-fill to a
lighter path.

### 8.10 Content requirements — heading contracts + the elements library
Two artifacts make the "required content" in §8.2 (contract check) and §8.9 (structure
layer) concrete. Both are **data, never model knowledge.**

**Heading contract (structure, per kind).** The ordered required *sections* for a kind
(complaint: caption → jurisdiction/venue → parties → general allegations → count(s) →
prayer; motion: intro → statement of facts → memorandum → conclusion). This is the existing
`StructuredOutputContract` + `StructuredOutputSections.analyze` pattern extended per
`DraftKind`; section presence is a **deterministic** check (present/missing → auto-repair).
Per-kind structural data.

**Elements library (substance, per cause of action × jurisdiction).** The legal *elements*
a count/claim must allege (breach of contract: valid contract · breach · damages ·
performance/occurrence of conditions precedent), plus procedural prerequisites and required
statutory recitals. Design:
- **Curated, app-maintained jurisdiction-pack data** (sibling of the binding-rules pack,
  §14), **never derived from the model's training** — that would reintroduce the #2
  fabrication risk. (Decision A.)
- **Structured as abstracted legal rules + primary-authority cites** — a majority/minority
  **common-law + UCC baseline** (jurisdiction-neutral) with **per-jurisdiction distinction
  overlays** (the GA-vs-baseline split is exactly how a jurisdiction pack layers).
- **Content-channel ranking (§8.4):** binding authority (statutes/rules/controlling cases)
  **controls** (tier 1); secondary sources (treatises, **bar-prep outlines**) are a tier-2
  **seed** for the general baseline, not the authority a draft cites.
- **Checking posture (Decision B):** a count's element-completeness is an **LLM-assisted,
  attorney-confirmed advisory checklist** (flags likely-missing elements; never certifies
  legal sufficiency) — distinct from the deterministic section-presence check.

One library, two consumers: it tells **generation** (§8.9) what each count must address and
**verification** (§8.2) what to look for.

**Seed source on hand.** The firm's 2026 multistate bar-prep outlines (Contracts/Sales,
Torts, Remedies, Commercial Paper, Secured Transactions, Agency/Partnership/Corporations,
Real Property, Civil Procedure) are a strong **scaffold** for the general baseline — already
split by subject with **GA distinctions broken out separately** (→ the future GA overlay).
Two constraints: (1) bar prep states the *general/majority* rule, so it is a tier-2 seed,
not the controlling authority a filing cites — the jurisdiction's own statutes/cases remain
tier-1; (2) it is **copyrighted commercial material** — use it to *identify* elements during
construction, but the shipped library must state rules in **independent language with
primary-authority citations** (elements are uncopyrightable law; the publisher's
expression/compilation is not), never reproducing the outline text or arrangement in a
distributed product (§14).

### 8.11 Cross-references (litigation)
Litigation cross-references are **structural and resolved deterministically by the harness —
never literal text the model writes** (Adaptation A). Forcing constraint: paragraph numbers
are dynamic (consecutive per 1.110(f)), so a literal "¶¶ 1–14" breaks the moment numbering
shifts.
- **Paragraph anchoring + range resolution** — paragraphs carry stable anchors; a
  re-allegation/incorporation reference is **symbolic** ("incorporate the General
  Allegations"), resolved to live paragraph numbers at render. The model/skeleton emits the
  symbolic reference; the harness numbers and fills the range.
- **Cross-ref linter** (deterministic — the litigation twin of §7's exhibit cross-ref):
  every ¶ range / section ref / exhibit ref resolves and is in bounds; every exhibit
  referenced exists and is attached, and vice versa. Failures → the §8.1 follow-up queue.
- **Defined short-names** — parties via the §8.8 party model; other shorthand ("the
  Contract," "the Property") via the **same defined-terms registry** §7 specs (declared once,
  used consistently). One linter serves both doc families.

---

## 9. Proposed registry (actionable, for later)

Use a small compiled identifier plus data-driven definitions. The compiled enum keeps
stable IDs distinct from research outputs; the editable definition registry carries per-firm
configuration and the firewall policy:

```swift
public enum DraftKindID: String, Codable, CaseIterable, Sendable {
    case complaint, answer, counterclaim, motionToDismiss, motionSummaryJudgment /* … */
    // see §6 for the full set
}

public enum GroundingPolicy: String, Codable, Sendable {
    case noMatterFacts          // slot/template only; no factual generation surface
    case matterFactsRequired    // non-Auth but grounded, e.g. demand letters
    case authorityAndFacts      // Auth sections: facts + sourced authority
}

public struct DraftKindDefinition: Codable, Sendable {
    public var id: DraftKindID
    public var renderShell: RenderShell       // courtFL, courtMDFL, letterhead, …
    public var defaultSkeleton: AnalyticalSkeleton
    public var blockType: DraftBlockType      // routedSkill, contract, servicePipeline
    public var groundingPolicy: GroundingPolicy
    public var assertsLegalAuthority: Bool    // drives mandatory citation review
    public var requiresFactProvenance: Bool   // true for grounded non-Auth letters too
    public var slotSpecs: [SlotSpec]
    public var headingContract: HeadingContract
}
```

Supporting enums: `RenderShell` (§4), `AnalyticalSkeleton` (§5), `DraftBlockType` (§3).
Each `contract` kind also needs a prompt template with a `{{context}}` slot. Firms may
configure definitions and exemplars; they do not add arbitrary compiled enum cases.

---

## 10. Suggested build sequence (when implementation begins)

**Jurisdiction order:** Florida **state** first — and, for v1, only. **Georgia and
MDFL/federal are both deferred expansion jurisdictions** (order between them open —
federal-next vs. GA-next); each = a shell set + a rules pack + (optionally) exemplars.

1. **Vertical slice** (Florida) to prove the pipeline end-to-end across both render
   families and both complexity extremes — and standing up the **per-section
   verification** (§8.2) and **exemplar-upload + precedence** (§8.4–8.5) plumbing as
   part of the slice, not as an afterthought:
   - `noticeAppearance` — `courtFL` shell + slot intake + orchestration, near-zero
     hallucination risk (service pipeline).
   - `motionToDismiss` — `houseMotionFL` + CRAC + precedent-with-firewall (contract).
   - `letterDemand` — `letterhead` shell + routed drafting skill.
2. **Renderer hardening** in `SupraExports` (caption, cert of service, letterhead) —
   grounded in the now-confirmed FL format/closing-block authorities (§12).
   *(Deferred: Georgia bring-up — `courtGA` shell + GA rules pack + user exemplars — once
   Florida is solid; the precedent-optional design already accommodates it.)*
3. **Court filings** breadth: remaining motions, responses, pleadings, notices, orders.
4. **Discovery** family (perRequest service pipelines).
5. **Memos & briefs** (creac contracts + precedent).
6. **Trial & chronology** services.
7. **Transactional** (clause library + assembly architecture, §7).

---

## 11. Open decisions

- **`DraftKind` vs. extending `StructuredOutputType`** — recommend a separate enum
  (drafting ≠ research output) but reuse the `assertsLegalAuthority`/citation-review
  mechanism.
- **Renderer dependency / caption fidelity** — RESOLVED by the round-tripped goldens and
  the `SupraExports` implementation spec: render programmatic WordprocessingML/OPC, not
  `NSAttributedString → .docx`; the caption is a 2-cell borderless table with exact widths
  (`[4680, 4680]` in the firm-zero default), and hard constructs are golden-locked.
- **Clause-library / transactional** — RESOLVED (§7): assembly-first (model selects + slot-
  fills pre-vetted clauses; model-touched clauses flagged); clauses are **firm-derived config**
  (extracted §15-style) + optional app FL defaults, versioned; consistency enforced by
  deterministic linters (defined-terms, party-role, exhibit cross-ref). *Impl detail still
  open:* clause storage mechanism (DB table vs. bundled resources).
- **Jurisdiction coverage** — RESOLVED: **Florida STATE only for v1.** **MDFL/federal
  deferred** (out of v1 — separate jurisdiction pack: FRCP + per-district local rules +
  federal caption / CM-ECF; volatile local rules confirmed at draft time; hooks retained)
  and **Georgia deferred**; the order between the two is **open** (federal-next vs. GA-next).
  Each needs its own shells, rules pack, and exemplars.
- **Conflict-prompt severity threshold** (§8.4) — RESOLVED: the exemplar is the
  formatting basis; prompt only on **material** format differences (limit overflow,
  missing mandatory certificate/recital, prohibited section). Cosmetic differences are
  not prompted. Substantive/case-law conflicts always prompt. A user-configurable
  threshold can come later.
- **Binding-rules pack format** — how the FL/GA rules packs (format requirements,
  required recitals, deadlines) are encoded so §8.2 rule-conformance can check against
  them: structured data vs. prompt text. *Authoritative FL sources on hand* (derive the FL
  rules pack from these, versioned by effective date): **Florida Rules of Civil Procedure**
  (eff. 2026-04-01); **Florida Rules of General Practice & Judicial Administration** (eff.
  2026-01-01 — signature 2.515, service 2.516, document format 2.520, e-filing 2.525); and
  **Fla. Stat. chs. 55, 77, 117** (foreign judgments, garnishment, notaries). The civil
  rules were substantially amended in 2024–2025, so effective-date versioning is required.
- **Content / elements channel** — RESOLVED (§8.10): heading contracts = per-kind required
  sections (deterministic check, existing `StructuredOutputContract` pattern); the
  **elements library** = curated jurisdiction-pack data (majority/UCC baseline + per-
  jurisdiction overlays), app-maintained, abstracted rules + primary cites, **never
  model-derived**; element-completeness is advisory/attorney-confirmed (not certified).
  Seedable from the firm's multistate bar-prep outlines (tier-2 secondary source; primary
  authority controls) — ship independently-stated rules + primary cites, **not** the
  copyrighted outline text/arrangement (§14).
- **Slot model & interactive follow-ups** — RESOLVED (§8.1): typed per-kind slot schema;
  auto-resolve from matter/party-model/`AssistantProfile`/elements-library, ask the user
  only for irreducible inputs; **hybrid draft-first** (Decision Z) — placeholder-and-flag
  rather than refuse, hard-blocks only for the few things a draft can't render without; a
  single severity-tagged follow-up queue (blocking vs. advisory) consolidated at the
  pre-file gate (§8.3).
- **Precedent structure/voice extraction** — RESOLVED (§15.5): a parallel extraction to the
  format derivation producing per-kind **fact-free structure templates** (deterministic
  skeleton + recurrence-verified firm boilerplate + conservative model abstraction);
  **hybrid**, guarded by cross-exemplar recurrence + the §8.2 output fact-provenance check.
  Fixed the §8.5 conflation (structure/voice ≠ the `HouseStyleSheet`).
- **Auto-repair semantics** — RESOLVED (§8.2): repair keyed to failure type — **regenerate**
  (structural/format, bounded 2 passes → escalate), **deterministic fix** (mechanical), or
  **strip → placeholder + flag** (substantive: facts/authority/elements). Substantive
  failures are **never re-rolled to pass** (that launders a hallucination); they become
  `[fact?]`/`[cite]` placeholders + advisory flag.
- **Litigation cross-references** — RESOLVED (§8.11): structural/symbolic, resolved
  deterministically by the harness — **never literal text the model writes** (dynamic ¶
  numbering per 1.110(f) would break a literal range). Paragraph anchoring + range
  resolution; a deterministic cross-ref linter (¶/section/exhibit refs resolve & in bounds;
  exhibit referenced⇔attached) → §8.1 queue; defined short-names via §8.8 + §7's registry.
- **Spanish / bilingual** — RESOLVED: **DROPPED** (2026-06-25, no translation feature); §6K
  is a tombstone, removed from the build sequence (§10).
- **Acceptance & testing** — RESOLVED (§16): four-layer taxonomy — golden-file render
  fidelity · fixture unit tests for the deterministic gates · **adversarial leakage/safety
  regression** for the firewall (core) · LLM-judge quality rubrics (bridge to prompt
  engineering). Acceptance contract = a grounded, to-spec, properly-flagged **first draft**;
  **attorney review is the acceptance gate**, never "filing-ready."
- **Exemplar storage scope** — per-matter vs. firm-wide library, and how exemplars are
  versioned as the user curates each per-jurisdiction set.
- **Product posture** — RESOLVED: Supra targets **multiple firms/lawyers** (not a personal
  tool), built on the author's FL workflows. Engine is shared/compiled; `HouseStyleSheet`,
  kinds, exemplars, and identity are **per-firm configuration data**; jurisdiction packs are
  app-maintained shared data; the author's house style is the default seed, not a hardcoded
  universal. Local-first ⇒ configurable distributable app, not cloud multi-tenant. See §14.
- **Source roles** — RESOLVED: secondary-source / Lexis templates are a *content /
  elements* source only; the user's house style is the sole *format* authority
  (Adaptation D, §8.4).
- **Heading scheme & numbering** — RESOLVED: one outline hierarchy `I.A.1.a.i.` mapped to
  heading levels 1–5; pleadings use manually numbered allegation ¶s (Fla. R. Civ. P.
  **1.110(f)**), all other kinds unnumbered prose with point headings (§4 Typography).
- **No baked-in identity** — RESOLVED: all firm/personal identifiers are user-supplied
  slots filled at render time; corpus identities are stripped on ingest (§8.6).
- **House style sheet values** — lift the exact indentation ladder, fonts, line spacing,
  and margins from the firm's house style (not invented); encode as a single
  `HouseStyleSheet`. The **derivation pipeline (§15)** is the mechanism — parsed per firm
  from uploaded `.docx`, confirmed by the firm.
- **Closing-block authorities** (§12) —
  *Confirmed against the authoritative sources on hand (FL Rules of Civil Procedure eff.
  2026-04-01; Rules of Gen. Prac. & Jud. Admin. eff. 2026-01-01; Fla. Stat. chs. 55, 77,
  117):* interrogatory verification under oath **1.340(a)(7)**; numbered allegations
  **1.110(f)**; service delegated to 2.516 by **1.080(a)** (filing → 2.525); original
  process by affidavit **1.070(b)**; FL Rule 1.380 has **no** conferral certificate
  (federal L.R. 3.01(g) only); `/s/` e-signature **2.515(b)(1)(A)**; signature-block
  content + FL Bar number **2.515(c)**; portal e-service **2.516(b)(1)**; cert content +
  service address **2.516(f)**; first-pleading exclusion **2.516(a)(1)**; format floor
  (≥12-pt, 1″ margins, numbered pages) **2.520(a)**; notary jurat **§117.05(3)(a)/(4)/(13)**;
  garnishment notice *first-class* **§77.041(2)**; foreign-judgment notice *registered
  RRR by clerk* **§55.505(2)**; federal unsworn-declaration default = within-US form
  **28 U.S.C. §1746(2)** (omit "under the laws of the United States"; (1) only for
  out-of-US); contractor final-payment affidavit prescribed form **§713.06(3)(d)**.
  *Deferred by design (not blockers):* **federal per-district specifics** — admission /
  Bar-number handling, word-count / Notice-of-Motion conventions — are **not** baked into
  the FL pack (federal local rules change regularly; confirm at draft time). **Georgia**
  is out of current scope (Florida-first); GA shells / rules / forms come later. With FL
  sources in hand, the **Florida** closing blocks are fully grounded.

---

## 12. Closing-block component library (signature / cert of service / notary jurat)

> Distilled from a multi-agent reconciliation of the corpus, adversarially verified.
> **Every pin-cite the verifiers could not confirm is marked ⚠️ VERIFY** — Layer 1 must
> never emit a ⚠️ item as settled text. Identity is slot-only (§8.6); no firm, attorney,
> client, or opposing-counsel names appear here.
> **Scope:** v1 is **FL state only**; the **federal (CM/ECF, §1746, federal Bar-number)
> variants below are deferred scaffolding** — retained as architectural hooks, not a built
> v1 path (§8.7).

Root cause (restated): closing blocks drift because Lexis content-skeletons (no named
styles, non-operative `"[form of service]"` language) are interleaved with the user's
filed house style. Converge **formatting** on the house style; **never** carry a Lexis
legal substitution; preserve every **jurisdiction × method × instrument** branch (that
variation is legally required).

### 12.1 Signature block
Canonical: stacked paragraphs (not a table), right-half block, left-aligned text.
```
Respectfully submitted: [Month DD, YYYY]  ← SEPARATE left-aligned line, 0.5″ indent, ABOVE
                                            the block (motions/briefs/memos only); colon +
                                            filing date, month spelled out in full
[FIRM NAME]                    ← right-half block begins here; or attorney-name-lead (both valid)
By: /s/ [signing attorney]     ← lowercase /s/
[ATTORNEY NAME]
[bar-number label] [number]    ← label is jurisdiction-specific (variants below)
[office street / suite / city / state / zip]   ← office-keyed slot, never hardcoded
Telephone / [Facsimile]
[Primary (and Secondary) E-Mail:]   ← bold label
[primary email] / [secondary emails 0–2, optional]
Attorneys for [party]          ← italicized LAST line in firm-zero goldens; singular/plural matches # signers; party = client
```
Fields: `respectfullySubmitted` (bool), `firmName`, `signingAttorney`, `attorneys[]`
(name, barLabel, barNumber, jurisdiction, optional `proHacVice`), `firmOffice`,
`partyRepresented`, `emails[]` (primary required; secondary optional), `serviceForum`,
`ofCounsel[]`, `signatureParties[]` (repeatable — multi-party).

PRESERVE: **FL e-signature** `/s/` — Fla. R. Gen. Prac. & Jud. Admin. **2.515(b)(1)(A)**
✓ ("the electronic signature indicator may be an '/s/' in front of the signer's printed
name"). **Signature-block content** — **2.515(c)** ✓: name, /s/ indicator, mailing
address, telephone, service e-mail, and (for attorneys) **Florida Bar number** + party
represented. Service e-mail required; **up to 2 additional addresses permitted, not
required** — 2.516(b)(2)(A) ✓ (**secondary never forced**). When the 2.516 designation
is stated inline in the body, list the addresses after the colon separated by
**semicolons** (no em-dashes, no "primary —/secondary —" labels). **Federal CM/ECF** `/s/` —
Fed. R. Civ. P. **11(a)**; **do not auto-suppress the FL Bar number for federal** —
per-district admission/Bar-number specifics are **deferred** (federal local rules change
regularly; confirm at draft time, not baked into the FL pack). **OF COUNSEL / "(admitted
pro hac vice)"** roster. **Manuscript signature line** → route to §12.3. **Georgia**
(State Bar of GA number; firm-after-attorney) — **deferred** (out of current FL-first scope).
FLATTEN: placement → one right-half indent; `/S/`→`/s/`; bar-label punctuation; date
long-form → `Dated: [date]`; table block → paragraphs; named-style vs direct formatting.
House style: the block is **single-spaced**, with a single blank line between its groups
(firm/attorney/bar/address · e-mail designation · representation line). In the firm-zero
Word goldens, the **representation line — "Attorneys for [party]" / "Counsel for [party]" —
is italicized and appears last, after the e-mail designation**; it is also italicized in the
certificate-of-service service list (§12.2). The **`/s/ [name]` e-signature is italicized and
underlined using underlined tab runs**; the renderer pins a tab stop for determinism rather
than emitting a bordered table/cell.

### 12.2 Certificate of service
```
CERTIFICATE OF SERVICE          ← centered, bold, underlined, all caps (firm-zero court shell)
I HEREBY CERTIFY that on [date], I [SERVICE-METHOD CLAUSE] the foregoing [title]
to the following:               ← 0.5″ first-line indent, SINGLE-spaced, left-aligned
[recipient/service list]        ← SINGLE-spaced; borderless table (state default) OR plain indented ¶s
/s/ [attorney]
[attorney name]                 ← plain: sentence case, NOT bold
```
**SERVICE-METHOD CLAUSE — pick one (rule-driven, never interchange):**
- FL e-Portal (filed): "electronically filed … using the Florida Courts E-Filing Portal,
  which will send a Notice of Electronic Filing".
- FL served-not-filed (discovery): "served … by e-mail" — **never the e-Portal/NEF clause**
  (nothing is filed; the NEF representation would be false; post-2025 amendment).
- Federal CM/ECF — two coordinate house phrasings, preserve both ("using the CM/ECF
  system, which will send electronic notice" / "with this Court's CM/ECF docketing system").
- Mail — statute-specific (do NOT default to "certified mail"): **garnishment** debtor
  notice = **first-class** mail by the plaintiff + a certificate of that service —
  **§77.041(2)** ✓; **foreign-judgment** recording notice = **registered mail, return
  receipt requested**, mailed by the **clerk** (creditor's notice is optional/supplemental)
  — **§55.505(2)** ✓. Mixed — per-recipient method tag.
- Email-service envelope (when served by email): subject begins "SERVICE OF COURT
  DOCUMENT" + case number; body carries style, document title, and server name + phone —
  2.516(b)(2)(C) ✓.

PRESERVE: FL service is delegated by **Rule 1.080(a)** to Rule 2.516 (filing → 2.525) ✓;
e-Portal clause grounds on **2.516(b)(1)** (portal e-service; complete on filing) ✓.
Cert-of-service required content — **2.516(f)** ✓: certification, date, name(s) served,
**service address(es)**, and method (the rule's safe-harbor form is a plain "I certify
that on (date) this document has been furnished to … by …"; signature governed by
**2.515**). Federal — Fed. R. Civ. P. 5(b)(2)(E). **Original process / first pleading
EXCLUDED** — 2.516(a)(1) ✓; served under Ch. 48 with proof of service by affidavit
(**Rule 1.070(b)** ✓), not a 2.516 cert. GA — **deferred** (out of current FL-first scope).
FLATTEN: heading → centered bold underlined all-caps; opener → "I HEREBY CERTIFY that on [date], I
…"; "true and correct copy" → one house form. House spacing: COS paragraph **0.5″
first-line indent + single-spaced**; recipient/service list **single-spaced**; the
sign-off name under `/s/` is **plain (sentence case, unbolded)** — distinct from the
main signature block's bold all-caps name.
Sibling: **Certificate of Conferral / Good-Faith Conference** often follows on
compel/continue/protective-order motions — model as a sibling. **Federal only**: M.D.
Fla. **L.R. 3.01(g)** good-faith-conferral certificate. **Fla. R. Civ. P. 1.380 contains
no rule-based conferral certificate** (confirmed against the 2026-04-01 rules) — any FL
state conferral expectation is by circuit administrative order, not the statewide rule;
do not auto-attach one to FL-state discovery motions.

### 12.3 Notary jurat / verification — branch on instrument type + notarizing state
Four legally-distinct instruments; never flatten together:
- **A — FL notarized affidavit jurat** (full §117.05, all confirmed against ch. 117):
  STATE/COUNTY venue (two stacked ¶s; drop the `)ss.` brace) — **§117.05(4)(a)** + "Sworn
  to (or affirmed) and subscribed before me by means of ☐ physical presence or ☐ online
  notarization [statute: 'audio-video communication technology' under part II], this __
  day of [month], [year], by [affiant][, on behalf of [entity]], who is personally known
  … or produced ___ as identification." + notary name / commission number / expiration /
  seal. Confirmed cites: short-form jurat **§117.05(13)** ✓; act type ("sworn" vs
  "acknowledged" — **jurat ≠ acknowledgment**) **§117.05(4)(b)** ✓; physical-presence /
  audio-video method **§117.05(4)(c)** ✓; ID recital **§117.05(4)(f)** (+ satisfactory
  evidence **(5)**) ✓; seal + commission number + expiration **§117.05(3)(a)** ✓.
- **B — Federal §1746 declaration** (unsworn, no notary): "I declare under penalty of
  perjury that the foregoing is true and correct." Default the **§1746(2) within-US**
  form — **omit** "under the laws of the United States of America" (that is §1746(1), for
  out-of-US execution only). ✓ confirmed against 28 U.S.C. §1746.
- **C — FL §92.525 unsworn declaration** (no notary): "Under penalties of perjury, I
  declare that I have read the foregoing … and that the facts stated in it are true."
- **D — FL interrogatory verification** (three real sub-forms, preserve all): D1/D2
  notarized under oath — Fla. R. Civ. P. **1.340(a)(7)** ✓ (answers "separately and
  fully in writing under oath unless … objected to," objected items "signed by the
  attorney"; confirmed against the 2026-04-01 rules); D3 unsworn §92.525 for
  objections-only responses.

Guardrails: **jurat vs. acknowledgment** — affidavits take a jurat ("sworn to and
subscribed"); reserve "acknowledged before me" for executed instruments (a misused
acknowledgment on a lien affidavit appears in the corpus — flag as a defect).
**Out-of-state notarization** — the notarizing state's form governs; never emit FL
§117.05 wording on a non-FL venue (venue is a free fill-in; never assume Florida).
**Georgia** — O.C.G.A. ch. 45-17; **GA has NO permanent RON statute → never emit the FL
physical-presence/online checkbox on a GA jurat** (a "§45-17-9 RON" cite surfaced in
analysis and was fabricated — removed). **Never auto-fill** notary name, commission
number, expiration, or ID type. §713.06 contractor final-payment affidavit is a distinct
instrument — **§713.06(3)(d)** ✓ prescribes the form ("must be in substantially the
following form": "Before me, the undersigned authority, personally appeared … after
being first duly sworn, deposes and says of his or her personal knowledge"), lists each
unpaid lienor + amount, is sworn (so takes the Template-A jurat), and adds the "Signed,
sealed, and delivered" execution + business signature block.

### 12.4 Shared render primitives + hard guardrails
Primitives (one parameterized implementation each): `rightHalfBlock` (signature + notary
blocks), `centeredBoldHeading` (cert / verification / declaration), `borderlessRecipientTable`
(+ plain-paragraph mode for federal), `jurisdictionVenueCaption`, `eSignatureLine`.

Renderer-enforced guardrails:
- No certificate of service on pre-suit correspondence, demand/hold letters, alerts,
  transactional agreements, or internal memos (never auto-append).
- No e-Portal/NEF clause on served-not-filed discovery.
- No FL §117.05 wording on out-of-state or GA notarizations.
- Jurat (not acknowledgment) on affidavits.
- Primary email required; secondary never forced; FL Bar number never auto-suppressed for federal.
- Route by `instrumentType` / `serviceForum` enums, **not** by template file.

---

## 13. courtFL house style across all Florida state-court filings

> Workflow-derived and adversarially verified across 14 FL state-court filing families.
> FL pin-cites confirmed against the Rules of Civil Procedure (2026-04-01) carry ✓;
> unconfirmed items are flagged **VERIFY**. Identity is slot-only (§8.6).

### 13.1 The shell is constant; only the body + closing blocks vary
Every FL state filing renders through **one shared `courtFL` shell + the `HouseStyleSheet`**
— the 2.520(a) page floor, centered bold court header, 2-cell caption (§4), centered/bold/
underlined title, double-spaced body with 0.5″ indent and single 12-pt blank breaks, and
the right-half single-spaced signature block. These apply **uniformly** and are never
re-derived per document. What changes by kind is only (a) the **body skeleton** (slot-fill
prose / numbered allegations / `I.A.1.a.i.` point headings / numbered requests / sectioned
outline / table) and (b) the **set of closing blocks** ("Respectfully submitted," or not;
attorney vs. judge vs. multi-party vs. affiant signature; 2.516 cert or not; notary /
declaration / verification or not; WHEREFORE / decretal / issuance line).

### 13.2 Per-kind structural matrix
| Kind | Body numbering | "Resp. sub."? | Signature | Cert. of service? | Notary/verif. | Kind-specific closing |
|---|---|---|---|---|---|---|
| Notice of Appearance (baseline) | prose, unnumbered | No | attorney | Yes (e-Portal) | none | none |
| Complaint / Petition | numbered allegations (1.110(f)) | No | attorney | **No** — initial pleading excluded (2.516(a)(1)); served w/ summons (Ch. 48), return of service (1.070(b)) | conditional (only a verified pleading) | PRAYER/WHEREFORE; opt. jury demand (1.430(b)); **Civil Cover Sheet** + summons accompany |
| Answer & Affirmative Defenses | numbered allegations | No | attorney | Yes | none | costs (+ authorized fees) only — no affirmative relief; specific admit/deny (1.110(c)), un-denied = admitted (1.110(e)) |
| Counterclaim / Crossclaim / 3d-Party | numbered allegations | No | attorney | Yes to existing parties; **new party served as original process** (1.070(b)) | conditional on cause of action | per-count WHEREFORE; opt. jury demand |
| Reply to Affirmative Defenses | numbered allegations | No | attorney | Yes | none | pleads **avoidance** (1.100(a)), not denial; no prayer; file only if required/permitted |
| Motion (+ incorporated memo) | point headings `I.A.1.a.i.` | **Yes** | attorney (repeatable) | Yes | none | WHEREFORE/relief; MSJ serves separate statement of material facts (1.510(c)(5)) |
| Response / Opposition | point headings (CRAC mirroring movant) | **Yes** | attorney | Yes | none | conclusion requesting **denial**; **MSJ opposition serves a responsive statement of material facts** (1.510(c)) |
| Notice (hearing/serving/settlement/dismissal) | prose, unnumbered | No | attorney | Yes (filed notices) | none | "PLEASE TAKE NOTICE"; voluntary-dismissal notice is operative (1.420(a)(1)(A) ✓); serving-discovery cover-notice is filed (e-Portal) while the discovery it transmits is served-not-filed (by-email) |
| Proposed Order | prose (numbered decretal ¶s) | No | **judge** (signature line, NO /s/) | **No** — "Copies furnished to:" list, not a cert | none | recital → "ORDERED AND ADJUDGED" (final) / "ORDERED" (non-final) → DONE AND ORDERED → judge signature → copies list; counsel's cert lives on the transmitting cover doc |
| Discovery request (rogs/RFP/RFA) | numbered requests | No | attorney | Yes — **served-not-filed "by e-mail"; NEVER e-Portal/NEF** | none (verification is the answering party's) | DEFINITIONS/INSTRUCTIONS/numbered items; separate Notice of Service is e-filed |
| Discovery response & objections | numbered (per-request objection map) | No | attorney (+ party on rog verif.) | Yes — **served-not-filed "by e-mail"** | **interrogatory ANSWERS = party verification (1.340(a)(7)); RFP/RFA = none** | general objections → per-request objection + "subject to and without waiving" + answer |
| Affidavit / Declaration / Verification | numbered averments (or single clause) | No | **affiant manuscript + notary** (no attorney /s/ on body) | **conditional** — standalone only; never as an exhibit / on process | **branch** (§117.05 jurat / §92.525 / §1746(2) / 1.340 verif.; §713.06 form) | STATE/COUNTY venue (sworn only) → averments → affiant signature → jurat/declaration clause |
| Stipulation | recital + numbered terms | No | **multi-party** (one block per party) | Yes | none | numbered terms; **dismissal = 1.420(a)(1)(B) ✓**, signed by all current parties, self-executing; extend-time/PO variants pair with a separate proposed order |
| Subpoena (duces tecum / depo / trial) | command + numbered schedule | No | attorney (issuing officer, 1.410) | Yes to parties; **witness served by process server (1.410(d))**; 1.351 nonparty docs may also go by mail/delivery w/ filed confirmation | none | command line → command ¶ → schedule → issuance; 1.351 needs prior party notice (10/15/45-day ✓) + attached proposed subpoena + right-to-object recital |
| Trial filing (witness/exhibit list, pretrial stmt) | table (lists) **or** labeled sectioned outline (non-argumentative) | No | attorney; **multi-party** for a joint pretrial statement | Yes | none | no prayer; **labeled sections, NOT CRAC point headings**; content governed by the judge's case-management/pretrial order (1.200/1.201) |

### 13.3 Notable deltas from the baseline notice (verifier-corrected)
- **Complaint** — numbered allegations; **no 2.516 cert** (renderer guardrail); a **Civil
  Cover Sheet is a mandatory statewide companion** (form number / current rule cite —
  **VERIFY**, "Rule 1.997" not present in the 2026 rules), plus the summons; state
  jurisdiction/venue **once**; for unliquidated damages plead only the general
  jurisdictional-amount allegation; verification off unless a verified pleading.
- **Motion** — `I.A.1.a.i.` point headings (hanging-indented) + a **left-aligned, 0.5″-
  indented "Respectfully submitted: [Month DD, YYYY]"** line (colon + filing date, month
  spelled out in full, above the signature block); party-role and relief are **both slots**; **no statewide rule-based conferral
  certificate** (don't pin to 1.380; attach only if a circuit AO/judge requires); MSJ
  statement of material facts is a separate served artifact (1.510(c)(5)). The **Statement
  of Facts is rendered as numbered fact paragraphs** (one independent fact each), and the
  **Conclusion is the final point heading** (next capital Roman numeral, e.g. `III.`).
- **Proposed Order** — signatory flips to the **judge** (signature line, no `/s/`, no firm
  block); **no cert** (a "Copies furnished to:" list); decretal mirrors only the motion's
  relief — no new facts/authority (fact firewall).
- **Affidavit** — **affiant** manuscript signature + notary, not an attorney `/s/`; cert
  **conditional** (standalone only, never as an exhibit); closing branches by instrument
  (§117.05 jurat / §92.525 / §1746(2) / 1.340 verif. / §713.06 form); STATE/COUNTY venue
  is a free fill-in — never assume Florida.
- **Discovery** — served-not-filed **"by e-mail"** clause, **never e-Portal/NEF**; the
  e-mail envelope carries the 2.516(b)(2)(C) subject/body; interrogatory **answers** get
  the answering party's verification (1.340(a)(7)).
- **Subpoena** — **no** generic witness-rights/records-custodian boilerplate is
  rule-mandated on an ordinary 1.410 subpoena, and **no** FL fee-tender-at-service
  requirement (that's federal FRCP 45); the right-to-object recital + prior party notice
  apply to the **1.351** nonparty-document subpoena.

### 13.4 ATTORNEY MUST VERIFY (consolidated)
- **Cross-cutting** — never auto-append a 2.516 cert to an initial pleading/original
  process (1.070(b)); never use the e-Portal/NEF clause on a served-not-filed paper;
  re-confirm any pin-cite against the currently effective rules (the FL civil rules were
  substantially amended; renumbered 1.280 subdivisions especially).
- **Pleadings** — which counts require verification or a statutory form (ch. 713 lien,
  injunction, dissolution); jury-demand placement/timing (1.430(b)); current Civil Cover
  Sheet form/cite; venue + jurisdictional-amount allegation; responsive-pleading deadline
  (1.140(a) default 20 days, *unless a statute prescribes otherwise* — e.g. §768.28);
  affirmative-defense numbering continues the consecutive sequence (1.110(f)); compulsory
  vs. permissive counterclaim (1.170); new-party joinder by amended pleading (1.250(c)).
- **Motion/Response** — page/word limits (division/judge AO, not statewide); MSJ 1.510
  timing + responsive statement of material facts as its own document; fee-entitlement
  basis pleaded in the body (§57.105 safe harbor).
- **Discovery** — response-deadline recital (30 days; 45 if served with process) as a
  rules-driven slot; interrogatory cap/standard forms (unconfirmed — don't assert);
  RFP ESI form-of-production (1.350(b)).
- **Stipulation/Notice** — dismissal posture: **notice 1.420(a)(1)(A)** (before MSJ
  hearing / retirement of jury / submission) vs. **stipulation 1.420(a)(1)(B)** ✓ vs.
  order; protective-order good-cause subdivision against the renumbered 1.280.
- **Affidavit** — §117.05 jurat pin-cites; §1746 form selection; §713.06(3)(d) statutory
  form + its pre-suit condition-precedent service.
- **Subpoena** — 1.351 timing (10/15/45-day ✓) and service mode (process server 1.410(d)
  or mail/delivery w/ filed confirmation 1.351(c)); deposition predicate (notice of
  deposition must precede); blank subpoenas are trial-only (1.410(b)(2)).
- **Trial filings** — no single statewide form; content/format/joint-vs-separate set by
  the assigned judge's case-management/pretrial order (1.200/1.201).

---

## 14. Configurability & multi-firm posture

> Product decision: Supra is built on the author's own FL litigation workflows but is
> intended as a **product usable by other firms and lawyers**, not a personal tool. That
> makes the **engine-vs-configuration split** load-bearing, not cosmetic.

### 14.1 Engine (shared, compiled) vs. configuration (per-firm data)
- **Engine** — pipeline, firewall, verification gates, party-alignment logic (§8.8),
  render primitives, orchestration, and the **prompt templates** (§8.9, app-authored /
  versioned). Compiled or app-shipped; shared by every install; users never edit it.
- **Configuration** — the `HouseStyleSheet` (§4), the `DraftKind` catalog + skeletons /
  heading contracts, exemplars, and `AssistantProfile` identity. **Data, owned per firm**,
  never compiled in.
- **Jurisdiction packs** — the binding-rules pack (FL now) is **app-maintained, shared**
  data, versioned by effective date and shippable as an update (a GA pack can land later
  without anyone recompiling). The law doesn't vary by firm.

### 14.2 Local-first multi-firm ≠ cloud multi-tenant
The app is on-device (MLX, no cloud — a hard constraint). "Usable by other firms" therefore
means a **configurable, distributable application**: each firm installs it and configures it
locally with its own house style, exemplars, and identity — *not* a shared SaaS database
with server-side tenants. "Per-firm configuration" = per-install config + a portable
onboarding/import model, plus shared jurisdiction packs delivered as data updates. Firm
isolation is inherent (separate installs); it must be respected if any sync/backup is added.

### 14.3 The author's house style is a default/seed, not the universal
Everything tuned in this spec (the FL `courtFL` house style and closing blocks, §12–13) is
**"firm zero's" configuration** — shipped as the **default template** a new firm starts from
and overrides, *not* a hardcoded universal. This is why **no-baked-identity** (§8.6) is now a
*requirement*, not a nicety: one firm's names or house style must never surface in another's
output. Identity and house style are per-firm data, seeded at onboarding.

### 14.4 Onboarding = the productized version of this session
A new firm onboards the way firm zero was built by hand here: upload representative filed
work product → derive that firm's `HouseStyleSheet` (caption geometry, typography,
signature/cert layout) and seed its exemplar library (§8.4–8.5). The app ships sensible FL
defaults so a firm is productive immediately, then converges on the firm's own house style as
exemplars accumulate. A settings surface exposes the derived style sheet, exemplar library,
kind catalog, and identity for review and override.

### 14.5 What this elevates from optional to required
- `HouseStyleSheet`, `DraftKind` catalog, exemplars, and identity are **first-class editable
  data** (bundled resources / DB), never compiled constants.
- An **onboarding/import flow** that derives a firm's house style from its uploaded work.
- A **settings/config surface** (view + tweak the style sheet, manage exemplars, set
  identity, enable/add kinds).
- **Jurisdiction packs as distributable, effective-date-versioned data.**

---

## 15. House-style derivation (onboarding extraction pipeline)

> This **productizes the manual reverse-engineering done in this session** (firm zero):
> turn a firm's uploaded filed work into a *proposed* `HouseStyleSheet` + seeded exemplars
> for the firm to confirm. **Deterministic-first** — the geometry is *parsed* from the
> firm's own OOXML, not guessed by the model.

### 15.1 Stages
0. **Intake & classify.** Firm uploads representative **filed `.docx`** work product;
   classify each by `DraftKind`. Capture the firm's identity early (Stage 6) so it can
   drive provenance filtering. **Exclude** non-house sources: imported templates (bracketed
   placeholders, no named styles) and documents signed by *another* firm (signature-block
   firm ≠ this firm) — the misattribution guard.
1. **Segment.** Parse each `document.xml` into an ordered paragraph/table stream with
   metadata (alignment, bold/italic, indent in twips, named style, table membership, run
   props). Locate recurring regions by anchor — caption table near the top; title; body;
   signature block (via "/s/" + Bar no. + "Attorneys for"); certificate of service (via
   "HEREBY CERTIFY"); jurat. Deterministic.
2. **Measure.** Extract the firm's actual values per component: page setup from `sectPr`
   (margins, page size) and `styles.xml`/`docDefaults` (font, default spacing); caption
   table column widths (`tcW`/`gridCol`, dxa) + layout (`)` ladder or not, case-block
   position); body line-spacing + first-line indent + paragraph spacing; the heading
   outline + per-level indent ladder + hanging geometry + numbered-allegation format;
   signature-block placement/spacing/field order + `/s/` style + representation-line
   italic + e-mail designation + "Respectfully submitted:" format; certificate-of-service
   heading + **the firm's actual service-method clause wording** + recipient layout +
   sign-off. Each measurement records value + source doc + agreement count.
3. **Cluster & resolve.** Across the corpus, cluster each field and take the **modal /
   canonical** value, dropping outliers and excluded-source values (the "recompute modal
   values after dropping false positives" step we did by hand). Compute per-field
   **confidence** (agreement × sample size). A thin or conflicting field → low confidence →
   fall back to the shipped FL default.
4. **Assemble.** Produce the proposed `HouseStyleSheet` (all derivable fields) + the
   per-kind **exemplar set** (structure/voice mirrored; **facts and identity quarantined**,
   §8.6).
5. **Confirm (required gate).** Present the proposed style sheet field-by-field in the
   settings surface — each with its **confidence and a source example** — for the firm to
   accept or override; low-confidence and default-fallback fields highlighted. Nothing is
   adopted silently (the "needs review" pattern). This *is* the firm's first-run version of
   the iteration we did manually here.
6. **Identity capture.** Firm name, attorneys, Bar numbers, e-mails, address are pulled
   from the signature blocks into `AssistantProfile` as **slots** — the firm's identity
   config, never written into the style sheet (firewall, §8.6 / §14.3).

### 15.2 Deterministic vs. model roles
Measurements (margins, indents, widths, spacing, font) are **parsed from OOXML** — exact,
not generated. The model assists only where judgment helps (classifying `DraftKind`,
isolating the service-method clause wording, house-vs-imported calls), and those outputs
are verified before use. Geometry is never model-guessed.

### 15.3 Inputs & fidelity
Prefer the firm's editable **`.docx`** filings — OOXML carries exact styles, indents, and
table widths. **PDF is lossy** for this (rendered positions, no style tree); accept it only
as a fallback and flag lower confidence. More documents → higher confidence and cleaner
modal values.

### 15.4 Honest scope
This is an **assist that proposes**, not magic that decides. Output quality tracks corpus
size and cleanliness; the provenance/misattribution guard (Stage 0) is the hardest part and
the biggest correctness risk (we hit it manually when opposing/co-counsel documents looked
like house style). The firm's confirmation (Stage 5) is mandatory; where derivation can't
reach confidence, the shipped FL default stands in, clearly flagged.

### 15.5 Structure & voice templates (content analog of the HouseStyleSheet)
A **second, parallel extraction from the same exemplars**, distinct from the format
derivation (§15.1–15.4): per (`DraftKind` × firm pattern) it produces a **fact-free
structure template** — the skeleton plus the firm's reusable boilerplate — that feeds §8.9
layer 5 (precedent). It must carry the section structure, argument rhythm, and
fact-independent phrasing, but **never the exemplar's facts, parties, holdings, or specific
application**. Hybrid extraction (decision), with two firewall layers:
- **Deterministic skeleton** — heading sequence, section order, and CRAC/argument rhythm,
  pulled from the exemplar's structure.
- **Recurrence-verified boilerplate** — text recurring across several of the firm's
  exemplars of a kind is fact-independent *by definition* (standard-of-review recitations,
  transitions, WHEREFORE phrasing); captured as the firm's voice. Needs ≥2–3 exemplars of
  the kind; with only one, take the skeleton plus a heavily-flagged model abstraction.
- **Conservative model abstraction** — for the remainder, the model replaces case-specifics
  with slots; treated as untrusted for facts.
- **Output backstop** — at generation, facts come only from the current matter (§8.9 layer
  3) and the **§8.2 fact-provenance check fires on the output**, so any residual specific
  that survived into a template is caught (it won't trace to *this* matter). Recurrence +
  output-provenance are the two guards that make capturing the firm's prose safe.

Voice for `Auth` kinds is limited to this boilerplate — no free voice-mining
(`style-exemplars-voice-only`); the `AssistantProfile` voice channel stays for
letters/outlines only (§8.6). Structure templates are **per-kind firm config** that
accumulates as exemplars are uploaded (precedent-optional: thin → skeleton + binding rules;
rich → full firm voice).

---

## 16. Acceptance & testing

The system has four kinds of output, each validated differently — one approach doesn't fit.

### 16.1 Test taxonomy
- **Golden-file / snapshot — render fidelity.** Fixed input (kind + slots + `HouseStyleSheet`)
  → known-correct OOXML, compared **structurally**: caption-table column widths, named styles,
  indents, spacing, the 2″ signature line, hanging-indent geometry — everything in §4/§12.
  The render is deterministic, so golden files are exactly right here.
- **Fixture unit tests — the deterministic gates.** Rule-conformance (§8.2), the cross-ref
  linter (§8.11), defined-terms (§7), the pre-file gate (§8.3): a violating fixture must flag;
  a compliant one must pass.
- **Adversarial leakage / safety regression — the firewall (most important).** Plant a
  distinctive fake fact + identity in an exemplar, generate a draft for a *different* matter,
  and assert **none of it leaks** (and that the §8.2 fact-provenance check catches any that
  did). Bait the model into inventing a citation → assert it emits `[cite]`, not a fabricated
  cite. These guard the load-bearing safety property (§2 / §8.6 / §8.9) and are feasible
  precisely because planted leakage is detectable. **Non-negotiable / core.**
- **Eval rubrics (LLM-judge) — generation quality.** On a held-out set: did the draft hit the
  required elements (§8.10), stay grounded, use the right structure, avoid placeholders where
  it shouldn't — regression-tracked. Advisory tuning signal; this is where the **automated
  prompt-engineering** work plugs in.

### 16.2 Acceptance contract
A draft is *acceptable to emit* when: render is to-spec (golden); every deterministic gate
passes or surfaces its failure as a flag; the firewall holds (placeholders, never
leaks/inventions); and all unresolved items sit in the pre-file follow-up queue (§8.1 / §8.3).
It is **not** "legally sufficient / filing-ready" — **attorney review is the acceptance gate**
for substance (Decision A). The tool's contract is *a grounded, to-spec, properly-flagged
first draft*, consistent with the advisory posture throughout.

### 16.3 Build order
Golden + fixture + **adversarial-leakage** tests are **foundational** — they land with the
§10 vertical slice. The quality-eval harness lands with the prompt-engineering work (§17).

---

## 17. Prompt engineering (offline, deterministic-driven)

Automated prompt optimization for the local model, constrained by **offline + prompts-are-
engine (§8.9) + the firewall**. Two layers, both offline, neither using a cloud or a strong
judge.

### 17.1 Where it runs
- **Instruction/scaffold optimization → dev-time (vendor).** The prompt templates are engine
  (§8.9), so they are optimized **once, offline, before shipping**, and distributed as
  versioned templates. Firms never tune prompts.
- **Demonstration selection → per-firm, on-device.** The one per-firm lever: choosing which of
  the firm's own exemplars (§15.5 structure templates) ride along as few-shot demonstrations
  per kind. Offline (firm data stays local); does not touch the engine prompts.

### 17.2 Fitness function — deterministic, not an LLM judge
Offline, the only available judge is the same local model that drafts — too weak to grade
reliably. So optimization scores the **deterministic signals already built**, never
"quality":
- §8.2 / §8.3 gate pass-rates (contract / structure / rule conformance);
- the §16 **adversarial-leakage tests** (no fact/identity leak; no invented citation);
- §8.10 element coverage; "no improper placeholder."

These are fast, judge-free, and measure exactly what the local model is weakest at and what
matters most. **Subjective quality stays attorney review (§16.2)** — never the optimizer's call.

### 17.3 Technique — bootstrapped few-shot
Run the pipeline over an eval set; keep the (input → output) examples that **pass the
deterministic gates** as the few-shot demonstrations baked into the template (the DSPy
`BootstrapFewShot` pattern — no judge needed). Secondary lever: a **bounded instruction-variant
search** — a handful of instruction variants, each scored by gate pass-rate, keep the best.
The local model is not asked to invent prompts wholesale.

### 17.4 Constraints
- **Versioned per (model × kind)** — prompts optimized for one MLX model can degrade on
  another; re-run on a model swap.
- **Eval data stays put** — dev-time optimization on vendor (firm-zero / synthetic) data;
  per-firm demonstration selection on the firm's device. No matter content moves.

### 17.5 Out of scope (offline)
Cloud optimizers / GPT-judge loops; any pure-LLM-judge optimization; per-firm **runtime**
prompt mutation (conflicts with prompts-as-engine; adds latency + non-determinism).
**Fine-tuning / LoRA** is a separate lever (model training, not prompt engineering) — its own
decision, not part of this.
