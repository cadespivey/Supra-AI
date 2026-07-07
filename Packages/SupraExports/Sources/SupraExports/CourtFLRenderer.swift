import Foundation
import SupraDraftingCore

// Court shell renderer (`.court(DocumentModel)`) for courtFL / courtMDFL.
// Emits canonical WML matching the round-tripped Word goldens (Notice §4.3 / Exports §4–§5).

public struct CourtFLRenderer: Renderer {
    public init() {}

    public func render(_ input: RenderInput, style: HouseStyleSheet) throws -> Data {
        guard case let .court(model) = input else {
            throw DraftError.renderFailure("CourtFLRenderer requires a .court(DocumentModel) input.")
        }
        try StyleSheetCompiler.validateFloor(style)

        let doc = OoxmlDocument(body: bodyElements(model, style: style),
                               section: StyleSheetCompiler.courtSection(style))
        let documentXML = OoxmlWriter.documentXML(doc)
        let package = DocxPackage.court(
            documentXML: documentXML,
            stylesXML: StyleSheetCompiler.stylesXML(style),
            settingsXML: StyleSheetCompiler.settingsXML(),
            footerXML: DocxPackage.pageNumberFooterXML
        )
        return try package.render()
    }

    /// Exposed for golden/structural tests: the raw `document.xml` string.
    public func documentXML(_ model: DocumentModel, style: HouseStyleSheet) throws -> String {
        try StyleSheetCompiler.validateFloor(style)
        let doc = OoxmlDocument(body: bodyElements(model, style: style),
                               section: StyleSheetCompiler.courtSection(style))
        return OoxmlWriter.documentXML(doc)
    }

    // MARK: - Body assembly

    private func bodyElements(_ model: DocumentModel, style: HouseStyleSheet) -> [BodyElement] {
        var elements: [BodyElement] = []

        // 1. Court header — centered bold (or plain when the firm disables it), one paragraph per line.
        let headerBold = style.caption.headerBoldCentered
        for line in model.caption.courtHeader.split(separator: "\n", omittingEmptySubsequences: false) {
            elements.append(.paragraph(OoxmlParagraph(
                props: ParaProps(jc: headerBold ? .center : nil),
                runs: [.text(String(line), props: RunProps(bold: headerBold))]
            )))
        }
        elements.append(.paragraph(.empty))

        // 2. Caption table.
        elements.append(.table(captionTable(model.caption, style: style)))
        elements.append(.paragraph(.empty))

        // 3. Title — centered, bold, caps, underline.
        elements.append(.paragraph(OoxmlParagraph(
            props: ParaProps(jc: .center),
            runs: [.text(model.title, props: RunProps(bold: true, underline: true, caps: true))]
        )))
        elements.append(.paragraph(.empty))

        // 4. Body blocks.
        let bodyParas = model.body.map { bodyBlock($0, style: style) }
        for (index, para) in bodyParas.enumerated() {
            elements.append(.paragraph(para))
            // Single 12-pt blank between body paragraphs (not after the last).
            if index < bodyParas.count - 1, isSeparable(model.body[index], model.body[index + 1]) {
                elements.append(.paragraph(.empty))
            }
        }

        // 5. Signature block.
        if let signature = model.signature {
            elements.append(.paragraph(.empty))
            elements.append(contentsOf: signatureBlock(signature, style: style).map { .paragraph($0) })
        }

        // 6. Certificate of service.
        if let certificate = model.certificate {
            elements.append(.paragraph(.empty))
            elements.append(contentsOf: certificateBlock(certificate, style: style).map { .paragraph($0) })
        }

        return elements
    }

    /// A blank line goes between two consecutive paragraph-type blocks; not between numbered
    /// allegations or point headings (those carry their own spacing).
    private func isSeparable(_ a: BodyBlock, _ b: BodyBlock) -> Bool {
        switch (a, b) {
        case (.numberedAllegation, .numberedAllegation): return false
        case (.pointHeading, _), (_, .pointHeading): return false
        case (.numberedAllegation, _), (_, .numberedAllegation): return false
        case (.sectionHeading, _): return false
        default: return true
        }
    }

