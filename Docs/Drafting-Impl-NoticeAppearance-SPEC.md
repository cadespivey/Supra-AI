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

---

## 9. Draft menu UX repair and multi-kind selection — Codex review addendum

This addendum supersedes the current `MatterDraftingView` surface, which is a fixed
`560 x 640` sheet hard-wired to Notice of Appearance. The current view becomes cramped,
cuts off service-recipient fields, uses placeholder-only text fields that read like static
labels, and gives the user no way to choose a document kind or describe a different work
product.

### 9.1 Proposed interaction model

When the user clicks **Draft** in a matter workspace, open a **Draft Workspace** rather
than a one-kind dialog.

1. **Choose work product** comes first.
   - Show a compact picker/list backed by `DefaultDraftKindRegistry.defaultDefinitions`.
   - Enabled now: `noticeAppearance`.
   - Present but unavailable until wired: `motionToDismiss`, `letterDemand`, with a short
     disabled reason instead of silently hiding them.
   - Add `Custom / describe work product` for anything outside the wired catalog. It should
     show a large prose field where the user can describe the desired output in ordinary
     language.
2. **Fill required inputs** changes based on the selected work product.
   - Notice of Appearance shows caption parties, represented party/client, service date,
     and service recipients.
   - Custom description shows a required multiline "Describe the work product" field plus
     optional context/instructions. It should not pretend to produce a court-formatted DOCX
     unless a renderer/pipeline exists for that kind.
3. **Generate** uses a kind-specific action label:
   - `Generate Notice of Appearance`
   - `Generate work-product description`
   - Later, `Generate Motion to Dismiss`, `Generate Demand Letter`, etc.
4. Validation must explain missing requirements inline. Do not rely on a disabled button
   with no reason; show the missing fields near the footer or next to the affected section.

### 9.2 Resizable presentation

The drafting surface must be resizable on macOS. Preferred implementation:

- Promote the draft surface to a separate resizable window using `WindowGroup` / `openWindow`
  with a route containing the `matterID`, if that can be done cleanly in `SupraAIApp`.
- If staying with `.sheet` for the first repair, remove the fixed `.frame(width: 560,
  height: 640)` and use flexible constraints: minimum around `760 x 620`, ideal around
  `940 x 760`, and max width/height `.infinity`. The content must lay out correctly when
  widened and remain usable at the minimum size.
- Keep header and footer pinned; only the form content scrolls. The footer must never cover
  the last service-recipient field.
- Persisting the last size is nice-to-have, not required for the first pass.

### 9.3 Field design

Adopt the Settings-style field treatment for drafting inputs and the Edit Matter sheet.
This is a shared form-system repair, not a draft-only styling tweak.

- Extract the existing Settings `LabeledTextField` / `LeadingTextField` pattern into a
  reusable shared component. Do not leave it private to Settings if Drafting and Matters
  also need it.
- Every input must have a visible label outside the field. Placeholders may provide examples,
  but cannot be the only label.
- Single-line fields use rounded, bordered, left-aligned text boxes.
- Long legal values use scalable fields:
  - party names and client names should allow wrapping/growth;
  - street/address and role fields should not be squeezed into tiny HStacks;
  - matter description and notes in Edit Matter should use multiline/scalable fields;
  - the custom work-product description must use `MultilineField`.
- Use a responsive layout: two columns when the window is wide, one column when narrow.
  Avoid fixed widths like the `State` field's `.frame(width: 90)` in `MatterDraftingView.swift:138`
  unless they are inside a grid that leaves the main fields room to breathe. (The Settings
  exemplar itself uses `width: 72` for State — `SettingsView.swift:485`.)
- Add keyboard tab order and accessibility labels for every dynamic row, especially party
  and service-recipient rows.

`MatterEditorSheet` must consume the same shared fields:

- Required: Matter name, Jurisdiction/court search, and Client perspective must read as
  explicit controls, not a label/value table.
