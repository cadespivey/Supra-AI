import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ZIPFoundation

/// Renders document content into real files in each required format. Born-digital
/// PDFs carry a text layer; "scanned" PDFs and images are rasterized text (no text
/// layer) so the import pipeline must OCR them.
public enum CorpusRenderers {
    public enum RenderError: Error { case contextCreationFailed, archiveCreationFailed }

    private static let pageSize = CGSize(width: 612, height: 792)
    private static let margin: CGFloat = 54

    // MARK: - PDF (born-digital, text layer)

    public static func writeBornDigitalPDF(text: String, to url: URL) throws {
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { throw RenderError.contextCreationFailed }
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
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { throw RenderError.contextCreationFailed }
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

    // MARK: - DOCX / XLSX (Office Open XML)

    public static func writeDOCX(text: String, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        guard let archive = try? Archive(url: url, accessMode: .create, pathEncoding: nil) else { throw RenderError.archiveCreationFailed }
        let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "<w:p><w:r><w:t xml:space=\"preserve\">\(xmlEscape(String($0)))</w:t></w:r></w:p>" }.joined()
        try addEntry(archive, "[Content_Types].xml", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>"#)
        try addEntry(archive, "_rels/.rels", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>"#)
        try addEntry(archive, "word/document.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>\(paragraphs)</w:body></w:document>")
    }

    public static func writeXLSX(sheets: [SheetSpec], to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        guard let archive = try? Archive(url: url, accessMode: .create, pathEncoding: nil) else { throw RenderError.archiveCreationFailed }
        let sheetList = sheets.isEmpty ? [SheetSpec(sheet: "Sheet1", cells: [])] : sheets
        var sheetEntries = ""
        var contentOverrides = ""
        var rels = ""
        for (index, sheet) in sheetList.enumerated() {
            let n = index + 1
            sheetEntries += "<sheet name=\"\(xmlEscape(sheet.sheet))\" sheetId=\"\(n)\" r:id=\"rId\(n)\"/>"
            rels += "<Relationship Id=\"rId\(n)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(n).xml\"/>"
            contentOverrides += "<Override PartName=\"/xl/worksheets/sheet\(n).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
            var rowsXML = ""
            for (rowIndex, row) in sheet.cells.enumerated() {
                let cells = row.enumerated().map { col, value in
                    "<c r=\"\(columnLetter(col))\(rowIndex + 1)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xmlEscape(value))</t></is></c>"
                }.joined()
                rowsXML += "<row r=\"\(rowIndex + 1)\">\(cells)</row>"
            }
            try addEntry(archive, "xl/worksheets/sheet\(n).xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>\(rowsXML)</sheetData></worksheet>")
        }
        try addEntry(archive, "[Content_Types].xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>\(contentOverrides)</Types>")
        try addEntry(archive, "_rels/.rels", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#)
        try addEntry(archive, "xl/_rels/workbook.xml.rels", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(rels)</Relationships>")
        try addEntry(archive, "xl/workbook.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets>\(sheetEntries)</sheets></workbook>")
    }

    // MARK: - Email

    public static func writeEML(_ email: EmailSpec, to url: URL) throws {
        var lines = [
            "From: \(email.from)",
            "To: \(email.to)",
            "Subject: \(email.subject)",
            "Date: \(email.date)",
        ]
        if let name = email.attachmentFilename, let body = email.attachmentBody {
            let boundary = "SupraTestBoundary"
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

    private static func bodyAttributedString(_ text: String, fontSize: CGFloat = 11) -> NSAttributedString {
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        return NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font])
    }

    private static func rasterizePage(frame: CTFrame) -> CGImage? {
        let scale = 2
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
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
            let start = Int(position)
            return data.subdata(in: start..<(start + size))
        }
    }

    private static func xmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func columnLetter(_ index: Int) -> String {
        var n = index, letters = ""
        repeat { letters = String(UnicodeScalar(UInt8(65 + n % 26))) + letters; n = n / 26 - 1 } while n >= 0
        return letters
    }
}
