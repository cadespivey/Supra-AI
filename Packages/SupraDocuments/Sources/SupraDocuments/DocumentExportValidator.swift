import Foundation
import PDFKit

/// Format-aware validation performed against the complete temporary artifact
/// before `DurableFileWriter` makes it visible at the destination.
public enum DocumentExportValidator {
    public enum ValidationError: Error, LocalizedError, Equatable, Sendable {
        case emptyMarkdown
        case invalidUTF8
        case malformedCSV
        case inconsistentCSVRows(expected: Int, actual: Int, row: Int)
        case unreadablePDF
        case emptyPDF
        case unreadableOfficeArchive
        case missingOfficePart(String)
        case malformedOfficeXML(String)

        public var errorDescription: String? {
            switch self {
            case .emptyMarkdown:
                "The Markdown export is empty."
            case .invalidUTF8:
                "The text export is not valid UTF-8."
            case .malformedCSV:
                "The CSV export could not be parsed."
            case let .inconsistentCSVRows(expected, actual, row):
                "CSV row \(row) has \(actual) fields; expected \(expected)."
            case .unreadablePDF:
                "The PDF export could not be opened."
            case .emptyPDF:
                "The PDF export has no pages."
            case .unreadableOfficeArchive:
                "The Office export is not a readable ZIP archive."
            case let .missingOfficePart(path):
                "The Office export is missing \(path)."
            case let .malformedOfficeXML(path):
                "The Office export contains malformed XML at \(path)."
            }
        }
    }

    public static func validate(_ url: URL, as format: DocumentExportFormat) throws {
        try Task.checkCancellation()
        switch format {
        case .markdown:
            try validateMarkdown(url)
        case .csv:
            try validateCSV(url)
        case .pdf:
            try validatePDF(url)
        case .docx:
            try validateOfficeArchive(
                url,
                requiredXMLParts: ["[Content_Types].xml", "_rels/.rels", "word/document.xml"]
            )
        case .xlsx:
            try validateOfficeArchive(
                url,
                requiredXMLParts: [
                    "[Content_Types].xml",
                    "_rels/.rels",
                    "xl/workbook.xml",
                    "xl/_rels/workbook.xml.rels",
                    "xl/worksheets/sheet1.xml"
                ]
            )
        }
    }

    private static func validateMarkdown(_ url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ValidationError.invalidUTF8
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptyMarkdown
        }
    }

    private static func validateCSV(_ url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ValidationError.invalidUTF8
        }
        let rows = try parseCSV(text)
        guard let expected = rows.first?.count, expected > 0 else {
            throw ValidationError.malformedCSV
        }
        for (offset, row) in rows.enumerated() where row.count != expected {
            throw ValidationError.inconsistentCSVRows(
                expected: expected,
                actual: row.count,
                row: offset + 1
            )
        }
    }

    private static func validatePDF(_ url: URL) throws {
        guard let document = PDFDocument(url: url) else {
            throw ValidationError.unreadablePDF
        }
        guard document.pageCount > 0 else {
            throw ValidationError.emptyPDF
        }
    }

    private static func validateOfficeArchive(_ url: URL, requiredXMLParts: [String]) throws {
        do {
            _ = try ZipArchiveReader.entryPaths(in: url)
        } catch {
            throw ValidationError.unreadableOfficeArchive
        }
        for path in requiredXMLParts {
            let data: Data
            do {
                guard let extracted = try ZipArchiveReader.entryData(in: url, path: path) else {
                    throw ValidationError.missingOfficePart(path)
                }
                data = extracted
            } catch let error as ValidationError {
                throw error
            } catch {
                throw ValidationError.unreadableOfficeArchive
            }
            let parser = XMLParser(data: data)
            guard parser.parse() else {
                throw ValidationError.malformedOfficeXML(path)
            }
        }
    }

    /// Small RFC 4180 state machine: quoted delimiters/newlines and doubled
    /// quotes are accepted; stray quotes and unterminated fields fail closed.
    private static func parseCSV(_ text: String) throws -> [[String]] {
        guard !text.isEmpty else { throw ValidationError.malformedCSV }
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var justClosedQuote = false
        var index = text.startIndex

        func finishField() {
            row.append(field)
            field.removeAll(keepingCapacity: true)
            justClosedQuote = false
        }
        func finishRow() {
            finishField()
            rows.append(row)
            row.removeAll(keepingCapacity: true)
        }

        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if inQuotes {
                if character == "\"" {
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = text.index(after: next)
                        continue
                    }
                    inQuotes = false
                    justClosedQuote = true
                } else {
                    field.append(character)
                }
            } else if justClosedQuote {
                if character == "," {
                    finishField()
                } else if character == "\n" {
                    finishRow()
                } else if character == "\r", next < text.endIndex, text[next] == "\n" {
                    finishRow()
                    index = text.index(after: next)
                    continue
                } else {
                    throw ValidationError.malformedCSV
                }
            } else {
                switch character {
                case "\"":
                    guard field.isEmpty else { throw ValidationError.malformedCSV }
                    inQuotes = true
                case ",":
                    finishField()
                case "\n":
                    finishRow()
                case "\r":
                    guard next < text.endIndex, text[next] == "\n" else {
                        throw ValidationError.malformedCSV
                    }
                    finishRow()
                    index = text.index(after: next)
                    continue
                default:
                    field.append(character)
                }
            }
            index = next
        }
        guard !inQuotes else { throw ValidationError.malformedCSV }
        if !row.isEmpty || !field.isEmpty || justClosedQuote || text.last == "," {
            finishRow()
        }
        guard !rows.isEmpty else { throw ValidationError.malformedCSV }
        return rows
    }
}
