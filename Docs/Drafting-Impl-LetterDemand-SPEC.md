# Implementation Spec — `letterDemand` vertical slice

> **Companion to** the design spec and the `NoticeAppearance` / `MotionToDismiss` impl specs
> (shared types: `DraftKind`, `Slot*`, `HouseStyleSheet`, `Generator`, `Renderer`,
> `DraftPipeline`, the firewall types; supporting types & reconciled protocols in
> `Drafting-Impl-CoreTypes-SPEC.md`). This doc is the **deltas** for `letterDemand` — the
> third slice kind and the **first non-court render shell**. Sample data is fictional.

`letterDemand`: `renderShell = .letterhead`, `skeleton = .none`, `blockType = .routedSkill`,
**`assertsLegalAuthority = false`**. It is the lightest engine path (one voice-driven
generation, no section loop, no caption/certificate) but adds the **letterhead shell** and
the **voice channel** the two court kinds never used.

---

## 0. What this slice adds / differs
1. **Letterhead render shell** — a business letter, not a court filing: firm letterhead block →
   date → recipient address → `RE:` line → salutation → body (single-spaced, block) → closing →
   signature → enclosures/cc. **No caption table, no court title, no 2.516 certificate of service.**
2. **Routed-skill generation** — the model writes the **whole letter at once** (not section-by-
   section), voice-driven. The **`AssistantProfile` voice channel is allowed here for *tone/register
   only*** (`VoiceContext.toneOnly = true`): a letter may mine the firm's writing *style*, never its
   *facts*. The contrast with the motion (`PromptParts.voice == nil`) is real, but state the rule
   precisely — **voice is gated on *grounded-ness*, not on `Auth`** (design §8.6). A demand letter
   **is grounded** (it recites matter facts: amount, dates, the obligation), which is exactly the
   context the `style-exemplars-voice-only` rule warns about. So even with voice on, the
   **fact-provenance gate still runs** (§0.3) — *that gate, not the absence of voice,* is what stops
   sample-derived facts from leaking. Decoding `.creative` (the `/draft` route).
