import Foundation

// A sparse, user-overridable subset of HouseStyleSheet (SPEC §4.1). Every style field is
// Optional: nil ⇒ inherit HouseStyleSheet.defaultFL. It resolves to an *effective*
// HouseStyleSheet via `resolved(over:)`, which the renderers consume. Track A (structure)
// only — it never carries identity (names/addresses live in FirmProfile slots) and never
// carries prose. A firm that touches nothing serializes to an essentially empty object and
// resolves to `.defaultFL` byte-for-byte (invariant 5).

/// Numbering glyph for numbered allegations (§4.2 #25). `.numberDot` is today's literal at
/// CourtFLRenderer.swift:168; `.numberParen` is the non-default that makes #25 wire-provable.
public enum NumberFormat: String, Codable, Sendable, Equatable {
    case numberDot    // "1."
    case numberParen  // "1)"
}

public struct FirmStyleProfile: Codable, Sendable, Equatable {

    /// Bumped when the shape changes so decode can migrate. Any decoded value is stamped to
    /// `currentSchemaVersion` on read (see `init(from:)`), so an older/absent version migrates
    /// forward rather than throwing.
    public var schemaVersion: Int

    // --- Letterhead (masthead text + labels + geometry) ---
    public var letterheadTagline: String?               // "Attorneys at Law"
    public var letterheadPhoneLabel: String?            // "Telephone: "
    public var letterheadFaxLabel: String?              // "Facsimile: "
    public var letterheadRELabel: String?               // "RE:"
    public var letterheadREIndentTwips: Int?            // 1440
    public var letterheadREHangingTwips: Int?           // 720
    public var letterheadEnclosurePrefix: String?       // "Enclosure: "
    public var letterheadCCPrefix: String?              // "cc:  " (note double space)
    public var letterheadBottomRule: Bool?              // honor LetterheadBlock.bottomRule
    public var letterheadParagraphStyle: LetterParaStyle? // .block / .indented

    // --- Caption (party block labels + geometry) ---
    public var captionPartySeparator: String?           // "v."
    public var captionClosingRuleGlyph: String?         // "/"
    public var captionCaseNumberLabel: String?          // "CASE NO.: "
    public var captionDivisionLabel: String?            // "DIVISION: "
    public var captionJudgeLabel: String?               // "JUDGE: "
    public var captionDesignationIndentTwips: Int?      // 720
    public var captionHeaderBoldCentered: Bool?         // honor CaptionStyle.headerBoldCentered
    public var captionClosingRuleEndsInSlash: Bool?     // honor CaptionStyle.closingRuleEndsInSlash

    // --- Signature block (labels + marks + prefixes) ---
    public var signatureESignatureMark: String?         // "/s/ "
    public var signatureByPrefix: String?               // "By: "
    public var signatureSubmittedLabel: String?         // "Respectfully submitted: "
    public var signatureRepresentationPrefix: String?   // "Attorneys for "
    public var signatureBarNumberLabel: String?         // "" today (no label baked)
    public var signaturePhoneLabel: String?             // "Telephone: "
    public var signatureFaxLabel: String?               // "Facsimile: "
    public var signatureEmailLabel: String?             // "Primary E-Mail: "
    public var signatureEmailLabelWithSecondary: String? // "Primary and Secondary E-Mail: "
    public var signatureFirmNameBoldCaps: Bool?         // honor SignatureStyle.firmNameBoldCaps
    public var signatureRepresentationLineItalic: Bool? // honor SignatureStyle.representationLineItalic

    // --- Certificate of service ---
    public var certificateHeading: String?              // "CERTIFICATE OF SERVICE"
    public var certificateAttestationPrefix: String?    // "I HEREBY CERTIFY that on "
    public var certificateAttestationSuffix: String?    // " to the following:"
    public var certificateHeadingCenteredBoldCaps: Bool? // honor CertificateStyle field
    /// Optional per-clause rewording. nil / missing key ⇒ built-in FL boilerplate.
    public var certificateClauseText: [ServiceMethodClause: String]?

    // --- Headings / body geometry ---
    // Names use the `body*` prefix to match the TESTPLAN wire-proof harness (T-BODY-*), which
    // is the executable contract. (SPEC §4.1 sketched these as `numberedAllegationFormat` /
    // `headingBaseIndentTwips` / `headingSpaceAfterTwips`; renamed here for test parity.)
    public var bodyBaseIndentTwips: Int?                // 720 (HeadingLadder.baseIndentTwips)
    public var bodySpaceAfterTwips: Int?               // 240 (HeadingLadder.spaceAfterTwips)
    public var bodyNumberFormat: NumberFormat?          // .numberDot ("N.")

    // --- Safe page/body knobs (subject to the 2.520(a) floor, §4.3) ---
    public var pageFontHalfPoints: Int?                 // 24 (>= 24 after clamp)
    public var pageMarginTwips: EdgeInsets?             // 1440 all sides (>= 1440 after clamp)
    public var bodyJustify: Bool?                       // true

    public static let currentSchemaVersion = 1
    public static let profileKey = "firm.styleProfile"

