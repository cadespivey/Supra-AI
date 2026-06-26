# Implementation Spec — `noticeAppearance` vertical slice

> **Companion to** `Docs/Drafting-Catalog-SPEC.md` (the design spec). Section references like
> "§8.1" point there. This doc is the **code-oriented** translation for the first build
> target. It contains only types/schemas; all sample data below is **fictional test fixture
> data** (no client content; identity is slot-only per design §8.6).
>
> **Why `noticeAppearance` first:** it is a `servicePipeline` kind (near-zero LLM — slot-fill
> + deterministic assembly), so it exercises the **renderer, slot model, verification, and
> pre-file gate end-to-end** without the generation/firewall surface. If the renderer + types
> survive this, the harder kinds layer on top. (Design §10.)

---

## 0. Scope of the slice
Build, end-to-end: resolve slots → assemble a `DocumentModel` → verify → pre-file gate →
render a `.docx`. The LLM is **not** invoked for this kind (the body is fixed language with
slots — see §5). What this slice proves: the `courtFL` shell renders to spec (caption table,
typography, signature block, certificate of service, page-1 number suppression), the slot
model resolves from matter + `AssistantProfile`, and the deterministic gates fire.

Out of slice (stubbed/deferred): generation/prompt-assembly (§8.9), authority/citation
(§8.2 — N/A, `assertsLegalAuthority == false`), the elements library (§8.10 — notices have
no counts), precedent extraction (§15.5), transactional (§7).

---

## 1. Module & file layout

```
FutureModules/SupraDrafting/Sources/SupraDrafting/
  DraftKind.swift            // enum + per-kind metadata
  Slot.swift                 // SlotSpec, SlotValue, SlotType, SlotSource
  HouseStyleSheet.swift      // the format config (concrete units)
  DocumentModel.swift        // shell-agnostic intermediate representation
  Caption.swift              // CaptionModel + minimal PartyModel (§8.8 subset)
  ClosingBlocks.swift        // SignatureBlockModel, CertificateModel
  HeadingContract.swift      // required-section contract (§8.10 structure half)
  FollowUp.swift             // FollowUp, Severity (§8.1 queue)
  Pipeline/
    DraftPipeline.swift      // orchestrator
    SlotResolver.swift       // protocol + default impl
    Verifier.swift           // protocol + courtFL impl (deterministic gates)
    PreFileGate.swift        // final whole-doc gate (§8.3)
  Kinds/
    NoticeAppearance.swift   // the kind's SlotSpec, HeadingContract, body template, assembler

FutureModules/SupraExports/Sources/SupraExports/
  Ooxml/
    OoxmlModel.swift         // typed WordprocessingML value types
    OoxmlWriter.swift        // OoxmlModel -> document.xml (String)
    StyleSheetCompiler.swift // HouseStyleSheet -> word/styles.xml + settings.xml
    DocxPackage.swift        // OPC zip assembly -> Data (.docx bytes)
  CourtFLRenderer.swift      // renderer implementation; imports the CoreTypes Renderer protocol
```

Package graph for v1 implementation (explicit to avoid circular imports):
- `SupraDraftingCore` owns protocol-facing DTOs and protocols (`Renderer`, `RenderInput`, `Verifier`, `SlotResolver`, shared models).
- `SupraDrafting` owns kind registries, pipelines, assemblers, prompt/generation orchestration, and gates; it depends on `SupraDraftingCore` plus existing session/retrieval adapters.
- `SupraExports` owns OOXML renderers and `DocxPackage`; it depends on `SupraDraftingCore` and implements `Renderer`.

Integration points (existing types — adapt, do not redefine): `AssistantProfile`
(identity/firm), the matter store (matter metadata + `DocumentRetrievalService`), and — for
later kinds only — `StructuredOutputController`, `ModelRouter`, `GenerateRequest`. Existing
`AssistantProfile` lacks bar/email/office fields, so the implementation needs a `DraftingProfile`
/ `FirmProfile` adapter before slot resolution.

---

## 2. Kind metadata

