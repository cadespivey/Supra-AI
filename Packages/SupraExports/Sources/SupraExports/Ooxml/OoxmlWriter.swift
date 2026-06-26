import Foundation

// OoxmlModel -> `word/document.xml` (canonical WordprocessingML string).
// Emits a clean renderer-owned subset (no rsid/paraId/proofErr noise). pPr/rPr children are
// written in OOXML schema order so the output validates and round-trips through Word/Pages.

public enum OoxmlWriter {

    public static func documentXML(_ doc: OoxmlDocument) -> String {
        var out = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        out += "\n"
        out += #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">"#
        out += "<w:body>"
        for element in doc.body {
            switch element {
            case let .paragraph(p): out += paragraphXML(p)
            case let .table(t): out += tableXML(t)
            }
        }
        out += sectionXML(doc.section)
        out += "</w:body></w:document>"
        return out
    }

    // MARK: - Paragraph

    public static func paragraphXML(_ p: OoxmlParagraph) -> String {
        var out = "<w:p>"
        let pPr = paragraphPropsXML(p.style, p.props)
        if !pPr.isEmpty { out += pPr }
        for run in p.runs { out += runXML(run) }
        out += "</w:p>"
        return out
    }

    private static func paragraphPropsXML(_ style: String?, _ props: ParaProps) -> String {
        var children = ""
        // Schema order: pStyle, pBdr, tabs, spacing, ind, jc
        if let style { children += #"<w:pStyle w:val="\#(style)"/>"# }
        if let bottom = props.bottomBorder {
            children += "<w:pBdr>" + borderXML("bottom", bottom) + "</w:pBdr>"
        }
        if !props.tabStops.isEmpty {
            children += "<w:tabs>"
            for tab in props.tabStops {
                children += #"<w:tab w:val="\#(tab.alignment.rawValue)" w:pos="\#(tab.positionTwips)"/>"#
            }
            children += "</w:tabs>"
        }
        if props.spacingLineUnits != nil || props.spaceAfterTwips != nil {
            var attrs = ""
            if let after = props.spaceAfterTwips { attrs += #" w:after="\#(after)""# }
            if let line = props.spacingLineUnits {
                attrs += #" w:line="\#(line)""#
                attrs += #" w:lineRule="\#(props.spacingLineRule ?? "auto")""#
            }
            children += "<w:spacing\(attrs)/>"
        }
        if props.indLeftTwips != nil || props.hangingTwips != nil || props.indFirstLineTwips != nil {
            var attrs = ""
            if let left = props.indLeftTwips { attrs += #" w:left="\#(left)""# }
            if let hanging = props.hangingTwips { attrs += #" w:hanging="\#(hanging)""# }
            if let firstLine = props.indFirstLineTwips { attrs += #" w:firstLine="\#(firstLine)""# }
            children += "<w:ind\(attrs)/>"
        }
        if let jc = props.jc { children += #"<w:jc w:val="\#(jc.rawValue)"/>"# }
        guard !children.isEmpty else { return "" }
        return "<w:pPr>" + children + "</w:pPr>"
    }

    // MARK: - Run

    public static func runXML(_ run: OoxmlRun) -> String {
        var out = "<w:r>"
        let rPr = runPropsXML(run.props)
        if !rPr.isEmpty { out += rPr }
        switch run.content {
        case let .text(s):
            out += #"<w:t xml:space="preserve">\#(escape(s))</w:t>"#
        case .tab:
            out += "<w:tab/>"
        case let .fieldChar(type):
            out += #"<w:fldChar w:fldCharType="\#(type.rawValue)"/>"#
        case let .instrText(s):
            out += #"<w:instrText xml:space="preserve">\#(escape(s))</w:instrText>"#
        }
        out += "</w:r>"
        return out
    }

    private static func runPropsXML(_ props: RunProps) -> String {
        guard !props.isEmpty else { return "" }
        var children = ""
        // Schema order: b, i, caps, sz, szCs, u
        if props.bold { children += "<w:b/>" }
        if props.italic { children += "<w:i/>" }
        if props.caps { children += "<w:caps/>" }
        if let sz = props.fontHalfPoints {
            children += #"<w:sz w:val="\#(sz)"/>"#
            children += #"<w:szCs w:val="\#(sz)"/>"#
        }
        if props.underline { children += #"<w:u w:val="single"/>"# }
        return "<w:rPr>" + children + "</w:rPr>"
    }

    // MARK: - Table

    public static func tableXML(_ table: OoxmlTable) -> String {
        var out = "<w:tbl><w:tblPr>"
        out += #"<w:tblW w:w="\#(table.widthTwips)" w:type="dxa"/>"#
        if let indent = table.indentTwips {
            out += #"<w:tblInd w:w="\#(indent)" w:type="dxa"/>"#
        }
        out += bordersXML("tblBorders", table.borders)
        if table.layoutFixed {
            out += #"<w:tblLayout w:type="fixed"/>"#
        }
        if let margin = table.cellMarginTwips {
            out += "<w:tblCellMar>"
            out += #"<w:left w:w="\#(margin)" w:type="dxa"/>"#
            out += #"<w:right w:w="\#(margin)" w:type="dxa"/>"#
            out += "</w:tblCellMar>"
        }
        out += "</w:tblPr>"
        out += "<w:tblGrid>"
        for col in table.grid {
            out += #"<w:gridCol w:w="\#(col)"/>"#
        }
        out += "</w:tblGrid>"
        for row in table.rows {
            out += "<w:tr>"
            for cell in row {
                out += cellXML(cell)
            }
            out += "</w:tr>"
        }
        out += "</w:tbl>"
        return out
    }

    private static func cellXML(_ cell: OoxmlCell) -> String {
        var out = "<w:tc><w:tcPr>"
        out += #"<w:tcW w:w="\#(cell.widthTwips)" w:type="dxa"/>"#
        out += bordersXML("tcBorders", cell.borders)
        out += "</w:tcPr>"
        if cell.content.isEmpty {
            out += "<w:p/>"
        } else {
            for p in cell.content { out += paragraphXML(p) }
        }
        out += "</w:tc>"
        return out
    }

    // MARK: - Borders

    private static func bordersXML(_ tag: String, _ borders: Borders) -> String {
        let sides: [(String, Border?)] = [
            ("top", borders.top), ("left", borders.left), ("bottom", borders.bottom),
            ("right", borders.right), ("insideH", borders.insideH), ("insideV", borders.insideV)
        ]
        let present = sides.filter { $0.1 != nil }
        guard !present.isEmpty else { return "" }
        var out = "<w:\(tag)>"
        for (name, border) in present {
            out += borderXML(name, border!)
        }
        out += "</w:\(tag)>"
        return out
    }

    private static func borderXML(_ name: String, _ border: Border) -> String {
        var attrs = #" w:val="\#(border.val)""#
        if let size = border.size { attrs += #" w:sz="\#(size)""# }
        if let space = border.space { attrs += #" w:space="\#(space)""# }
        if let color = border.color { attrs += #" w:color="\#(color)""# }
        return "<w:\(name)\(attrs)/>"
    }

    // MARK: - Section

    private static func sectionXML(_ s: SectionProps) -> String {
        var out = "<w:sectPr>"
        if let id = s.defaultFooterRelId {
            out += #"<w:footerReference w:type="default" r:id="\#(id)"/>"#
        }
        if let id = s.firstFooterRelId {
            out += #"<w:footerReference w:type="first" r:id="\#(id)"/>"#
        }
        out += #"<w:pgSz w:w="\#(s.pageWidthTwips)" w:h="\#(s.pageHeightTwips)"/>"#
        out += #"<w:pgMar w:top="\#(s.marginTopTwips)" w:right="\#(s.marginRightTwips)" w:bottom="\#(s.marginBottomTwips)" w:left="\#(s.marginLeftTwips)" w:header="720" w:footer="720" w:gutter="0"/>"#
        if let start = s.pageNumberStart {
            out += #"<w:pgNumType w:start="\#(start)"/>"#
        }
        if s.titlePage {
            out += "<w:titlePg/>"
        }
        out += "</w:sectPr>"
        return out
    }

    // MARK: - Escaping

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }
}
