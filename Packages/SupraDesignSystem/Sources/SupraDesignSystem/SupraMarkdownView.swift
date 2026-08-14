import Foundation
import SwiftUI

/// The two established Markdown presentation contracts used by the app.
public enum SupraMarkdownPresentation: Sendable {
    /// Full LLM-answer rendering: headings, lists, quotes, code, tables, and citation links.
    case assistantResponse
    /// The deliberately lightweight, line-oriented preview used for saved output versions.
    case savedOutput
}

/// Citation-aware Markdown rendering with explicit presentation policy.
///
/// The component owns parsing and streaming refresh. Containers continue to own their broader
/// accessibility grouping, reading width, and source-list actions.
public struct SupraMarkdownView: View {
    public let text: String
    public let presentation: SupraMarkdownPresentation
    public let citationLabels: Set<String>
    public let onCitationTap: ((String) -> Void)?

    @State private var blocks: [SupraMarkdownBlock]
    @State private var sourceText: String
    @State private var sourceLabels: Set<String>

    public init(
        text: String,
        presentation: SupraMarkdownPresentation,
        citationLabels: Set<String> = [],
        onCitationTap: ((String) -> Void)? = nil
    ) {
        self.text = text
        self.presentation = presentation
        self.citationLabels = citationLabels
        self.onCitationTap = onCitationTap

        let linked = Self.preparedText(text, citationLabels: citationLabels)
        _blocks = State(initialValue: SupraMarkdownParser.parse(linked))
        _sourceText = State(initialValue: text)
        _sourceLabels = State(initialValue: citationLabels)
    }

    @ViewBuilder
    public var body: some View {
        switch presentation {
        case .assistantResponse:
            assistantResponse
        case .savedOutput:
            savedOutput
        }
    }

    private var assistantResponse: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks.indices, id: \.self) { index in
                SupraMarkdownBlockView(block: blocks[index])
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard SupraMarkdownCitationLinker.route(url, onCitationTap: onCitationTap) else {
                return .systemAction
            }
            return .handled
        })
        .onAppear(perform: refresh)
        .onChange(of: text) { _, _ in refresh() }
        .onChange(of: citationLabels) { _, _ in refresh() }
    }

    private var savedOutput: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(savedOutputLines.enumerated()), id: \.offset) { _, line in
                savedOutputLine(line)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var savedOutputLines: [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    @ViewBuilder
    private func savedOutputLine(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("### ") {
            Text(trimmed.dropFirst(4)).font(.subheadline.weight(.semibold))
        } else if trimmed.hasPrefix("## ") {
            Text(trimmed.dropFirst(3)).font(.headline)
        } else if trimmed.hasPrefix("# ") {
            Text(trimmed.dropFirst(2)).font(.title3.weight(.bold))
        } else if trimmed.isEmpty {
            Color.clear.frame(height: 2)
        } else {
            Text(SupraMarkdownInline.attributed(line)).font(.callout).textSelection(.enabled)
        }
    }

    private func refresh() {
        guard text != sourceText || citationLabels != sourceLabels else { return }
        sourceText = text
        sourceLabels = citationLabels
        blocks = SupraMarkdownParser.parse(Self.preparedText(text, citationLabels: citationLabels))
    }

    private static func preparedText(_ text: String, citationLabels: Set<String>) -> String {
        let stripped = SupraEmojiStripper.strip(text)
        return citationLabels.isEmpty
            ? stripped
            : SupraMarkdownCitationLinker.linkedText(stripped, labels: citationLabels)
    }
}

public enum SupraMarkdownCitationLinker {
    /// Rewrites known standalone citation markers into tappable custom-scheme Markdown links.
    public static func linkedText(_ text: String, labels: Set<String>) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(?<![\w/])\[([AS]\d{1,3})\]"#) else {
            return text
        }
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let label = source.substring(with: match.range(at: 1))
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            if labels.contains(label) {
                result += "[\\[\(label)\\]](supracite://\(label))"
            } else {
                result += source.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
        }
        result += source.substring(from: cursor)
        return result
    }

    /// Extracts an uppercased citation label from a `supracite://A1` URL.
    public static func label(from url: URL) -> String? {
        guard url.scheme == "supracite" else { return nil }
        let raw = url.host ?? String(url.absoluteString.dropFirst("supracite://".count))
        return raw.isEmpty ? nil : raw.uppercased()
    }

    /// Routes a citation URL to the supplied action and reports whether it was handled.
    @discardableResult
    public static func route(
        _ url: URL,
        onCitationTap: ((String) -> Void)?
    ) -> Bool {
        guard let label = label(from: url) else { return false }
        onCitationTap?(label)
        return true
    }
}

public enum SupraMarkdownColumnAlignment: Equatable, Sendable {
    case leading
    case center
    case trailing

    fileprivate var alignment: Alignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

public enum SupraMarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bulletList([String])
    case numberedList([String])
    case codeBlock(String)
    case quote(String)
    case table(headers: [String], rows: [[String]], aligns: [SupraMarkdownColumnAlignment])
    case rule
}

private struct SupraMarkdownBlockView: View {
    let block: SupraMarkdownBlock

