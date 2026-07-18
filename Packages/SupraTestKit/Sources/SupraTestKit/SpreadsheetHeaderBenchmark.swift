import Foundation

public struct SpreadsheetHeaderAssociation: Hashable, Sendable {
    public var sourceFilename: String
    public var sheetName: String
    public var cellReference: String
    public var headerReference: String

    public init(
        sourceFilename: String,
        sheetName: String,
        cellReference: String,
        headerReference: String
    ) {
        self.sourceFilename = sourceFilename
        self.sheetName = sheetName
        self.cellReference = cellReference.uppercased()
        self.headerReference = headerReference.uppercased()
    }

    fileprivate var benchmarkKey: String {
        "\(sourceFilename)|\(sheetName)|\(cellReference)->\(headerReference)"
    }
}

/// Corpus-derived scoring for the revision-bound XLSX `header_for` graph.
///
/// Explicit table ranges are the golden source. Every data cell must point to
/// its same-column header; cells beyond the first column must also point to the
/// first cell in their row so legal table retrieval retains row context.
public enum SpreadsheetHeaderBenchmark {
    public static func expectedAssociations(in specification: MatterSpec) -> Set<SpreadsheetHeaderAssociation> {
        var expected = Set<SpreadsheetHeaderAssociation>()
        for document in specification.documents where document.format == .xlsx {
            for sheet in document.spreadsheet ?? [] {
                guard let table = sheet.table,
                      let range = CellRange(table.range),
                      range.minRow < range.maxRow else { continue }
                for row in (range.minRow + 1)...range.maxRow {
                    for column in range.minColumn...range.maxColumn {
                        let cell = cellReference(column: column, row: row)
                        expected.insert(SpreadsheetHeaderAssociation(
                            sourceFilename: document.filename,
                            sheetName: sheet.sheet,
                            cellReference: cell,
                            headerReference: cellReference(column: column, row: range.minRow)
                        ))
                        if column > range.minColumn {
                            expected.insert(SpreadsheetHeaderAssociation(
                                sourceFilename: document.filename,
                                sheetName: sheet.sheet,
                                cellReference: cell,
                                headerReference: cellReference(column: range.minColumn, row: row)
                            ))
                        }
                    }
                }
            }
        }
        return expected
    }

    public static func observations(
        expected: Set<SpreadsheetHeaderAssociation>,
        predicted: [SpreadsheetHeaderAssociation]
    ) -> [BenchmarkObservation] {
        let score = BenchmarkMetrics.setScore(
            expected: Set(expected.map(\.benchmarkKey)),
            predicted: predicted.map(\.benchmarkKey)
        )
        return [
            BenchmarkObservation(
                metricID: "B-TAB-01",
                name: "header_association_precision",
                unit: "rate",
                result: score.precision
            ),
            BenchmarkObservation(
                metricID: "B-TAB-01",
                name: "header_association_recall",
                unit: "rate",
                result: score.recall
            ),
            BenchmarkObservation(
                metricID: "B-TAB-01",
                name: "header_association_f1",
                unit: "rate",
                result: score.f1
            ),
        ]
    }

    private struct CellRange {
        let minColumn: Int
        let maxColumn: Int
        let minRow: Int
        let maxRow: Int

        init?(_ value: String) {
            let endpoints = value.uppercased().split(separator: ":", omittingEmptySubsequences: false)
            guard endpoints.count == 2,
                  let first = Self.cell(String(endpoints[0])),
                  let last = Self.cell(String(endpoints[1])) else { return nil }
            minColumn = min(first.column, last.column)
            maxColumn = max(first.column, last.column)
            minRow = min(first.row, last.row)
            maxRow = max(first.row, last.row)
        }

        private static func cell(_ reference: String) -> (column: Int, row: Int)? {
            let letters = reference.prefix { $0.isLetter }
            let digits = reference.dropFirst(letters.count)
            guard !letters.isEmpty, let row = Int(digits), row > 0 else { return nil }
            var column = 0
            for scalar in letters.unicodeScalars {
                let value = Int(scalar.value) - Int(UnicodeScalar("A").value) + 1
                guard (1...26).contains(value) else { return nil }
                column = column * 26 + value
            }
            return (column, row)
        }
    }

    private static func cellReference(column: Int, row: Int) -> String {
        precondition(column > 0 && row > 0)
        var value = column
        var letters = ""
        while value > 0 {
            value -= 1
            letters.insert(Character(UnicodeScalar(65 + value % 26)!), at: letters.startIndex)
            value /= 26
        }
        return "\(letters)\(row)"
    }
}
