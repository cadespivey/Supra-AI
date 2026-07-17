import Foundation
import SupraCore

// Batched map-reduce chronology support (WO 42 batched-chronology follow-up): a partial-date
// value type, a parsed chronology entry, a strict table parser for map-pass
// outputs, a deterministic merge + renderer, and a per-document batch planner.
// These are pure types — no store, runtime, or I/O — so the controller's
// map/merge orchestration stays fully unit-testable.

/// A partial calendar date parsed from a chronology row's Date column. `nil`
/// components mean the source gave no finer precision; a fully-nil value is an
/// undated placeholder (entries carry `date: nil` for undated rows instead).
///
/// Ordering: year, then month (nil first), then day (nil first) — so "2024"
/// sorts before "January 2024", which sorts before "2024-01-05". A nil
/// component sorts before every concrete value at its level, which keeps
/// partial dates ahead of the specific days they might contain rather than
/// guessing a day for them.
public struct ChronologyDate: Comparable, Equatable, Sendable {
    public var year: Int?
    public var month: Int?
    public var day: Int?

    public init(year: Int?, month: Int? = nil, day: Int? = nil) {
        self.year = year
        self.month = month
        self.day = day
    }

    public static func < (lhs: ChronologyDate, rhs: ChronologyDate) -> Bool {
        // nil-first at every level: rank nil below any real component value.
        func rank(_ component: Int?) -> Int { component ?? Int.min }
        return (rank(lhs.year), rank(lhs.month), rank(lhs.day))
            < (rank(rhs.year), rank(rhs.month), rank(rhs.day))
    }

