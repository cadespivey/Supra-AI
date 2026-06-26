import Foundation
import ZIPFoundation

public struct DocxPackage: Sendable {
    public var parts: [String: String]

    public init(parts: [String: String]) {
        self.parts = parts
    }

    public static func court(
        documentXML: String,
        stylesXML: String,
        settingsXML: String,
        footerXML: String,
        emptyFooterXML: String = "<w:ftr xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:p/></w:ftr>"
    ) -> DocxPackage {
        let relsType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        return DocxPackage(parts: [
            "[Content_Types].xml": contentTypes(includeFooters: true),
            "_rels/.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="\(relsType)/officeDocument" Target="word/document.xml"/>
            </Relationships>
            """,
            "word/_rels/document.xml.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rIdStyles" Type="\(relsType)/styles" Target="styles.xml"/>
              <Relationship Id="rIdSettings" Type="\(relsType)/settings" Target="settings.xml"/>
              <Relationship Id="rIdFooter1" Type="\(relsType)/footer" Target="footer1.xml"/>
              <Relationship Id="rIdFooterEmpty" Type="\(relsType)/footer" Target="footerEmpty.xml"/>
            </Relationships>
            """,
            "word/document.xml": documentXML,
            "word/styles.xml": stylesXML,
            "word/settings.xml": settingsXML,
            "word/footer1.xml": footerXML,
            "word/footerEmpty.xml": emptyFooterXML
        ])
    }

    /// Letterhead package — omits court-only footer parts (Letter §3.10 / Exports §1).
    public static func letter(
        documentXML: String,
        stylesXML: String,
        settingsXML: String
    ) -> DocxPackage {
        let relsType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        return DocxPackage(parts: [
            "[Content_Types].xml": contentTypes(includeFooters: false),
            "_rels/.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="\(relsType)/officeDocument" Target="word/document.xml"/>
            </Relationships>
            """,
            "word/_rels/document.xml.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rIdStyles" Type="\(relsType)/styles" Target="styles.xml"/>
              <Relationship Id="rIdSettings" Type="\(relsType)/settings" Target="settings.xml"/>
            </Relationships>
            """,
            "word/document.xml": documentXML,
            "word/styles.xml": stylesXML,
            "word/settings.xml": settingsXML
        ])
    }

    /// Centered `PAGE` field footer (the DEFAULT footer, used from page 2). Exports §4.6.
    public static let pageNumberFooterXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:p><w:pPr><w:jc w:val="center"/></w:pPr>
        <w:r><w:fldChar w:fldCharType="begin"/></w:r>
        <w:r><w:instrText xml:space="preserve"> PAGE </w:instrText></w:r>
        <w:r><w:fldChar w:fldCharType="separate"/></w:r>
        <w:r><w:t>1</w:t></w:r>
        <w:r><w:fldChar w:fldCharType="end"/></w:r>
      </w:p>
    </w:ftr>
    """

    /// Empty FIRST-page footer (suppresses the page-1 number). Exports §4.6.
    public static let emptyFooterXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p/></w:ftr>
    """

    public func render() throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("docx")
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try Archive(url: url, accessMode: .create)

        for path in parts.keys.sorted() {
            let data = Data(parts[path, default: ""].utf8)
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: .none,
                provider: { position, size in
                    data.subdata(in: Int(position)..<Int(position) + size)
                }
            )
        }

        return try Data(contentsOf: url)
    }

    private static func contentTypes(includeFooters: Bool) -> String {
        let footerOverrides = includeFooters ? """
          <Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>
          <Override PartName="/word/footerEmpty.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>
        """ : ""
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
          <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
          <Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>
        \(footerOverrides)
        </Types>
        """
    }
}

public enum DocxPackageError: Error, Equatable {
    case cannotCreateArchive
}

public enum OoxmlNormalizer {
    /// Strips volatile Word-only output so renderer-owned WML can be compared structurally.
    /// Removes rsid/paraId/textId attributes, proofErr / lastRenderedPageBreak markers, tblLook /
    /// tblPrEx metadata, then collapses insignificant whitespace.
    public static func normalize(_ xml: String) -> String {
        var result = xml
        let patterns = [
            #"\s+w:rsid[A-Za-z]*="[^"]*""#,
            #"\s+w14:[A-Za-z0-9]+="[^"]*""#,
            #"\s+w15:[A-Za-z0-9]+="[^"]*""#,
            #"\s+xmlns:w14="[^"]*""#,
            #"<w:proofErr\b[^>]*/>"#,
            #"<w:lastRenderedPageBreak\b[^>]*/>"#,
            #"<w:tblLook\b[^>]*/>"#,
            #"<w:tblPrEx>.*?</w:tblPrEx>"#,
            #"\s+w:rsidP="[^"]*""#
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        result = result.replacingOccurrences(of: #">\s+<"#, with: "><", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The concatenated visible text of a document.xml body, in order. Used to assert that the
    /// renderer emits exactly the expected words (slot values, clause text) regardless of how Word
    /// split runs in the golden.
    public static func visibleText(_ xml: String) -> String {
        var pieces: [String] = []
        let pattern = #"<w:t(?:\s[^>]*)?>(.*?)</w:t>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return ""
        }
        let ns = xml as NSString
        for match in regex.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            pieces.append(unescape(ns.substring(with: match.range(at: 1))))
        }
        return pieces.joined()
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }
}