```swift
public enum DraftKind: String, Codable, CaseIterable, Sendable {
    case noticeAppearance
    case motionToDismiss
    case letterDemand
    // … full catalog in design §6; only these three in the slice (§10)

    public var renderShell: RenderShell {
        switch self { case .letterDemand: .letterhead; default: .courtFL }
    }
    public var skeleton: AnalyticalSkeleton {
        switch self { case .noticeAppearance: .none; case .motionToDismiss: .houseMotionFL
                      case .letterDemand: .none }
    }
    public var blockType: DraftBlockType {
        switch self { case .noticeAppearance: .servicePipeline
                      case .motionToDismiss: .contract; case .letterDemand: .routedSkill }
    }
    public var assertsLegalAuthority: Bool {
        switch self { case .motionToDismiss: true; default: false }
    }
    public var groundingPolicy: GroundingPolicy {
        switch self {
        case .noticeAppearance: .noMatterFacts
        case .motionToDismiss: .authorityAndFacts
        case .letterDemand: .matterFactsRequired
        }
    }
    public var requiresFactProvenance: Bool { groundingPolicy != .noMatterFacts }
}

public enum RenderShell: String, Codable, Sendable {
    case courtFL, courtMDFL, courtGA, letterhead, internalMemo, chronologyTable, agreement
}
public enum AnalyticalSkeleton: String, Codable, Sendable {
    case none, irac, crac, creac, houseMotionFL, countPerClaim, perRequest, clauseAssembly, chronology
}
public enum DraftBlockType: String, Codable, Sendable { case routedSkill, contract, servicePipeline }
```

Per-kind data (`SlotSpec`, `HeadingContract`, body template, assembler) lives in
`Kinds/<Kind>.swift` (§5), not on the enum — keeps the kind catalog as **data** (design §14).
The pipeline reads that data through a registry:

```swift
public struct DraftKindDefinition: Sendable {
    public var kind: DraftKind
    public var slotSpecs: [SlotSpec]
    public var headingContract: HeadingContract
}
public protocol DraftKindRegistryProtocol: Sendable {
    func definition(for kind: DraftKind) -> DraftKindDefinition
}
```
For the first slice, the registry contains only `noticeAppearance`, `motionToDismiss`, and
`letterDemand`; later firms can override definitions/config without adding enum cases.

---

## 3. Core data types

### 3.1 Slot model (design §8.1)
```swift
public struct SlotSpec: Sendable {
    public let key: String                 // "caseNumber", "partyRepresented", "primaryEmail"
    public let type: SlotType
    public let source: SlotSource
    public let requirement: Requirement
    public let validator: SlotValidatorKey      // resolves to code; keeps SlotSpec data-serializable
}
public enum SlotValidatorKey: String, Codable, Sendable { case none, caseNumberFormat, emailFormat }
public indirect enum SlotType: Sendable {
    case text, date, money, citation, partyRef, enumValue([String]), email
    case officeBlock, addressBlock, serviceRecipientList
    case list(SlotType)
}
public enum SlotSource: Sendable {
    case matterMetadata, matterDocument, assistantProfile, partyModel, rulesPack, userPrompt
}
public enum Requirement: Sendable { case required, optional, conditional(on: String) }

public struct SlotValue: Sendable {
    public let key: String
    public let content: SlotContent
    public let provenance: Provenance?     // fact → matter-doc cite; identity → AssistantProfile; nil otherwise
    public let state: SlotState
}
public enum SlotContent: Sendable, Equatable {
    case text(String), date(DateOnly), money(Decimal, currency: String), citation(CitationRef)
    case partyLines([PartyLine]), office(OfficeBlock), address(AddressBlock), serviceRecipients([ServiceRecipient])
    case list([SlotContent])
}
public enum SlotState: Sendable { case derived, confirmed, missing }
public enum Provenance: Sendable { case matterDocument(id: String, locator: String), assistantProfile, partyModel }
```
`noticeAppearance` declares no `userPrompt`/`matterDocument` slots — it resolves entirely from
`matterMetadata`, `assistantProfile`, and `partyModel` (so the draft-first hybrid asks the
user **nothing** for this kind; design §8.1 Decision Z).