3. **Fact firewall still applies** — a demand letter recites facts ("$X due under the contract
   dated Y"), so `factProvenance` (§8.2) is still on; facts come only from the matter with
   `[S#]` provenance. Authority is typically N/A (`assertsLegalAuthority == false`), but if the
   letter cites a statute, the `[cite]` discipline still holds.
4. **Identity firewall** — the letterhead (firm name/address/contact) is `AssistantProfile`
   slots, never baked into the template (design §8.6).

---

## 1. New types

### 1.1 Letterhead style (HouseStyleSheet addition — design §4/§15 per-firm)
Canonical `LetterheadBlock`, `LetterParaStyle`, and `LetterheadStyle` definitions live with the
single `HouseStyleSheet` type (NoticeAppearance §3.2 / CoreTypes module). They are shown here as
the full field list for the letter slice; do not redeclare them in a second module.

```swift
public struct LetterheadBlock: Codable, Sendable {
    public var firmNameHalfPoints: Int = 32        // 16pt
    public var taglineHalfPoints: Int = 20         // 10pt
    public var contactHalfPoints: Int = 20         // 10pt
    public var separator: String = " • "
    public var bottomRule = true
}
public struct LetterheadStyle: Codable, Sendable {     // LOCKED against letterDemand-golden.docx
    public var headerBlock: LetterheadBlock = .init()  // CENTERED: firm name, tagline, contact lines, pBdr rule
    public var bodyLineSpacing: LineSpacing = .single   // single-spaced; one blank line between paragraphs
    public var bodyJustify = true                  // body is JUSTIFIED (jc both) — golden
    public var bodyParagraphStyle: LetterParaStyle = .block  // .block: no first-line indent
    public var dateFormat: DateStyle = .monthDayYear        // left-aligned
    public var closing: String = "Respectfully,"   // golden (NOT "Sincerely,")
    public var signatureIndentTwips = 4680         // closing + signature block sit in the RIGHT half (like court §12)
    public var signatureGapLines: Int = 2          // blank lines for a wet signature between closing and typed name
    public var pageNumbers: Bool = false           // v1 golden: no footer/page numbers
}
public enum LetterParaStyle: String, Codable, Sendable { case block, indented }
```
Added to `HouseStyleSheet` as `var letterhead: LetterheadStyle?` (nil for court-only firms;
derived from the firm's letter exemplars via §15). The court-filing geometry (caption,
court signature block) is unused on this shell.

### 1.2 Letter document model (the letterhead shell's render input)
The court `DocumentModel` (caption/title/body/signature/certificate) doesn't fit a letter, so
the renderer takes a **shell-tagged input**:
```swift
// RenderInput is defined in CoreTypes; this slice adds the LetterModel carried by `.letter`.
public struct LetterModel: Sendable {
    public var letterhead: LetterheadFill     // firm block, from AssistantProfile slots
    public var date: DateOnly
    public var recipient: AddressBlock        // name · title · firm · street · city/state/zip
    public var reLine: String                 // "RE: Demand for Payment — [matter ref]"
    public var salutation: String             // "Dear Mr. Whitfield:"
    public var body: [String]                 // the voice-driven paragraphs (model output)
    public var closing: String                // from LetterheadStyle.closing
    public var signerName: String
    public var signerTitle: String?
    public var enclosures: [String]
    public var cc: [String]
}
```
`Renderer.render(_:style:)` switches on `RenderInput`; the court path is the
`NoticeAppearance`/`Motion` renderer, the letter path is `LetterheadRenderer` (SupraExports).

### 1.3 Generation (routed-skill — one call, voice on)
Reuses `Generator`, but the `PromptParts` differ from the motion:
```swift
// letterDemand
PromptParts(
    taskInstruction: template(.letterDemand),      // "Draft a demand letter…", engine prompt (§8.9/§17)
    voice: VoiceContext(profile: assistantProfile, toneOnly: true), // tone/register only; facts still gated (§8.6 — grounded)
    sectionContract: .wholeLetter,                  // not section-by-section
    facts: retrieve(matter),                        // the obligation, amount, dates — [S#] labelled
    authorities: [],                                // typically none; [cite] discipline if law is cited
    precedent: structureTemplate(.letterDemand, firm), // firm's demand-letter voice/skeleton (§15.5)
    decoding: .creative)
```
The model returns a structured `GeneratedLetter` (`paragraphs`, `assertedFacts`, `citesUsed`) which
is then assembled into `LetterModel.body`. Post-generation, the **fact-provenance** gate still runs
on `assertedFacts` (every recited fact must trace to a `[S#]`), and the `factProvenance →
stripToPlaceholderAndFlag` repair applies (`[fact?]`, never re-roll — design §8.2). If `citesUsed`
is non-empty despite `assertsLegalAuthority == false`, the authority/citation placeholder discipline
still runs for those cited legal assertions.

### 1.4 Slot deltas
`recipient` (`.text`, `.matterMetadata` — opposing party/counsel address); `reSubject`
(`.text`, `.userPrompt`); `demandAmount` (`.money`/`.text`, `.matterMetadata` or `.userPrompt`);
`responseDeadline` (`.date`, `.userPrompt`); `tone` (`.enumValue(["firm","measured","final"])`,
`.userPrompt`, optional). Letterhead fields (firm name/address/phone/email/signer) all
`.assistantProfile`. No caption/division/case-number slots (not a court filing).

---

## 2. The letter flow
```
resolve slots (recipient/demand/deadline from user+matter; letterhead identity auto)
  → facts = retrieve(matter)                       // obligation, amount, dates ([S#])
  → parts = PromptParts(voice: profile, decoding: .creative, …)   // ONE call, voice ON
  → generated = Generator.generate(parts) as GeneratedLetter
  → verify: factProvenance on generated.assertedFacts (strip [fact?] + flag if untraced); authority gate only if generated.citesUsed is non-empty
            NO certificate-of-service requirement (not filed)
  → assemble LetterModel (letterhead from AssistantProfile, date, recipient, RE, salutation, body, closing, signer)
  → PreFileGate: letterhead complete? recipient present? (no caption/cert checks for this shell)
  → Renderer.render(.letter(model), style)
```

---

## 3. Render — the letterhead shell (`LetterheadRenderer`, SupraExports) — LOCKED against the golden
Maps `LetterModel` → OOXML (reusing `OoxmlModel`/`OoxmlWriter`/`StyleSheetCompiler`/`DocxPackage`):
1. **Letterhead block** → **centered**: firm name bold `sz=32` (16pt) · "Attorneys at Law" italic
   `sz=20` (10pt) · contact lines `sz=20` with `  •  ` separators · then a paragraph with a
   full-width `<w:pBdr><w:bottom/></w:pBdr>` **rule**. (≤12pt is fine here — the 2.520(a) floor is court-only.)
2. **Date** → **left**, `monthDayYear`.
3. **Delivery notation** → **bold + italic, title case**: "Via Certified Mail, Return Receipt Requested"
   (golden — not all-caps). Optional; omit for plain mail.
4. **Recipient address block** → left, single-spaced.
5. **`RE:` line** → bold, **hanging indent** `<w:ind w:left="1440" w:hanging="720"/>`: bold "RE:" + tab +
   bold subject (subject wraps aligned at 1.0″).
6. **Salutation** → "Dear …:", left.
7. **Body** → `bodyLineSpacing` (single) + **justified** (`jc both`) + `.block` (no first-line indent),
   one blank line between. **No** court double-spacing.
8. **Closing + signature** → in the **RIGHT half** (`ind left=signatureIndentTwips` = 4680, like court
   §12): `closing` ("Respectfully,") · `signatureGapLines` (2) blank lines · signer name · firm name.
   **No `/s/`** (wet signature in the gap); no bar/office lines (those live in the letterhead).
9. **Enclosures / cc** → back at the **left margin** (not indented): "Enclosure: …", "cc:  …".
10. **No footer / page numbers** in v1 (`LetterheadStyle.pageNumbers == false`; the golden has none).
No `sectPr` caption logic; standard 1″ margins (or the firm's letter margins).

---

## 4. Acceptance criteria (design §16)
- **Golden-file:** a fixed `LetterModel` + `HouseStyleSheet.letterhead` → golden `document.xml`:
  letterhead block present and **all from slots** (no literal firm text in the template); body
  single-spaced block paragraphs; closing + signature gap; no caption table, no cert-of-service
  element.
- **Voice fixture (the contrast case):** assert `PromptParts.voice != nil` **with `toneOnly == true`**
  for `letterDemand`, and `== nil` for `motionToDismiss` — the §8.6 boundary (voice gated on
  grounded-ness; tone-only when on) in code. Pair it with the fact-firewall fixture below: for a
  grounded letter, the fact gate — not voice's absence — is the actual guard.
- **Fact-firewall fixture:** plant a distinctive fake fact in the firm's letter exemplar; generate
  a demand for a different matter; assert it doesn't appear and the `factProvenance` gate would
  catch it (→ `[fact?]`). (Same guard as the motion, on the recited-facts surface.)
- **No-baked-identity:** render with firm A vs. firm B letterhead slots → each output carries only
  its own firm block.
- **Gate fixture:** a demand letter must **not** get an auto-appended 2.516 certificate (design §12
  guardrail: never on pre-suit correspondence) — assert the pre-file gate adds no cert requirement
  for the `.letterhead` shell.

---

## 5. Open decisions / risks
1. **Letterhead source** — rendered from `AssistantProfile` slots (recommended) vs. an uploaded
   firm letterhead image/template. Image letterhead = a per-firm asset; slots = portable. Lean slots
   for v1; allow an optional header image later.
2. **Certified-mail proof** — a demand letter is often sent certified mail; that's a *proof of
   mailing*, not a 2.516 cert, and is out of slice (note for the `letterDemandStatutory` ch. 558
   variant, which has a statutory checklist — design §6F).
3. **Voice intensity** — `.creative` decoding + voice channel risks drift; cap with the same
   eval rubric (§16/§17) on a held-out letter set. Attorney review remains the acceptance gate.

**Done = the letterhead golden matches, the voice-boundary + fact-firewall + no-cert fixtures
pass.** This proves the second render shell and the voice path; both ride the same
`OoxmlModel`/`DocxPackage` the court shell uses — which the next doc (SupraExports) specifies.