- Optional: Client names, Matter description, Court, Judge, Case number, Practice area,
  Notes, and LEDES IDs must all use visible labels and bordered entry regions.
- The jurisdiction autocomplete row needs the same bordered search field treatment, while
  keeping suggestions, N/A/Clear actions, and validation text intact.
- Avoid right-aligned typed values in the grouped form; user-entered text should flow from
  the left like Settings.

### 9.4 Controller/API changes

Do not keep adding one-off UI calls like `draftNoticeOfAppearance(...)` as the only public
entry point. Keep that method as the implementation for the existing kind, but add a small
request layer for the UI:

```swift
public enum MatterDraftRequest: Sendable, Equatable {
    case noticeAppearance(NoticeAppearanceDraftInput)
    case customDescription(CustomDraftDescriptionInput)
}

public struct DraftKindAvailability: Sendable, Equatable, Identifiable {
    public var id: DraftKindID
    public var title: String
    public var isEnabled: Bool
    public var disabledReason: String?
}

public struct CustomDraftDescriptionInput: Sendable, Equatable {
    public var title: String
    public var description: String
    public var instructions: String
}
```

`MatterDraftingController` should expose:

- `availableDraftKinds() -> [DraftKindAvailability]`, sourced from the registry and the
  controller's actually wired generation paths.
- `draft(_ request: MatterDraftRequest) async -> Result<DraftArtifact, DraftError>`.

For this repair, `draft(.noticeAppearance(...))` dispatches to the existing deterministic
pipeline. `draft(.customDescription(...))` may initially create a structured plain-text /
markdown artifact or route through the existing drafting model path, but it must clearly
label the output as a description/request, not a court-ready rendered filing.

Also update the result model so it can represent custom artifacts without forcing them into
`DraftKindID`. For example, add an `artifactType` / `format` field and make the draft kind
optional, or introduce a wrapper enum such as `MatterDraftArtifactSource.kind(DraftKindID)` /
`.customDescription`. Do not add a fake `DraftKindID.custom` unless the drafting registry,
renderer, and tests all genuinely support it.

### 9.5 File-by-file implementation plan

Edited:

- `Apps/SupraAI/SupraAI/Matters/MatterWorkspaceView.swift` — open the new resizable Draft
  Workspace instead of the fixed Notice-only sheet.
- `Apps/SupraAI/SupraAI/Matters/MatterDraftingView.swift` — split into a work-product picker,
  shared shell, `NoticeAppearanceForm`, `CustomDescriptionForm`, result section, and pinned
  footer.
- `Apps/SupraAI/SupraAI/Matters/MatterEditorSheet.swift` — replace placeholder-only grouped
  form rows with the same labeled/bordered fields and make long values scalable.
- `Apps/SupraAI/SupraAI/SettingsView.swift` or a new shared component file — extract the
  Settings-style labeled text field so drafting uses the same identifiable input boxes.
- `Packages/SupraSessions/Sources/SupraSessions/MatterDraftingController.swift` — add request
  dispatch and availability metadata while preserving `draftNoticeOfAppearance` internally.

New if useful:

- `Apps/SupraAI/SupraAI/Matters/DraftInputField.swift` — reusable labeled field wrappers for
  single-line and multiline draft inputs.
- `Apps/SupraAI/SupraAI/Matters/DraftKindPicker.swift` — registry-backed work-product chooser.

Tests:

- UI smoke test opens Draft Workspace, selects Notice of Appearance, resizes wider/taller, and
  verifies the footer does not overlap the recipient fields.
- UI/accessibility test verifies all visible entry boxes have labels independent of placeholder
  text in both Draft Workspace and Edit Matter.
- UI smoke test opens Edit Matter, verifies required/optional fields have visible bordered
  entry boxes, and confirms long matter descriptions/notes expand without overlapping rows.
- Controller test verifies availability reports Notice of Appearance enabled and unwired kinds
  disabled with reasons.
- Controller test verifies custom description requires non-empty description text and returns a
  clearly labeled plain-text/markdown artifact until a rendered pipeline is wired.

