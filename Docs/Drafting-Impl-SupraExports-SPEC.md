# Implementation Spec — `SupraExports` (the renderer)

> **Companion to** the design spec (§4, §11, §12) and the three kind impl specs, which all
> depend on this. `SupraExports` is the **shared Layer-1 renderer** — it turns
> `(RenderInput, HouseStyleSheet)` into `.docx` bytes. It is the **highest-risk** module
> (render fidelity), so the hard OOXML constructs are centralized here and **golden-locked**.
> Shared types & the `Renderer`/`RenderInput` protocol live in `Drafting-Impl-CoreTypes-SPEC.md`.
> **No cloud, no Word/Office dependency** at runtime (the OPC Zip is the one real packaging
> primitive — see §1).

`Renderer` and `RenderInput` are imported from `SupraDraftingCore`; this module implements the renderer and must not redeclare the protocol.

---

## 1. The OPC package (`Ooxml/DocxPackage.swift`)
A court `.docx` is a Zip (OPC) with these minimal renderer-owned parts:
```
[Content_Types].xml          // declares the part content types
_rels/.rels                  // → word/document.xml (officeDocument)
word/document.xml            // ← CourtFLRenderer / LetterheadRenderer
word/styles.xml              // ← StyleSheetCompiler(HouseStyleSheet)
word/settings.xml            // evenAndOddHeaders off; compat defaults
word/footer1.xml             // centered PAGE field (DEFAULT footer)
word/footerEmpty.xml         // empty (FIRST-page footer → suppresses page-1 number)
word/_rels/document.xml.rels // → styles.xml, settings.xml, footer1.xml, footerEmpty.xml
```
`DocxPackage` assembles these strings into a Zip → `Data`. Foundation has **no Zip writer**;
for v1, prefer the repo's already-pinned `ZIPFoundation` dependency (used by `SupraDocuments`) unless
a later dependency review deliberately replaces it with a small store-only OPC writer. Parts are UTF-8 XML.
Letterhead packages omit court-only footer parts unless page numbering is explicitly enabled in a later style.

### 1.1 The fixed boilerplate parts (literal)
```xml
<!-- [Content_Types].xml -->
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml"  ContentType="application/xml"/>
  <Override PartName="/word/document.xml"    ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
  <Override PartName="/word/styles.xml"      ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
  <Override PartName="/word/settings.xml"    ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>
  <Override PartName="/word/footer1.xml"     ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>
  <Override PartName="/word/footerEmpty.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>
</Types>

<!-- _rels/.rels -->
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>

<!-- word/_rels/document.xml.rels -->
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rIdStyles"      Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles"   Target="styles.xml"/>
  <Relationship Id="rIdSettings"    Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings" Target="settings.xml"/>
  <Relationship Id="rIdFooter1"     Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer"   Target="footer1.xml"/>
  <Relationship Id="rIdFooterEmpty" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer"   Target="footerEmpty.xml"/>
</Relationships>
```
The footer `r:id`s here are exactly the ones `sectPr` references (§4.6).

### 1.2 `styles.xml` skeleton (one style shown; the rest follow the §3 table)
```xml
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:docDefaults><w:rPrDefault><w:rPr>
    <w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman"/><w:sz w:val="24"/>
  </w:rPr></w:rPrDefault></w:docDefaults>
  <w:style w:type="paragraph" w:styleId="Body">
    <w:name w:val="Body"/>
    <w:pPr><w:spacing w:line="480" w:lineRule="auto"/><w:ind w:firstLine="720"/><w:jc w:val="both"/></w:pPr>
  </w:style>
  <!-- CourtHeader, DocTitle, CaptionLine, MotionSectionHeading, CertificateHeading, SigLine, CosBody, LetterBody, H1…H5 likewise -->
</w:styles>
```

---

