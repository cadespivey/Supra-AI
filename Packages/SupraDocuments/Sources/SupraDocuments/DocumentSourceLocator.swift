import Foundation
import SupraCore

/// A serializable pointer back to the exact source location behind a citation
/// (plan §6.3). Stored as `locator_json` on cited output sources and used to drive
/// in-app preview navigation + best-effort highlights (WO 40).
public struct DocumentSourceLocator: Codable, Sendable, Equatable {
    public var sourceKind: DocumentSourceKind
    public var pageIndex: Int?
    public var pageLabel: String?
    public var sheetName: String?
    public var cellRange: String?
    public var emailPartPath: String?
    public var charStart: Int?
    public var charEnd: Int?
    public var boundingBoxesJSON: String?

    public init(
        sourceKind: DocumentSourceKind,
        pageIndex: Int? = nil,
        pageLabel: String? = nil,
        sheetName: String? = nil,
        cellRange: String? = nil,
        emailPartPath: String? = nil,
        charStart: Int? = nil,
        charEnd: Int? = nil,
        boundingBoxesJSON: String? = nil
    ) {
        self.sourceKind = sourceKind
        self.pageIndex = pageIndex
        self.pageLabel = pageLabel
        self.sheetName = sheetName
        self.cellRange = cellRange
        self.emailPartPath = emailPartPath
        self.charStart = charStart
        self.charEnd = charEnd
        self.boundingBoxesJSON = boundingBoxesJSON
    }

    /// A short human-readable location, e.g. "p. 3", "Sheet1!B4:D9", "email body".
    public var displayString: String {
        switch sourceKind {
        case .pdfPage:
            return "p. \(pageLabel ?? pageIndex.map { String($0 + 1) } ?? "?")"
        case .image:
            return "image" + (pageLabel.map { " \($0)" } ?? "")
        case .spreadsheetCellRange:
            let sheet = sheetName ?? "Sheet"
            return cellRange.map { "\(sheet)!\($0)" } ?? sheet
        case .emailBody:
            return "email body"
        case .emailAttachment:
            return "email attachment"
        case .text, .markdown, .html, .xml, .convertedDocument:
            if let start = charStart, let end = charEnd { return "chars \(start)–\(end)" }
            return "document"
        }
    }

    public func encodedJSON() -> String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