    // MARK: - Caption table (LOCKED, golden)

    private func captionTable(_ caption: CaptionModel, style: HouseStyleSheet) -> OoxmlTable {
        let c = style.caption
        var leftCell: [OoxmlParagraph] = []

        for (index, party) in caption.parties.enumerated() {
            // Party name (plain).
            leftCell.append(OoxmlParagraph(runs: [.text(party.name)]))
            leftCell.append(.empty)
            // Designation indented.
            leftCell.append(OoxmlParagraph(
                props: ParaProps(indLeftTwips: c.designationIndentTwips),
                runs: [.text(party.designation)]
            ))
            // Between parties: blank + separator + blank (only between, not after the last).
            if index < caption.parties.count - 1 {
                leftCell.append(.empty)
                leftCell.append(OoxmlParagraph(runs: [.text(c.partySeparator)]))
                leftCell.append(.empty)
            }
        }
        // Closing rule to the ½ mark, ending in the closing glyph (firms may disable it).
        if c.closingRuleEndsInSlash {
            leftCell.append(.empty)
            leftCell.append(OoxmlParagraph(
                props: ParaProps(jc: .right, bottomBorder: .rule),
                runs: [.text(c.closingRuleGlyph)]
            ))
        }

        var rightCell: [OoxmlParagraph] = [
            OoxmlParagraph(runs: [.text("\(c.caseNumberLabel)\(caption.caseNumber)")])
        ]
        if let division = caption.division, !division.isEmpty {
            rightCell.append(OoxmlParagraph(runs: [.text("\(c.divisionLabel)\(division)")]))
        }
        if let judge = caption.judge, !judge.isEmpty {
            rightCell.append(OoxmlParagraph(runs: [.text("\(c.judgeLabel)\(judge)")]))
        }

        return OoxmlTable(
            widthTwips: c.tableWidthTwips,
            borders: .none,
            grid: [c.leftCellWidthTwips, c.rightCellWidthTwips],
            rows: [[
                OoxmlCell(widthTwips: c.leftCellWidthTwips, content: leftCell),
                OoxmlCell(widthTwips: c.rightCellWidthTwips, content: rightCell)
            ]],
            cellMarginTwips: c.cellMarginTwips,
            indentTwips: c.cellMarginTwips
        )
    }

    // MARK: - Body blocks

    private func bodyBlock(_ block: BodyBlock, style: HouseStyleSheet) -> OoxmlParagraph {
        let bodyLine = style.body.lineSpacing == .double ? 480 : 240
        switch block {
        case let .paragraph(text):
            return OoxmlParagraph(
                props: ParaProps(jc: style.body.justify ? .both : nil,
                                 indFirstLineTwips: style.body.firstLineIndentTwips,
                                 spacingLineUnits: bodyLine, spacingLineRule: "auto"),
                runs: [.text(text)]
            )
        case let .numberedAllegation(number, text):
            // Number at margin, tab to the base indent, text there, continuation to margin (Exports §4.4).
            let numText = style.body.numberFormat == .numberParen ? "\(number))" : "\(number)."
            return OoxmlParagraph(
                props: ParaProps(jc: style.body.justify ? .both : nil,
                                 spacingLineUnits: bodyLine, spacingLineRule: "auto",
                                 tabStops: [TabStop(positionTwips: style.headings.baseIndentTwips)]),
                runs: [.text(numText), OoxmlRun(.tab), .text(text)]
            )
        case let .pointHeading(level, numeral, text):
            // Hanging-indent point heading (Exports §4.3): ind left=n·base hanging=base, tab at n·base,
            // spacing after=spaceAfter. Level-1 numerals bold+caps; deeper bold title-case.
            let base = style.headings.baseIndentTwips
            let pos = level * base
            let headingProps = RunProps(bold: true, caps: level == 1)
            return OoxmlParagraph(
                props: ParaProps(indLeftTwips: pos, hangingTwips: base,
                                 spaceAfterTwips: style.headings.spaceAfterTwips, tabStops: [TabStop(positionTwips: pos)]),
                runs: [.text(numeral, props: RunProps(bold: true)), OoxmlRun(.tab),
                       .text(text, props: headingProps)]
            )
        case let .sectionHeading(text):
            // Centered bold, NOT underlined (golden-confirmed).
            return OoxmlParagraph(
                props: ParaProps(jc: .center),
                runs: [.text(text, props: RunProps(bold: true))]
            )
        }
    }

