import Foundation

/// Renderer-neutral semantic form of a generated document export. It keeps the
/// output body, review state, and source appendix as distinct nodes so each file
/// renderer can add presentation without reconstructing meaning from plain text.
public struct RichExportDocument: Sendable, Equatable {
    public enum Inline: Sendable, Equatable {
        case text(String)
        case emphasis(String)
        case strong(String)
        case code(String)
        case citation(String)
        case link(label: String, destination: String)
    }

    public enum TableAlignment: Sendable, Equatable {
        case leading
        case center
        case trailing
    }

    public struct Table: Sendable, Equatable {
        public var headers: [[Inline]]
        public var alignments: [TableAlignment]
        public var rows: [[[Inline]]]

        public init(
            headers: [[Inline]],
            alignments: [TableAlignment],
            rows: [[[Inline]]]
        ) {
            self.headers = headers
            self.alignments = alignments
            self.rows = rows
        }
    }

    public struct Source: Sendable, Equatable {
        public var label: String
        public var documentName: String
        public var locator: String
        public var excerpt: String
        public var warnings: String

        public init(
            label: String,
            documentName: String,
            locator: String,
            excerpt: String,
            warnings: String
        ) {
            self.label = label
            self.documentName = documentName
            self.locator = locator
            self.excerpt = excerpt
            self.warnings = warnings
        }
    }

    public enum Block: Sendable, Equatable {
        case title([Inline])
        case reviewBanner([Inline])
        case heading(level: Int, content: [Inline])
        case paragraph([Inline])
        case blockQuote([Inline])
        case unorderedList(items: [[Inline]])
        case orderedList(start: Int, items: [[Inline]])
        case table(Table)
        case sourceAppendix([Source])
    }

    public var blocks: [Block]

    public init(payload: DocumentExportPayload) {
        var blocks: [Block] = [
            .title([.text(payload.title)]),
            .reviewBanner([.text(payload.reviewWarning)]),
        ]
        blocks.append(contentsOf: RichExportMarkdownParser.parse(payload.contentMarkdown))
        blocks.append(.sourceAppendix(payload.sources.map(Source.init)))
        self.blocks = blocks
    }
}

private extension RichExportDocument.Source {
    init(_ source: DocumentExportPayload.SourceRow) {
        self.init(
            label: source.label,
            documentName: source.documentName,
            locator: source.locator,
            excerpt: source.excerpt,
            warnings: source.warnings
        )
    }
}

private enum RichExportMarkdownParser {
    typealias Block = RichExportDocument.Block
    typealias Inline = RichExportDocument.Inline
    typealias Table = RichExportDocument.Table
    typealias Alignment = RichExportDocument.TableAlignment

    static func parse(_ markdown: String) -> [Block] {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [Block] = []
        var index = 0

        while index < lines.count {
            if isBlank(lines[index]) {
                index += 1
                continue
            }
            if let heading = heading(from: lines[index]) {
                blocks.append(.heading(level: heading.level, content: parseInline(heading.text)))
                index += 1
                continue
            }
            if let table = table(from: lines, startingAt: index) {
                blocks.append(.table(table.value))
                index = table.nextIndex
                continue
            }
            if unorderedItem(from: lines[index]) != nil {
                var items: [[Inline]] = []
                while index < lines.count, let item = unorderedItem(from: lines[index]) {
                    items.append(parseInline(item))
                    index += 1
                }
                blocks.append(.unorderedList(items: items))
                continue
            }
            if let first = orderedItem(from: lines[index]) {
                var items = [parseInline(first.text)]
                let start = first.number
                index += 1
                while index < lines.count, let item = orderedItem(from: lines[index]) {
                    items.append(parseInline(item.text))
                    index += 1
                }
                blocks.append(.orderedList(start: start, items: items))
                continue
            }
            if quoteText(from: lines[index]) != nil {
                var quoteLines: [String] = []
                while index < lines.count, let quote = quoteText(from: lines[index]) {
                    quoteLines.append(quote)
                    index += 1
                }
                blocks.append(.blockQuote(parseInline(quoteLines.joined(separator: " "))))
                continue
            }

            var paragraphLines: [String] = []
            while index < lines.count, !isBlank(lines[index]) {
                if !paragraphLines.isEmpty, startsBlock(lines: lines, at: index) { break }
                paragraphLines.append(lines[index].trimmingCharacters(in: .whitespaces))
                index += 1
            }
            blocks.append(.paragraph(parseInline(paragraphLines.joined(separator: " "))))
        }
        return blocks
    }