    /// Parses a chronology Date-cell string into a partial date, or nil when no
    /// date form is recognized. Recognized forms, most-specific first (the same
    /// families `DateExtraction` detects, plus the partial month-year and
    /// bare-year forms): ISO `2024-01-05`, slashed `1/5/2024`, month-name
    /// `January 5, 2024`, month-year `January 2024`, bare year `2024`.
    ///
    /// SEMANTIC CHOICE (documented per work order): month-name canonical
    /// precision — a full month-name date maps to year+month+day; a month-year
    /// form maps to year+month with `day` nil; a bare year maps to year only.
    /// The raw cell text is preserved on the entry (`dateText`), so no
    /// precision is invented or lost in display.
    public static func parse(_ text: String) -> ChronologyDate? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)

        func capture(_ match: NSTextCheckingResult, _ index: Int) -> String? {
            guard let captureRange = Range(match.range(at: index), in: trimmed) else { return nil }
            return String(trimmed[captureRange])
        }

        func firstMatch(_ pattern: String) -> NSTextCheckingResult? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            return regex.firstMatch(in: trimmed, range: range)
        }

        func valid(year: Int, month: Int, day: Int) -> ChronologyDate? {
            let isLeapYear = year.isMultiple(of: 400)
                || (year.isMultiple(of: 4) && !year.isMultiple(of: 100))
            let daysInMonth = [
                1: 31, 2: isLeapYear ? 29 : 28, 3: 31, 4: 30,
                5: 31, 6: 30, 7: 31, 8: 31,
                9: 30, 10: 31, 11: 30, 12: 31,
            ]
            guard let maximumDay = daysInMonth[month], (1...maximumDay).contains(day) else { return nil }
            return ChronologyDate(year: year, month: month, day: day)
        }

        if let match = firstMatch(#"\b(\d{4})-(\d{1,2})-(\d{1,2})\b"#) {
            guard let year = capture(match, 1).flatMap(Int.init),
                  let month = capture(match, 2).flatMap(Int.init),
                  let day = capture(match, 3).flatMap(Int.init)
            else { return nil }
            return valid(year: year, month: month, day: day)
        }
        if let match = firstMatch(#"\b(\d{1,2})/(\d{1,2})/(\d{4})\b"#) {
            guard let month = capture(match, 1).flatMap(Int.init),
                  let day = capture(match, 2).flatMap(Int.init),
                  let year = capture(match, 3).flatMap(Int.init)
            else { return nil }
            return valid(year: year, month: month, day: day)
        }
        let monthPattern = monthNames.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        if let match = firstMatch(#"\b("# + monthPattern + #")\.?\s+(\d{1,2})(?:st|nd|rd|th)?\s*,?\s*(\d{4})\b"#) {
            guard let month = capture(match, 1).flatMap({ monthNames[$0.lowercased()] }),
                  let day = capture(match, 2).flatMap(Int.init),
                  let year = capture(match, 3).flatMap(Int.init)
            else { return nil }
            return valid(year: year, month: month, day: day)
        }
        if let match = firstMatch(#"\b(?:the\s+)?(\d{1,2})(?:st|nd|rd|th)?\s+day\s+of\s+("# + monthPattern + #")\.?\s*,?\s*(\d{4})\b"#) {
            guard let day = capture(match, 1).flatMap(Int.init),
                  let month = capture(match, 2).flatMap({ monthNames[$0.lowercased()] }),
                  let year = capture(match, 3).flatMap(Int.init)
            else { return nil }
            return valid(year: year, month: month, day: day)
        }
        if let match = firstMatch(#"\b(\d{1,2})(?:st|nd|rd|th)?\s+("# + monthPattern + #")\.?\s*,?\s*(\d{4})\b"#) {
            guard let day = capture(match, 1).flatMap(Int.init),
                  let month = capture(match, 2).flatMap({ monthNames[$0.lowercased()] }),
                  let year = capture(match, 3).flatMap(Int.init)
            else { return nil }
            return valid(year: year, month: month, day: day)
        }
        if let match = firstMatch(#"\b("# + monthPattern + #")\.?\s+(\d{4})\b"#),
           let month = capture(match, 1).map({ monthNames[$0.lowercased()] ?? 0 }), month != 0,
           let year = capture(match, 2).flatMap(Int.init) {
            return ChronologyDate(year: year, month: month, day: nil)
        }
        if let match = firstMatch(#"\b((?:19|20)\d{2})\b"#),
           let year = capture(match, 1).flatMap(Int.init) {
            return ChronologyDate(year: year, month: nil, day: nil)
        }
        return nil
    }

    /// Whether the entire cell is an unqualified, full-precision date. This is
    /// deliberately narrower than `parse`, which can find a date inside text
    /// such as "on or about January 5, 2024" for sorting. Only an unqualified
    /// cell may deduplicate across different date renderings; otherwise a
    /// legally material certainty qualifier could be lost and citations fused.
    static func hasUnqualifiedFullPrecisionSyntax(_ text: String) -> Bool {
        let monthPattern = monthNames.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        let patterns = [
            #"\d{4}-\d{1,2}-\d{1,2}"#,
            #"\d{1,2}/\d{1,2}/\d{4}"#,
            #"("# + monthPattern + #")\.?\s+\d{1,2}(?:st|nd|rd|th)?\s*,?\s*\d{4}"#,
            #"(?:the\s+)?\d{1,2}(?:st|nd|rd|th)?\s+day\s+of\s+("# + monthPattern + #")\.?\s*,?\s*\d{4}"#,
            #"\d{1,2}(?:st|nd|rd|th)?\s+("# + monthPattern + #")\.?\s*,?\s*\d{4}"#,
        ]
        let pattern = #"^\s*(?:"# + patterns.joined(separator: "|") + #")\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range)?.range == range
    }

    /// Whether a full date in surrounding prose is explicitly weakened or made
    /// relative (for example, "on or about", "before", or "no later than").
    /// Qualifiers must directly introduce the date so unrelated prose such as
    /// "filed by counsel on January 5" is not misclassified.
    static func hasPrecisionQualifierBeforeFullDate(_ text: String) -> Bool {
        let monthPattern = monthNames.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        let fullDatePatterns = [
            #"\d{4}-\d{1,2}-\d{1,2}"#,
            #"\d{1,2}/\d{1,2}/\d{4}"#,
            #"("# + monthPattern + #")\.?\s+\d{1,2}(?:st|nd|rd|th)?\s*,?\s*\d{4}"#,
            #"(?:the\s+)?\d{1,2}(?:st|nd|rd|th)?\s+day\s+of\s+("# + monthPattern + #")\.?\s*,?\s*\d{4}"#,
            #"\d{1,2}(?:st|nd|rd|th)?\s+("# + monthPattern + #")\.?\s*,?\s*\d{4}"#,
        ]
        let qualifier = #"(?:on\s+or\s+about|about|approximate(?:ly)?|around|circa|before|after|prior\s+to|no\s+later\s+than|not\s+later\s+than|by)"#
        let pattern = #"\b"# + qualifier + #"\s+(?:on\s+)?(?:"#
            + fullDatePatterns.joined(separator: "|") + #")\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    private static let monthNames: [String: Int] = [
        "january": 1, "jan": 1, "february": 2, "feb": 2,
        "march": 3, "mar": 3, "april": 4, "apr": 4,
        "may": 5, "june": 6, "jun": 6, "july": 7, "jul": 7,
        "august": 8, "aug": 8, "september": 9, "sep": 9, "sept": 9,
        "october": 10, "oct": 10, "november": 11, "nov": 11,
        "december": 12, "dec": 12,
    ]
}

