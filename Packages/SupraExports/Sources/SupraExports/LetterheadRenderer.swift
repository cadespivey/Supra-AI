import Foundation
import SupraDraftingCore

// Letterhead shell renderer (`.letter(LetterModel)`) — a business letter, not a court filing.
// LOCKED against letterDemand-golden.docx (Letter §3 / Exports §5). No caption / certificate / footer.

public struct LetterheadRenderer: Renderer {
    public init() {}

    public func render(_ input: RenderInput, style: HouseStyleSheet) throws -> Data {
        guard case let .letter(model) = input else {
            throw DraftError.renderFailure("LetterheadRenderer requires a .letter(LetterModel) input.")
        }
        // The 2.520(a) floor is court-only; letters are not floor-guarded.
        let doc = OoxmlDocument(body: bodyElements(model, style: style),
                               section: StyleSheetCompiler.letterSection(style))
        let documentXML = OoxmlWriter.documentXML(doc)
        let package = DocxPackage.letter(
            documentXML: documentXML,
            stylesXML: StyleSheetCompiler.stylesXML(style),
            settingsXML: StyleSheetCompiler.settingsXML()
        )
        return try package.render()
    }

    public func documentXML(_ model: LetterModel, style: HouseStyleSheet) -> String {
        let doc = OoxmlDocument(body: bodyElements(model, style: style),
                               section: StyleSheetCompiler.letterSection(style))
        return OoxmlWriter.documentXML(doc)
    }

    // MARK: - Body assembly

    private func bodyElements(_ model: LetterModel, style: HouseStyleSheet) -> [BodyElement] {
        let letterhead = style.letterhead ?? LetterheadStyle()
        let block = letterhead.headerBlock
        var elements: [BodyElement] = []

        // 1. Letterhead — centered: firm name (bold 16pt), tagline (italic 10pt), contact lines (10pt),
        //    then a full-width pBdr rule.
        elements.append(centered(model.letterhead.firmName,
                                 props: RunProps(bold: true, fontHalfPoints: block.firmNameHalfPoints)))
        elements.append(centered(block.tagline,
                                 props: RunProps(italic: true, fontHalfPoints: block.taglineHalfPoints)))
        let office = model.letterhead.office
        var addressLine = office.street
        if let suite = office.suite, !suite.isEmpty { addressLine += ", \(suite)" }
        addressLine += "\(block.separator)\(office.city), \(office.state) \(office.zip)"
        elements.append(centered(addressLine, props: RunProps(fontHalfPoints: block.contactHalfPoints)))
        var contactLine = "\(block.phoneLabel)\(office.phone)"
        if let fax = office.fax, !fax.isEmpty { contactLine += "\(block.separator)\(block.faxLabel)\(fax)" }
        elements.append(centered(contactLine, props: RunProps(fontHalfPoints: block.contactHalfPoints)))
        // Full-width rule (firms may disable it).
        if block.bottomRule {
            elements.append(.paragraph(OoxmlParagraph(props: ParaProps(bottomBorder: .rule))))
        }
        elements.append(.paragraph(.empty))

        // 2. Date — left.
        elements.append(.paragraph(OoxmlParagraph(runs: [.text(format(model.date))])))
        elements.append(.paragraph(.empty))

        // 3. Recipient address block — left, single-spaced. (Delivery notation carried inline if present
        //    as the first recipient line convention is omitted; renderer keeps it simple per LetterModel.)
        for line in recipientLines(model.recipient) {
            elements.append(.paragraph(OoxmlParagraph(runs: [.text(line)])))
        }
        elements.append(.paragraph(.empty))

        // 4. RE: line — bold, hanging indent (firm-configurable label + geometry).
        elements.append(.paragraph(OoxmlParagraph(
            props: ParaProps(indLeftTwips: letterhead.reIndentTwips, hangingTwips: letterhead.reHangingTwips),
            runs: [.text(letterhead.reLabel, props: RunProps(bold: true)),
                   OoxmlRun(.tab, props: RunProps(bold: true)),
                   .text(model.reLine, props: RunProps(bold: true))]
        )))
        elements.append(.paragraph(.empty))

        // 5. Salutation — left.
        elements.append(.paragraph(OoxmlParagraph(runs: [.text(model.salutation)])))
        elements.append(.paragraph(.empty))

        // 6. Body — single-spaced, justified; block (no first-line indent) or indented per firm style.
        let bodyFirstLine = letterhead.bodyParagraphStyle == .indented ? 720 : nil
        for (index, paragraph) in model.body.enumerated() {
            elements.append(.paragraph(OoxmlParagraph(
                props: ParaProps(jc: letterhead.bodyJustify ? .both : nil, indFirstLineTwips: bodyFirstLine),
                runs: [.text(paragraph)]
            )))
            if index < model.body.count - 1 {
                elements.append(.paragraph(.empty))
            }
        }
        elements.append(.paragraph(.empty))

        // 7. Closing + signature — right half (ind left=signatureIndentTwips). No /s/.
        let indent = letterhead.signatureIndentTwips
        elements.append(.paragraph(OoxmlParagraph(
            props: ParaProps(indLeftTwips: indent),
            runs: [.text(model.closing)]
        )))
        for _ in 0..<letterhead.signatureGapLines {
            elements.append(.paragraph(OoxmlParagraph(props: ParaProps(indLeftTwips: indent))))
        }
        elements.append(.paragraph(OoxmlParagraph(
            props: ParaProps(indLeftTwips: indent),
            runs: [.text(model.signerName)]
        )))
        if let title = model.signerTitle, !title.isEmpty {
            elements.append(.paragraph(OoxmlParagraph(
                props: ParaProps(indLeftTwips: indent), runs: [.text(title)]
            )))
        }
        elements.append(.paragraph(OoxmlParagraph(
            props: ParaProps(indLeftTwips: indent),
            runs: [.text(model.letterhead.firmName)]
        )))

        // 8. Enclosures / cc — back at the left margin.
        if !model.enclosures.isEmpty || !model.cc.isEmpty {
            elements.append(.paragraph(.empty))
            for enclosure in model.enclosures {
                elements.append(.paragraph(OoxmlParagraph(runs: [.text("\(letterhead.enclosurePrefix)\(enclosure)")])))
            }
            for cc in model.cc {
                elements.append(.paragraph(OoxmlParagraph(runs: [.text("\(letterhead.ccPrefix)\(cc)")])))
            }
        }

        return elements
    }

    // MARK: - Helpers

    private func centered(_ text: String, props: RunProps) -> BodyElement {
        .paragraph(OoxmlParagraph(props: ParaProps(jc: .center), runs: [.text(text, props: props)]))
    }

    private func recipientLines(_ recipient: AddressBlock) -> [String] {
        var lines: [String] = [recipient.name]
        if let title = recipient.title, !title.isEmpty { lines.append(title) }
        if let firm = recipient.firm, !firm.isEmpty { lines.append(firm) }
        lines.append(recipient.street)
        lines.append("\(recipient.city), \(recipient.state) \(recipient.zip)")
        return lines
    }

    private func format(_ date: DateOnly) -> String {
        let months = ["", "January", "February", "March", "April", "May", "June",
                      "July", "August", "September", "October", "November", "December"]
        let month = (date.month >= 1 && date.month <= 12) ? months[date.month] : "\(date.month)"
        return "\(month) \(date.day), \(date.year)"
    }
}