    // MARK: - Signature block (right-half; order LOCKED)

    private func signatureBlock(_ sig: SignatureBlockModel, style: HouseStyleSheet) -> [OoxmlParagraph] {
        let indent = style.signature.leftIndentTwips
        var paras: [OoxmlParagraph] = []

        // Optional "Respectfully submitted: [date]" on its own left-aligned line (motions only).
        if let date = sig.respectfullySubmitted {
            paras.append(OoxmlParagraph(
                props: ParaProps(indFirstLineTwips: style.body.firstLineIndentTwips),
                runs: [.text("\(style.signature.submittedLabel)\(format(date))")]
            ))
        }

        // Firm name — bold caps (unless the firm disables it).
        let firmBoldCaps = style.signature.firmNameBoldCaps
        paras.append(OoxmlParagraph(
            props: ParaProps(indLeftTwips: indent),
            runs: [.text(sig.firmName, props: RunProps(bold: firmBoldCaps, caps: firmBoldCaps))]
        ))
        // "By: " + e-signature line.
        paras.append(eSignatureLine(name: sig.signingAttorney, indent: indent, style: style, prefix: style.signature.byPrefix))
        // Attorney name — plain.
        paras.append(simpleIndented(sig.signingAttorney, indent: indent))
        // Bar number (optionally label-prefixed).
        if let bar = sig.attorneys.first {
            paras.append(simpleIndented("\(style.signature.barNumberLabel)\(bar.barNumber)", indent: indent))
        }
        // Office lines.
        paras.append(simpleIndented(sig.firmName, indent: indent))
        var streetLine = sig.office.street
        if let suite = sig.office.suite, !suite.isEmpty { streetLine += ", \(suite)" }
        paras.append(simpleIndented(streetLine, indent: indent))
        paras.append(simpleIndented("\(sig.office.city), \(sig.office.state) \(sig.office.zip)", indent: indent))
        paras.append(simpleIndented("\(style.signature.phoneLabel)\(sig.office.phone)", indent: indent))
        if let fax = sig.office.fax, !fax.isEmpty {
            paras.append(simpleIndented("\(style.signature.faxLabel)\(fax)", indent: indent))
        }

        // E-mail designation — bold label + primary, secondaries each on their own line.
        let emailLabel = sig.emails.secondary.isEmpty ? style.signature.emailLabel : style.signature.emailLabelWithSecondary
        paras.append(OoxmlParagraph(
            props: ParaProps(indLeftTwips: indent),
            runs: [.text(emailLabel, props: RunProps(bold: true)), .text(sig.emails.primary)]
        ))
        for secondary in sig.emails.secondary {
            paras.append(simpleIndented(secondary, indent: indent))
        }

        // "Attorneys for [party]" — italic (unless disabled), LAST line.
        paras.append(OoxmlParagraph(
            props: ParaProps(indLeftTwips: indent),
            runs: [.text("\(style.signature.representationPrefix)\(sig.partyRepresented)", props: RunProps(italic: style.signature.representationLineItalic))]
        ))
        return paras
    }

    // MARK: - Certificate of service

