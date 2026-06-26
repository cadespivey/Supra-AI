import Foundation
import SupraDraftingCore

// HouseStyleSheet -> word/styles.xml + word/settings.xml.
// Also enforces the 2.520(a) format floor: < 12pt font or < 1" margin throws (design §4 / impl §3).

public enum StyleSheetCompiler {

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
