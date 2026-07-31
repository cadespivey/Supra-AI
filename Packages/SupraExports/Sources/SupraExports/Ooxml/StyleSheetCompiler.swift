import Foundation
import SupraDraftingCore

// HouseStyleSheet -> word/styles.xml + word/settings.xml.
// Also enforces the 2.520(a) format floor: < 12pt font or < 1" margin throws (design §4 / impl §3).

public enum StyleSheetCompiler {

    /// Reusable style set for renderer-neutral generated outputs. This keeps
    /// general exports on the same typed OOXML boundary as court/letter work
    /// without importing a jurisdiction-specific `HouseStyleSheet`.
    public static func richExportStylesXML() -> String {
        func runProperties(
            size: Int,
            bold: Bool = false,
            italic: Bool = false,
            color: String = "000000"
        ) -> String {
            var value = #"<w:rFonts w:ascii="Calibri" w:hAnsi="Calibri"/>"#
            if bold { value += "<w:b/>" }
            if italic { value += "<w:i/>" }
            value += #"<w:color w:val="\#(color)"/>"#
            value += #"<w:sz w:val="\#(size)"/><w:szCs w:val="\#(size)"/>"#
            return value
        }

        var out = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        out += "\n"
        out += #"<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">"#
        out += "<w:docDefaults><w:rPrDefault><w:rPr>"
        out += runProperties(size: 22)
        out += "</w:rPr></w:rPrDefault></w:docDefaults>"
        out += #"<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:pPr><w:spacing w:after="120" w:line="264" w:lineRule="auto"/></w:pPr><w:rPr>\#(runProperties(size: 22))</w:rPr></w:style>"#
        out += paragraphStyle(
            id: "ExportTitle",
            name: "Export Title",
            pPr: #"<w:spacing w:after="280"/><w:jc w:val="center"/>"#,
            rPr: runProperties(size: 44, bold: true)
        )
        out += paragraphStyle(
            id: "ReviewBanner",
            name: "Review Banner",
            pPr: #"<w:spacing w:after="240"/><w:jc w:val="center"/>"#,
            rPr: runProperties(size: 20, bold: true, color: "7A5A00")
        )
        let headings: [(size: Int, before: Int, after: Int, color: String)] = [
            (32, 320, 160, "2E74B5"),
            (26, 240, 120, "2E74B5"),
            (24, 160, 80, "1F4D78"),
            (22, 120, 80, "1F4D78"),
            (22, 120, 80, "1F4D78"),
            (22, 120, 80, "1F4D78"),
        ]
        for (offset, heading) in headings.enumerated() {
            out += paragraphStyle(
                id: "ExportHeading\(offset + 1)",
                name: "Export Heading \(offset + 1)",
                pPr: #"<w:keepNext/><w:spacing w:before="\#(heading.before)" w:after="\#(heading.after)"/>"#,
                rPr: runProperties(size: heading.size, bold: true, color: heading.color)
            )
        }
        out += paragraphStyle(
            id: "ExportBody",
            name: "Export Body",
            pPr: #"<w:spacing w:after="120" w:line="264" w:lineRule="auto"/>"#,
            rPr: runProperties(size: 22)
        )
        out += paragraphStyle(
            id: "ExportQuote",
            name: "Export Quote",
            pPr: #"<w:spacing w:after="120" w:line="264" w:lineRule="auto"/><w:ind w:left="480"/>"#,
            rPr: runProperties(size: 22, italic: true)
        )
        out += paragraphStyle(
            id: "ExportList",
            name: "Export List",
            pPr: #"<w:spacing w:after="160" w:line="280" w:lineRule="auto"/>"#,
            rPr: runProperties(size: 22)
        )
        out += paragraphStyle(
            id: "ExportTableHeader",
            name: "Export Table Header",
            pPr: #"<w:spacing w:after="0" w:line="240" w:lineRule="auto"/>"#,
            rPr: runProperties(size: 20, bold: true)
        )
        out += paragraphStyle(
            id: "ExportTableBody",
            name: "Export Table Body",
            pPr: #"<w:spacing w:after="0" w:line="240" w:lineRule="auto"/>"#,
            rPr: runProperties(size: 20)
        )
        out += paragraphStyle(
            id: "SourceHeading",
            name: "Source Heading",
            pPr: #"<w:keepNext/><w:spacing w:before="240" w:after="120"/>"#,
            rPr: runProperties(size: 26, bold: true, color: "2E74B5")
        )
        out += paragraphStyle(
            id: "SourceBody",
            name: "Source Body",
            pPr: #"<w:spacing w:after="80" w:line="240" w:lineRule="auto"/>"#,
            rPr: runProperties(size: 20)
        )
        out += "</w:styles>"
        return out
    }

    /// Throws `DraftError.styleFloorViolation` if the sheet violates the court formatting floor.
    /// Letterhead-only shells pass `enforceFloor: false` (the floor is court-only — Letter §3.1).
    public static func validateFloor(_ style: HouseStyleSheet) throws {
        if style.page.fontHalfPoints < 24 {
            throw DraftError.styleFloorViolation(
                "Font \(Double(style.page.fontHalfPoints) / 2.0)pt is below the 12pt floor (Fla. R. Jud. Admin. 2.520(a))."
            )
        }
        let m = style.page.marginTwips
        let minMargin = min(m.top, m.leading, m.bottom, m.trailing)
        if minMargin < 1440 {
            throw DraftError.styleFloorViolation(
                "Margin \(Double(minMargin) / 1440.0)\" is below the 1\" floor (Fla. R. Jud. Admin. 2.520(a))."
            )
        }
    }

