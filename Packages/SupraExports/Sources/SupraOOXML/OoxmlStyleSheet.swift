import Foundation

/// Renderer-neutral generated-output styles and compatibility settings.
public enum OoxmlStyleSheet {
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

    public static func settingsXML() -> String {
        var out = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        out += "\n"
        out += #"<w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">"#
        out += #"<w:evenAndOddHeaders w:val="false"/>"#
        out += #"<w:compat><w:compatSetting w:name="compatibilityMode" w:uri="http://schemas.microsoft.com/office/word" w:val="15"/></w:compat>"#
        out += "</w:settings>"
        return out
    }

    private static func paragraphStyle(
        id: String,
        name: String,
        pPr: String = "",
        rPr: String = ""
    ) -> String {
        var out = #"<w:style w:type="paragraph" w:styleId="\#(id)">"#
        out += #"<w:name w:val="\#(OoxmlWriter.escape(name))"/>"#
        if !pPr.isEmpty { out += "<w:pPr>" + pPr + "</w:pPr>" }
        if !rPr.isEmpty { out += "<w:rPr>" + rPr + "</w:rPr>" }
        out += "</w:style>"
        return out
    }
}
