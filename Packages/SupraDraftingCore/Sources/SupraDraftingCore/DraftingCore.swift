import Foundation

public enum DraftError: Error, Sendable, Equatable {
    case styleFloorViolation(String)     // < 12pt or < 1" margin (2.520(a)) — StyleSheetCompiler
    case renderFailure(String)
    case missingRequiredSlot(String)     // a blocking slot the user must supply
    case packagingFailure(String)        // Zip/OPC assembly
}

public enum DraftKindID: String, Codable, CaseIterable, Sendable, Equatable {
    case noticeAppearance
    case motionToDismiss
    case letterDemand
}

public enum RenderShell: String, Codable, Sendable, Equatable {
    case courtFL
    case courtMDFL
    case courtGA
    case letterhead
    case internalMemo
    case chronologyTable
    case agreement
}

public enum AnalyticalSkeleton: String, Codable, Sendable, Equatable {
    case none
    case irac
    case crac
    case creac
    case houseMotionFL
    case countPerClaim
    case perRequest
    case clauseAssembly
    case chronology
}

public enum DraftBlockType: String, Codable, Sendable, Equatable {
    case routedSkill
    case contract
    case servicePipeline
}

public enum GroundingPolicy: String, Codable, Sendable, Equatable {
    case noMatterFacts
    case matterFactsRequired
    case authorityAndFacts
}

public struct DraftKindDefinition: Codable, Sendable, Equatable {
    public var id: DraftKindID
    public var renderShell: RenderShell
    public var defaultSkeleton: AnalyticalSkeleton
    public var blockType: DraftBlockType
    public var groundingPolicy: GroundingPolicy
    public var assertsLegalAuthority: Bool
    public var slotSpecs: [SlotSpec]
    public var headingContract: HeadingContract

    public var requiresFactProvenance: Bool { groundingPolicy != .noMatterFacts }

    public init(
        id: DraftKindID,
        renderShell: RenderShell,
        defaultSkeleton: AnalyticalSkeleton,
        blockType: DraftBlockType,
        groundingPolicy: GroundingPolicy,
        assertsLegalAuthority: Bool,
        slotSpecs: [SlotSpec],
        headingContract: HeadingContract
    ) {
        self.id = id
        self.renderShell = renderShell
        self.defaultSkeleton = defaultSkeleton
        self.blockType = blockType
        self.groundingPolicy = groundingPolicy
        self.assertsLegalAuthority = assertsLegalAuthority
        self.slotSpecs = slotSpecs
        self.headingContract = headingContract
    }
}

public enum Section: String, Codable, Sendable, Equatable {
    case caption
    case title
    case body
    case wholeLetter
    case introduction
    case statementOfFacts
    case memorandumOfLaw
    case argument
    case conclusion
    case signature
    case certificateOfService
}

public struct HeadingContract: Codable, Sendable, Equatable {
    public var required: [Section]

    public init(required: [Section]) {
        self.required = required
    }
}

public struct SectionRequirement: Sendable, Equatable {
    public var section: Section
    public var mustContain: [String]
    public var elementKeys: [String]

    public static let wholeLetter = SectionRequirement(section: .wholeLetter, mustContain: [], elementKeys: [])

    public init(section: Section, mustContain: [String], elementKeys: [String]) {
        self.section = section
        self.mustContain = mustContain
        self.elementKeys = elementKeys
    }
}

public struct DateOnly: Codable, Sendable, Equatable {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }
}

public enum DateStyle: String, Codable, Sendable, Equatable {
    case monthDayYear
}

public struct EdgeInsets: Codable, Sendable, Equatable {
    public var top: Int
    public var leading: Int
    public var bottom: Int
    public var trailing: Int

    public init(top: Int, leading: Int, bottom: Int, trailing: Int) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }
}

public indirect enum SlotType: Codable, Sendable, Equatable {
    case text
    case date
    case money
    case citation
    case partyRef
    case enumValue([String])
    case email
    case officeBlock
    case addressBlock
    case serviceRecipientList
    case list(SlotType)
}

public enum SlotSource: String, Codable, Sendable, Equatable {
    case matterMetadata
    case matterDocument
    case assistantProfile
    case partyModel
    case rulesPack
    case userPrompt
}