    public static func settingsXML() -> String {
        var out = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        out += "\n"
        out += #"<w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">"#
        out += #"<w:evenAndOddHeaders w:val="false"/>"#
        out += #"<w:compat><w:compatSetting w:name="compatibilityMode" w:uri="http://schemas.microsoft.com/office/word" w:val="15"/></w:compat>"#
        out += "</w:settings>"
        return out
    }

    /// Compiles the named paragraph styles so a firm's derived geometry flows through the renderer.
    public static func stylesXML(_ style: HouseStyleSheet) -> String {
        let font = OoxmlWriter.escape(style.page.fontName)
        let sz = style.page.fontHalfPoints
        let bodyLine = style.body.lineSpacing == .double ? 480 : 240
        let firstLine = style.body.firstLineIndentTwips

        var out = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        out += "\n"
        out += #"<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">"#
        out += "<w:docDefaults><w:rPrDefault><w:rPr>"
        out += #"<w:rFonts w:ascii="\#(font)" w:hAnsi="\#(font)"/><w:sz w:val="\#(sz)"/><w:szCs w:val="\#(sz)"/>"#
        out += "</w:rPr></w:rPrDefault></w:docDefaults>"

        // Body: double-spaced, first-line indent, justified.
        out += paragraphStyle(id: "Body", name: "Body",
                              pPr: #"<w:spacing w:line="\#(bodyLine)" w:lineRule="auto"/><w:ind w:firstLine="\#(firstLine)"/><w:jc w:val="both"/>"#)
        // Court header: centered bold.
        out += paragraphStyle(id: "CourtHeader", name: "Court Header",
                              pPr: #"<w:jc w:val="center"/>"#, rPr: "<w:b/>")
        // Document title: centered, bold, underlined caps.
        out += paragraphStyle(id: "DocTitle", name: "Doc Title",
                              pPr: #"<w:jc w:val="center"/>"#, rPr: #"<w:b/><w:caps/><w:u w:val="single"/>"#)
        // Caption line: single-spaced.
        out += paragraphStyle(id: "CaptionLine", name: "Caption Line",
                              pPr: #"<w:spacing w:line="240" w:lineRule="auto"/>"#)
        // Motion section heading: centered bold, NOT underlined.
        out += paragraphStyle(id: "MotionSectionHeading", name: "Motion Section Heading",
                              pPr: #"<w:jc w:val="center"/>"#, rPr: "<w:b/>")
        // Certificate heading: centered, bold, underlined.
        out += paragraphStyle(id: "CertificateHeading", name: "Certificate Heading",
                              pPr: #"<w:jc w:val="center"/>"#, rPr: #"<w:b/><w:caps/><w:u w:val="single"/>"#)
        // Signature line: single-spaced, right-half indent.
        out += paragraphStyle(id: "SigLine", name: "Signature Line",
                              pPr: #"<w:spacing w:line="240" w:lineRule="auto"/><w:ind w:left="\#(style.signature.leftIndentTwips)"/>"#)
        // Certificate body: single-spaced, first-line indent.
        out += paragraphStyle(id: "CosBody", name: "Certificate Body",
                              pPr: #"<w:spacing w:line="240" w:lineRule="auto"/><w:ind w:firstLine="\#(style.certificate.bodyFirstLineIndentTwips)"/>"#)
        // Letter body: single-spaced block, justified.
        out += paragraphStyle(id: "LetterBody", name: "Letter Body",
                              pPr: #"<w:spacing w:line="240" w:lineRule="auto"/><w:jc w:val="both"/>"#)
        // Heading ladder H1…H5 (bold + 12pt gap below; per-paragraph indents carry the geometry).
        for n in 1...5 {
            out += paragraphStyle(id: "H\(n)", name: "Heading \(n)",
                                  pPr: #"<w:spacing w:after="240"/>"#, rPr: "<w:b/>")
        }
        out += "</w:styles>"
        return out
    }

    private static func paragraphStyle(id: String, name: String, pPr: String = "", rPr: String = "") -> String {
        var out = #"<w:style w:type="paragraph" w:styleId="\#(id)">"#
        out += #"<w:name w:val="\#(OoxmlWriter.escape(name))"/>"#
        if !pPr.isEmpty { out += "<w:pPr>" + pPr + "</w:pPr>" }
        if !rPr.isEmpty { out += "<w:rPr>" + rPr + "</w:rPr>" }
        out += "</w:style>"
        return out
    }

    // MARK: - sectPr builder from HouseStyleSheet

    /// Builds the court `SectionProps` (page-1 suppression + centered PAGE footer from p.2).
    public static func courtSection(_ style: HouseStyleSheet) -> SectionProps {
        SectionProps(
            pageWidthTwips: style.page.widthTwips,
            pageHeightTwips: style.page.heightTwips,
            marginTopTwips: style.page.marginTwips.top,
            marginRightTwips: style.page.marginTwips.trailing,
            marginBottomTwips: style.page.marginTwips.bottom,
            marginLeftTwips: style.page.marginTwips.leading,
            titlePage: style.page.suppressFirstPageNumber,
            defaultFooterRelId: "rIdFooter1",
            firstFooterRelId: "rIdFooterEmpty",
            pageNumberStart: 1
        )
    }

    /// Builds the letterhead `SectionProps` (no footer parts unless page numbering is enabled).
    public static func letterSection(_ style: HouseStyleSheet) -> SectionProps {
        SectionProps(
            pageWidthTwips: style.page.widthTwips,
            pageHeightTwips: style.page.heightTwips,
            marginTopTwips: style.page.marginTwips.top,
            marginRightTwips: style.page.marginTwips.trailing,
            marginBottomTwips: style.page.marginTwips.bottom,
            marginLeftTwips: style.page.marginTwips.leading,
            titlePage: false,
            defaultFooterRelId: nil,
            firstFooterRelId: nil,
            pageNumberStart: nil
        )
    }
}
