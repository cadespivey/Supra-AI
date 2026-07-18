import SupraTestKit
import XCTest

final class SpreadsheetHeaderBenchmarkTests: XCTestCase {
    /// Expected RED: `SpreadsheetHeaderBenchmark` does not exist until M4-W4
    /// turns the XLSX `header_for` graph into a deterministic B-TAB score.
    func testExpectedAssociationsIncludeColumnAndRowHeadersForExplicitTables() throws {
        let specification = try MatterSpec.decode(from: Data(#"""
        {
          "matterName": "Synthetic Matter",
          "jurisdiction": "Test",
          "partyPerspective": "Neutral",
          "practiceArea": "Test",
          "summary": "Synthetic benchmark fixture",
          "attorneyNotesMarkdown": "",
          "benchmarkProfile": "document-intelligence",
          "documents": [{
            "filename": "damages.xlsx",
            "folder": "Evidence",
            "format": "xlsx",
            "spreadsheet": [{
              "sheet": "Line Items",
              "cells": [
                ["Category", "Amount", "Source"],
                ["Labor", "100", "Invoice"],
                ["Materials", "200", "Receipt"]
              ],
              "table": {
                "name": "DamagesTable",
                "range": "A1:C3",
                "headers": ["Category", "Amount", "Source"]
              }
            }]
          }],
          "answerKey": {
            "qa": [],
            "chronology": [],
            "taskKeys": {
              "lists": [], "chronology": [], "comparisons": [],
              "contradictions": [], "negatives": [], "structures": [], "versions": []
            }
          }
        }
        """#.utf8))

        let associations = SpreadsheetHeaderBenchmark.expectedAssociations(in: specification)

        XCTAssertEqual(associations.count, 10)
        XCTAssertTrue(associations.contains(.init(
            sourceFilename: "damages.xlsx",
            sheetName: "Line Items",
            cellReference: "B2",
            headerReference: "B1"
        )))
        XCTAssertTrue(associations.contains(.init(
            sourceFilename: "damages.xlsx",
            sheetName: "Line Items",
            cellReference: "B2",
            headerReference: "A2"
        )))
        XCTAssertFalse(associations.contains(.init(
            sourceFilename: "damages.xlsx",
            sheetName: "Line Items",
            cellReference: "A1",
            headerReference: "A1"
        )))
    }

    /// Expected RED: B-TAB observations are unavailable until the benchmark
    /// compares persisted graph edges with the corpus-derived golden set.
    func testObservationsExposeExactPrecisionRecallAndF1() throws {
        let expected: Set<SpreadsheetHeaderAssociation> = [
            .init(sourceFilename: "book.xlsx", sheetName: "Sheet1", cellReference: "B2", headerReference: "B1"),
            .init(sourceFilename: "book.xlsx", sheetName: "Sheet1", cellReference: "B2", headerReference: "A2"),
        ]
        let predicted = [
            SpreadsheetHeaderAssociation(
                sourceFilename: "book.xlsx", sheetName: "Sheet1", cellReference: "B2", headerReference: "B1"
            ),
            SpreadsheetHeaderAssociation(
                sourceFilename: "book.xlsx", sheetName: "Sheet1", cellReference: "B2", headerReference: "C1"
            ),
        ]

        let observations = SpreadsheetHeaderBenchmark.observations(
            expected: expected,
            predicted: predicted
        )

        XCTAssertEqual(observations.map(\.metricID), ["B-TAB-01", "B-TAB-01", "B-TAB-01"])
        XCTAssertEqual(observations.map(\.name), [
            "header_association_precision",
            "header_association_recall",
            "header_association_f1",
        ])
        XCTAssertEqual(observations.compactMap(\.result.value), [0.5, 0.5, 0.5])
    }
}
