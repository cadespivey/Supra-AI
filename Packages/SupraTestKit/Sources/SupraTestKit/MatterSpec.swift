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
    public var benchmarkProfile: String?
    public var documents: [DocumentSpec]
    public var answerKey: AnswerKey
}

public struct DocumentSpec: Codable, Sendable {
    public enum Format: String, Codable, Sendable {
        case pdf, scanned_pdf, mixed_pdf, locked_pdf, image_png, docx, xlsx, eml, msg
    }

    public var filename: String
    public var folder: String
    public var format: Format
    public var purpose: String?
    public var hiddenFacts: [String]?
    public var bodyText: String?
    public var spreadsheet: [SheetSpec]?
    public var email: EmailSpec?
    public var benchmarkFeatures: [BenchmarkFeature]?
    public var duplicateOf: String?
}

public enum BenchmarkFeature: String, Codable, Sendable {
    case numbering
    case tables
    case footnotes
    case endnotes
    case comments
    case trackedChanges = "tracked_changes"
    case headersFooters = "headers_footers"
    case formulasCachedValues = "formulas_cached_values"
    case mergedCells = "merged_cells"
    case hiddenRows = "hidden_rows"
    case hiddenSheets = "hidden_sheets"
    case cellFormats = "cell_formats"
    case tableHeaders = "table_headers"
    case quotedReplies = "quoted_replies"
    case threadHeaders = "thread_headers"
    case cidInlineImage = "cid_inline_image"
    case lowConfidenceOCR = "low_confidence_ocr"
}

public struct SheetSpec: Codable, Sendable {
    public var sheet: String
    public var cells: [[String]]
    public var state: String?
    public var hiddenRows: [Int]?
    public var mergedCells: [String]?
    public var formulas: [FormulaCellSpec]?
    public var table: SheetTableSpec?

    public init(
        sheet: String,
        cells: [[String]],
        state: String? = nil,
        hiddenRows: [Int]? = nil,
        mergedCells: [String]? = nil,
        formulas: [FormulaCellSpec]? = nil,
        table: SheetTableSpec? = nil
    ) {
        self.sheet = sheet
        self.cells = cells
        self.state = state
        self.hiddenRows = hiddenRows
        self.mergedCells = mergedCells
        self.formulas = formulas
        self.table = table
    }
}

public struct FormulaCellSpec: Codable, Sendable {
    public var cell: String
    public var formula: String
    public var cachedValue: String
}

public struct SheetTableSpec: Codable, Sendable {
    public var name: String
    public var range: String
    public var headers: [String]
}

public struct EmailSpec: Codable, Sendable {
    public var from: String
    public var to: String
    public var subject: String
    public var date: String
    public var body: String
    public var attachmentFilename: String?
    public var attachmentBody: String?
    public var bcc: String?
    public var messageID: String?
    public var inReplyTo: String?
    public var references: [String]?
    public var inlineImageCID: String?
    public var inlineImageFilename: String?
    public var inlineImageBody: String?

    public init(
        from: String,
        to: String,
        subject: String,
        date: String,
        body: String,
        attachmentFilename: String? = nil,
        attachmentBody: String? = nil,
        bcc: String? = nil,
        messageID: String? = nil,
        inReplyTo: String? = nil,
        references: [String]? = nil,
        inlineImageCID: String? = nil,
        inlineImageFilename: String? = nil,
        inlineImageBody: String? = nil
    ) {
        self.from = from
        self.to = to
        self.subject = subject
        self.date = date
        self.body = body
        self.attachmentFilename = attachmentFilename
        self.attachmentBody = attachmentBody
        self.bcc = bcc
        self.messageID = messageID
        self.inReplyTo = inReplyTo
        self.references = references
        self.inlineImageCID = inlineImageCID
        self.inlineImageFilename = inlineImageFilename
        self.inlineImageBody = inlineImageBody
    }
}

public struct AnswerKey: Codable, Sendable {
    public var qa: [QAItem]
    public var chronology: [ChronologyItem]
    public var courtListener: CourtListenerScenario?
    public var taskKeys: TaskAnswerKeys
}

public struct TaskAnswerKeys: Codable, Sendable {
    public var lists: [TaskAnswerKey]
    public var chronology: [TaskAnswerKey]
    public var comparisons: [TaskAnswerKey]
    public var contradictions: [TaskAnswerKey]
    public var negatives: [TaskAnswerKey]
    public var structures: [TaskAnswerKey]
    public var versions: [TaskAnswerKey]
}

public struct TaskAnswerKey: Codable, Sendable {
    public var id: String
    public var prompt: String
    public var expectedAnswer: String
    public var evidence: [EvidenceLocator]
}

public struct EvidenceLocator: Codable, Sendable {
    public var sourceFilename: String
    public var locatorHint: String
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
