import Darwin
import Foundation
@testable import SupraDocuments
import XCTest

final class DurableFileWriterBoundedReadTests: XCTestCase {
    // ACR-FILE-042a. Expected compile RED at c0d4b1f0: the validation API has
    // no caller-supplied authoritative byte count, so descriptor reads are
    // sized only by mutable filesystem state.
    func testACRFILE042ValidatedReadRejectsMismatchedExpectedByteCountBeforeValidator() throws {
        try assertExpectedByteCountMismatch(durable: false)
    }

    // ACR-FILE-042b. Relaunch durability validation must enforce the same bound
    // before validator, exact-file fsync, or parent-directory synchronization.
    func testACRFILE042DurableReadRejectsMismatchedExpectedByteCountBeforeValidator() throws {
        try assertExpectedByteCountMismatch(durable: true)
    }

    private func assertExpectedByteCountMismatch(
        durable: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Supra-Bounded-Read-\(durable)-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent("matter-123", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let destination = parent.appendingPathComponent("artifact.md")
        let payload = Data(repeating: 0x5a, count: (64 * 1_024) + 37)
        try payload.write(to: destination)
        let writer = DurableFileWriter()
        let identity = try XCTUnwrap(
            writer.installedFileIdentity(at: destination, containedIn: root),
            file: file,
            line: line
        )
        var validatorCalls = 0

        XCTAssertThrowsError(
            try {
                if durable {
                    return try writer.durablyValidatedInstalledFileData(
                        matching: identity,
                        at: destination,
                        containedIn: root,
                        expectedByteCount: payload.count - 1,
                        validator: { _ in validatorCalls += 1 }
                    )
                }
                return try writer.validatedInstalledFileData(
                    matching: identity,
                    at: destination,
                    containedIn: root,
                    expectedByteCount: payload.count - 1,
                    validator: { _ in validatorCalls += 1 }
                )
            }(),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? DurableFileWriter.WriterError,
                .retainedManagedFileChanged(destination.lastPathComponent),
                file: file,
                line: line
            )
        }

        XCTAssertEqual(validatorCalls, 0, file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: destination), payload, file: file, line: line)
        XCTAssertEqual(
            try DocumentStorage.sha256Hex(ofFileAt: destination),
            DocumentStorage.sha256Hex(of: payload),
            file: file,
            line: line
        )
        var status = stat()
        XCTAssertEqual(
            destination.path.withCString { Darwin.lstat($0, &status) },
            0,
            file: file,
            line: line
        )
        XCTAssertEqual(UInt64(status.st_nlink), 1, file: file, line: line)
    }
}