### 9.6 Phasing

1. Extract/shared labeled field components and apply them to Edit Matter first, since it is
   the smaller surface and proves the component.
2. Resizable shell + Settings-style labeled fields for the existing Notice of Appearance flow.
3. Work-product picker with disabled-but-visible catalog kinds and inline validation.
4. Custom description path and controller request wrapper.
5. Wire additional kinds (`letterDemand`, then `motionToDismiss`) behind the same picker when
   their pipelines are ready.

## 10. Research Session planner repair — Codex review addendum

The "New Research Session" planner (`ResearchPlannerView`) has the same form-field and
presentation defects this addendum already catalogues for the drafting surface, plus a
distinct model-routing defect that makes query generation fail on simple questions. The
two field/presentation fixes reuse the shared components from §9.2–§9.3; the routing fix
is planner-specific.

### 10.1 Field design — reuse the §9.3 components

`ResearchPlannerView` currently builds the "Legal issue or question" input with
`TextField(..., axis: .vertical).lineLimit(3...6)`
([`ResearchPlannerView.swift`](../Apps/SupraAI/SupraAI/Research/ResearchPlannerView.swift) §"Issue").
On macOS that control commits-and-reselects on Return instead of inserting a newline, has
no visible border, and does not grow past six lines — the exact problem §9.3 fixes.

- Replace the issue field with the existing `MultilineField`
  (`Apps/SupraAI/SupraAI/MultilineField.swift`): it is bordered, auto-grows from
  `minLines`, and inserts real line breaks on Return. Use `minLines: 4` so a multi-sentence
  issue has room.
- The single-line filter fields ("Additional preferred courts", "Excluded courts") and the
  "Title" field must adopt the same Settings-style labeled/bordered single-line treatment
  §9.3 extracts, with a visible label outside the field — not placeholder-only labels.
- The per-query editor rows in the "Proposed Queries" section use plain `TextField("Query",
  …)`. A query can be long; give it the same bordered single-line (or growing) treatment so
  it reads as an editable field, not a label.

### 10.2 Resizable presentation — reuse the §9.2 rule

The planner is shown as a `.sheet` and hard-pins itself to `.frame(width: 600, height: 740)`
(`MatterResearchView.swift` presents it; the fixed frame is set at the bottom of
`ResearchPlannerView.body`). Apply the §9.2 rule:

- Remove the fixed `.frame(width: 600, height: 740)`. Use flexible constraints: minimum
  around `560 x 640`, ideal around `680 x 780`, max width/height `.infinity`. Content must
  stay usable at the minimum and lay out correctly when widened.
- Keep the "New Research Session" header and the Cancel / "N approved" / Save Plan footer
  pinned; only the `Form` scrolls. The footer must never cover the last query row.
- Persisting the last size is nice-to-have, not required.

### 10.3 Model-routing defect — query generation returns zero queries

