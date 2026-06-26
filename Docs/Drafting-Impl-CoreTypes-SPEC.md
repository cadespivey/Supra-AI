# Implementation Spec — `SupraDraftingCore` (shared types & reconciled protocols)

> **Canonical home for cross-cutting types** referenced by the four slice impl specs
> (NoticeAppearance, MotionToDismiss, LetterDemand, SupraExports). Where a per-doc protocol
> declaration differs from this file, **this file wins** (it reconciles the inconsistencies
> the review found). The large *models* still live where first defined — slot model /
> `HouseStyleSheet` / `DocumentModel` / closing blocks in **NoticeAppearance §3**; generation /
> authority / verification-result types in **MotionToDismiss §1** — and reference the types
> below.

---

## 1. Reconciled protocols (supersede the per-doc declarations)

```swift
// ── Renderer: one signature for all shells (fixes the DocumentModel-vs-RenderInput split) ──
public protocol Renderer {
    func render(_ input: RenderInput, style: HouseStyleSheet) throws -> Data   // .docx bytes
}
public enum RenderInput: Sendable {
    case court(DocumentModel)     // courtFL / courtMDFL  (noticeAppearance, motionToDismiss)
    case letter(LetterModel)      // letterhead           (letterDemand)
}

// ── Verifier: one entry point that handles slot-fill, generated sections, and letters ──
public protocol Verifier {
    /// Async because authority validation may call CourtListener. Pure deterministic verifiers
    /// may return immediately.
    func verify(_ unit: VerifyUnit, kind: DraftKind, style: HouseStyleSheet) async -> VerificationResult
}
public enum VerifyUnit: Sendable {
    case wholeDocument(DocumentModel)                         // slot-fill kinds (noticeAppearance)
    case section(GeneratedSection, requirement: SectionRequirement,
                 facts: [GroundedFact], authorities: [VerifiedAuthority]) // generated Auth sections
    case letter(GeneratedLetter, model: LetterModel)          // whole-letter + provenance surface
}

public protocol SlotResolver {
    func resolve(_ spec: [SlotSpec], matter: MatterContext, profile: AssistantProfile)
        async -> (SlotResolution, [FollowUp])
}
public protocol Generator { func generate(_ parts: PromptParts) async throws -> GeneratedSection }
```

## 2. `Section` + `HeadingContract` (fixes the undefined enum / granularity mix)
```swift
public enum Section: String, Sendable, Equatable {
    case caption, title, body, wholeLetter    // body = generic body; wholeLetter = letter contract sentinel
    case introduction, statementOfFacts, memorandumOfLaw, argument, conclusion  // motion-granular
    case signature, certificateOfService
}
public struct HeadingContract: Sendable { public let required: [Section] }
```
A slot-fill kind uses coarse sections (`.body`); a `houseMotionFL` kind uses the granular set.
Both draw from the one enum, so the contract check (§8.2) is uniform.

## 3. Slot resolution (fixes the undefined `SlotResolution`)
```swift
public struct SlotResolution: Sendable {
    public let values: [String: SlotValue]    // keyed by SlotSpec.key
    public subscript(_ key: String) -> SlotValue? { values[key] }
}
```
(`SlotSpec`, `SlotValue`, `SlotType`, `SlotSource`, `Requirement`, `SlotContent`, `SlotState`,
`Provenance` are defined in **NoticeAppearance §3.1**.)