### 3.2 HouseStyleSheet (design §4 — units pinned)
**Units:** twips (1/1440 inch) unless noted; font size in **half-points** (OOXML `w:sz`).
Values below are the `defaultFL` seed (design §14.3); a firm's derived sheet (§15) overrides.
```swift
public struct HouseStyleSheet: Codable, Sendable {
    public var page: PageSetup
    public var body: BodyStyle
    public var caption: CaptionStyle
    public var headings: HeadingLadder        // unused by noticeAppearance; present for the shell
    public var signature: SignatureStyle
    public var certificate: CertificateStyle
    public var letterhead: LetterheadStyle?   // nil for court-only firms; used by LetterheadRenderer
}

public struct PageSetup: Codable, Sendable {
    public var widthTwips = 12240             // 8.5"
    public var heightTwips = 15840            // 11"
    public var marginTwips = EdgeInsets(top: 1440, leading: 1440, bottom: 1440, trailing: 1440)  // 1" (≥ 2.520(a))
    public var fontName = "Times New Roman"
    public var fontHalfPoints = 24            // 12 pt (≥ 2.520(a) floor — enforced; see §6)
    public var suppressFirstPageNumber = true // design §4 "page numbers"
}
public struct BodyStyle: Codable, Sendable {
    public var lineSpacing: LineSpacing = .double
    public var firstLineIndentTwips = 720     // 0.5"
    public var blankBreakIsSingleLine = true  // one single 12pt blank line between paras/after title
    public var justify = true
}
public struct CaptionStyle: Codable, Sendable {        // LOCKED 2-column, no buffer (golden)
    public var tableWidthTwips = 9360         // = usable width (12240 − 2×1440); NOT 9720
    public var leftCellWidthTwips = 4680      // party block (½ usable)
    public var rightCellWidthTwips = 4680     // case block (½ usable)
    public var cellMarginTwips = 10           // tblCellMar L/R (Word emitted this on the table)
    public var singleSpaced = true
    public var closingRuleEndsInSlash = true  // paragraph pBdr-bottom + right "/" (SupraExports §4.7)
    public var headerBoldCentered = true
}
public struct SignatureStyle: Codable, Sendable {
    public var leftIndentTwips = 4680         // right-half block
    public var singleSpaced = true
    public var firmNameBoldCaps = true
    public var representationLineItalic = true        // *italic* "Attorneys for [party]" — LAST line of the block (after e-mails), golden-confirmed
    public var eSignature: ESignatureStyle = .init()  // /s/ italic + underline 2"
}
public struct ESignatureStyle: Codable, Sendable {     // LOCKED: underlined name + underlined tab(s), NO cell
    public var italic = true
    public var underline = true
    public var underlineTabStopTwips = 2880   // pin a tab stop at left+2880; emit underlined <w:tab/> to it
}                                             // golden uses default tab stops; renderer pins for determinism (SupraExports §4.2)
public struct CertificateStyle: Codable, Sendable {
    public var headingCenteredBoldCaps = true
    public var bodySingleSpaced = true
    public var bodyFirstLineIndentTwips = 720 // 0.5"
    public var serviceListSingleSpaced = true
    public var counselLineItalic = true       // "Counsel for [party]"
    public var signOffNamePlainSentenceCase = true
    public var serviceMethodClause: ServiceMethodClause = .flEPortal  // design §12.2
}
public enum LineSpacing: String, Codable, Sendable { case single, double }   // OOXML: 240 / 480 line units
public enum ServiceMethodClause: String, Codable, Sendable {
    case flEPortal, flServedNotFiled, federalCMECF, mailFirstClass, mailRegisteredRRR  // design §12.2
}

// Also used by LetterDemand §1.1; included here so HouseStyleSheet is one canonical type.
public struct LetterheadBlock: Codable, Sendable {
    public var firmNameHalfPoints: Int = 32
    public var taglineHalfPoints: Int = 20
    public var contactHalfPoints: Int = 20
    public var separator: String = " • "
    public var bottomRule = true
}
public enum LetterParaStyle: String, Codable, Sendable { case block, indented }
public struct LetterheadStyle: Codable, Sendable {
    public var headerBlock: LetterheadBlock = .init()
    public var bodyLineSpacing: LineSpacing = .single
    public var bodyJustify = true
    public var bodyParagraphStyle: LetterParaStyle = .block
    public var dateFormat: DateStyle = .monthDayYear
    public var closing: String = "Respectfully,"
    public var signatureIndentTwips = 4680
    public var signatureGapLines: Int = 2
    public var pageNumbers: Bool = false
}
```