    /// A blank profile: overrides nothing, resolves to `.defaultFL`.
    public init(schemaVersion: Int = FirmStyleProfile.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        // every style field defaults to nil
    }

    /// Resilient decode (SPEC §4.4): every style key is optional via `decodeIfPresent`, so a
    /// persisted profile written by an older shape (missing keys) decodes without throwing, and
    /// the stored `schemaVersion` is ignored and stamped to `currentSchemaVersion` (migrate-forward).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = Self.currentSchemaVersion   // migrate: stamp current, never trust stored

        self.letterheadTagline = try c.decodeIfPresent(String.self, forKey: .letterheadTagline)
        self.letterheadPhoneLabel = try c.decodeIfPresent(String.self, forKey: .letterheadPhoneLabel)
        self.letterheadFaxLabel = try c.decodeIfPresent(String.self, forKey: .letterheadFaxLabel)
        self.letterheadRELabel = try c.decodeIfPresent(String.self, forKey: .letterheadRELabel)
        self.letterheadREIndentTwips = try c.decodeIfPresent(Int.self, forKey: .letterheadREIndentTwips)
        self.letterheadREHangingTwips = try c.decodeIfPresent(Int.self, forKey: .letterheadREHangingTwips)
        self.letterheadEnclosurePrefix = try c.decodeIfPresent(String.self, forKey: .letterheadEnclosurePrefix)
        self.letterheadCCPrefix = try c.decodeIfPresent(String.self, forKey: .letterheadCCPrefix)
        self.letterheadBottomRule = try c.decodeIfPresent(Bool.self, forKey: .letterheadBottomRule)
        self.letterheadParagraphStyle = try c.decodeIfPresent(LetterParaStyle.self, forKey: .letterheadParagraphStyle)

        self.captionPartySeparator = try c.decodeIfPresent(String.self, forKey: .captionPartySeparator)
        self.captionClosingRuleGlyph = try c.decodeIfPresent(String.self, forKey: .captionClosingRuleGlyph)
        self.captionCaseNumberLabel = try c.decodeIfPresent(String.self, forKey: .captionCaseNumberLabel)
        self.captionDivisionLabel = try c.decodeIfPresent(String.self, forKey: .captionDivisionLabel)
        self.captionJudgeLabel = try c.decodeIfPresent(String.self, forKey: .captionJudgeLabel)
        self.captionDesignationIndentTwips = try c.decodeIfPresent(Int.self, forKey: .captionDesignationIndentTwips)
        self.captionHeaderBoldCentered = try c.decodeIfPresent(Bool.self, forKey: .captionHeaderBoldCentered)
        self.captionClosingRuleEndsInSlash = try c.decodeIfPresent(Bool.self, forKey: .captionClosingRuleEndsInSlash)

        self.signatureESignatureMark = try c.decodeIfPresent(String.self, forKey: .signatureESignatureMark)
        self.signatureByPrefix = try c.decodeIfPresent(String.self, forKey: .signatureByPrefix)
        self.signatureSubmittedLabel = try c.decodeIfPresent(String.self, forKey: .signatureSubmittedLabel)
        self.signatureRepresentationPrefix = try c.decodeIfPresent(String.self, forKey: .signatureRepresentationPrefix)
        self.signatureBarNumberLabel = try c.decodeIfPresent(String.self, forKey: .signatureBarNumberLabel)
        self.signaturePhoneLabel = try c.decodeIfPresent(String.self, forKey: .signaturePhoneLabel)
        self.signatureFaxLabel = try c.decodeIfPresent(String.self, forKey: .signatureFaxLabel)
        self.signatureEmailLabel = try c.decodeIfPresent(String.self, forKey: .signatureEmailLabel)
        self.signatureEmailLabelWithSecondary = try c.decodeIfPresent(String.self, forKey: .signatureEmailLabelWithSecondary)
        self.signatureFirmNameBoldCaps = try c.decodeIfPresent(Bool.self, forKey: .signatureFirmNameBoldCaps)
        self.signatureRepresentationLineItalic = try c.decodeIfPresent(Bool.self, forKey: .signatureRepresentationLineItalic)

        self.certificateHeading = try c.decodeIfPresent(String.self, forKey: .certificateHeading)
        self.certificateAttestationPrefix = try c.decodeIfPresent(String.self, forKey: .certificateAttestationPrefix)
        self.certificateAttestationSuffix = try c.decodeIfPresent(String.self, forKey: .certificateAttestationSuffix)
        self.certificateHeadingCenteredBoldCaps = try c.decodeIfPresent(Bool.self, forKey: .certificateHeadingCenteredBoldCaps)
        self.certificateClauseText = try c.decodeIfPresent([ServiceMethodClause: String].self, forKey: .certificateClauseText)

        self.bodyBaseIndentTwips = try c.decodeIfPresent(Int.self, forKey: .bodyBaseIndentTwips)
        self.bodySpaceAfterTwips = try c.decodeIfPresent(Int.self, forKey: .bodySpaceAfterTwips)
        self.bodyNumberFormat = try c.decodeIfPresent(NumberFormat.self, forKey: .bodyNumberFormat)