## 4. Supporting value types (the previously-undefined pile)
```swift
public struct DateOnly: Sendable, Equatable { public var year, month, day: Int }       // render via DateStyle
public enum DateStyle: Sendable { case monthDayYear }                                   // "July 21, 2026"
public struct EdgeInsets: Codable, Sendable { public var top, leading, bottom, trailing: Int }  // TWIPS (renamed from EdgeInsetsTwips)

public protocol MatterContext: Sendable {                       // thin wrapper over the existing matter store
    var metadata: [String: String] { get }                      // caption fields, parties, case no., division
    func retrieve(_ query: String, limit: Int) async -> [GroundedFact]   // DocumentRetrievalService
}
public struct GroundedFact: Sendable { public let text: String; public let label: String /* "[S1]" */; public let docId: String; public let locator: String }
public struct FactRef: Sendable, Equatable { public let label: String /* "[S#]" */ }
public struct CitationRef: Sendable, Equatable {
    public let raw: String                                       // "123 So. 3d 456" OR the literal "[cite]"
    public var isPlaceholder: Bool { raw == "[cite]" }
}
public enum ValidationResult: Sendable { case ok, invalid(String) }
// CiteValidity lives with CitatorClient in MotionToDismiss §1.2 (no duplicate here).

public enum SkeletonShape: Sendable { case crac, creac, irac, none }
public enum Numbering: Sendable { case none, numberedFacts }
public enum RepeatAxis: Sendable { case ground }
public struct SectionDef: Sendable {
    public let id: Section; public let generate: Bool
    public var decoding: Decoding = .grounded; public var numbering: Numbering = .none
    public var headingLevel: Int? = nil; public var skeletonShape: SkeletonShape = .none
    public var repeatPer: RepeatAxis? = nil; public var isWhereforePoint = false
}
public struct SectionRequirement: Sendable {
    public let section: Section; public let mustContain: [String]; public let elementKeys: [String]
    public static let wholeLetter = SectionRequirement(section: .wholeLetter, mustContain: [], elementKeys: [])
}

public enum GroundingPolicy: Sendable, Codable { case noMatterFacts, matterFactsRequired, authorityAndFacts }
public struct VoiceContext: Sendable { public let profile: AssistantProfile; public let toneOnly: Bool } // toneOnly == true ALWAYS in grounded kinds (§8.6)

// closing-block sub-types (used by NoticeAppearance §3.5 models)
public struct AttorneyLine: Sendable { public var name: String; public var barNumber: String }
public struct OfficeBlock: Sendable { public var street: String; public var suite: String?; public var city, state, zip: String; public var phone: String; public var fax: String? }
public struct EmailDesignation: Sendable { public var primary: String; public var secondary: [String] }  // 0–2
public struct ServiceRecipient: Sendable { public var name, firm: String; public var address: OfficeBlock; public var emails: [String]; public var role: String /* "Counsel for Plaintiff" */ }

// letterhead sub-types (LetterModel)
public struct AddressBlock: Sendable { public var name: String; public var title, firm: String?; public var street, city, state, zip: String }
public struct LetterheadFill: Sendable { public var firmName: String; public var office: OfficeBlock }   // from AssistantProfile slots

// generated-letter provenance surface (LetterDemand)
public struct GeneratedLetter: Sendable {
    public var paragraphs: [String]
    public var assertedFacts: [FactRef]
    public var citesUsed: [CitationRef]
}

public struct FollowUp: Sendable {
    public enum Severity: Sendable { case blocking, advisory }
    public enum Kind: Sendable { case missingSlot(String), conflict, verify, confirmDerived, ruleViolation, structure }
    public let severity: Severity; public let kind: Kind; public let message: String
}
public struct VerificationResult: Sendable { public var failures: [GateFailure]; public var followUps: [FollowUp] }
public struct GateFailure: Sendable { public let gate: Gate; public let detail: String; public let repair: RepairStrategy }
public enum Gate: Sendable { case contract, citationFormat, authorityValidity, ruleConformance, factProvenance, elementCompleteness }
public enum RepairStrategy: Sendable { case regenerate(maxPasses: Int), deterministicFix, stripToPlaceholderAndFlag }
public struct GateResult: Sendable { public var failures: [GateFailure]; public var followUps: [FollowUp] }
public struct DraftResult: Sendable { public var docx: Data; public var followUps: [FollowUp] }
```

**Swift access-control note:** every public DTO above and in the slice specs needs an explicit
`public init(...)` if it crosses module boundaries; Swift's synthesized memberwise initializers
are internal.

## 5. Errors (fixes the unspecified `throws`)
```swift
public enum DraftError: Error, Sendable {
    case styleFloorViolation(String)     // < 12pt or < 1" margin (2.520(a)) — StyleSheetCompiler
    case renderFailure(String)
    case missingRequiredSlot(String)     // a blocking slot the user must supply
    case packagingFailure(String)        // Zip/OPC assembly
}
```

(`Decoding`, `PromptParts`, `GeneratedSection`, `VerifiedAuthority`, `AuthSource`,
`CitatorClient`, `AuthorityResolver` are defined in **MotionToDismiss §1**. `VerificationResult`,
`GateFailure`, `Gate`, and `RepairStrategy` live here because the notice slice needs them before
`motionToDismiss` is implemented. `StructureTemplate` is **design §15.5** — optional/nil for the
slice, see each kind's flow.)
