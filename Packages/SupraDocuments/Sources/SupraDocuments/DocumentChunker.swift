import Foundation
import SupraCore

/// Input to chunking: one extracted part plus its locator (plan §7.1).
public struct ChunkPart: Sendable {
    public var partID: String?
    public var sourceKind: DocumentSourceKind
    public var pageIndex: Int?
    public var pageLabel: String?
    public var sheetName: String?
    public var cellRange: String?
    public var emailPartPath: String?
    public var ocrConfidence: Double?
    public var boundingBoxesJSON: String?
    public var text: String

    public init(
        partID: String? = nil,
        sourceKind: DocumentSourceKind,
        text: String,
        pageIndex: Int? = nil,
        pageLabel: String? = nil,
        sheetName: String? = nil,
        cellRange: String? = nil,
        emailPartPath: String? = nil,
        ocrConfidence: Double? = nil,
        boundingBoxesJSON: String? = nil
    ) {
        self.partID = partID
        self.sourceKind = sourceKind
        self.text = text
        self.pageIndex = pageIndex
        self.pageLabel = pageLabel
        self.sheetName = sheetName
        self.cellRange = cellRange
        self.emailPartPath = emailPartPath
        self.ocrConfidence = ocrConfidence
        self.boundingBoxesJSON = boundingBoxesJSON
    }
}

/// A retrieval chunk with a stable locator and char range within its part.
public struct DocumentChunk: Sendable, Equatable {
    public var chunkIndex: Int
    public var partID: String?
    public var sourceKind: DocumentSourceKind
    public var pageIndex: Int?
    public var pageLabel: String?
    public var sheetName: String?
    public var cellRange: String?
    public var emailPartPath: String?
    public var charStart: Int
    public var charEnd: Int
    public var text: String
    public var displayExcerpt: String
    public var tokenCount: Int
    public var ocrConfidence: Double?
    public var boundingBoxesJSON: String?
}

/// Deterministic chunker: chunks by natural part boundaries first, then splits
/// long text into character-bounded chunks with overlap, preferring to break at
/// paragraph/sentence boundaries. Locators are preserved so citations resolve
/// back to the right page/sheet/part (plan §7.1).
public struct DocumentChunker: Sendable {
    public let maxChars: Int
    public let overlapChars: Int

    public init(maxChars: Int = 1200, overlapChars: Int = 200) {
        self.maxChars = max(200, maxChars)
        self.overlapChars = max(0, min(overlapChars, maxChars / 2))
    }

    public func chunk(parts: [ChunkPart]) -> [DocumentChunk] {
        var chunks: [DocumentChunk] = []
        var index = 0
        for part in parts {
            let characters = Array(part.text)
            guard characters.contains(where: { !$0.isWhitespace }) else { continue }
            for (start, end) in ranges(characters) {
                let slice = String(characters[start..<end])
                let trimmed = slice.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                chunks.append(DocumentChunk(
                    chunkIndex: index,
                    partID: part.partID,
                    sourceKind: part.sourceKind,
                    pageIndex: part.pageIndex,
                    pageLabel: part.pageLabel,
                    sheetName: part.sheetName,
                    cellRange: part.cellRange,
                    emailPartPath: part.emailPartPath,
                    charStart: start,
                    charEnd: end,
                    text: slice,
                    displayExcerpt: Self.excerpt(slice),
                    tokenCount: Self.approxTokenCount(slice),
                    ocrConfidence: part.ocrConfidence,
                    boundingBoxesJSON: part.boundingBoxesJSON
                ))
                index += 1
            }
        }
        return chunks
    }

    /// Returns char ranges (start, end) over a character array, preferring breaks
    /// at paragraph/sentence/space boundaries within the tail window.
    private func ranges(_ characters: [Character]) -> [(Int, Int)] {
        let length = characters.count
        guard length > maxChars else { return [(0, length)] }
        var result: [(Int, Int)] = []
        var start = 0
        while start < length {
            let hardEnd = min(start + maxChars, length)
            var end = hardEnd
            if hardEnd < length {
                let windowStart = max(hardEnd - overlapChars - 1, start + 1)
                end = preferredBreak(in: characters, from: windowStart, to: hardEnd) ?? hardEnd
            }
            result.append((start, end))
            if end >= length { break }
            start = max(end - overlapChars, start + 1)
        }
        return result
    }

    /// Last paragraph break, else sentence break, else space within the window.
    private func preferredBreak(in characters: [Character], from lower: Int, to upper: Int) -> Int? {
        var lastSpace: Int?
        var lastSentence: Int?
        var i = lower
        while i < upper {
            let ch = characters[i]
            if ch == "\n" {
                if i + 1 < upper && characters[i + 1] == "\n" { return i + 2 } // paragraph
                lastSentence = i + 1
            } else if ch == "." || ch == "!" || ch == "?" {
                if i + 1 < upper && characters[i + 1] == " " { lastSentence = i + 1 }
            } else if ch == " " {
                lastSpace = i + 1
            }
            i += 1
        }
        return lastSentence ?? lastSpace
    }

    public static func excerpt(_ text: String, limit: Int = 220) -> String {
        let collapsed = text.split(whereSeparator: { $0 == "\n" || $0 == "\t" }).joined(separator: " ")
        if collapsed.count <= limit { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }

    static func approxTokenCount(_ text: String) -> Int {
        text.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
    }
}