## 2. `OoxmlModel` + `OoxmlWriter` (typed WML → `document.xml`)
The value types (§ NoticeAppearance impl) serialize 1:1 to WordprocessingML. Namespaces on the
root: `xmlns:w="…/wordprocessingml/2006/main" xmlns:r="…/officeDocument/2006/relationships"`.
Mapping reference:
- `OoxmlParagraph` → `<w:p><w:pPr>…</w:pPr> {runs} </w:p>`; `style` → `<w:pStyle w:val="…"/>`.
- `ParaProps`: `jc` → `<w:jc w:val="both"/>`; indents → `<w:ind w:left=".." w:hanging=".." w:firstLine=".."/>` (twips); spacing → `<w:spacing w:line="480" w:lineRule="auto"/>` (double) / `w:line="240"` (single); `spaceAfterTwips` → `w:after`.
- `OoxmlRun` → `<w:r><w:rPr>…</w:rPr><w:t xml:space="preserve">{escaped}</w:t></w:r>`; `bold/italic/underline/caps` → `<w:b/> <w:i/> <w:u w:val="single"/> <w:caps/>`; `tab` → `<w:tab/>`.
- `OoxmlTable` → `<w:tbl><w:tblPr><w:tblW w:w=".." w:type="dxa"/>{borders}<w:tblLayout w:type="fixed"/></w:tblPr><w:tblGrid>{<w:gridCol w:w=".."/>}</w:tblGrid>{rows}</w:tbl>`.
- `OoxmlCell` → `<w:tc><w:tcPr><w:tcW w:w=".." w:type="dxa"/>{tcBorders}</w:tcPr>{paragraphs}</w:tc>`.

**XML-escape** `& < >` (and `"` in attrs). `xml:space="preserve"` on every `<w:t>` so leading/
trailing spaces in slot values survive.

---

## 3. `StyleSheetCompiler` (`HouseStyleSheet` → `styles.xml` / `settings.xml` / `sectPr`)
- **`docDefaults`** → `<w:rFonts w:ascii="{page.fontName}"…/>`, `<w:sz w:val="{page.fontHalfPoints}"/>` (24 = 12 pt).
- **Named paragraph styles** (so a firm's derived geometry flows through — design §14):
  `Body` (line 480/auto, ind firstLine 720, jc both), `CourtHeader` (center, b), `DocTitle`
  (center, b, u, caps), `CaptionLine` (line 240), `MotionSectionHeading` (center, b, **not underlined**),
  `CertificateHeading` (center, b, u), `SigLine` (line 240, ind left {signature.leftIndentTwips}),
  `CosBody` (line 240, ind firstLine 720), `LetterBody` (line 240, block), and the **heading ladder**
  `H1…H5` (§4 — see §4.3 below).
- **`sectPr`** (emitted at the end of `document.xml` body):
  `<w:pgSz w:w="{page.widthTwips}" w:h="{page.heightTwips}"/>`,
  `<w:pgMar w:top=".." w:right=".." w:bottom=".." w:left=".." w:header="720" w:footer="720"/>`,
  plus the page-1-suppression block (§4.6).
- **Floor guard** — if `page.fontHalfPoints < 24` or any margin `< 1440`, the compiler **throws
  / emits a `ruleConformance` `GateFailure`** (2.520(a), design §4). Never silently sub-floor.

---

## 4. The hard constructs (centralized; each golden-locked)

### 4.1 Caption — 2-cell borderless table (LOCKED against the golden, design §4)
> **Round-trip correction:** the firm's caption is a **2-column** table (party block | case block),
> each **4680 twips**, total **9360** = the true usable width (12240 − 2×1440). There is **no
> buffer column** — the spec's earlier 3-cell / 360-buffer / 9720 design was wrong (9720 also
> overran the margins). The visual gutter is just the right cell's content not filling its half.
```xml
<w:tbl>
  <w:tblPr><w:tblW w:w="9360" w:type="dxa"/><w:tblInd w:w="10" w:type="dxa"/>
    <w:tblBorders><w:top w:val="nil"/><w:left w:val="nil"/><w:bottom w:val="nil"/>
      <w:right w:val="nil"/><w:insideH w:val="nil"/><w:insideV w:val="nil"/></w:tblBorders>
    <w:tblLayout w:type="fixed"/>
    <w:tblCellMar><w:left w:w="10" w:type="dxa"/><w:right w:w="10" w:type="dxa"/></w:tblCellMar></w:tblPr>
  <w:tblGrid><w:gridCol w:w="4680"/><w:gridCol w:w="4680"/></w:tblGrid>
  <w:tr>
    <w:tc><w:tcPr><w:tcW w:w="4680" w:type="dxa"/>{tcBorders nil}</w:tcPr>{party lines}{closing rule §4.7}</w:tc>
    <w:tc><w:tcPr><w:tcW w:w="4680" w:type="dxa"/>{tcBorders nil}</w:tcPr>{CASE NO. line}{DIVISION line}</w:tc>
  </w:tr>
</w:tbl>
```
Left-cell party lines are single-spaced; one empty line between parties and on each side of "v.";
designations ("Plaintiff,"/"Defendant.") carry `ind left="720"`. Right cell: two consecutive
paragraphs (CASE NO., DIVISION), no blank.