    private func certificateBlock(_ cert: CertificateModel, style: HouseStyleSheet) -> [OoxmlParagraph] {
        var paras: [OoxmlParagraph] = []

        // Heading — centered bold caps underline (firms may disable the centered-bold-caps styling).
        let certHeadingBoldCaps = style.certificate.headingCenteredBoldCaps
        paras.append(OoxmlParagraph(
            props: ParaProps(jc: certHeadingBoldCaps ? .center : nil),
            runs: [.text(style.certificate.heading, props: RunProps(bold: certHeadingBoldCaps, underline: true, caps: certHeadingBoldCaps))]
        ))
        paras.append(.empty)

        // Body — single-spaced, first-line indent. Middle connective ", I " stays fixed (§4.2 #23).
        let body = "\(style.certificate.attestationPrefix)\(format(cert.date)), I \(clauseText(cert.clause, style: style))\(style.certificate.attestationSuffix)"
        paras.append(OoxmlParagraph(
            props: ParaProps(indFirstLineTwips: style.certificate.bodyFirstLineIndentTwips),
            runs: [.text(body)]
        ))
        paras.append(.empty)

        // Recipients.
        for recipient in cert.recipients {
            paras.append(OoxmlParagraph(runs: [.text(recipient.name)]))
            if !recipient.firm.isEmpty { paras.append(OoxmlParagraph(runs: [.text(recipient.firm)])) }
            var streetLine = recipient.address.street
            if let suite = recipient.address.suite, !suite.isEmpty { streetLine += ", \(suite)" }
            paras.append(OoxmlParagraph(runs: [.text(streetLine)]))
            paras.append(OoxmlParagraph(runs: [.text("\(recipient.address.city), \(recipient.address.state) \(recipient.address.zip)")]))
            for email in recipient.emails {
                paras.append(OoxmlParagraph(runs: [.text(email)]))
            }
            paras.append(OoxmlParagraph(runs: [.text(recipient.role, props: RunProps(italic: true))]))
        }
        paras.append(.empty)

        // Sign-off — e-signature line (no "By: ") + plain name.
        paras.append(eSignatureLine(name: cert.signOffAttorney, indent: style.signature.leftIndentTwips, style: style, prefix: nil))
        paras.append(simpleIndented(cert.signOffAttorney, indent: style.signature.leftIndentTwips))
        return paras
    }

    // MARK: - Helpers

    /// The `/s/ Name` construct — one paragraph, italic+underlined name + underlined tab(s) to a
    /// pinned tab stop for a reproducible rule (LOCKED, Exports §4.2).
    private func eSignatureLine(name: String, indent: Int, style: HouseStyleSheet, prefix: String?) -> OoxmlParagraph {
        let tabPos = indent + style.signature.eSignature.underlineTabStopTwips
        let sigProps = RunProps(italic: style.signature.eSignature.italic, underline: style.signature.eSignature.underline)
        var runs: [OoxmlRun] = []
        if let prefix { runs.append(.text(prefix)) }
        runs.append(.text("\(style.signature.eSignature.mark)\(name)", props: sigProps))
        runs.append(OoxmlRun(.tab, props: sigProps))
        return OoxmlParagraph(
            props: ParaProps(indLeftTwips: indent, tabStops: [TabStop(positionTwips: tabPos)]),
            runs: runs
        )
    }

    private func simpleIndented(_ text: String, indent: Int) -> OoxmlParagraph {
        OoxmlParagraph(props: ParaProps(indLeftTwips: indent), runs: [.text(text)])
    }

    private func format(_ date: DateOnly) -> String {
        let months = ["", "January", "February", "March", "April", "May", "June",
                      "July", "August", "September", "October", "November", "December"]
        let month = (date.month >= 1 && date.month <= 12) ? months[date.month] : "\(date.month)"
        return "\(month) \(date.day), \(date.year)"
    }

    private func clauseText(_ clause: ServiceMethodClause, style: HouseStyleSheet) -> String {
        if let override = style.certificate.clauseText[clause] { return override }
        switch clause {
        case .flEPortal:
            return "electronically filed the foregoing with the Clerk of Court using the Florida Courts E-Filing Portal, which will send a Notice of Electronic Filing"
        case .flServedNotFiled:
            return "served the foregoing via the Florida Courts E-Filing Portal"
        case .federalCMECF:
            return "electronically filed the foregoing with the Clerk of Court using the CM/ECF system, which will send a Notice of Electronic Filing"
        case .mailFirstClass:
            return "served the foregoing by first-class U.S. Mail"
        case .mailRegisteredRRR:
            return "served the foregoing by certified mail, return receipt requested"
        }
    }
}