### 3.3 DocumentModel (the renderer's input — shell-agnostic)
```swift
public struct DocumentModel: Sendable {
    public var caption: CaptionModel
    public var title: String                 // e.g. "NOTICE OF APPEARANCE"
    public var body: [BodyBlock]
    public var signature: SignatureBlockModel?
    public var certificate: CertificateModel?
}
public enum BodyBlock: Sendable {
    case paragraph(String)                            // body style: double-spaced, 0.5" first-line indent
    case numberedAllegation(number: Int, text: String) // pleadings (not used here)
    case pointHeading(level: Int, numeral: String, text: String) // motions (not used here)
    case sectionHeading(String)                        // shell-specific style; motion section labels are centered bold, NOT underlined
}
```

### 3.4 Caption + party model (design §8.8 subset)
```swift
public struct CaptionModel: Sendable {
    public var courtHeader: String           // "IN THE CIRCUIT COURT OF THE FOURTH JUDICIAL CIRCUIT,\nIN AND FOR DUVAL COUNTY, FLORIDA"
    public var parties: [PartyLine]
    public var caseNumber: String
    public var division: String?
    public var judge: String?
}
public struct PartyLine: Sendable { public var name: String; public var designation: String } // "MERIDIAN…, LLC" / "Plaintiff,"
```
For a notice (two parties, no compound roles) the full party model (§8.8) reduces to a
straight P/D list. The model API is the same so complex postures (counterclaim, third-party)
slot in later without changing the caption renderer.

### 3.5 Closing-block models (design §12)
```swift
public struct SignatureBlockModel: Sendable {
    public var respectfullySubmitted: DateOnly?      // motions/briefs only → nil for notice
    public var firmName: String
    public var signingAttorney: String
    public var attorneys: [AttorneyLine]             // name, "Florida Bar No. NNN"
    public var office: OfficeBlock                    // street/suite/city/state/zip/phone/fax
    public var partyRepresented: String              // "Defendant"
    public var emails: EmailDesignation               // primary required; secondary 0–2
}
public struct CertificateModel: Sendable {
    public var date: DateOnly
    public var clause: ServiceMethodClause
    public var documentTitle: String?
    public var recipients: [ServiceRecipient]         // name+Esq · firm · address · emails · "Counsel for X"
    public var signOffAttorney: String
}
```

---

## 4. The renderer (SupraExports) — concrete OOXML

The `.docx` is an OPC (zip) package. **Approach:** generate WordprocessingML programmatically
(not `NSAttributedString → officeOpenXML`, which can't reliably emit the caption table with
exact column widths). `word/styles.xml` is **compiled from the `HouseStyleSheet`** so each
firm's geometry flows through (design §14). Direct formatting is used only where a style
won't reach (the 2″ signature underline).

### 4.1 Package contents (`DocxPackage`)
```
[Content_Types].xml
_rels/.rels                         → word/document.xml
word/_rels/document.xml.rels        → styles.xml, settings.xml, footer1.xml, footerEmpty.xml
word/document.xml                   ← from CourtFLRenderer
word/styles.xml                     ← from StyleSheetCompiler(HouseStyleSheet)
word/settings.xml                   ← evenAndOddHeaders off; defaults
word/footer1.xml                    ← centered PAGE field (used as the DEFAULT footer)
word/footerEmpty.xml                ← empty FIRST-page footer (suppresses page 1 number)
```
Zip with no compression metadata pitfalls (store/deflate fine); the package is `Data`.