### 4.2 e-signature line `By: /s/ Name` (LOCKED against the golden, design §12)
> **Round-trip correction:** there is **no table and no bordered cell.** The firm's signature line
> is a **single paragraph** (`ind left="4680"`) — `"By: "` (plain) + the name run (italic +
> `<w:u w:val="single"/>`) + **one or more `<w:tab/>` runs that are themselves italic+underlined**,
> which extend the rule past the name. The "≈2.0″ / 4-tab" length is just underlined tabs landing
> on default tab stops — it was never a *fixed* 2880-twip width. (So my earlier "bordered cell"
> was wrong; the tab-leader was right.)
```xml
<w:p><w:pPr><w:ind w:left="4680"/></w:pPr>
  <w:r><w:t xml:space="preserve">By: </w:t></w:r>
  <w:r><w:rPr><w:i/><w:u w:val="single"/></w:rPr><w:t>/s/ Jordan A. Reyes</w:t></w:r>
  <w:r><w:rPr><w:i/><w:u w:val="single"/></w:rPr><w:tab/></w:r>
  <w:r><w:rPr><w:i/><w:u w:val="single"/></w:rPr><w:tab/></w:r>
</w:p>
```
**Renderer note (determinism):** the golden uses *default* tab stops (every 720 from the margin),
so the underline length tracks the name length — fine for a human, non-deterministic for a golden
test. The renderer should **pin it**: declare one `<w:tabs><w:tab w:val="left" w:pos="7560"/></w:tabs>`
(= `left 4680` + 2880) and emit a single underlined `<w:tab/>` to it, giving a reproducible 2.0″
rule. The COS sign-off is the same construct without `"By: "` (the golden used one tab there).

### 4.3 Hanging-indent point headings `I.A.1.a.i.` (LOCKED against the motion golden, design §4)
> **Confirmed:** the geometry is exactly per level *n* (1-based) `ind left=n·720 hanging=720` + a
> tab stop at `n·720` — Word didn't touch the indent math. The golden added one thing my guess
> lacked: **`<w:spacing w:after="240"/>`** (a 12-pt gap below each heading, before the body). Level-1
> numerals are bold+caps; deeper levels bold title-case. Manual numerals — **never `w:numPr`**.
```xml
<w:p><w:pPr>
    <w:tabs><w:tab w:val="left" w:pos="{n*720}"/></w:tabs>
    <w:spacing w:after="240"/>
    <w:ind w:left="{n*720}" w:hanging="720"/></w:pPr>
  <w:r><w:rPr><w:b/></w:rPr><w:t>{numeral}</w:t></w:r>          <!-- "I." (lvl1 adds <w:caps/>) / "A." / "1." -->
  <w:r><w:tab/></w:r>
  <w:r><w:rPr><w:b/>{<w:caps/> at lvl 1}</w:rPr><w:t>{heading text}</w:t></w:r>
</w:p>
```
First-line indent = `left − hanging` = `(n-1)·720` (numeral); tab → `n·720` (text); wrapped lines
return to `left = n·720`. (pPr child order: `tabs` → `spacing` → `ind`.) The following body
paragraph is the normal double-spaced `Body`; the heading's `after="240"` supplies the gap. The
`H{n}` named style can carry the bold/`after`; the indents are per-paragraph.

### 4.4 Numbered allegation / Statement-of-Facts ¶ (design §4) — number at margin, text at 0.5″, **continuation to margin**
Not a hanging indent (continuation returns to the margin, *left* of the text):
```xml
<w:p><w:pPr><w:pStyle w:val="Body"/>
    <w:ind w:left="0" w:firstLine="0"/>
    <w:tabs><w:tab w:val="left" w:pos="720"/></w:tabs></w:pPr>
  <w:r><w:t>{n}.</w:t></w:r><w:r><w:tab/></w:r><w:r><w:t>{fact text}</w:t></w:r>
</w:p>
```
Number at 0, tab to 720, text at 0.5″; double-spaced (`Body`), wraps to margin.