public enum Requirement: Codable, Sendable, Equatable {
    case required
    case optional
    case conditional(on: String)
}

public enum SlotValidatorKey: String, Codable, Sendable, Equatable {
    case none
    case caseNumberFormat
    case emailFormat
}

public struct SlotSpec: Codable, Sendable, Equatable {
    public var key: String
    public var type: SlotType
    public var source: SlotSource
    public var requirement: Requirement
    public var validator: SlotValidatorKey

    public init(key: String, type: SlotType, source: SlotSource, requirement: Requirement, validator: SlotValidatorKey) {
        self.key = key
        self.type = type
        self.source = source
        self.requirement = requirement
        self.validator = validator
    }
}

public struct AttorneyLine: Codable, Sendable, Equatable {
    public var name: String
    public var barNumber: String

    public init(name: String, barNumber: String) {
        self.name = name
        self.barNumber = barNumber
    }
}

public struct OfficeBlock: Codable, Sendable, Equatable {
    public var street: String
    public var suite: String?
    public var city: String
    public var state: String
    public var zip: String
    public var phone: String
    public var fax: String?

    public init(street: String, suite: String?, city: String, state: String, zip: String, phone: String, fax: String?) {
        self.street = street
        self.suite = suite
        self.city = city
        self.state = state
        self.zip = zip
        self.phone = phone
        self.fax = fax
    }
}

public struct EmailDesignation: Codable, Sendable, Equatable {
    public var primary: String
    public var secondary: [String]

    public init(primary: String, secondary: [String]) {
        self.primary = primary
        self.secondary = secondary
    }
}

public struct ServiceRecipient: Codable, Sendable, Equatable {
    public var name: String
    public var firm: String
    public var address: OfficeBlock
    public var emails: [String]
    public var role: String

    public init(name: String, firm: String, address: OfficeBlock, emails: [String], role: String) {
        self.name = name
        self.firm = firm
        self.address = address
        self.emails = emails
        self.role = role
    }
}

public struct AddressBlock: Codable, Sendable, Equatable {
    public var name: String
    public var title: String?
    public var firm: String?
    public var street: String
    public var city: String
    public var state: String
    public var zip: String

    public init(name: String, title: String?, firm: String?, street: String, city: String, state: String, zip: String) {
        self.name = name
        self.title = title
        self.firm = firm
        self.street = street
        self.city = city
        self.state = state
        self.zip = zip
    }
}

public struct CitationRef: Codable, Sendable, Equatable {
    public var raw: String
    public var isPlaceholder: Bool { raw == "[cite]" }

    public init(raw: String) {
        self.raw = raw
    }
}

public enum SlotContent: Sendable, Equatable {
    case text(String)
    case date(DateOnly)
    case money(Decimal, currency: String)
    case citation(CitationRef)
    case partyLines([PartyLine])
    case office(OfficeBlock)
    case address(AddressBlock)
    case serviceRecipients([ServiceRecipient])
    case list([SlotContent])

    public var serviceRecipientValues: [ServiceRecipient]? {
        guard case let .serviceRecipients(values) = self else { return nil }
        return values
    }
}

public enum SlotState: String, Codable, Sendable, Equatable {
    case derived
    case confirmed
    case missing
}

public enum Provenance: Codable, Sendable, Equatable {
    case matterDocument(id: String, locator: String)
    case assistantProfile
    case partyModel
}

public struct SlotValue: Sendable, Equatable {
    public var key: String
    public var content: SlotContent
    public var provenance: Provenance?
    public var state: SlotState

    public init(key: String, content: SlotContent, provenance: Provenance?, state: SlotState) {
        self.key = key
        self.content = content
        self.provenance = provenance
        self.state = state
    }
}

public struct SlotResolution: Sendable, Equatable {
    public var values: [String: SlotValue]

    public subscript(_ key: String) -> SlotValue? { values[key] }

    public init(values: [String: SlotValue]) {
        self.values = values
    }
}

public struct PageSetup: Codable, Sendable, Equatable {
    public var widthTwips: Int
    public var heightTwips: Int
    public var marginTwips: EdgeInsets
    public var fontName: String
    public var fontHalfPoints: Int
    public var suppressFirstPageNumber: Bool