**Symptom.** On a plain question of law (observed: "Does the Uniform Commercial Code apply
to sales of goods less than $500?") the planner runs a long analysis and then reports "no
recommended queries," even though search terms are trivial to produce.

**Root cause.** Query generation reuses the heavyweight `.legalResearch` preset, which is
tuned for long-form substantive research answers, not structured extraction:

- `ResearchPlannerView` (`ResearchPlannerView.swift:139-141`) builds the route via
  `ModelRouter(configuration: .fromEnvironment()).route(for: .legalResearch)` and passes it
  into `controller.generatePlan(... route: route)` (`:197`). `generatePlan`
  (`ResearchSessionController.swift:225`) uses `route ?? ModelRouter().route(for:
  .legalResearch)` — so the **view-supplied** `.legalResearch` route wins, and the bare
  `ModelRouter()` form is only the fallback when no route is passed. Either way,
  `collect(...)` (`ResearchSessionController.swift:763-774`) forwards
  `route.options` to the runtime **verbatim** (`options: route?.options ?? GenerationOptions()`).
  The `.legalResearch` preset carries `thinkingBudget: .high` and `maxOutputTokens: 6000`
  (`GenerationOptions.swift:181`, `generationParameters`).
- With high thinking enabled, a reasoning model spends most of its budget *answering the
  legal question* inside a `<think>` trace instead of emitting the `## Query N` template.
- `ResearchQueryPlanner.parseQueries` calls `ReasoningContent.answer(from:)`, which splits
  on `</think>`. If the output truncates before the close tag, the entire chain-of-thought
  is returned as the "answer"; if thinking closes and the model writes a prose conclusion,
  there is still no `## Query` heading. Either way the parser finds zero queries and the
  controller reports the generic `.incomplete("Query generation didn't return any
  queries.")`.

The prompt template (`research-query-generation-v1.md`) is already correct — it says
"Output only the Markdown below — no commentary." The defect is the **route**, not the
prompt: a deterministic 5-query extraction is being run through the app's heaviest
reasoning preset.

**Fix.**

1. **Stop reusing `.legalResearch` options for query planning.** Query generation needs a
   short, deterministic, thinking-off route. **Chosen path (lowest-risk): override the
   options inside `ResearchSessionController.collect(...)`.** `collect(...)` is the single
   generation chokepoint for planning (its only caller is `generatePlan`, line 244), so
   forcing `thinkingBudget = .off` and capping `maxOutputTokens` (~1024) there fixes both the
   view-supplied route and the bare-`ModelRouter()` fallback at once, with no SupraCore enum
   churn and no view edit. With thinking off, the model emits the `## Query N` structure
   directly and the existing parser succeeds.
   - Alternative (dedicated preset) — only if presets-as-single-source-of-truth is worth the
     churn: add `GenerationPreset.legalQueryPlanning` with `(temperature 0.15, topP 0.85,
     topK 20, maxContextTokens 32_768, maxOutputTokens ~1024, thinkingBudget .off,
     repetitionPenalty nil)`. If you take this path you **must** add the case to BOTH
     exhaustive `switch self` statements — `displayName` (`GenerationOptions.swift:145-156`)
     and `generationParameters` (`GenerationOptions.swift:167-189`) — or SupraCore won't
     compile, and you must **leave it out of** `userSelectableDefaults`
     (`GenerationOptions.swift:115-120`), which `GenerationPresetTests.swift:69` asserts
     equals exactly `[.balanced, .precise, .drafting, .extractive]`. The preset must then be
     wired into what the **view** computes at `ResearchPlannerView.swift:141` (and the
     controller fallback at `:225`), not just one of them. The `collect()` override avoids
     all of this.
2. **Report truncated reasoning honestly.** In `generatePlan` (around
   `ResearchSessionController.swift:244-253`), after `collect(...)`, resolve the raw output
   *before* parsing: `ReasoningContent.resolve(rawOutput: output, thinkingEnabled:
   effectiveRoute.options.thinkingBudget.enablesModelThinking)`. On `.truncatedReasoning`,
   set a distinct `planState` message ("The model ran out of room while thinking — try
   again, or add queries manually.") and do **not** call `parseQueries` — required because
   `parseQueries` internally calls `ReasoningContent.answer(from:)`
   (`ResearchQueryPlanner.swift:50`), which returns a partial CoT unchanged when there is no
   `</think>`. On `.answer(text)`, pass the resolved text to `parseQueries`. This is the
   first production adopter of `resolve(...)` (the ~10 existing sites use `answer(from:)`).
   With the chosen thinking-off path this branch is mostly defensive, but it makes a future
   thinking-on planner safe.
3. **Parser salvage (optional hardening).** When the resolved answer contains no `## Query`
   heading but does contain candidate lines (a numbered list, or quoted phrases), salvage up
   to `expectedQueryCount` of them rather than returning zero. Lower priority once (1) lands;
   keep it behind a clear fallback path so it never masks a real generation failure.

### 10.4 File-by-file implementation plan

Edited:

- `Packages/SupraSessions/Sources/SupraSessions/ResearchSessionController.swift` — **the
  whole routing fix lives here.** In `collect(...)` derive planning options from the route
  (force `thinkingBudget = .off`, cap `maxOutputTokens`) instead of forwarding `route.options`
  verbatim; in `generatePlan` resolve via `ReasoningContent.resolve` before `parseQueries` and
  report truncated reasoning distinctly.
- `Apps/SupraAI/SupraAI/Research/ResearchPlannerView.swift` — swap the issue `TextField` for
  `MultilineField` with a visible caption label; remove the fixed `.frame(width: 600, height:
  740)` and apply the §10.2 flexible constraints with pinned header/footer.
- **Do NOT touch `route(forStructuredOutput:)`'s `.researchPlan` case** (`ModelRouting.swift:262`).
  The per-query planner never calls that API — it routes via `route(for: .legalResearch)`
  (view `:141` → `generatePlan` → `collect` `:225/:244/:772`). `route(forStructuredOutput:
  .researchPlan)` feeds the *separate* Matter Outputs / structured-output surface
  (`StructuredOutputController.swift:172`, `MatterOutputsView.swift:86`); editing it would not
  fix the planner and would change an unrelated feature.
- `Packages/SupraResearch/Sources/SupraResearch/ResearchQueryPlanner.swift` — only if
  implementing §10.3(3) salvage; otherwise unchanged.

### 10.5 Tests

- Planner-parsing test: a raw output that is pure `<think>…` with no `</think>` (truncated)
  resolves to truncated-reasoning, NOT to an answer, and the controller reports the distinct
  message rather than "didn't return any queries."
- Planner-parsing test: a well-formed `# Research Queries` / `## Query N` block still parses
  to five queries (regression guard on the happy path).
- Routing test: the query-planning route reports `thinkingBudget == .off` and a bounded
  `maxOutputTokens`, and is not the `.legalResearch` preset.
- UI smoke test: open New Research Session, type a multi-line issue with a Return in the
  middle (verify the newline is inserted, not a commit), resize the sheet wider/taller, and
  confirm the footer never covers the query rows.
- UI/accessibility test: every visible entry box in the planner has a label independent of
  placeholder text.

### 10.6 Phasing

1. Routing fix first (§10.3 items 1–2): it is the functional defect and is independently
   testable with parser/routing unit tests, no UI work required.
2. Field design (§10.1) reusing the §9.3 shared components.
3. Resizable presentation (§10.2).
4. Optional parser salvage (§10.3 item 3) only if real-world generations still under-produce
   after the routing fix.

## 11. App-wide form-field and resizable-sheet sweep — Codex review addendum

§9 and §10 fix the same two defects (placeholder-only `TextField(axis: .vertical)` prose
fields, and fixed-frame non-resizable sheets) on the drafting, Edit Matter, and research
surfaces. The same two anti-patterns recur on several more surfaces — the "Ask the
Documents" panel screenshotted in review is one. Fix them in one sweep using the shared
`MultilineField` (already in the app target and already proven inside Settings' grouped
`Form`) rather than one screen per bug report. Compare every one of these against the Settings
field treatment: a visible label outside the field, a bordered/rounded entry region, and prose
fields that grow and accept a Return as a line break. Match Settings' label idiom — a
`VStack(alignment: .leading, spacing: 4)` with `Text(label).font(.caption).foregroundStyle(.secondary)`
above the `MultilineField` (see `SettingsView.swift:224-229`).

> **Implemented (pass 1 — defect sweep).** The routing fix (§10.3), every prose-field →
> `MultilineField` conversion (§9.3 multiline rows, §10.1, §11.1) with a visible label, every
> resizable-sheet fix (§9.2, §10.2, §11.2), and Shift-Return on the composers (§11.3).
>
> **Implemented (pass 2 — multi-kind drafting, §9.1/§9.4).** `MatterDraftingController` now exposes
> `availableDraftKinds()`, `draft(_ request: MatterDraftRequest, matterID:)`, and
> `draftCustomDescription(...)`, with `MatterDraftRequest` / `NoticeAppearanceDraftInput` /
> `CustomDraftDescriptionInput` / `DraftKindAvailability`. `DraftArtifact` now carries
> `source: MatterDraftArtifactSource` (`.kind`/`.customDescription`) + `format` (`.docx`/`.markdown`)
> instead of a bare `DraftKindID` — no fake `.custom` kind. `MatterDraftingView` became a Draft
> Workspace: a work-product picker (wired kinds enabled; motion/letter shown disabled-with-reason;
> a Custom option), per-kind forms, a kind-specific Generate label, and inline validation, all
> routed through `draft(_:)`. The custom path writes a clearly-labeled markdown description (the
> user's own words + matter context — no LLM, firewall intact).
>
> **Implemented (pass 3 — field restyle + Demand Letter).** (a) `LabeledTextField`/`LeadingTextField`
> were moved out of `SettingsView` into the shared `MultilineField.swift` (internal), and Edit
> Matter's single-line fields (name, court, judge, case number, practice area, LEDES IDs) now use
> them — visible labels, bordered, left-aligned. (b) The **`letterDemand` generator is wired**:
> `MatterDraftingController.draftLetterDemand(matterID:input:modelID:route:)` builds grounded facts
> from the user's claim/amount/deadline, generates the body with the on-device drafting model via
> `RuntimeLetterGenerator` (a `LetterGenerator` that emits no citations), and renders the `.docx`
> through the existing `runLetter` pipeline (verifier + pre-file gate + letterhead). The Draft
> Workspace gained a Demand Letter form + model resolution; `letterDemand` enables only when a
> runtime is present. Firewall: the model sees only the user's grounded facts and is told not to
> invent facts or cite law; the attorney reviews every line.
>
> **Still deferred:** wiring real generation for `motionToDismiss` (the milestone — it needs
> CourtListener citation verification + the authority firewall + multi-section grounded generation;
> it stays disabled-with-reason, routable via Custom); and an LLM-routed *custom* path (today the
> custom path is deterministic — the user's own words, not model-generated prose).

### 11.1 Prose fields to convert to `MultilineField`

These are form fields (not chat composers — see §11.3) where Return should insert a newline
and the box should be bordered and auto-growing:

- `Apps/SupraAI/SupraAI/Documents/MatterDocumentsView.swift` — "Your question" in the Ask
  the Documents panel (`TextField("Your question", axis: .vertical).lineLimit(2...4)`). Give
  it a visible "Your question" label and `MultilineField(minLines: 3)`.
- `Apps/SupraAI/SupraAI/Outputs/MatterOutputsView.swift` — "Issue, facts, or notes for this
  output."
- `Apps/SupraAI/SupraAI/Authorities/AuthorityDetailView.swift` — "User notes."
- `Apps/SupraAI/SupraAI/ScratchPad/BillingDraftView.swift` — "Narrative" (already
  `.roundedBorder`, but still commits on Return; move to `MultilineField` for newline
  support and consistency).
- (Already covered: `ResearchPlannerView` issue field in §10.1; `MatterEditorSheet` client
  names / description / notes in §9.3.)

### 11.2 Sheets to make resizable

Apply the §9.2 rule (remove the fixed `.frame(width:height:)`, use min/ideal/max with pinned
header + footer, only the body scrolls):

- `Apps/SupraAI/SupraAI/Documents/MatterDocumentsView.swift` — Ask the Documents sheet
  (`.frame(width: 620, height: 600)`) and the Document Chronology sheet
  (`.frame(width: 640, height: 620)`). Both grow useful content (Q&A answer, chronology
  table) and must be resizable; the answer/result region should take the extra height.
- `Apps/SupraAI/SupraAI/Outputs/MatterOutputsView.swift` — new-output sheet
  (`.frame(width: 520, height: 600)`).
- `Apps/SupraAI/SupraAI/ScratchPad/BillingDraftView.swift` — `EditLineSheet`, the LEDES line
  editor (`.frame(width: 520)` at `:350`, presented via `.sheet(item: $editing)` at `:38`).
  This is the **same** sheet whose "Narrative" field §11.1 grows to `MultilineField`, so it
  must be widenable or the grown field has no horizontal room. It is **width-only** today (no
  height frame — it sizes to content), so just unlock width: `.frame(minWidth: 480,
  idealWidth: 560, maxWidth: .infinity)`. Do not impose a fixed height.
- `Apps/SupraAI/SupraAI/ModelsView.swift` — `ModelDownloadSheet` (`.frame(width: 580)` at
  `:588`, `.sheet(isPresented: $showDownloadSheet)`). Width-only; swap for `.frame(minWidth:
  480, idealWidth: 580, maxWidth: .infinity)` so long repo IDs/notes get room. Its body is a
  plain `VStack`/`ForEach` (not scrollable), so if height resizing is also wanted, wrap the
  body in a `ScrollView` first to avoid clipping. Lower priority (no prose field).
- (Already covered: `ResearchPlannerView` 600×740 in §10.2; `MatterDraftingView` 560×640 and
  `MatterEditorSheet` 560×620 in §9.)

### 11.3 Composers — keep Return-to-send, make Shift-Return insert a newline

The chat and note composers use `TextField(axis: .vertical)` with `.onSubmit` on purpose:
Return *sends*, and the single rounded-border pill is the intended chrome. Do **not** convert
them to `MultilineField` — that would break Return-to-send. Instead, the prescribed line-break
affordance is **Shift-Return → insert a newline** (with plain Return still sending and
⌘-Return kept as the explicit send shortcut on the button).

Two code sites cover all three surfaces the user named:

- `Apps/SupraAI/SupraAI/GlobalChatsView.swift` — the `inputBox` composer
  (`TextField(..., axis: .vertical).onSubmit(send)`). This component is reused **inline** by
  the matter Chat tab (`MatterWorkspaceView` instantiates `GlobalChatsView(... listStyle:
  .inline)`), so fixing `inputBox` fixes **both** global chat and matter chat — there is no
  separate matter-chat composer to touch.
- `Apps/SupraAI/SupraAI/ScratchPad/ScratchPadView.swift` — the note composer
  (`TextField(..., axis: .vertical).onSubmit(submit)`, with ⌘-Return on the send button).

Implementation:

- On macOS, a vertical-axis `TextField` with `.onSubmit` already routes plain Return to
  submit and Shift-Return to a newline. **Verify** this holds in the running app first; if it
  does, the only change is a discoverability hint (e.g. a `.help`/placeholder note such as
  "⇧�return for a new line"). Do not add redundant handlers that could double-fire `send`.
- If the default does not reliably insert the newline, make it deterministic with
  `.onKeyPress(.return)`: when `press.modifiers.contains(.shift)` return `.ignored` (let the
  field insert the newline); otherwise call `send`/`submit` and return `.handled`. If you take
  this path, **remove** the now-redundant `.onSubmit` so Return cannot send twice. `.onKeyPress`
  is macOS 14+, which is within the app's deployment target.
- Keep the `canSend`/disabled guards and the ⌘-Return button shortcut unchanged.

Add one small UI test asserting that Shift-Return on the composer increases the draft's line
count without sending, and plain Return sends and clears the draft.

### 11.4 Tests and phasing

- Reuse the §9/§10 UI/accessibility tests, extended to assert that the Ask the Documents
  question field, the new-output context field, and the authority notes field each have a
  visible label, accept a Return as a newline, and grow with content.
- Resizable smoke tests for the Ask the Documents and Chronology sheets: widen/heighten and
  confirm the footer never covers the last field and the result region absorbs the slack.
- Phasing: land §11 together with the §9.3 shared-component extraction — once the shared
  labeled field and `MultilineField` adoption pattern exist, these conversions are
  mechanical and should all go in the same sweep so the app reads consistently.