### 4.2 `OoxmlModel` (typed value types → `OoxmlWriter`)
```swift
public struct OoxmlParagraph { var style: String?; var props: ParaProps; var runs: [OoxmlRun] }
public struct ParaProps {
    var jc: Jc?; var indFirstLineTwips: Int?; var indLeftTwips: Int?; var hangingTwips: Int?
    var spacingLineUnits: Int?; var spacingLineRule: String? // "auto"/"atLeast"
    var spaceAfterTwips: Int?; var tabStops: [TabStop] = []; var bottomBorder: Border? = nil
}
public enum RunContent { case text(String), tab, fieldChar(FieldCharType), instrText(String) }
public struct OoxmlRun { var content: RunContent; var props: RunProps }
public struct RunProps { var bold = false; var italic = false; var underline = false; var caps = false; var fontHalfPoints: Int? = nil }
public struct OoxmlTable { var widthTwips: Int; var borders: Borders; var grid: [Int]; var rows: [[OoxmlCell]]; var layoutFixed = true; var cellMarginTwips: Int? = nil; var indentTwips: Int? = nil }
public struct OoxmlCell { var widthTwips: Int; var borders: Borders; var content: [OoxmlParagraph] }
public struct TabStop { var positionTwips: Int; var alignment: Jc = .left }
public enum FieldCharType { case begin, separate, end }
public struct Border { var val: String; var size: Int?; var space: Int? }
public struct Borders { var top, left, bottom, right, insideH, insideV: Border?; static let none = Borders(top:nil,left:nil,bottom:nil,right:nil,insideH:nil,insideV:nil) }
public enum Jc: String { case left, center, right, both }
```
`OoxmlWriter` maps these 1:1 to `<w:p>/<w:pPr>/<w:r>/<w:rPr>`, `<w:tbl>/<w:tblPr>/<w:tblGrid>/<w:tr>/<w:tc>`.
Spacing: `LineSpacing.double` → `<w:spacing w:line="480" w:lineRule="auto"/>`; single → `240`.
Single 12-pt blank break between body paragraphs → a paragraph spacing of `spaceAfterTwips: 0`
plus an explicit empty single-spaced paragraph (matches the "one single 12-pt line" rule, §4).

### 4.3 `CourtFLRenderer.render(_:style:)` — the mapping
1. **Court header** → `OoxmlParagraph(jc:.center, runs:[bold caps])`, lines split on `\n`.
2. **Caption table** → `OoxmlTable(widthTwips: 9360, borders:.none, grid:[4680, 4680], layoutFixed:true, cellMargin:10)`, one `<w:tr>` with **2** `<w:tc>` (all `tcBorders` none) — **no buffer column** (LOCKED, golden):
   - **left cell** (4680): one single-spaced `<w:p>` per party line (name; designation `ind left=720`), one empty `<w:p>` between parties and on each side of "v."; then the **closing rule** (LOCKED, §4): canonical renderer output is a paragraph with `<w:pBdr><w:bottom w:val="single" w:sz="6" w:space="1"/></w:pBdr>` + `jc=right` + "/". The motion fixture's literal-underscore variant is empirical background only; do not emit it from the shared renderer.
   - **right cell** (4680): two single-spaced `<w:p>`: "CASE NO.: …" then "DIVISION: …", no blank between.