    public init(
        widthTwips: Int = 12240,
        heightTwips: Int = 15840,
        marginTwips: EdgeInsets = EdgeInsets(top: 1440, leading: 1440, bottom: 1440, trailing: 1440),
        fontName: String = "Times New Roman",
        fontHalfPoints: Int = 24,
        suppressFirstPageNumber: Bool = true
    ) {
        self.widthTwips = widthTwips
        self.heightTwips = heightTwips
        self.marginTwips = marginTwips
        self.fontName = fontName
        self.fontHalfPoints = fontHalfPoints
        self.suppressFirstPageNumber = suppressFirstPageNumber
    }
}

public enum LineSpacing: String, Codable, Sendable, Equatable {
    case single
    case double
}

public struct BodyStyle: Codable, Sendable, Equatable {
    public var lineSpacing: LineSpacing
    public var firstLineIndentTwips: Int
    public var blankBreakIsSingleLine: Bool
    public var justify: Bool

    public init(lineSpacing: LineSpacing = .double, firstLineIndentTwips: Int = 720, blankBreakIsSingleLine: Bool = true, justify: Bool = true) {
        self.lineSpacing = lineSpacing
        self.firstLineIndentTwips = firstLineIndentTwips
        self.blankBreakIsSingleLine = blankBreakIsSingleLine
        self.justify = justify
    }
}

public struct CaptionStyle: Codable, Sendable, Equatable {
    public var tableWidthTwips: Int
    public var leftCellWidthTwips: Int
    public var rightCellWidthTwips: Int
    public var cellMarginTwips: Int
    public var singleSpaced: Bool
    public var closingRuleEndsInSlash: Bool
    public var headerBoldCentered: Bool

    public init(
        tableWidthTwips: Int = 9360,
        leftCellWidthTwips: Int = 4680,
        rightCellWidthTwips: Int = 4680,
        cellMarginTwips: Int = 10,
        singleSpaced: Bool = true,
        closingRuleEndsInSlash: Bool = true,
        headerBoldCentered: Bool = true
    ) {
        self.tableWidthTwips = tableWidthTwips
        self.leftCellWidthTwips = leftCellWidthTwips
        self.rightCellWidthTwips = rightCellWidthTwips
        self.cellMarginTwips = cellMarginTwips
        self.singleSpaced = singleSpaced
        self.closingRuleEndsInSlash = closingRuleEndsInSlash
        self.headerBoldCentered = headerBoldCentered
    }
}

public struct HeadingLadder: Codable, Sendable, Equatable {
    public var baseIndentTwips: Int

    public init(baseIndentTwips: Int = 720) {
        self.baseIndentTwips = baseIndentTwips
    }
}

public struct ESignatureStyle: Codable, Sendable, Equatable {
    public var italic: Bool
    public var underline: Bool
    public var underlineTabStopTwips: Int

    public init(italic: Bool = true, underline: Bool = true, underlineTabStopTwips: Int = 2880) {
        self.italic = italic
        self.underline = underline
        self.underlineTabStopTwips = underlineTabStopTwips
    }
}

public struct SignatureStyle: Codable, Sendable, Equatable {
    public var leftIndentTwips: Int
    public var singleSpaced: Bool
    public var firmNameBoldCaps: Bool
    public var representationLineItalic: Bool
    public var eSignature: ESignatureStyle

    public init(leftIndentTwips: Int = 4680, singleSpaced: Bool = true, firmNameBoldCaps: Bool = true, representationLineItalic: Bool = true, eSignature: ESignatureStyle = ESignatureStyle()) {
        self.leftIndentTwips = leftIndentTwips
        self.singleSpaced = singleSpaced
        self.firmNameBoldCaps = firmNameBoldCaps
        self.representationLineItalic = representationLineItalic
        self.eSignature = eSignature
    }
}

public enum ServiceMethodClause: String, Codable, Sendable, Equatable {
    case flEPortal
    case flServedNotFiled
    case federalCMECF
    case mailFirstClass
    case mailRegisteredRRR
}