### 4.5 Single 12-pt blank between double-spaced paragraphs (design §4)
Insert one **explicitly single-spaced empty paragraph** between `Body` paragraphs and after a
title (never rely on `w:after`, which would scale with the page):
```xml
<w:p><w:pPr><w:spacing w:line="240" w:lineRule="auto"/></w:pPr></w:p>
```

### 4.6 Page-1 number suppression + centered footer from p.2 (design §4)
In `sectPr`:
```xml
<w:titlePg/>
<w:pgNumType w:start="1"/>
<w:footerReference w:type="first"   r:id="rIdFooterEmpty"/>
<w:footerReference w:type="default" r:id="rIdFooter1"/>
```
`footerEmpty.xml` = an empty `<w:p/>`; `footer1.xml` = centered `PAGE` field:
```xml
<w:p><w:pPr><w:jc w:val="center"/></w:pPr>
  <w:r><w:fldChar w:fldCharType="begin"/></w:r>
  <w:r><w:instrText xml:space="preserve"> PAGE </w:instrText></w:r>
  <w:r><w:fldChar w:fldCharType="separate"/></w:r>
  <w:r><w:t>1</w:t></w:r>                              <!-- cached result; shown until the field recalculates -->
  <w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>
```
The `separate` + cached-result run matters: without it, Pages / PDF export can show a blank until
the field recalculates. Word recalcs on open either way.

### 4.7 Closing caption rule to the ½ mark ending in `/` (design §4)
A `CaptionLine` paragraph: a **bottom border on the paragraph** spanning the cell, then a `/`.
Canonical renderer output is a bordered-bottom paragraph (`<w:pBdr><w:bottom .../></w:pBdr>`)
sized by the cell, with a trailing `/` run. Do **not** emit a literal underscore run or a 1-cell
bordered table; those are historical Word-fixture variants that the normalizer may recognize only
as legacy equivalents.

---

## 5. Shell renderers
- **`CourtFLRenderer`** (`.court(DocumentModel)`) — court header → §4.1 caption → §DocTitle →
  body (`paragraph`→Body; `numberedAllegation`→§4.4; `pointHeading`→§4.3; `sectionHeading`→
  `MotionSectionHeading` unless a kind-specific renderer maps it otherwise) → signature block (right-half; `respectfullySubmitted` → separate left `firstLine
  720` line if non-nil; `/s/` → §4.2) → certificate (heading, single-spaced body, service list,
  plain sign-off) → §4.6 footer. Used by `noticeAppearance` + `motionToDismiss`.
- **`LetterheadRenderer`** (`.letter(LetterModel)`) — **LOCKED** (`letterDemand-golden.docx`): centered
  letterhead (firm 16pt bold / tagline + contact 10pt, `•` separators) + full-width `pBdr` rule → date
  (left) → optional **bold-italic** delivery notation → recipient → `RE:` (bold, hanging `left=1440
  hanging=720` + tab) → salutation → body (single-spaced, **justified**, block) → closing
  **"Respectfully,"** + signature block in the **right half** (`left=4680`, **no `/s/`**) → enclosure/cc at
  the **left margin**. No caption/cert/§4.6 footer. See LetterDemand §3.
Both emit the same `OoxmlModel` and share `StyleSheetCompiler`/`OoxmlWriter`/`DocxPackage`.

---

## 6. Acceptance criteria
- **Golden-file (per kind):** render the fixed fixtures (NoticeAppearance §7.1, Motion §3.1,
  Letter §4) → committed golden `document.xml` + `styles.xml`. Test = **structural XML compare**
  after an explicit normalizer: sort attributes, collapse insignificant whitespace, strip volatile
  Word output (`w:rsid*`, `w14:*`, `w:proofErr`, `w:lastRenderedPageBreak`, unused namespace declarations,
  and optional Word-only table/look metadata), then compare element trees for renderer-owned WML.