    private static func startsBlock(lines: [String], at index: Int) -> Bool {
        heading(from: lines[index]) != nil
            || table(from: lines, startingAt: index) != nil
            || unorderedItem(from: lines[index]) != nil
            || orderedItem(from: lines[index]) != nil
            || quoteText(from: lines[index]) != nil
    }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let count = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(count) else { return nil }
        let markerEnd = trimmed.index(trimmed.startIndex, offsetBy: count)
        guard markerEnd < trimmed.endIndex, trimmed[markerEnd].isWhitespace else { return nil }
        let text = trimmed[markerEnd...].trimmingCharacters(in: .whitespaces)
        return (count, text)
    }

    private static func unorderedItem(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2,
              let marker = trimmed.first,
              ["-", "*", "+"].contains(marker),
              trimmed[trimmed.index(after: trimmed.startIndex)].isWhitespace else {
            return nil
        }
        return trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
    }

    private static func orderedItem(from line: String) -> (number: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty,
              let number = Int(digits),
              let dot = trimmed.index(trimmed.startIndex, offsetBy: digits.count, limitedBy: trimmed.endIndex),
              dot < trimmed.endIndex,
              trimmed[dot] == "." else { return nil }
        let afterDot = trimmed.index(after: dot)
        guard afterDot < trimmed.endIndex, trimmed[afterDot].isWhitespace else { return nil }
        return (number, trimmed[afterDot...].trimmingCharacters(in: .whitespaces))
    }

    private static func quoteText(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == ">" else { return nil }
        return trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
    }

    private static func table(
        from lines: [String],
        startingAt index: Int
    ) -> (value: Table, nextIndex: Int)? {
        guard index + 1 < lines.count else { return nil }
        let headers = tableCells(from: lines[index])
        let dividerCells = tableCells(from: lines[index + 1])
        guard headers.count >= 2,
              headers.count == dividerCells.count else { return nil }
        let alignments = dividerCells.compactMap(alignment(from:))
        guard alignments.count == headers.count else { return nil }

        var rows: [[[Inline]]] = []
        var nextIndex = index + 2
        while nextIndex < lines.count, !isBlank(lines[nextIndex]) {
            let cells = tableCells(from: lines[nextIndex])
            guard cells.count == headers.count else { break }
            rows.append(cells.map(parseInline))
            nextIndex += 1
        }
        return (
            Table(
                headers: headers.map(parseInline),
                alignments: alignments,
                rows: rows
            ),
            nextIndex
        )
    }

    private static func tableCells(from line: String) -> [String] {
        var body = line.trimmingCharacters(in: .whitespaces)
        guard body.contains("|") else { return [] }
        if body.first == "|" { body.removeFirst() }
        if body.last == "|" { body.removeLast() }

        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in body {
            if escaped {
                if character == "|" || character == "\\" {
                    current.append(character)
                } else {
                    current.append("\\")
                    current.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func alignment(from delimiter: String) -> Alignment? {
        let trimmed = delimiter.trimmingCharacters(in: .whitespaces)
        let leadingColon = trimmed.first == ":"
        let trailingColon = trimmed.last == ":"
        let dashes = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        guard dashes.count >= 3, dashes.allSatisfy({ $0 == "-" }) else { return nil }
        if leadingColon, trailingColon { return .center }
        if trailingColon { return .trailing }
        return .leading
    }

    private static func parseInline(_ text: String) -> [Inline] {
        var result: [Inline] = []
        var plain = ""
        var index = text.startIndex

        func flushPlain() {
            guard !plain.isEmpty else { return }
            result.append(.text(plain))
            plain = ""
        }

        while index < text.endIndex {
            if text[index...].hasPrefix("**") {
                let contentStart = text.index(index, offsetBy: 2)
                if let closing = text.range(of: "**", range: contentStart..<text.endIndex),
                   closing.lowerBound > contentStart {
                    flushPlain()
                    result.append(.strong(String(text[contentStart..<closing.lowerBound])))
                    index = closing.upperBound
                    continue
                }
            }
            if text[index] == "`" {
                let contentStart = text.index(after: index)
                if let closing = text[contentStart...].firstIndex(of: "`"), closing > contentStart {
                    flushPlain()
                    result.append(.code(String(text[contentStart..<closing])))
                    index = text.index(after: closing)
                    continue
                }
            }
            if text[index] == "*", !text[index...].hasPrefix("**") {
                let contentStart = text.index(after: index)
                if let closing = text[contentStart...].firstIndex(of: "*"), closing > contentStart {
                    flushPlain()
                    result.append(.emphasis(String(text[contentStart..<closing])))
                    index = text.index(after: closing)
                    continue
                }
            }
            if text[index] == "[",
               let closeBracket = text[index...].firstIndex(of: "]"),
               closeBracket > text.index(after: index) {
                let labelStart = text.index(after: index)
                let label = String(text[labelStart..<closeBracket])
                let afterBracket = text.index(after: closeBracket)
                if afterBracket < text.endIndex, text[afterBracket] == "(" {
                    let destinationStart = text.index(after: afterBracket)
                    if let closeParenthesis = text[destinationStart...].firstIndex(of: ")"),
                       closeParenthesis > destinationStart {
                        flushPlain()
                        result.append(.link(
                            label: label,
                            destination: String(text[destinationStart..<closeParenthesis])
                        ))
                        index = text.index(after: closeParenthesis)
                        continue
                    }
                } else if isCitationLabel(label) {
                    flushPlain()
                    result.append(.citation(label))
                    index = afterBracket
                    continue
                }
            }

            plain.append(text[index])
            index = text.index(after: index)
        }
        flushPlain()
        return result
    }

    private static func isCitationLabel(_ value: String) -> Bool {
        guard let first = value.first,
              first.isLetter,
              value.contains(where: { $0.isNumber }) else { return false }
        return value.dropFirst().allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
        }
    }
}