public struct CertificateStyle: Codable, Sendable, Equatable {
    public var headingCenteredBoldCaps: Bool
    public var bodySingleSpaced: Bool
    public var bodyFirstLineIndentTwips: Int
    public var serviceListSingleSpaced: Bool
    public var counselLineItalic: Bool
    public var signOffNamePlainSentenceCase: Bool
    public var serviceMethodClause: ServiceMethodClause

    public init(
        headingCenteredBoldCaps: Bool = true,
        bodySingleSpaced: Bool = true,
        bodyFirstLineIndentTwips: Int = 720,
        serviceListSingleSpaced: Bool = true,
        counselLineItalic: Bool = true,
        signOffNamePlainSentenceCase: Bool = true,
        serviceMethodClause: ServiceMethodClause = .flEPortal
    ) {
        self.headingCenteredBoldCaps = headingCenteredBoldCaps
        self.bodySingleSpaced = bodySingleSpaced
        self.bodyFirstLineIndentTwips = bodyFirstLineIndentTwips
        self.serviceListSingleSpaced = serviceListSingleSpaced
        self.counselLineItalic = counselLineItalic
        self.signOffNamePlainSentenceCase = signOffNamePlainSentenceCase
        self.serviceMethodClause = serviceMethodClause
    }
}

public struct LetterheadBlock: Codable, Sendable, Equatable {
    public var firmNameHalfPoints: Int
    public var taglineHalfPoints: Int
    public var contactHalfPoints: Int
    public var separator: String
    public var bottomRule: Bool

    public init(firmNameHalfPoints: Int = 32, taglineHalfPoints: Int = 20, contactHalfPoints: Int = 20, separator: String = " • ", bottomRule: Bool = true) {
        self.firmNameHalfPoints = firmNameHalfPoints
        self.taglineHalfPoints = taglineHalfPoints
        self.contactHalfPoints = contactHalfPoints
        self.separator = separator
        self.bottomRule = bottomRule
    }
}

public enum LetterParaStyle: String, Codable, Sendable, Equatable {
    case block
    case indented
}

public struct LetterheadStyle: Codable, Sendable, Equatable {
    public var headerBlock: LetterheadBlock
    public var bodyLineSpacing: LineSpacing
    public var bodyJustify: Bool
    public var bodyParagraphStyle: LetterParaStyle
    public var dateFormat: DateStyle
    public var closing: String
    public var signatureIndentTwips: Int
    public var signatureGapLines: Int
    public var pageNumbers: Bool

    public init(
        headerBlock: LetterheadBlock = LetterheadBlock(),
        bodyLineSpacing: LineSpacing = .single,
        bodyJustify: Bool = true,
        bodyParagraphStyle: LetterParaStyle = .block,
        dateFormat: DateStyle = .monthDayYear,
        closing: String = "Respectfully,",
        signatureIndentTwips: Int = 4680,
        signatureGapLines: Int = 2,
        pageNumbers: Bool = false
    ) {
        self.headerBlock = headerBlock
        self.bodyLineSpacing = bodyLineSpacing
        self.bodyJustify = bodyJustify
        self.bodyParagraphStyle = bodyParagraphStyle
        self.dateFormat = dateFormat
        self.closing = closing
        self.signatureIndentTwips = signatureIndentTwips
        self.signatureGapLines = signatureGapLines
        self.pageNumbers = pageNumbers
    }
}

public struct HouseStyleSheet: Codable, Sendable, Equatable {
    public var page: PageSetup
    public var body: BodyStyle
    public var caption: CaptionStyle
    public var headings: HeadingLadder
    public var signature: SignatureStyle
    public var certificate: CertificateStyle
    public var letterhead: LetterheadStyle?

    public init(
        page: PageSetup = PageSetup(),
        body: BodyStyle = BodyStyle(),
        caption: CaptionStyle = CaptionStyle(),
        headings: HeadingLadder = HeadingLadder(),
        signature: SignatureStyle = SignatureStyle(),
        certificate: CertificateStyle = CertificateStyle(),
        letterhead: LetterheadStyle? = LetterheadStyle()
    ) {
        self.page = page
        self.body = body
        self.caption = caption
        self.headings = headings
        self.signature = signature
        self.certificate = certificate
        self.letterhead = letterhead
    }

    public static let defaultFL = HouseStyleSheet()
}

