import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import ZIPFoundation

/// Renders document content into real files in each required format. Born-digital
/// PDFs carry a text layer; "scanned" PDFs and images are rasterized text (no text
/// layer) so the import pipeline must OCR them.
public enum CorpusRenderers {
    public enum RenderError: Error { case contextCreationFailed, archiveCreationFailed, pdfEncryptionFailed }

    private static let pageSize = CGSize(width: 612, height: 792)
    private static let margin: CGFloat = 54
    private static let fixedDocumentDate = Date(timeIntervalSince1970: 1_704_067_200)
    private static var pdfAuxiliaryInfo: CFDictionary {
        [
            kCGPDFContextCreator as String: "SupraTestKit",
        ] as CFDictionary
    }

    // MARK: - PDF (born-digital, text layer)

    public static func writeBornDigitalPDF(text: String, to url: URL) throws {
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, pdfAuxiliaryInfo) else { throw RenderError.contextCreationFailed }
        let attributed = bodyAttributedString(text)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let textRect = mediaBox.insetBy(dx: margin, dy: margin)
        var start = 0
        let total = attributed.length
        repeat {
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(start, 0), CGPath(rect: textRect, transform: nil), nil)
            CTFrameDraw(frame, context)
            start += max(CTFrameGetVisibleStringRange(frame).length, 1)
            context.endPDFPage()
        } while start < total
        context.closePDF()
    }

    // MARK: - Scanned PDF (rasterized, OCR-only)

    public static func writeScannedPDF(text: String, to url: URL) throws {
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, pdfAuxiliaryInfo) else { throw RenderError.contextCreationFailed }
        // Paginate the text, rasterize each page to an image, and draw the image
        // (no text run) so the only way to read it back is OCR.
        let attributed = bodyAttributedString(text, fontSize: 13)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let textRect = CGRect(origin: .zero, size: pageSize).insetBy(dx: margin, dy: margin)
        var start = 0
        let total = attributed.length
        repeat {
            let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(start, 0), CGPath(rect: textRect, transform: nil), nil)
            guard let image = rasterizePage(frame: frame) else { break }
            context.beginPDFPage(nil)
            context.draw(image, in: mediaBox)
            context.endPDFPage()
            start += max(CTFrameGetVisibleStringRange(frame).length, 1)
        } while start < total
        context.closePDF()
    }

    /// A two-page fixture with a born-digital first page and a raster-only
    /// second page. This is intentionally one PDF so page-level fallback can be
    /// measured without conflating it with whole-document OCR.
    public static func writeMixedPDF(text: String, to url: URL) throws {
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, pdfAuxiliaryInfo) else { throw RenderError.contextCreationFailed }

        let digital = bodyAttributedString("BORN-DIGITAL PAGE\n\n\(text)")
        let digitalFrame = CTFramesetterCreateFrame(
            CTFramesetterCreateWithAttributedString(digital),
            CFRangeMake(0, 0),
            CGPath(rect: mediaBox.insetBy(dx: margin, dy: margin), transform: nil),
            nil
        )
        context.beginPDFPage(nil)
        CTFrameDraw(digitalFrame, context)
        context.endPDFPage()

        let scanned = bodyAttributedString("RASTER-ONLY EXHIBIT PAGE\n\n\(text)", fontSize: 13)
        let scannedFrame = CTFramesetterCreateFrame(
            CTFramesetterCreateWithAttributedString(scanned),
            CFRangeMake(0, 0),
            CGPath(rect: mediaBox.insetBy(dx: margin, dy: margin), transform: nil),
            nil
        )
        guard let image = rasterizePage(frame: scannedFrame) else { throw RenderError.contextCreationFailed }
        context.beginPDFPage(nil)
        context.draw(image, in: mediaBox)
        context.endPDFPage()
        context.closePDF()
    }

    public static func writeLockedPDF(text: String, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)-unlocked.pdf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try writeBornDigitalPDF(text: text, to: temporary)
        guard let document = PDFDocument(url: temporary), document.write(
            to: url,
            withOptions: [
                .userPasswordOption: "synthetic-fixture-password",
                .ownerPasswordOption: "synthetic-fixture-owner-password",
            ]
        ) else {
            throw RenderError.pdfEncryptionFailed
        }
    }

    // MARK: - Image (PNG, OCR-only)

    public static func writeImagePNG(text: String, to url: URL) throws {
        let attributed = bodyAttributedString(text, fontSize: 15)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let textRect = CGRect(origin: .zero, size: pageSize).insetBy(dx: margin, dy: margin)
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), CGPath(rect: textRect, transform: nil), nil)
        guard let image = rasterizePage(frame: frame),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw RenderError.contextCreationFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    public static func writeLowConfidenceImagePNG(text: String, to url: URL) throws {
        let gray = CGColor(gray: 0.62, alpha: 1)
        let attributed = bodyAttributedString(text, fontSize: 7, foregroundColor: gray)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let textRect = CGRect(origin: .zero, size: pageSize).insetBy(dx: margin + 18, dy: margin + 18)
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), CGPath(rect: textRect, transform: nil), nil)
        guard let image = rasterizePage(frame: frame, scale: 1),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw RenderError.contextCreationFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    // MARK: - DOCX / XLSX (Office Open XML)

    public static func writeDOCX(
        text: String,
        features: Set<BenchmarkFeature> = [],
        to url: URL
    ) throws {
        if !features.isEmpty {
            try writeStructuredDOCX(text: text, features: features, to: url)
            return
        }
        try? FileManager.default.removeItem(at: url)
        guard let archive = try? Archive(url: url, accessMode: .create, pathEncoding: nil) else { throw RenderError.archiveCreationFailed }
        let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "<w:p><w:r><w:t xml:space=\"preserve\">\(xmlEscape(String($0)))</w:t></w:r></w:p>" }.joined()
        try addEntry(archive, "[Content_Types].xml", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>"#)
        try addEntry(archive, "_rels/.rels", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>"#)
        try addEntry(archive, "word/document.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>\(paragraphs)</w:body></w:document>")
    }

    public static func writeXLSX(
        sheets: [SheetSpec],
        features: Set<BenchmarkFeature> = [],
        to url: URL
    ) throws {
        try? FileManager.default.removeItem(at: url)
        guard let archive = try? Archive(url: url, accessMode: .create, pathEncoding: nil) else { throw RenderError.archiveCreationFailed }
        let sheetList = sheets.isEmpty ? [SheetSpec(sheet: "Sheet1", cells: [])] : sheets
        var sheetEntries = ""
        var contentOverrides = ""
        var rels = ""
        var nextTableID = 1
        for (index, sheet) in sheetList.enumerated() {
            let n = index + 1
            let state = features.contains(.hiddenSheets) ? sheet.state.map { " state=\"\(xmlEscape($0))\"" } ?? "" : ""
            sheetEntries += "<sheet name=\"\(xmlEscape(sheet.sheet))\" sheetId=\"\(n)\"\(state) r:id=\"rId\(n)\"/>"
            rels += "<Relationship Id=\"rId\(n)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(n).xml\"/>"
            contentOverrides += "<Override PartName=\"/xl/worksheets/sheet\(n).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
            let formulas = Dictionary(uniqueKeysWithValues: (sheet.formulas ?? []).map { ($0.cell, $0) })
            var rowsXML = ""
            for (rowIndex, row) in sheet.cells.enumerated() {
                let cells = row.enumerated().map { col, value in
                    let reference = "\(columnLetter(col))\(rowIndex + 1)"
                    if let formula = formulas[reference], features.contains(.formulasCachedValues) {
                        let style = features.contains(.cellFormats) ? " s=\"1\"" : ""
                        return "<c r=\"\(reference)\"\(style)><f>\(xmlEscape(formula.formula))</f><v>\(xmlEscape(formula.cachedValue))</v></c>"
                    }
                    return "<c r=\"\(reference)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xmlEscape(value))</t></is></c>"
                }.joined()
                let hidden = features.contains(.hiddenRows) && (sheet.hiddenRows ?? []).contains(rowIndex + 1)
                    ? " hidden=\"1\""
                    : ""
                rowsXML += "<row r=\"\(rowIndex + 1)\"\(hidden)>\(cells)</row>"
            }
            let merged = features.contains(.mergedCells) ? sheet.mergedCells ?? [] : []
            let mergeEntries = merged.map { "<mergeCell ref=\"\(xmlEscape($0))\"/>" }.joined()
            let mergesXML = merged.isEmpty
                ? ""
                : "<mergeCells count=\"\(merged.count)\">\(mergeEntries)</mergeCells>"
            var tablePartsXML = ""
            if let table = sheet.table, features.contains(.tableHeaders) {
                let tableID = nextTableID
                nextTableID += 1
                let columns = table.headers.enumerated().map { index, header in
                    "<tableColumn id=\"\(index + 1)\" name=\"\(xmlEscape(header))\"/>"
                }.joined()
                let tableXML = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><table xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" id=\"\(tableID)\" name=\"\(xmlEscape(table.name))\" displayName=\"\(xmlEscape(table.name))\" ref=\"\(xmlEscape(table.range))\" totalsRowShown=\"0\"><autoFilter ref=\"\(xmlEscape(table.range))\"/><tableColumns count=\"\(table.headers.count)\">\(columns)</tableColumns><tableStyleInfo name=\"TableStyleMedium2\" showFirstColumn=\"0\" showLastColumn=\"0\" showRowStripes=\"1\" showColumnStripes=\"0\"/></table>"
                try addEntry(archive, "xl/tables/table\(tableID).xml", tableXML)
                try addEntry(archive, "xl/worksheets/_rels/sheet\(n).xml.rels", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/table\" Target=\"../tables/table\(tableID).xml\"/></Relationships>")
                contentOverrides += "<Override PartName=\"/xl/tables/table\(tableID).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.table+xml\"/>"
                tablePartsXML = "<tableParts count=\"1\"><tablePart r:id=\"rId1\"/></tableParts>"
            }
            let worksheetXML = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheetData>\(rowsXML)</sheetData>\(mergesXML)\(tablePartsXML)</worksheet>"
            try addEntry(archive, "xl/worksheets/sheet\(n).xml", worksheetXML)
        }
        if features.contains(.cellFormats) {
            let stylesID = sheetList.count + 1
            rels += "<Relationship Id=\"rId\(stylesID)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
            contentOverrides += "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
            try addEntry(archive, "xl/styles.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><fonts count=\"1\"><font><sz val=\"11\"/><name val=\"Aptos\"/></font></fonts><fills count=\"1\"><fill><patternFill patternType=\"none\"/></fill></fills><borders count=\"1\"><border/></borders><cellStyleXfs count=\"1\"><xf/></cellStyleXfs><cellXfs count=\"2\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/><xf numFmtId=\"4\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/></cellXfs></styleSheet>")
        }
        try addEntry(archive, "[Content_Types].xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>\(contentOverrides)</Types>")
        try addEntry(archive, "_rels/.rels", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#)
        try addEntry(archive, "xl/_rels/workbook.xml.rels", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(rels)</Relationships>")
        try addEntry(archive, "xl/workbook.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets>\(sheetEntries)</sheets></workbook>")
    }

    private static func writeStructuredDOCX(
        text: String,
        features: Set<BenchmarkFeature>,
        to url: URL
    ) throws {
        try? FileManager.default.removeItem(at: url)
        guard let archive = try? Archive(url: url, accessMode: .create, pathEncoding: nil) else {
            throw RenderError.archiveCreationFailed
        }

        var body = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "<w:p><w:r><w:t xml:space=\"preserve\">\(xmlEscape(String($0)))</w:t></w:r></w:p>" }
            .joined()
        var overrides = "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"
        var relationships = ""
        var nextRelationshipID = 1
        var headerRelationshipID: Int?
        var footerRelationshipID: Int?

        func addRelationship(type: String, target: String) -> Int {
            let id = nextRelationshipID
            nextRelationshipID += 1
            relationships += "<Relationship Id=\"rId\(id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/\(type)\" Target=\"\(target)\"/>"
            return id
        }

        if features.contains(.numbering) {
            body += "<w:p><w:pPr><w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"1\"/></w:numPr></w:pPr><w:r><w:t>Preserve source files.</w:t></w:r></w:p>"
            body += "<w:p><w:pPr><w:numPr><w:ilvl w:val=\"1\"/><w:numId w:val=\"1\"/></w:numPr></w:pPr><w:r><w:t>Record every admitted attachment.</w:t></w:r></w:p>"
            overrides += "<Override PartName=\"/word/numbering.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml\"/>"
            _ = addRelationship(type: "numbering", target: "numbering.xml")
            try addEntry(archive, "word/numbering.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:numbering xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:abstractNum w:abstractNumId=\"0\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/><w:lvlText w:val=\"%1.\"/></w:lvl><w:lvl w:ilvl=\"1\"><w:start w:val=\"1\"/><w:numFmt w:val=\"lowerLetter\"/><w:lvlText w:val=\"%2.\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num></w:numbering>")
        }

        if features.contains(.tables) {
            body += "<w:tbl><w:tblPr><w:tblW w:w=\"0\" w:type=\"auto\"/></w:tblPr><w:tr><w:trPr><w:tblHeader/></w:trPr><w:tc><w:p><w:r><w:t>Category</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Value</w:t></w:r></w:p></w:tc></w:tr><w:tr><w:tc><w:p><w:r><w:t>Exposure</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>$275,000</w:t></w:r></w:p></w:tc></w:tr></w:tbl>"
        }

        if features.contains(.footnotes) {
            body += "<w:p><w:r><w:t>Payment is due after acceptance</w:t></w:r><w:r><w:footnoteReference w:id=\"2\"/></w:r><w:r><w:t>.</w:t></w:r></w:p>"
            overrides += "<Override PartName=\"/word/footnotes.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.footnotes+xml\"/>"
            _ = addRelationship(type: "footnotes", target: "footnotes.xml")
            try addEntry(archive, "word/footnotes.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:footnotes xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:footnote w:id=\"-1\"><w:p><w:r><w:separator/></w:r></w:p></w:footnote><w:footnote w:id=\"0\"><w:p><w:r><w:continuationSeparator/></w:r></w:p></w:footnote><w:footnote w:id=\"2\"><w:p><w:r><w:t>Acceptance means written sign-off by Dana Quill.</w:t></w:r></w:p></w:footnote></w:footnotes>")
        }

        if features.contains(.endnotes) {
            body += "<w:p><w:r><w:t>The audit schedule is controlling</w:t></w:r><w:r><w:endnoteReference w:id=\"2\"/></w:r><w:r><w:t>.</w:t></w:r></w:p>"
            overrides += "<Override PartName=\"/word/endnotes.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.endnotes+xml\"/>"
            _ = addRelationship(type: "endnotes", target: "endnotes.xml")
            try addEntry(archive, "word/endnotes.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:endnotes xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:endnote w:id=\"-1\"><w:p><w:r><w:separator/></w:r></w:p></w:endnote><w:endnote w:id=\"0\"><w:p><w:r><w:continuationSeparator/></w:r></w:p></w:endnote><w:endnote w:id=\"2\"><w:p><w:r><w:t>Audit Schedule C supersedes earlier schedules.</w:t></w:r></w:p></w:endnote></w:endnotes>")
        }

        if features.contains(.comments) {
            body += "<w:p><w:commentRangeStart w:id=\"0\"/><w:r><w:t>Thirty-day review period</w:t></w:r><w:commentRangeEnd w:id=\"0\"/><w:r><w:commentReference w:id=\"0\"/></w:r></w:p>"
            overrides += "<Override PartName=\"/word/comments.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.comments+xml\"/>"
            _ = addRelationship(type: "comments", target: "comments.xml")
            try addEntry(archive, "word/comments.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:comments xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:comment w:id=\"0\" w:author=\"Synthetic Reviewer\" w:date=\"2026-01-15T12:00:00Z\"><w:p><w:r><w:t>Confirm whether business days were intended.</w:t></w:r></w:p></w:comment></w:comments>")
        }

        if features.contains(.trackedChanges) {
            body += "<w:p><w:r><w:t>The cap is </w:t></w:r><w:del w:id=\"1\" w:author=\"Synthetic Reviewer\" w:date=\"2026-01-15T12:00:00Z\"><w:r><w:delText>$150,000</w:delText></w:r></w:del><w:ins w:id=\"2\" w:author=\"Synthetic Reviewer\" w:date=\"2026-01-15T12:01:00Z\"><w:r><w:t>$275,000</w:t></w:r></w:ins><w:r><w:t>.</w:t></w:r></w:p>"
        }

        if features.contains(.headersFooters) {
            headerRelationshipID = addRelationship(type: "header", target: "header1.xml")
            footerRelationshipID = addRelationship(type: "footer", target: "footer1.xml")
            overrides += "<Override PartName=\"/word/header1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml\"/><Override PartName=\"/word/footer1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml\"/>"
            try addEntry(archive, "word/header1.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:hdr xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:p><w:r><w:t>SYNTHETIC AGREEMENT — CONFIDENTIAL TEST FIXTURE</w:t></w:r></w:p></w:hdr>")
            try addEntry(archive, "word/footer1.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:ftr xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:p><w:r><w:t>Fixture page footer — DI-2026-001</w:t></w:r></w:p></w:ftr>")
        }

        let headerReference = headerRelationshipID.map { "<w:headerReference w:type=\"default\" r:id=\"rId\($0)\"/>" } ?? ""
        let footerReference = footerRelationshipID.map { "<w:footerReference w:type=\"default\" r:id=\"rId\($0)\"/>" } ?? ""
        body += "<w:sectPr>\(headerReference)\(footerReference)<w:pgSz w:w=\"12240\" w:h=\"15840\"/></w:sectPr>"

        let contentTypes = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>\(overrides)</Types>"
        let rootRelationships = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>"
        let documentRelationships = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(relationships)</Relationships>"
        let documentXML = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><w:body>\(body)</w:body></w:document>"
        try addEntry(archive, "[Content_Types].xml", contentTypes)
        try addEntry(archive, "_rels/.rels", rootRelationships)
        try addEntry(archive, "word/_rels/document.xml.rels", documentRelationships)
        try addEntry(archive, "word/document.xml", documentXML)
    }

    // MARK: - Email

    public static func writeEML(_ email: EmailSpec, to url: URL) throws {
        var lines = [
            "From: \(email.from)",
            "To: \(email.to)",
            "Subject: \(email.subject)",
            "Date: \(email.date)",
        ]
        if let bcc = email.bcc { lines.append("Bcc: \(bcc)") }
        if let messageID = email.messageID { lines.append("Message-ID: \(messageID)") }
        if let inReplyTo = email.inReplyTo { lines.append("In-Reply-To: \(inReplyTo)") }
        if let references = email.references, !references.isEmpty {
            lines.append("References: \(references.joined(separator: " "))")
        }

        if let cid = email.inlineImageCID,
           let inlineName = email.inlineImageFilename,
           let inlineBody = email.inlineImageBody {
            let boundary = "SupraRelatedBoundary"
            lines.append("MIME-Version: 1.0")
            lines.append("Content-Type: multipart/related; boundary=\"\(boundary)\"")
            lines.append("")
            lines.append("--\(boundary)")
            lines.append("Content-Type: text/html; charset=utf-8")
            lines.append("")
            lines.append("<html><body><pre>\(email.body)</pre><img src=\"cid:\(cid)\" alt=\"inline synthetic exhibit\"></body></html>")
            lines.append("--\(boundary)")
            lines.append("Content-Type: image/png; name=\"\(inlineName)\"")
            lines.append("Content-ID: <\(cid)>")
            lines.append("Content-Disposition: inline; filename=\"\(inlineName)\"")
            lines.append("Content-Transfer-Encoding: base64")
            lines.append("")
            let inlineData = Data(base64Encoded: inlineBody) ?? Data(inlineBody.utf8)
            lines.append(inlineData.base64EncodedString())
            if let name = email.attachmentFilename, let body = email.attachmentBody {
                lines.append("--\(boundary)")
                lines.append("Content-Type: application/octet-stream")
                lines.append("Content-Disposition: attachment; filename=\"\(name)\"")
                lines.append("Content-Transfer-Encoding: base64")
                lines.append("")
                lines.append(Data(body.utf8).base64EncodedString())
            }
            lines.append("--\(boundary)--")
        } else if let name = email.attachmentFilename, let body = email.attachmentBody {
            let boundary = "SupraTestBoundary"
            lines.append("MIME-Version: 1.0")
            lines.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
            lines.append("")
            lines.append("--\(boundary)")
            lines.append("Content-Type: text/plain")
            lines.append("")
            lines.append(email.body)
            lines.append("--\(boundary)")
            lines.append("Content-Type: application/octet-stream")
            lines.append("Content-Disposition: attachment; filename=\"\(name)\"")
            lines.append("Content-Transfer-Encoding: base64")
            lines.append("")
            lines.append(Data(body.utf8).base64EncodedString())
            lines.append("--\(boundary)--")
        } else {
            lines.append("Content-Type: text/plain")
            lines.append("")
            lines.append(email.body)
        }
        try lines.joined(separator: "\n").data(using: .utf8)?.write(to: url)
    }

    /// Outlook `.msg` is intentionally written as opaque bytes — the app reports it
    /// "unsupported", which the import-report path is meant to exercise.
    public static func writeMSG(_ email: EmailSpec, to url: URL) throws {
        let text = "Subject: \(email.subject)\nFrom: \(email.from)\n\n\(email.body)"
        try Data(text.utf8).write(to: url)
    }

    // MARK: - Helpers

    private static func bodyAttributedString(
        _ text: String,
        fontSize: CGFloat = 11,
        foregroundColor: CGColor? = nil
    ) -> NSAttributedString {
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        var attributes: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): font]
        if let foregroundColor {
            attributes[.init(kCTForegroundColorAttributeName as String)] = foregroundColor
        }
        return NSAttributedString(string: text, attributes: attributes)
    }

    private static func rasterizePage(frame: CTFrame, scale: Int = 2) -> CGImage? {
        let width = Int(pageSize.width) * scale
        let height = Int(pageSize.height) * scale
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        CTFrameDraw(frame, context)
        return context.makeImage()
    }

    private static func addEntry(_ archive: Archive, _ path: String, _ contents: String) throws {
        let data = Data(contents.utf8)
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            modificationDate: fixedDocumentDate
        ) { position, size in
            let start = Int(position)
            return data.subdata(in: start..<(start + size))
        }
    }

    private static func xmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func columnLetter(_ index: Int) -> String {
        var n = index, letters = ""
        repeat { letters = String(UnicodeScalar(UInt8(65 + n % 26))) + letters; n = n / 26 - 1 } while n >= 0
        return letters
    }
}