        self.pageFontHalfPoints = try c.decodeIfPresent(Int.self, forKey: .pageFontHalfPoints)
        self.pageMarginTwips = try c.decodeIfPresent(EdgeInsets.self, forKey: .pageMarginTwips)
        self.bodyJustify = try c.decodeIfPresent(Bool.self, forKey: .bodyJustify)
    }
}

extension FirmStyleProfile {
    /// Overlay non-nil overrides onto `base` and return the effective sheet the renderers
    /// consume (SPEC §4.1). Pure, deterministic, total (never throws). Because every field is
    /// Optional, an empty profile fires no `.map` closure and returns `base` unchanged — this is
    /// the zero-regression proof obligation (`FirmStyleProfile().resolved(over:.defaultFL)
    /// == .defaultFL`, invariant 5).
    public func resolved(over base: HouseStyleSheet = .defaultFL) -> HouseStyleSheet {
        var s = base

        // Letterhead — base.letterhead is non-nil in .defaultFL.
        if var lh = s.letterhead {
            var hb = lh.headerBlock
            letterheadTagline.map { hb.tagline = $0 }            // §4.2 #1
            letterheadPhoneLabel.map { hb.phoneLabel = $0 }      // #2
            letterheadFaxLabel.map { hb.faxLabel = $0 }          // #3
            letterheadBottomRule.map { hb.bottomRule = $0 }      // wire-up
            lh.headerBlock = hb
            letterheadRELabel.map { lh.reLabel = $0 }            // #4
            letterheadREIndentTwips.map { lh.reIndentTwips = $0 } // #5
            letterheadREHangingTwips.map { lh.reHangingTwips = $0 } // #5
            letterheadEnclosurePrefix.map { lh.enclosurePrefix = $0 } // #6
            letterheadCCPrefix.map { lh.ccPrefix = $0 }          // #7
            letterheadParagraphStyle.map { lh.bodyParagraphStyle = $0 } // wire-up (existing field)
            s.letterhead = lh
        }

        // Caption
        captionPartySeparator.map { s.caption.partySeparator = $0 }             // #8
        captionClosingRuleGlyph.map { s.caption.closingRuleGlyph = $0 }         // #9
        captionCaseNumberLabel.map { s.caption.caseNumberLabel = $0 }           // #10
        captionDivisionLabel.map { s.caption.divisionLabel = $0 }               // #11
        captionJudgeLabel.map { s.caption.judgeLabel = $0 }                     // #12
        captionDesignationIndentTwips.map { s.caption.designationIndentTwips = $0 } // #13
        captionHeaderBoldCentered.map { s.caption.headerBoldCentered = $0 }     // wire-up (existing field)
        captionClosingRuleEndsInSlash.map { s.caption.closingRuleEndsInSlash = $0 } // wire-up (existing field)

        // Signature
        signatureESignatureMark.map { s.signature.eSignature.mark = $0 }        // #14
        signatureByPrefix.map { s.signature.byPrefix = $0 }                     // #15
        signatureSubmittedLabel.map { s.signature.submittedLabel = $0 }         // #16
        signatureRepresentationPrefix.map { s.signature.representationPrefix = $0 } // #17
        signatureBarNumberLabel.map { s.signature.barNumberLabel = $0 }         // #18
        signaturePhoneLabel.map { s.signature.phoneLabel = $0 }                 // #19
        signatureFaxLabel.map { s.signature.faxLabel = $0 }                     // #20
        signatureEmailLabel.map { s.signature.emailLabel = $0 }                 // #21
        signatureEmailLabelWithSecondary.map { s.signature.emailLabelWithSecondary = $0 } // #21
        signatureFirmNameBoldCaps.map { s.signature.firmNameBoldCaps = $0 }     // wire-up (existing field)
        signatureRepresentationLineItalic.map { s.signature.representationLineItalic = $0 } // wire-up (existing field)

        // Certificate
        certificateHeading.map { s.certificate.heading = $0 }                   // #22
        certificateAttestationPrefix.map { s.certificate.attestationPrefix = $0 } // #23
        certificateAttestationSuffix.map { s.certificate.attestationSuffix = $0 } // #23
        certificateHeadingCenteredBoldCaps.map { s.certificate.headingCenteredBoldCaps = $0 } // wire-up (existing field)
        certificateClauseText.map { s.certificate.clauseText = $0 }             // #24

        // Headings / body geometry
        bodyBaseIndentTwips.map { s.headings.baseIndentTwips = $0 }             // #26–28
        bodySpaceAfterTwips.map { s.headings.spaceAfterTwips = $0 }             // #29
        bodyNumberFormat.map { s.body.numberFormat = $0 }                       // #25

        // Safe page/body knobs (clamped by §4.3 afterward)
        pageFontHalfPoints.map { s.page.fontHalfPoints = $0 }
        pageMarginTwips.map { s.page.marginTwips = $0 }
        bodyJustify.map { s.body.justify = $0 }

        return s
    }
}
