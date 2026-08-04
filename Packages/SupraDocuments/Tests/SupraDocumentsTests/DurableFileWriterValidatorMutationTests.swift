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
                    XCTAssertTrue(
                        String(describing: error)
                            .contains("publicDestinationStillLinkedWithoutRetainedQuarantine"),
                        "call=\(mutationCall), throws=\(throwsAfterMutation), error=\(error)"
                    )
                }

                XCTAssertEqual(validationCallCount, mutationCall)
                XCTAssertEqual(try Data(contentsOf: destination), payload)
                XCTAssertEqual(try Data(contentsOf: XCTUnwrap(quarantine)), foreignBytes)
            }
        }
    }
}
