import Foundation
@testable import SupraDocuments
import XCTest

final class DurableFileWriterTests: XCTestCase {
    func testACRFILE001FaultsPreserveExistingDestinationAndRemoveTemporaryFiles() throws {
        for stage in DurableFileWriter.FaultStage.allCases {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let destination = directory.appendingPathComponent("output.txt")
            try Data("old-canary".utf8).write(to: destination)
            let writer = DurableFileWriter { observed in
                if observed == stage { throw InjectedFailure(stage: stage) }
            }

            XCTAssertThrowsError(
                try writer.write(Data("new-value".utf8), to: destination) { temporary in
                    XCTAssertEqual(try Data(contentsOf: temporary), Data("new-value".utf8))
                },
                "Expected injected failure at \(stage)"
            )
            XCTAssertEqual(try Data(contentsOf: destination), Data("old-canary".utf8))
            XCTAssertTrue(try temporaryArtifacts(in: directory).isEmpty)
        }
    }

    func testACRFILE002WriterFailureLeavesNewDestinationAbsentAndCleansPartialFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("new.txt")
        let writer = DurableFileWriter()

        XCTAssertThrowsError(
            try writer.write(to: destination, writer: { sink in
                try sink.write(Data("partial-private-data".utf8))
                throw InjectedFailure(stage: .duringWrite)
            }, validator: { _ in })
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(try temporaryArtifacts(in: directory).isEmpty)
    }

    func testACRFILE003ValidatorFailurePreservesExistingBytes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("validated.txt")
        try Data("known-good".utf8).write(to: destination)

        XCTAssertThrowsError(
            try DurableFileWriter().write(Data("malformed".utf8), to: destination) { _ in
                throw InjectedFailure(stage: .beforeValidation)
            }
        )

        XCTAssertEqual(try Data(contentsOf: destination), Data("known-good".utf8))
        XCTAssertTrue(try temporaryArtifacts(in: directory).isEmpty)
    }

    func testACRFILE004SuccessfulReplacementIsCompleteValidatedAndSameDirectory() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("complete.txt")
        try Data("old".utf8).write(to: destination)
        var validatedURL: URL?

        try DurableFileWriter().write(Data("complete-new-value".utf8), to: destination) { temporary in
            validatedURL = temporary
            XCTAssertEqual(temporary.deletingLastPathComponent(), destination.deletingLastPathComponent())
            XCTAssertEqual(try String(contentsOf: temporary, encoding: .utf8), "complete-new-value")
        }

        XCTAssertNotEqual(validatedURL, destination)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "complete-new-value")
        XCTAssertTrue(try temporaryArtifacts(in: directory).isEmpty)
    }

    func testACRFILE005CancellationUsesFailureGuarantees() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("cancelled.txt")
        try Data("old-canary".utf8).write(to: destination)
        let writer = DurableFileWriter { stage in
            if stage == .beforeInstall { throw CancellationError() }
        }

        XCTAssertThrowsError(
            try writer.write(Data("new".utf8), to: destination, validator: { _ in })
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data("old-canary".utf8))
        XCTAssertTrue(try temporaryArtifacts(in: directory).isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Supra-DurableFileWriter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func temporaryArtifacts(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".supra-tmp-") }
    }
}

private struct InjectedFailure: Error {
    let stage: DurableFileWriter.FaultStage
}