3. **Title** → centered, bold, underlined caps `<w:p>`; preceded/followed by a single blank line.
4. **Body** → for each `.paragraph`, a `<w:p>` with body style (`line=480 auto`, `ind firstLine=720`, `jc=both`), single blank line between.
5. **Signature block** (right-half: `ind left=4680`, single-spaced) — **order LOCKED against both goldens**:
   - `respectfullySubmitted` → **separate left-aligned** `<w:p>` (`ind firstLine=720`) "Respectfully submitted: [Month DD, YYYY]" **only if non-nil** (nil for the notice; present on the motion).
   - firm (**bold caps**) · "By: " + **eSignatureLine** · attorney (**plain**) · "Florida Bar No. N" · office lines · **bold** "Primary and Secondary E-Mail: " + primary, then each secondary on its own `<w:p>` · **then *italic* "Attorneys for [party]" as the LAST line** (after the e-mails — golden-confirmed; never above them).
   - **eSignatureLine** (`/s/ Name`) — **one paragraph, no table** (LOCKED, §4.2 / SupraExports §4.2): runs `"By: "` (plain) + italic+underlined "/s/ Name" + italic+underlined `<w:tab/>`(s) out to a pinned tab stop at `left + signature.eSignature.underlineTabStopTwips`. The COS sign-off is the same construct without "By: ".
6. **Certificate of service**:
   - centered bold underlined "CERTIFICATE OF SERVICE"; one single blank line.
   - body `<w:p>` single-spaced, `ind firstLine=720`: "I HEREBY CERTIFY that on [date], I " + **clause text for `certificate.clause`** + " to the following:". Clause text table (design §12.2):
     - `.flEPortal` → "electronically filed the foregoing with the Clerk of Court using the Florida Courts E-Filing Portal, which will send a Notice of Electronic Filing".
   - recipient list: single-spaced `<w:p>` per line; *italic* "Counsel for [party]".
   - sign-off: eSignatureLine "/s/ Name" then a **plain sentence-case** name `<w:p>`.
7. **Footer / page numbers** → `sectPr` with `<w:titlePg/>`, a `footerReference w:type="first"` to an **empty** footer (suppresses page 1), and `w:type="default"` → `footer1.xml` (centered `PAGE` field). `<w:pgNumType w:start="1"/>`. Margins from `page.marginTwips`; page size from `page.width/heightTwips`.

### 4.4 `StyleSheetCompiler` (HouseStyleSheet → styles.xml)
- `docDefaults`: `rFonts = page.fontName`, `sz = page.fontHalfPoints`.
- Named paragraph styles: `Body` (line 480, firstLine 720, jc both), `CourtHeader` (center, bold), `DocTitle` (center, bold, underline), `CaptionLine` (line 240), `SigLine` (line 240, ind left 4680), `CosBody` (line 240, firstLine 720), `MotionSectionHeading` (center, bold, not underlined), and `CertificateHeading` (center, bold, underline). Heading-ladder styles emitted but unused by this kind.
- **Floor guard:** if `page.fontHalfPoints < 24` or any `marginTwips < 1440`, the compiler refuses and emits a rule-conformance failure (2.520(a), design §4) — never silently sub-floor.

---

## 5. The `noticeAppearance` kind (`Kinds/NoticeAppearance.swift`)

```swift
enum NoticeAppearance {
    static let slotSpec: [SlotSpec] = [
        .init(key: "courtHeader",      type: .text,     source: .matterMetadata,   requirement: .required, validator: .none),
        .init(key: "parties",          type: .list(.partyRef), source: .partyModel, requirement: .required, validator: .none),
        .init(key: "caseNumber",       type: .text,     source: .matterMetadata,   requirement: .required, validator: .caseNumberFormat),
        .init(key: "division",         type: .text,     source: .matterMetadata,   requirement: .optional, validator: .none),
        .init(key: "partyRepresented", type: .text,     source: .matterMetadata,   requirement: .required, validator: .none),
        .init(key: "firm",             type: .text,     source: .assistantProfile, requirement: .required, validator: .none),
        .init(key: "signingAttorney",  type: .text,     source: .assistantProfile, requirement: .required, validator: .none),
        .init(key: "barNumber",        type: .text,     source: .assistantProfile, requirement: .required, validator: .none),
        .init(key: "office",           type: .officeBlock, source: .assistantProfile, requirement: .required, validator: .none),
        .init(key: "primaryEmail",     type: .email,    source: .assistantProfile, requirement: .required, validator: .emailFormat),
        .init(key: "secondaryEmails",  type: .list(.email), source: .assistantProfile, requirement: .optional, validator: .none),
        .init(key: "recipients",       type: .serviceRecipientList, source: .matterMetadata, requirement: .required, validator: .none), // opposing counsel service list
        .init(key: "serviceDate",      type: .date,     source: .matterMetadata,   requirement: .required, validator: .none),  // = today by default
    ]

    static let headingContract = HeadingContract(required: [.caption, .title, .body, .signature, .certificateOfService])

    // Body is FIXED language with slots — NO LLM call (this is a servicePipeline kind).
    static func assemble(_ slots: SlotResolution) -> DocumentModel { /* fill the template below */ }
}
```
**Body template (slots in `[…]`):**
> PLEASE TAKE NOTICE that the undersigned attorney, [signingAttorney] of [firm], hereby
> enters an appearance as counsel of record for [partyRepresented], [partyName], in the
> above-styled action, and requests that copies of all pleadings, notices, orders,
> correspondence, and other documents filed or served in this action be furnished to the
> undersigned at the addresses set forth below.
>
> Pursuant to Florida Rule of General Practice and Judicial Administration 2.516, the
> undersigned designates the following e-mail addresses for service of all documents in
> this action: [primaryEmail]; [secondaryEmails joined by "; "].

