import Foundation

/// RFC-4180 CSV parsing for NLRB exports. A real state machine — never
/// `split(separator: ",")` — because NLRB case names and allegations carry
/// quoted commas, escaped quotes, and mixed CRLF/LF line endings.
enum NlrbCSVImporter {
    /// Raw rows (arrays of cells). Handles quoted fields, `""` escapes,
    /// CRLF/LF, and blank cells; a trailing newline does not create a row.
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var cell = ""
        var inQuotes = false
        var index = text.startIndex

        func endCell() {
            row.append(cell)
            cell = ""
        }
        func endRow() {
            endCell()
            // A completely empty line yields [""] — drop it.
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }

        while index < text.endIndex {
            let character = text[index]
            if inQuotes {
                if character == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\"" {
                        cell.append("\"")   // escaped quote
                        index = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    cell.append(character)
                }
            } else {
                switch character {
                case "\"":
                    inQuotes = true
                case ",":
                    endCell()
                case "\r\n", "\r", "\n":
                    // CRLF is a SINGLE Swift Character (grapheme cluster), so
                    // it needs its own case — it matches neither "\r" nor "\n".
                    endRow()
                default:
                    cell.append(character)
                }
            }
            index = text.index(after: index)
        }
        if !cell.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    /// Header-mapped rows: the first row is the header; every later row maps
    /// header → cell. Unmapped/extra cells are preserved positionally under
    /// `column_N`. Header keys keep their ORIGINAL text (raw preservation);
    /// use `normalizedHeaderKey` to look fields up alias-insensitively.
    static func headerMappedRows(_ text: String) -> [[String: String]] {
        let rows = parse(text)
        guard let header = rows.first else { return [] }
        return rows.dropFirst().map { cells in
            var mapped: [String: String] = [:]
            for (index, cell) in cells.enumerated() {
                let key = index < header.count && !header[index].isEmpty ? header[index] : "column_\(index)"
                mapped[key] = cell
            }
            return mapped
        }
    }

    /// Case-insensitive, punctuation-insensitive header key: `Case Number`,
    /// `case_number`, and `CaseNumber` all normalize to `casenumber`.
    static func normalizedHeaderKey(_ header: String) -> String {
        header.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Field lookup by alias over a header-mapped row.
    static func value(in row: [String: String], aliases: [String]) -> String? {
        let wanted = Set(aliases.map(normalizedHeaderKey))
        for (key, value) in row where wanted.contains(normalizedHeaderKey(key)) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}
