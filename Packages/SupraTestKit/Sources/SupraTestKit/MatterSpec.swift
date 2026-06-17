import Foundation

/// Decodable spec for a seeded test matter (authored as JSON). Lenient about
/// optional fields so authored specs decode robustly.
public struct MatterSpec: Codable, Sendable {
    public var matterName: String
    public var jurisdiction: String
    public var partyPerspective: String
    public var practiceArea: String
    public var summary: String
    public var attorneyNotesMarkdown: String
    public var documents: [DocumentSpec]
    public var answerKey: AnswerKey
}

public struct DocumentSpec: Codable, Sendable {
    public enum Format: String, Codable, Sendable {
        case pdf, scanned_pdf, image_png, docx, xlsx, eml, msg
    }

    public var filename: String
    public var folder: String
    public var format: Format
    public var purpose: String?
    public var hiddenFacts: [String]?
    public var bodyText: String?
    public var spreadsheet: [SheetSpec]?
    public var email: EmailSpec?
}

public struct SheetSpec: Codable, Sendable {
    public var sheet: String
    public var cells: [[String]]
}

public struct EmailSpec: Codable, Sendable {
    public var from: String
    public var to: String
    public var subject: String
    public var date: String
    public var body: String
    public var attachmentFilename: String?
    public var attachmentBody: String?
}

public struct AnswerKey: Codable, Sendable {
    public var qa: [QAItem]
    public var chronology: [ChronologyItem]
    public var courtListener: CourtListenerScenario?
}

public struct QAItem: Codable, Sendable {
    public var question: String
    public var expectedAnswer: String
    public var sourceFilename: String
    public var locatorHint: String?
    public var requiresOCR: Bool?
    public var crossDocument: Bool?
}

public struct ChronologyItem: Codable, Sendable {
    public var date: String
    public var event: String
    public var sourceFilename: String
}

public struct CourtListenerScenario: Codable, Sendable {
    public var legalIssue: String
    public var jurisdiction: String
    public var expectedAuthorityNames: [String]
}

public extension MatterSpec {
    static func decode(from data: Data) throws -> MatterSpec {
        try JSONDecoder().decode(MatterSpec.self, from: data)
    }
}