- **Construct unit tests:** assert the exact WML for each §4 construct given a minimal model
  (caption grid `[4680,4680]`; `H2` para has `ind left=1440 hanging=720` + tab `pos=1440`;
  fact ¶ has tab `pos=720` and no left indent; the blank-line ¶ is `line=240`; signature is a
  single paragraph with italic+underlined `/s/ Name` plus an underlined tab to a pinned tab stop;
  `sectPr` has `titlePg` + both footer refs).
- **Floor guard:** `fontHalfPoints=22` or `margin<1440` → `StyleSheetCompiler` throws/flags.
- **Open-in-Word/Pages parity (manual gate, pre-release):** the golden `.docx` opens clean (no
  repair prompt) in Word and Pages and matches the design renders — the empirical check for the
  five constructs that can't be fully unit-asserted.

---

## 7. Empirical golden-locks — status
Validated against **`Docs/Fixtures/noticeAppearance-golden.docx`** (#1–#4) and
**`Docs/Fixtures/motionToDismiss-golden.docx`** (#5) — synthetic filings hand-finished in real Word
and round-tripped, each with an extracted `…golden.document.xml`. **All five are now LOCKED.**
1. **e-signature line — ✅ LOCKED:** one paragraph, `"By: "` + italic+underlined name + italic+
   underlined `<w:tab/>`(s); **no table/bordered cell** (§4.2). Render with a pinned tab stop for
   determinism. *(My "bordered cell" guess was wrong.)*
2. **`By: /s/ Name` on one line — ✅ LOCKED:** it *is* the single paragraph in #1; nothing special.
3. **Closing caption rule — ✅ LOCKED:** paragraph `<w:pBdr><w:bottom w:val="single" w:sz="6"
   w:space="1"/></w:pBdr>` + `jc="right"` + `"/"` (§4.7).
4. **Page-1 suppression — ✅ LOCKED:** `sectPr` with `titlePg` + `footerReference type="first"`→empty
   footer + `type="default"`→centered `PAGE` field (with `separate`+result run) + `pgNumType start="1"`
   (§4.6). Word reproduced this verbatim.
5. **Hanging-indent headings — ✅ LOCKED:** `ind left=n·720 hanging=720` + tab at `n·720` +
   `<w:spacing w:after="240"/>`; manual bold numerals (level-1 caps), not `w:numPr` (§4.3). Locked
   against `motionToDismiss-golden.docx`.

**All five constructs are now locked across both court shells.** Remaining house-style facts the
goldens also fixed: section labels (`STATEMENT OF FACTS`, `MEMORANDUM OF LAW`) are **centered bold,
not underlined** (CONCLUSION is instead a roman point-heading); "Attorneys for [party]" is the
**last** signature line (after the e-mails); the attorney name is **plain** (not bold); Word emits
**typographic** quotes/apostrophes (the renderer should too).

The golden normalizer is part of the contract: current Word-extracted fixtures contain Word-only
noise and direct-formatting variants. Either sanitize/regenerate fixtures to the renderer's canonical
subset or keep the normalizer above strict and versioned.

The **letterhead shell** (`LetterheadRenderer`, §5) is also locked, against
`Docs/Fixtures/letterDemand-golden.docx`: centered letterhead + full-width rule, left date, optional
bold-italic delivery notation, hanging `RE:` line, justified single-spaced block body, closing
**"Respectfully,"** + right-half (`left=4680`) signature block with **no `/s/`**, and enclosure/cc
back at the left margin. **All three render shells are now grounded in round-tripped Word goldens.**

**Definition of done for the slice:** all three kinds' goldens match, the construct unit tests
pass, the floor guard fires, and the goldens open clean in Word/Pages matching the design
renders. At that point the renderer is proven, and `SupraDrafting` (pipeline, slots, generation,
firewall) builds on a fidelity-locked foundation.

---

## 8. Dependencies & constraints
- **No third-party OOXML library** (full control over the constructs above; avoids a dependency
  that fights the fidelity). Pure Swift string-building for WML. For the **OPC Zip**, use the
  repo's existing vetted `ZIPFoundation` dependency for v1 unless a later dependency review mandates
  a small store-only writer; don't assume Foundation ships a Zip writer (it doesn't).
- **No network, no Office** at runtime — pure local generation (design §1).
- `HouseStyleSheet`-driven throughout (no hardcoded geometry) so per-firm derived sheets (§15)
  and the `defaultFL` seed both flow through the same renderer.
