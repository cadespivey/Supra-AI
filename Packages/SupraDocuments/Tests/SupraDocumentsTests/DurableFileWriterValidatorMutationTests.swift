import Foundation
@testable import SupraDocuments
import XCTest

final class DurableFileWriterValidatorMutationTests: XCTestCase {
    private enum InjectedFailure: Error {
        case missingQuarantine
        case stop
    }

    // ACR-FILE-024. Both the returning and throwing content-validator boundaries
    // can move the exact quarantine to public and replace its old name with
    // foreign bytes. Classification must report a public exact survivor without
    // claiming that exact rollback material remains at the foreign name.
    func testACRFILE024ValidatorMutationClassifiesPublicOnlyExactSurvivor() throws {
        for mutationCall in [1, 2] {
            for throwsAfterMutation in [false, true] {
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "Supra-Validator-Mutation-\(UUID().uuidString)",
                        isDirectory: true
                    )
                defer { try? FileManager.default.removeItem(at: root) }
                let destination = root
                    .appendingPathComponent("exports", isDirectory: true)
                    .appendingPathComponent("matter-123", isDirectory: true)
                    .appendingPathComponent("motion.md")
                let payload = Data("# Exact validator survivor\n".utf8)
                let foreignBytes = Data("foreign-validator-quarantine".utf8)
                let writer = DurableFileWriter()
                let identity = try writer.writeNewOwned(
                    payload,
                    to: destination,
                    containedIn: root,
                    validator: { _ in }
                )
                var quarantine: URL?
                var validationCallCount = 0

                XCTAssertThrowsError(
                    try writer.removeInstalledFile(
                        matching: identity,
                        at: destination,
                        containedIn: root,
                        quarantineCheckpoint: { _, candidate in quarantine = candidate },
                        contentValidator: { _ in
                            validationCallCount += 1
                            guard validationCallCount == mutationCall else { return }
                            guard let quarantine else {
                                throw InjectedFailure.missingQuarantine
                            }
                            try FileManager.default.moveItem(at: quarantine, to: destination)
                            try foreignBytes.write(to: quarantine)
                            if throwsAfterMutation { throw InjectedFailure.stop }
                        }
                    )
                ) { error in
                    guard case .publicDestinationStillLinkedWithoutRetainedQuarantine =
                        error as? DurableFileWriter.WriterError else {
                        return XCTFail(
                            "call=\(mutationCall), throws=\(throwsAfterMutation), error=\(error)"
                        )
                    }
                }

                XCTAssertEqual(validationCallCount, mutationCall)
                XCTAssertEqual(try Data(contentsOf: destination), payload)
                XCTAssertEqual(try Data(contentsOf: XCTUnwrap(quarantine)), foreignBytes)
            }
        }
    }

    // ACR-FILE-027. A returning validator may mutate the same quarantined inode
    // after checking the immutable Data it received. The final boundary must
    // bind that validated value to a second descriptor-bound read before unlink.
    func testACRFILE027FinalReturningValidatorMutationRetainsQuarantine() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Supra-Final-Validator-Mutation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent("matter-123", isDirectory: true)
            .appendingPathComponent("motion.md")
        let payload = Data("# Validated rollback bytes\n".utf8)
        let mutated = Data("# Mutated after returning validation\n".utf8)
        let writer = DurableFileWriter()
        let identity = try writer.writeNewOwned(
            payload,
            to: destination,
            containedIn: root,
            validator: { _ in }
        )
        var quarantine: URL?
        var validationCallCount = 0

        XCTAssertThrowsError(
            try writer.removeInstalledFile(
                matching: identity,
                at: destination,
                containedIn: root,
                quarantineCheckpoint: { _, candidate in quarantine = candidate },
                contentValidator: { _ in
                    validationCallCount += 1
                    guard validationCallCount == 2 else { return }
                    let handle = try FileHandle(forWritingTo: XCTUnwrap(quarantine))
                    defer { try? handle.close() }
                    try handle.truncate(atOffset: 0)
                    try handle.write(contentsOf: mutated)
                    try handle.synchronize()
                }
            )
        ) { error in
            guard case let .retainedQuarantineChanged(name) =
                error as? DurableFileWriter.WriterError else {
                return XCTFail("expected retained-quarantine change, got \(error)")
            }
            guard let quarantine else {
                return XCTFail("compensation never exposed its quarantine name")
            }
            XCTAssertEqual(name, quarantine.lastPathComponent)
        }

        XCTAssertEqual(validationCallCount, 2)
        let retained = try XCTUnwrap(quarantine)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        if FileManager.default.fileExists(atPath: retained.path) {
            XCTAssertEqual(try Data(contentsOf: retained), mutated)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