public struct PartyLine: Codable, Sendable, Equatable {
    public var name: String
    public var designation: String

    public init(name: String, designation: String) {
        self.name = name
        self.designation = designation
    }
}

public struct CaptionModel: Sendable, Equatable {
    public var courtHeader: String
    public var parties: [PartyLine]
    public var caseNumber: String
    public var division: String?
    public var judge: String?

    public init(courtHeader: String, parties: [PartyLine], caseNumber: String, division: String?, judge: String?) {
        self.courtHeader = courtHeader
        self.parties = parties
        self.caseNumber = caseNumber
        self.division = division
        self.judge = judge
    }
}

public enum BodyBlock: Sendable, Equatable {
    case paragraph(String)
    case numberedAllegation(number: Int, text: String)
    case pointHeading(level: Int, numeral: String, text: String)
    case sectionHeading(String)
}

public struct SignatureBlockModel: Sendable, Equatable {
    public var respectfullySubmitted: DateOnly?
    public var firmName: String
    public var signingAttorney: String
    public var attorneys: [AttorneyLine]
    public var office: OfficeBlock
    public var partyRepresented: String
    public var emails: EmailDesignation

    public init(respectfullySubmitted: DateOnly?, firmName: String, signingAttorney: String, attorneys: [AttorneyLine], office: OfficeBlock, partyRepresented: String, emails: EmailDesignation) {
        self.respectfullySubmitted = respectfullySubmitted
        self.firmName = firmName
        self.signingAttorney = signingAttorney
        self.attorneys = attorneys
        self.office = office
        self.partyRepresented = partyRepresented
        self.emails = emails
    }
}

public struct CertificateModel: Sendable, Equatable {
    public var date: DateOnly
    public var clause: ServiceMethodClause
    public var documentTitle: String?
    public var recipients: [ServiceRecipient]
    public var signOffAttorney: String

    public init(date: DateOnly, clause: ServiceMethodClause, documentTitle: String?, recipients: [ServiceRecipient], signOffAttorney: String) {
        self.date = date
        self.clause = clause
        self.documentTitle = documentTitle
        self.recipients = recipients
        self.signOffAttorney = signOffAttorney
    }
}

public struct DocumentModel: Sendable, Equatable {
    public var caption: CaptionModel
    public var title: String
    public var body: [BodyBlock]
    public var signature: SignatureBlockModel?
    public var certificate: CertificateModel?

    public init(caption: CaptionModel, title: String, body: [BodyBlock], signature: SignatureBlockModel?, certificate: CertificateModel?) {
        self.caption = caption
        self.title = title
        self.body = body
        self.signature = signature
        self.certificate = certificate
    }
}

public struct LetterheadFill: Sendable, Equatable {
    public var firmName: String
    public var office: OfficeBlock

    public init(firmName: String, office: OfficeBlock) {
        self.firmName = firmName
        self.office = office
    }
}

public struct LetterModel: Sendable, Equatable {
    public var letterhead: LetterheadFill
    public var date: DateOnly
    public var recipient: AddressBlock
    public var reLine: String
    public var salutation: String
    public var body: [String]
    public var closing: String
    public var signerName: String
    public var signerTitle: String?
    public var enclosures: [String]
    public var cc: [String]

    public init(letterhead: LetterheadFill, date: DateOnly, recipient: AddressBlock, reLine: String, salutation: String, body: [String], closing: String, signerName: String, signerTitle: String?, enclosures: [String], cc: [String]) {
        self.letterhead = letterhead
        self.date = date
        self.recipient = recipient
        self.reLine = reLine
        self.salutation = salutation
        self.body = body
        self.closing = closing
        self.signerName = signerName
        self.signerTitle = signerTitle
        self.enclosures = enclosures
        self.cc = cc
    }
}

public enum RenderInput: Sendable, Equatable {
    case court(DocumentModel)
    case letter(LetterModel)
}

public protocol Renderer: Sendable {
    func render(_ input: RenderInput, style: HouseStyleSheet) throws -> Data
}

public protocol SlotResolver: Sendable {
    func resolve(_ spec: [SlotSpec], matter: MatterContext, profile: DraftingProfile) async -> (SlotResolution, [FollowUp])
}