    var body: some View {
        switch block {
        case let .heading(level, text):
            Text(SupraMarkdownInline.attributed(text))
                .font(headingFont(level))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level <= 2 ? 2 : 0)
        case let .paragraph(text):
            Text(SupraMarkdownInline.attributed(text))
                .fixedSize(horizontal: false, vertical: true)
        case let .bulletList(items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(items.indices, id: \.self) { index in
                    listRow(marker: "•", text: items[index])
                }
            }
        case let .numberedList(items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(items.indices, id: \.self) { index in
                    listRow(marker: "\(index + 1).", text: items[index])
                }
            }
        case let .codeBlock(code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        case let .quote(text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                Text(SupraMarkdownInline.attributed(text))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .table(headers, rows, aligns):
            SupraMarkdownTableView(headers: headers, rows: rows, aligns: aligns)
        case .rule:
            Divider()
        }
    }

    private func listRow(marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker).foregroundStyle(.secondary).monospacedDigit()
            Text(SupraMarkdownInline.attributed(text)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.weight(.bold)
        case 2: .title3.weight(.bold)
        case 3: .headline
        default: .subheadline.weight(.semibold)
        }
    }
}

private struct SupraMarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]
    let aligns: [SupraMarkdownColumnAlignment]

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                ForEach(headers.indices, id: \.self) { column in
                    Text(SupraMarkdownInline.attributed(headers[column]))
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: alignment(column))
                }
            }
            Divider()
            ForEach(rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(headers.indices, id: \.self) { column in
                        Text(SupraMarkdownInline.attributed(cell(row, column)))
                            .frame(maxWidth: .infinity, alignment: alignment(column))
                    }
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.15)))
    }

    private func cell(_ row: Int, _ column: Int) -> String {
        guard row < rows.count, column < rows[row].count else { return "" }
        return rows[row][column]
    }

    private func alignment(_ column: Int) -> Alignment {
        column < aligns.count ? aligns[column].alignment : .leading
    }
}

private enum SupraMarkdownInline {
    static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(text)
    }
}

/// Forgiving line-based parser for the Markdown shapes commonly emitted by the local model.
public enum SupraMarkdownParser {
    public static func parse(_ raw: String) -> [SupraMarkdownBlock] {
        var blocks: [SupraMarkdownBlock] = []
        let lines = raw.components(separatedBy: "\n")
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph.removeAll()
        }

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                var code: [String] = []
                index += 1
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.codeBlock(code.joined(separator: "\n")))
                continue
            }

            if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }

            if trimmed.contains("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                flushParagraph()
                let (table, consumed) = parseTable(lines, start: index)
                blocks.append(table)
                index += consumed
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count {
                    let line = lines[index].trimmingCharacters(in: .whitespaces)
                    guard line.hasPrefix(">") else { break }
                    quoted.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }

            if isBullet(trimmed) {
                flushParagraph()
                var items: [String] = []
                while index < lines.count, isBullet(lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(bulletText(lines[index].trimmingCharacters(in: .whitespaces)))
                    index += 1
                }
                blocks.append(.bulletList(items))
                continue
            }

            if isNumbered(trimmed) {
                flushParagraph()
                var items: [String] = []
                while index < lines.count, isNumbered(lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(numberedText(lines[index].trimmingCharacters(in: .whitespaces)))
                    index += 1
                }
                blocks.append(.numberedList(items))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            paragraph.append(trimmed)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#", level < 6 {
            level += 1
            index = line.index(after: index)
        }
        guard level > 0, index < line.endIndex, line[index] == " " else { return nil }
        return (level, String(line[index...]).trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" }
            || stripped.allSatisfy { $0 == "*" }
            || stripped.allSatisfy { $0 == "_" }
    }

    private static func isBullet(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
    }

    private static func bulletText(_ line: String) -> String {
        String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }

    private static func isNumbered(_ line: String) -> Bool {
        var index = line.startIndex
        var digits = 0
        while index < line.endIndex, line[index].isNumber {
            digits += 1
            index = line.index(after: index)
        }
        guard digits > 0, index < line.endIndex, line[index] == "." || line[index] == ")" else {
            return false
        }
        let next = line.index(after: index)
        return next < line.endIndex && line[next] == " "
    }

    private static func numberedText(_ line: String) -> String {
        guard let marker = line.firstIndex(where: { $0 == "." || $0 == ")" }) else { return line }
        return String(line[line.index(after: marker)...]).trimmingCharacters(in: .whitespaces)
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") else { return false }
        return trimmed.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }

    private static func splitRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func parseTable(_ lines: [String], start: Int) -> (SupraMarkdownBlock, Int) {
        let headers = splitRow(lines[start])
        let aligns = splitRow(lines[start + 1]).map { spec -> SupraMarkdownColumnAlignment in
            let left = spec.hasPrefix(":")
            let right = spec.hasSuffix(":")
            if left && right { return .center }
            if right { return .trailing }
            return .leading
        }
        var rows: [[String]] = []
        var index = start + 2
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.contains("|") else { break }
            rows.append(splitRow(lines[index]))
            index += 1
        }
        return (.table(headers: headers, rows: rows, aligns: aligns), index - start)
    }
}

/// Removes default-emoji glyphs and explicit emoji-presentation selectors while preserving
/// ordinary text symbols that can carry legal or code meaning.
public enum SupraEmojiStripper {
    public static func strip(_ text: String) -> String {
        guard text.contains(where: isEmoji) else { return text }
        return String(text.filter { !isEmoji($0) })
    }

    private static func isEmoji(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            scalar.properties.isEmojiPresentation || scalar.value == 0xFE0F
        }
    }
}