No identity literal appears in the template — every name/email/bar/address is a slot
(design §8.6). This is the leakage-test invariant (§7).

---

## 6. Pipeline & verification

```swift
// SlotResolver, Renderer, Verifier protocols are defined in SupraDraftingCore (CoreTypes §1) —
// one signature for all kinds. `SlotResolution`, `VerifyUnit`, `RenderInput` are there too.
public struct DraftPipeline {
    let resolver: SlotResolver; let verifier: Verifier; let gate: PreFileGate; let renderer: Renderer
    public func run(kind: DraftKind, matter: MatterContext, profile: AssistantProfile,
                    style: HouseStyleSheet) async throws -> DraftResult {
        let definition = DraftKindRegistry.default.definition(for: kind)
        let (slots, intakeFollowups) = await resolver.resolve(definition.slotSpecs, matter: matter, profile: profile)
        let model = NoticeAppearance.assemble(slots)                       // no LLM for this kind
        let vr = await verifier.verify(.wholeDocument(model), kind: kind, style: style)  // CoreTypes VerifyUnit
        let gateResult = gate.check(model, kind: kind, style: style)
        let docx = try renderer.render(.court(model), style: style)        // CoreTypes RenderInput
        return DraftResult(docx: docx, followUps: intakeFollowups + vr.followUps + gateResult.followUps)
    }
}
```
**Gates that apply to `noticeAppearance`** (design §8.2/§8.3):
- **Contract/structure** — `headingContract.required` all present in `DocumentModel` (deterministic).
- **Rule conformance** — `serviceMethodClause == .flEPortal` (a filed notice is e-served, §12.2);
  format floor via `StyleSheetCompiler` guard (2.520(a)); a 2.516 certificate **present**.
- **Fact provenance / authority** — **N/A** (`assertsLegalAuthority == false`; no facts asserted).
- **Pre-file gate** — caption complete (parties + caseNumber non-empty), signature block present,
  certificate attached. Failures → `FollowUp(severity: .blocking | .advisory)`.

```swift
public struct FollowUp: Sendable {
    public enum Severity: Sendable { case blocking, advisory }
    public let severity: Severity; public let kind: Kind; public let message: String
    public enum Kind: Sendable { case missingSlot(String), conflict, verify, confirmDerived, ruleViolation, structure }
}
```

---

## 7. Acceptance criteria (design §16)