public protocol MatterContext: Sendable {
    var metadata: [String: String] { get }
    func retrieve(_ query: String, limit: Int) async -> [GroundedFact]
}

public protocol DraftingProfile: Sendable {
    var identity: [String: String] { get }
}

public struct GroundedFact: Sendable, Equatable {
    public var text: String
    public var label: String
    public var docId: String
    public var locator: String

    public init(text: String, label: String, docId: String, locator: String) {
        self.text = text
        self.label = label
        self.docId = docId
        self.locator = locator
    }
}

public struct FactRef: Sendable, Equatable {
    public var label: String

    public init(label: String) {
        self.label = label
    }
}

public struct VerifiedAuthority: Sendable, Equatable {
    public var cite: CitationRef
    public var snippet: String
    public var source: AuthSource

    public init(cite: CitationRef, snippet: String, source: AuthSource) {
        self.cite = cite
        self.snippet = snippet
        self.source = source
    }
}

public enum AuthSource: String, Sendable, Equatable {
    case courtListener
    case userSupplied
}

public struct GeneratedSection: Sendable, Equatable {
    public var blocks: [BodyBlock]
    public var citesUsed: [CitationRef]
    public var assertedFacts: [FactRef]

    public init(blocks: [BodyBlock], citesUsed: [CitationRef], assertedFacts: [FactRef]) {
        self.blocks = blocks
        self.citesUsed = citesUsed
        self.assertedFacts = assertedFacts
    }
}

public struct GeneratedLetter: Sendable, Equatable {
    public var paragraphs: [String]
    public var assertedFacts: [FactRef]
    public var citesUsed: [CitationRef]

    public init(paragraphs: [String], assertedFacts: [FactRef], citesUsed: [CitationRef]) {
        self.paragraphs = paragraphs
        self.assertedFacts = assertedFacts
        self.citesUsed = citesUsed
    }
}

public enum VerifyUnit: Sendable, Equatable {
    case wholeDocument(DocumentModel)
    case section(GeneratedSection, requirement: SectionRequirement, facts: [GroundedFact], authorities: [VerifiedAuthority])
    case letter(GeneratedLetter, model: LetterModel)
}

public protocol Verifier: Sendable {
    func verify(_ unit: VerifyUnit, kind: DraftKindID, style: HouseStyleSheet) async -> VerificationResult
}

public struct FollowUp: Sendable, Equatable {
    public enum Severity: Sendable, Equatable {
        case blocking
        case advisory
    }

    public enum Kind: Sendable, Equatable {
        case missingSlot(String)
        case conflict
        case verify
        case confirmDerived
        case ruleViolation
        case structure
    }

    public var severity: Severity
    public var kind: Kind
    public var message: String

    public init(severity: Severity, kind: Kind, message: String) {
        self.severity = severity
        self.kind = kind
        self.message = message
    }
}

public struct VerificationResult: Sendable, Equatable {
    public var failures: [GateFailure]
    public var followUps: [FollowUp]

    public init(failures: [GateFailure], followUps: [FollowUp]) {
        self.failures = failures
        self.followUps = followUps
    }
}

public struct GateFailure: Sendable, Equatable {
    public var gate: Gate
    public var detail: String
    public var repair: RepairStrategy

    public init(gate: Gate, detail: String, repair: RepairStrategy) {
        self.gate = gate
        self.detail = detail
        self.repair = repair
    }
}

public enum Gate: String, Sendable, Equatable {
    case contract
    case citationFormat
    case authorityValidity
    case ruleConformance
    case factProvenance
    case elementCompleteness
}

public enum RepairStrategy: Sendable, Equatable {
    case regenerate(maxPasses: Int)
    case deterministicFix
    case stripToPlaceholderAndFlag
}

public struct GateResult: Sendable, Equatable {
    public var failures: [GateFailure]
    public var followUps: [FollowUp]

    public init(failures: [GateFailure], followUps: [FollowUp]) {
        self.failures = failures
        self.followUps = followUps
    }
}

public struct DraftResult: Sendable, Equatable {
    public var docx: Data
    public var followUps: [FollowUp]

    public init(docx: Data, followUps: [FollowUp]) {
        self.docx = docx
        self.followUps = followUps
    }
}
