import Foundation
import SupraCore
@testable import SupraTestKit
import XCTest

/// T-UTILITY-01
///
/// Expected RED: no shared, versioned canonical-JSON encoder or lowercase SHA-256 formatter
/// exists in SupraCore, and the three protocol-significant TestKit reports each configure a
/// private JSONEncoder instead of delegating to one byte contract.
final class ArchitectureUXTUtility01Tests: XCTestCase {
    private enum Wire {
        static let marker = "T_UTILITY_01_WIRE_731"
        static let recordID = "record-713"
        static let forbiddenDefault = "DEFAULT-000"

        struct Nested: Codable {
            let identity: String
            let version: Int
        }

        struct Value: Codable {
            let marker: String
            let nested: Nested
            let path: String
            let values: [Int]
        }

        static let value = Value(
            marker: marker,
            nested: Nested(identity: recordID, version: 7),
            path: "synthetic/v7/item",
            values: [7, 8]
        )
    }

    func testVersionOneCanonicalJSONAndDigestVectorsAreByteExact() throws {
        let compact = try CanonicalJSON.encode(
            Wire.value,
            version: .v1,
            presentation: .compact
        )
        let expectedCompact = Data(
            #"{"marker":"T_UTILITY_01_WIRE_731","nested":{"identity":"record-713","version":7},"path":"synthetic/v7/item","values":[7,8]}"#.utf8
        )
        XCTAssertEqual(compact, expectedCompact)
        XCTAssertEqual(
            SHA256Digest.lowercaseHex(compact),
            "3f822e22656f9f6109f4c1aa636c3b59c2283b7dbf32d737e2f6abd147752167"
        )

        let pretty = try CanonicalJSON.encode(
            Wire.value,
            version: .v1,
            presentation: .prettyPrinted
        )
        let expectedPretty = Data(#"""
        {
          "marker" : "T_UTILITY_01_WIRE_731",
          "nested" : {
            "identity" : "record-713",
            "version" : 7
          },
          "path" : "synthetic/v7/item",
          "values" : [
            7,
            8
          ]
        }
        """#.utf8)
        XCTAssertEqual(pretty, expectedPretty)
        XCTAssertEqual(
            SHA256Digest.lowercaseHex(pretty),
            "68d9c7033cb02965e5c32451c8c6600d4346d57e834e48ae4f1c645ce7183775"
        )

        let exactOutputs = [compact, pretty].map { String(decoding: $0, as: UTF8.self) }
        XCTAssertTrue(exactOutputs.allSatisfy { $0.contains(Wire.marker) })
        XCTAssertTrue(exactOutputs.allSatisfy { $0.contains(Wire.recordID) })
        XCTAssertFalse(exactOutputs.joined(separator: "\n").contains(Wire.forbiddenDefault))
    }

    func testProtocolSignificantReportsUseTheExplicitVersionOnePrettyContract() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SupraTestKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // SupraTestKit
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository
        let sourcePaths = [
            "Packages/SupraTestKit/Sources/SupraTestKit/BenchmarkReport.swift",
            "Packages/SupraTestKit/Sources/SupraTestKit/PerformanceBenchmark.swift",
            "Packages/SupraTestKit/Sources/SupraTestKit/ChunkerComparisonReport.swift",
        ]

        for relativePath in sourcePaths {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            XCTAssertTrue(source.contains("CanonicalJSON.encode("), relativePath)
            XCTAssertTrue(source.contains("version: .v1"), relativePath)
            XCTAssertTrue(source.contains("presentation: .prettyPrinted"), relativePath)
            XCTAssertFalse(source.contains("JSONEncoder()"), relativePath)
            XCTAssertFalse(source.contains("outputFormatting"), relativePath)
        }
    }
}