### 7.1 Golden-file (render fidelity) — the core test
Fixture input (all fictional): `DraftKind.noticeAppearance` + a fixed `SlotResolution` (the
"Harwell & Branch / Meridian v. Atlantic Ridge / 2026-CA-001847" set used in the design
renders) + `HouseStyleSheet.defaultFL`. Expected: a committed golden `word/document.xml` and
`word/styles.xml`. Test = render → **structural XML compare** using the shared SupraExports §6
normalizer (strip Word-only `rsid`/`w14`/proofing noise, normalize whitespace/attribute order,
then compare renderer-owned element trees) against the golden. Assertions the golden encodes:
- caption is a 2-cell `<w:tbl>` with `tblBorders` none, `tblLayout fixed`, grid `[4680,4680]`, total width `9360`;
- party left-cell paragraphs single-spaced (`w:line="240"`); one empty `<w:p>` between parties and around "v.";
- right cell: "CASE NO." then "DIVISION", consecutive, no blank;
- closing rule: bottom-bordered construct + "/" run at the ½ mark;
- title `<w:p>` center+bold+underline;
- body `<w:p>` `w:line="480" auto`, `w:ind firstLine="720"`, `jc both`; single blank between;
- signature block `ind left="4680"`, single-spaced; `/s/` = italic+underlined name + italic+underlined `<w:tab/>`(s), **no cell** (§4.2); **bold** "Primary and Secondary E-Mail:" label; *italic* "Attorneys for Defendant" as the **last** line of the block; **no** "Respectfully submitted" line;
- COS heading center+bold; body `w:line="240"`, `firstLine 720`; FL e-Portal clause text exact; "Counsel for Plaintiff" italic; sign-off name plain;
- `sectPr`: `titlePg`, empty first footer, default footer with `PAGE` field; `pgMar` 1440; `pgSz` 12240×15840.

### 7.2 Leakage / safety fixture (firewall — design §16.1, even for a slot-fill kind)
- **No-baked-identity:** render the kind with **slot set A** (firm A) and **slot set B** (firm B,
  disjoint values). Assert each `.docx` text contains **only its own** firm/attorney/email/party
  strings and none from the other set. Proves identity is slot-only and the template carries none.
- **Template purity:** assert `NoticeAppearance` body template + the kind's static text contain no
  `[A-Z][a-z]+ (Bar No\.|@)` / proper-name patterns — only `[slot]` tokens.

### 7.3 Deterministic-gate fixtures (unit tests)
- Notice assembled without a certificate → pre-file gate emits `.blocking structure`.
- `HouseStyleSheet` with `fontHalfPoints = 22` → `StyleSheetCompiler` emits `.ruleViolation` (2.520(a)).
- `serviceMethodClause = .flServedNotFiled` on a (filed) notice → rule-conformance flags (a notice of
  appearance is filed; the e-Portal/NEF clause applies — never the served-not-filed clause, §12.2).
- Missing `primaryEmail` → `.blocking missingSlot("primaryEmail")` (2.516 designation requires it).

---

## 8. Implementation decisions — RESOLVED via the round-tripped goldens
All of the original open items are now **locked** against `Docs/Fixtures/noticeAppearance-golden.docx`
(+ `motionToDismiss-golden.docx`); see SupraExports §7 for the construct status.
1. **The 2″ e-signature "underline" — ✅ LOCKED:** *not* a bordered cell. One paragraph: `"By: "` +
   italic+underlined name + italic+underlined `<w:tab/>`(s) to a pinned tab stop (§4.2). My earlier
   "bordered cell" lean was wrong.
2. **Closing caption rule — ✅ LOCKED:** paragraph bottom-border (`pBdr`) + right `"/"` (notice golden);
   a literal `____…/` run is the firm's accepted equivalent (motion golden).
3. **Named styles vs. direct formatting** — still the design call: prefer `StyleSheetCompiler` named
   styles so a firm's derived sheet flows through; direct formatting only for the underline tabs.
4. **"By: /s/ Name" on one line — ✅ LOCKED:** it's the single paragraph in #1; no table needed.
5. **Page-1 suppression — ✅ LOCKED:** `titlePg` + empty first-page footer + default `PAGE` footer;
   Word reproduced it verbatim in both goldens.

**Done = this slice renders byte-stable golden files, the leakage fixtures pass, and the gate
fixtures fire.** That is the proof the §1–§17 architecture survives real types; `motionToDismiss`
then adds the generation/firewall path on the same renderer + pipeline.
