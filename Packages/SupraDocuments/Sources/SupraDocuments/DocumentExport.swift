import CoreText
import Foundation
import SupraCore
import ZIPFoundation

public enum DocumentExportFormat: String, Sendable, CaseIterable, Codable {
    case pdf
    case markdown
    case docx
    case csv
    case xlsx

    public var fileExtension: String { self == .markdown ? "md" : rawValue }
}

/// The data needed to export a generated output with its citations + source
/// appendix (plan §10.3). Carries no raw imported documents.
public struct DocumentExportPayload: Sendable, Equatable {
    public struct SourceRow: Sendable, Equatable {
        public var label: String
        public var documentName: String
        public var locator: String
        public var excerpt: String
        public var warnings: String

        public init(label: String, documentName: String, locator: String, excerpt: String, warnings: String = "") {
            self.label = label
            self.documentName = documentName
            self.locator = locator
            self.excerpt = excerpt
            self.warnings = warnings
        }
    }

    public var title: String
    public var contentMarkdown: String
    public var reviewWarning: String
    public var sources: [SourceRow]

    public init(title: String, contentMarkdown: String, reviewWarning: String, sources: [SourceRow]) {
        self.title = title
        self.contentMarkdown = contentMarkdown
        self.reviewWarning = reviewWarning
        self.sources = sources
    }

