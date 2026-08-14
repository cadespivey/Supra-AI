import SupraOOXML

public extension DocxPackage {
    static func court(
        documentXML: String,
        stylesXML: String,
        settingsXML: String,
        footerXML: String,
        emptyFooterXML: String = "<w:ftr xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:p/></w:ftr>"
    ) -> DocxPackage {
        let relsType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        return DocxPackage(parts: [
            "[Content_Types].xml": draftingContentTypes(includeFooters: true, includeEmptyFooter: true),
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
            "word/footerEmpty.xml": emptyFooterXML,
        ])
    }

    /// Letterhead package — omits court-only footer parts (Letter §3.10 / Exports §1).
    static func letter(
        documentXML: String,
        stylesXML: String,
        settingsXML: String
    ) -> DocxPackage {
        let relsType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        return DocxPackage(parts: [
            "[Content_Types].xml": draftingContentTypes(includeFooters: false),
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
            "word/settings.xml": settingsXML,
        ])
    }

    private static func draftingContentTypes(
        includeFooters: Bool,
        includeEmptyFooter: Bool = false
    ) -> String {
        let footerOverrides = includeFooters ? """
          <Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>
        """ : ""
        let emptyFooterOverride = includeEmptyFooter ? """
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
        \(emptyFooterOverride)
        </Types>
        """
    }
}