/// One parsed chronology row: the raw Date-cell text, its canonical partial
/// date, the event text with citation markers stripped, and the row's `[S#]`
/// labels in first-appearance order. The strict table parser rejects a row whose
/// date syntax it cannot recognize; callers may still construct nil-date entries
/// explicitly when working with a known undated source.
public struct ChronologyEntry: Equatable, Sendable {
    public var dateText: String
    public var date: ChronologyDate?
    public var eventText: String
    public var labels: [String]

    public init(dateText: String, date: ChronologyDate?, eventText: String, labels: [String]) {
        self.dateText = dateText
        self.date = date
        self.eventText = eventText
        self.labels = labels
    }
}

/// Strict parser for `| Date | Event | Source |` map-pass output. Header and
/// decoration rows are neither entries nor unparsed. Any other non-empty line
/// that fails to parse as a three-column row counts as unparsed — including
/// prose mixed around otherwise valid rows — so model output is never silently
/// dropped. Markdown code-fence delimiters are tolerated as presentation only.
public enum ChronologyTableParser {
    public static func parse(_ markdown: String) -> (entries: [ChronologyEntry], unparsedRowCount: Int) {
        var entries: [ChronologyEntry] = []
        var unparsedRowCount = 0
        let normalizedNewlines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        for rawLine in normalizedNewlines.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("```") { continue }
            guard line.contains("|") else {
                unparsedRowCount += 1
                continue
            }
            if isDecoration(line) || isHeader(line) { continue }
            if let entry = parseRow(line) {
                entries.append(entry)
            } else {
                unparsedRowCount += 1
            }
        }
        return (entries, unparsedRowCount)
    }

    /// Splits a table line into trimmed cells, dropping only the empty edge
    /// components produced by a leading/trailing pipe.
    static func cells(of line: String) -> [String] {
        var components = line.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if line.hasPrefix("|"), components.first?.isEmpty == true { components.removeFirst() }
        if line.hasSuffix("|"), components.last?.isEmpty == true { components.removeLast() }
        return components
    }

    private static func parseRow(_ line: String) -> ChronologyEntry? {
        let rowCells = cells(of: line)
        guard rowCells.count == 3 else { return nil }
        let dateText = rowCells[0]
        let eventText = strippedEventText(rowCells[1])
        let eventLabels = CitationCoverage.usedLabels(in: rowCells[1])
        let sourceLabels = CitationCoverage.usedLabels(in: rowCells[2])
        guard !dateText.isEmpty,
              let parsedDate = ChronologyDate.parse(dateText),
              !eventText.isEmpty,
              !eventLabels.isEmpty,
              Set(eventLabels) == Set(sourceLabels)
        else { return nil }
        return ChronologyEntry(
            dateText: dateText,
            date: parsedDate,
            eventText: eventText,
            labels: eventLabels
        )
    }

    /// Event text with inline citation markers removed and whitespace collapsed,
    /// so the dedup key (and the rendered event column) is label-independent.
    private static func strippedEventText(_ cell: String) -> String {
        cell.replacingOccurrences(of: #"\[[A-Za-z]{1,3}\d{1,4}\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func isDecoration(_ line: String) -> Bool {
        line.replacingOccurrences(of: "|", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .trimmingCharacters(in: .whitespaces)
            .isEmpty
    }

    private static func isHeader(_ line: String) -> Bool {
        let headerTokens: Set<String> = ["date", "event", "source", "description", "fact", "document", "locator"]
        let rowCells = cells(of: line).filter { !$0.isEmpty }
        guard !rowCells.isEmpty else { return false }
        return rowCells.allSatisfy { headerTokens.contains($0.lowercased()) }
    }
}

/// Deterministic merge of per-batch chronology entries plus the shared table
/// renderer for the merged result.
public enum ChronologyMerge {
    /// Merges batches in order: duplicates collapse on canonical date +
    /// case/whitespace-folded event text with their labels unioned in numeric
    /// ascending order; the result sorts by date ascending with a stable
    /// tie-break, and undated entries trail in encounter order.
    ///
    /// SEMANTIC CHOICE (documented per work order): when duplicates differ in
    /// surface form (dateText rendering, event casing/spacing), the
    /// FIRST-ENCOUNTERED variant survives — earlier batches cover earlier
    /// documents, so the first phrasing is the one already anchored to the
    /// lowest-numbered labels.
    public static func merge(_ batches: [[ChronologyEntry]]) -> [ChronologyEntry] {
        var keyOrder: [String] = []
        var entriesByKey: [String: ChronologyEntry] = [:]

        for batch in batches {
            for entry in batch {
                let key = dedupKey(entry)
                if var existing = entriesByKey[key] {
                    existing.labels = unionLabels(existing.labels, entry.labels)
                    entriesByKey[key] = existing
                } else {
                    entriesByKey[key] = entry
                    keyOrder.append(key)
                }
            }
        }

        let unique = keyOrder.compactMap { entriesByKey[$0] }
        // Explicit encounter-index tie-break: stable regardless of the standard
        // library sort's stability guarantees.
        return unique.enumerated().sorted { lhs, rhs in
            switch (lhs.element.date, rhs.element.date) {
            case let (left?, right?):
                if left != right { return left < right }
                return lhs.offset < rhs.offset
            case (nil, nil):
                return lhs.offset < rhs.offset
            case (nil, .some):
                return false
            case (.some, nil):
                return true
            }
        }.map(\.element)
    }

    /// Renders merged entries back into the standard `| Date | Event | Source |`
    /// table (header + decoration row), citing each row's labels inline in the
    /// event column and in the source column, so `parse(renderTable(entries))`
    /// round-trips the entries exactly.
    public static func renderTable(_ entries: [ChronologyEntry]) -> String {
        var lines = ["| Date | Event | Source |", "|---|---|---|"]
        for entry in entries {
            let citations = entry.labels.map { "[\($0)]" }.joined(separator: " ")
            let event = citations.isEmpty ? entry.eventText : "\(entry.eventText) \(citations)"
            lines.append("| \(entry.dateText) | \(event) | \(citations) |")
        }
        return lines.joined(separator: "\n")
    }

    private static func dedupKey(_ entry: ChronologyEntry) -> String {
        let canonicalDate: String
        if let date = entry.date,
           date.year != nil,
           date.month != nil,
           date.day != nil,
           ChronologyDate.hasUnqualifiedFullPrecisionSyntax(entry.dateText) {
            canonicalDate = "\(date.year.map(String.init) ?? "_")-\(date.month.map(String.init) ?? "_")-\(date.day.map(String.init) ?? "_")"
        } else {
            // Partial/unknown date text can carry material distinctions that the
            // canonical components cannot represent (for example Spring versus
            // Fall 2024). Deduplicating those rows on year alone can attach one
            // source's citation to a different event, so only full dates may
            // deduplicate across surface renderings.
            canonicalDate = "partial:" + entry.dateText
                .lowercased()
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let foldedEvent = entry.eventText
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return canonicalDate + "|" + foldedEvent
    }

    /// Union preserving every label once, sorted numerically by the label's
    /// digits ("S2" before "S10"; non-numeric labels trail lexicographically).
    private static func unionLabels(_ first: [String], _ second: [String]) -> [String] {
        var union = first
        for label in second where !union.contains(label) {
            union.append(label)
        }
        return union.sorted { lhs, rhs in
            switch (labelNumber(lhs), labelNumber(rhs)) {
            case let (left?, right?):
                if left != right { return left < right }
                return lhs < rhs
            case (nil, nil):
                return lhs < rhs
            case (nil, .some):
                return false
            case (.some, nil):
                return true
            }
        }
    }

    private static func labelNumber(_ label: String) -> Int? {
        guard let digits = label.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(label[digits])
    }
}

/// Plans which prepared sources go into which map pass. Greedy fill by a
/// caller-supplied size budget; a document's items stay contiguous in ONE batch unless
/// the document alone exceeds the budget, in which case it splits at item
/// boundaries (never mid-item) and its final partial batch closes without
/// taking neighbors. Batches are ordered by `orderDate` ascending with nil
/// dates last (stable on input order); `sourceIndices` always refer to the
/// input `items` array.
public enum ChronologyBatchPlanner {
    public struct Item: Sendable {
        public var documentKey: String
        public var charCount: Int
        public var orderDate: Date?

        public init(documentKey: String, charCount: Int, orderDate: Date?) {
            self.documentKey = documentKey
            self.charCount = charCount
            self.orderDate = orderDate
        }
    }

    public static func plan(items: [Item], characterBudget: Int) -> [ChronologyBatch] {
        let budget = max(1, characterBudget)

        // Group item indices by document (first-appearance order); a group's
        // order date is its first item's non-nil date.
        var groups: [(indices: [Int], orderDate: Date?)] = []
        var groupIndexByKey: [String: Int] = [:]
        for (index, item) in items.enumerated() {
            if let groupIndex = groupIndexByKey[item.documentKey] {
                groups[groupIndex].indices.append(index)
                if groups[groupIndex].orderDate == nil { groups[groupIndex].orderDate = item.orderDate }
            } else {
                groupIndexByKey[item.documentKey] = groups.count
                groups.append(([index], item.orderDate))
            }
        }

        let orderedGroups = groups.enumerated().sorted { lhs, rhs in
            switch (lhs.element.orderDate, rhs.element.orderDate) {
            case let (left?, right?):
                if left != right { return left < right }
                return lhs.offset < rhs.offset
            case (nil, nil):
                return lhs.offset < rhs.offset
            case (nil, .some):
                return false
            case (.some, nil):
                return true
            }
        }.map(\.element)

        var batches: [[Int]] = []
        var current: [Int] = []
        var currentTotal = 0

        func closeBatch() {
            if !current.isEmpty {
                batches.append(current)
                current = []
                currentTotal = 0
            }
        }

        for group in orderedGroups {
            let groupTotal = group.indices.reduce(0) { $0 + items[$1].charCount }
            if groupTotal > budget {
                // Oversized document: it owns its batches, split at item boundaries.
                closeBatch()
                for index in group.indices {
                    let size = items[index].charCount
                    if !current.isEmpty, currentTotal + size > budget { closeBatch() }
                    current.append(index)
                    currentTotal += size
                }
                closeBatch()
            } else {
                if !current.isEmpty, currentTotal + groupTotal > budget { closeBatch() }
                current.append(contentsOf: group.indices)
                currentTotal += groupTotal
            }
        }
        closeBatch()

        return batches.map { ChronologyBatch(sourceIndices: $0) }
    }
}

/// One planned map pass: the indices (into the planner's input array) of the
/// sources this pass covers.
public struct ChronologyBatch: Equatable, Sendable {
    public var sourceIndices: [Int]

    public init(sourceIndices: [Int]) {
        self.sourceIndices = sourceIndices
    }
}

/// Deterministic completeness audit for a synthesized narrative. Citation-label
/// coverage alone is insufficient because one source can support several dated
/// entries; each entry must have a same-label narrative span with the same date
/// and all of the entry's material event tokens in order. The matcher is
/// intentionally conservative: a rewrite it cannot establish is surfaced for
/// review rather than treated as complete.
public enum ChronologyNarrativeCoverage {
    public static func omittedEntries(
        from entries: [ChronologyEntry],
        in narrative: String
    ) -> [ChronologyEntry] {
        let spans = candidateSpans(in: narrative)
        var availableSpanIndices = Array(spans.indices)
        var omitted: [ChronologyEntry] = []
        for entry in entries {
            if let availableOffset = availableSpanIndices.firstIndex(where: { index in
                represents(entry, span: spans[index])
            }) {
                // A single synthesized sentence can establish at most one merged
                // entry. Otherwise a longer sentence can silently stand in for
                // several distinct source facts that synthesis dropped.
                availableSpanIndices.remove(at: availableOffset)
            } else {
                omitted.append(entry)
            }
        }
        return omitted
    }

    private static func represents(_ entry: ChronologyEntry, span: String) -> Bool {
        let usedLabels = Set(CitationCoverage.usedLabels(in: span))
        // Synthesis may neither drop nor add a label for an entry. Allowing an
        // extra, otherwise valid source here would let the aggregate verifier's
        // any-supporting-citation rule launder a citation that does not support
        // this particular fact.
        guard Set(entry.labels) == usedLabels else { return false }

        if let entryDate = entry.date {
            guard ChronologyDate.parse(span) == entryDate else { return false }
            if entryDate.month != nil,
               entryDate.day != nil,
               ChronologyDate.hasUnqualifiedFullPrecisionSyntax(entry.dateText),
               ChronologyDate.hasPrecisionQualifierBeforeFullDate(span) {
                return false
            }
            if entryDate.month == nil
                || entryDate.day == nil
                || !ChronologyDate.hasUnqualifiedFullPrecisionSyntax(entry.dateText) {
                guard isOrderedSubsequence(materialTokens(in: entry.dateText), of: materialTokens(in: span)) else {
                    return false
                }
            }
        }

        let eventTokens = materialTokens(in: entry.eventText)
        guard !eventTokens.isEmpty else { return false }
        return isOrderedSubsequence(eventTokens, of: materialTokens(in: span))
    }

    private static func candidateSpans(in narrative: String) -> [String] {
        var spans: [String] = []
        let nsNarrative = narrative as NSString
        let fullRange = NSRange(location: 0, length: nsNarrative.length)
        if let regex = try? NSRegularExpression(pattern: #"[^.!?\n]+(?:[.!?]+|$)"#) {
            for match in regex.matches(in: narrative, range: fullRange) {
                let sentence = nsNarrative.substring(with: match.range)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty, !spans.contains(sentence) { spans.append(sentence) }
            }
        }
        if spans.isEmpty {
            let fallback = narrative.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fallback.isEmpty { spans.append(fallback) }
        }
        return spans
    }

    private static func materialTokens(in text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let tokens = folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return tokens.filter { !stopWords.contains($0) }
    }

    private static func isOrderedSubsequence(_ required: [String], of available: [String]) -> Bool {
        guard !required.isEmpty else { return true }
        var nextIndex = 0
        for token in required {
            guard nextIndex < available.count,
                  let match = available[nextIndex...].firstIndex(of: token)
            else { return false }
            nextIndex = match + 1
        }
        return true
    }

    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "been", "by", "for",
        "from", "in", "is", "of", "on", "or", "the", "to", "was", "were", "with",
    ]
}