    /// Plain text rendering used for PDF/DOCX (output + warning + appendix).
    var plainText: String {
        var lines = [title, "", reviewWarning, "", contentMarkdown]
        if !sources.isEmpty {
            lines.append("")
            lines.append("Sources")
            for source in sources {
                var line = "[\(source.label)] \(source.documentName) — \(source.locator)"
                if !source.warnings.isEmpty { line += " (\(source.warnings))" }
                lines.append(line)
                if !source.excerpt.isEmpty { lines.append("    \(source.excerpt)") }
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Writes a generated output to disk in the requested format with inline
/// citations + a source appendix + a review warning. No raw imported documents
/// are embedded (plan §10.3).
public enum DocumentExportBuilder {
    public enum FaultStage: String, Sendable {
        case beforeRender
        case beforeValidation
    }

    public typealias FaultInjector = (FaultStage) throws -> Void

    public static func write(
        _ payload: DocumentExportPayload,
        format: DocumentExportFormat,
        to url: URL,
        writer: DurableFileWriter = DurableFileWriter(),
        faultInjector: FaultInjector = { _ in }
    ) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Task.checkCancellation()
        try faultInjector(.beforeRender)
        try Task.checkCancellation()
        let data = try render(payload, format: format)
        try Task.checkCancellation()
        try writer.write(data, to: url) { temporaryURL in
            try faultInjector(.beforeValidation)
            try DocumentExportValidator.validate(temporaryURL, as: format)
        }
    }

    private static func render(_ payload: DocumentExportPayload, format: DocumentExportFormat) throws -> Data {
        switch format {
        case .markdown:
            return renderMarkdown(payload)
        case .csv:
            return renderCSV(payload)
        case .pdf:
            return try renderPDF(payload)
        case .docx:
            return try renderDOCX(payload)
        case .xlsx:
            return try renderXLSX(payload)
        }
    }

    // MARK: - Markdown

    private static func renderMarkdown(_ payload: DocumentExportPayload) -> Data {
        var text = "# \(payload.title)\n\n> \(payload.reviewWarning)\n\n\(payload.contentMarkdown)\n"
        if !payload.sources.isEmpty {
            text += "\n## Sources\n"
            for source in payload.sources {
                text += "- **[\(source.label)]** \(source.documentName) — \(source.locator)"
                text += source.warnings.isEmpty ? "\n" : " ⚠️ \(source.warnings)\n"
                if !source.excerpt.isEmpty { text += "  > \(source.excerpt)\n" }
            }
        }
        return Data(text.utf8)
    }

    // MARK: - CSV (source appendix table)

    private static func renderCSV(_ payload: DocumentExportPayload) -> Data {
        var rows = ["Label,Document,Locator,Warnings,Excerpt"]
        for source in payload.sources {
            rows.append([source.label, source.documentName, source.locator, source.warnings, source.excerpt].map(csvField).joined(separator: ","))
        }
        return Data(rows.joined(separator: "\n").utf8)
    }

    private static func csvField(_ value: String) -> String {
        let safe = CSVCellSanitizer.neutralize(value)
        return "\"\(safe.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    // MARK: - PDF (CoreText, paginated)

    private static func renderPDF(_ payload: DocumentExportPayload) throws -> Data {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ExtractionError.fileUnreadable("Could not create PDF context.")
        }
        let inset: CGFloat = 54
        let textRect = mediaBox.insetBy(dx: inset, dy: inset)
        let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
        let attributed = NSAttributedString(string: payload.plainText, attributes: [
            .init(kCTFontAttributeName as String): font
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let total = attributed.length
        var start = 0
        repeat {
            context.beginPDFPage(nil)
            let path = CGPath(rect: textRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(start, 0), path, nil)
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            start += max(visible.length, 1)
            context.endPDFPage()
        } while start < total
        context.closePDF()
        return output as Data
    }

    // MARK: - DOCX (minimal Office Open XML)

    private static func renderDOCX(_ payload: DocumentExportPayload) throws -> Data {
        let archive = try Archive(data: Data(), accessMode: .create, pathEncoding: nil)
        let paragraphs = payload.plainText.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "<w:p><w:r><w:t xml:space=\"preserve\">\(xmlEscape(String($0)))</w:t></w:r></w:p>" }
            .joined()
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(paragraphs)</w:body></w:document>
        """
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
        """
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """
        try addEntry(archive, "[Content_Types].xml", contentTypes)
        try addEntry(archive, "_rels/.rels", rels)
        try addEntry(archive, "word/document.xml", document)
        guard let data = archive.data else {
            throw ExtractionError.fileUnreadable("Could not finish DOCX.")
        }
        return data
    }

    // MARK: - XLSX (minimal Office Open XML — source appendix table)

    private static func renderXLSX(_ payload: DocumentExportPayload) throws -> Data {
        let archive = try Archive(data: Data(), accessMode: .create, pathEncoding: nil)
        var rowsXML = ""
        func row(_ number: Int, _ values: [String]) -> String {
            let cells = values.enumerated().map { index, value in
                let safe = CSVCellSanitizer.neutralize(value)
                return "<c r=\"\(columnLetter(index))\(number)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xmlEscape(safe))</t></is></c>"
            }.joined()
            return "<row r=\"\(number)\">\(cells)</row>"
        }
        rowsXML += row(1, ["Label", "Document", "Locator", "Warnings", "Excerpt"])
        for (offset, source) in payload.sources.enumerated() {
            rowsXML += row(offset + 2, [source.label, source.documentName, source.locator, source.warnings, source.excerpt])
        }
        let sheet = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\(rowsXML)</sheetData></worksheet>
        """
        let workbook = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Sources" sheetId="1" r:id="rId1"/></sheets></workbook>
        """
        let workbookRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>
        """
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>
        """
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """
        try addEntry(archive, "[Content_Types].xml", contentTypes)
        try addEntry(archive, "_rels/.rels", rels)
        try addEntry(archive, "xl/workbook.xml", workbook)
        try addEntry(archive, "xl/_rels/workbook.xml.rels", workbookRels)
        try addEntry(archive, "xl/worksheets/sheet1.xml", sheet)
        guard let data = archive.data else {
            throw ExtractionError.fileUnreadable("Could not finish XLSX.")
        }
        return data
    }

    // MARK: - Helpers

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
        var n = index
        var letters = ""
        repeat {
            letters = String(UnicodeScalar(UInt8(65 + n % 26))) + letters
            n = n / 26 - 1
        } while n >= 0
        return letters
    }
}
