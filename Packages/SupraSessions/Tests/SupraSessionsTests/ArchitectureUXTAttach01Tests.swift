import Foundation
@testable import SupraSessions
import XCTest

/// T-ATTACH-01. Quick-attachment limits are per attachment, not per turn,
/// and every context carries the exact provenance needed to disclose a partial
/// read without turning the truncation notice into source text.
///
/// Expected RED: `ChatAttachmentContext` has no typed counts, extraction mode,
/// truncation, durability, verification, source URL, or presentation contract.
/// Its current capped text also appends a notice after the 40,000 included
/// characters, so the exact N/N+1 inclusion postcondition is false.
final class ArchitectureUXTAttach01Tests: XCTestCase {
    private enum Wire {
        static let recordID = "record-713"
        static let version = 7
        static let nextVersion = 8
        static let exactName = "T_ATTACH_01_WIRE_731_N_40000.txt"
        static let overflowName = "T_ATTACH_01_WIRE_731_N_PLUS_1_40001.txt"
        static let exactBoundary = "⑦"
        static let excludedBoundary = "⑧"
        static let forbiddenDefault = "DEFAULT-000"
    }

    func testExact40000And40001BoundaryCarriesTypedTruthfulMetadata() async throws {
        let fixture = try makeBoundaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let loader = ChatAttachmentLoader()

        let exact = try await loader.load(url: fixture.exactURL)
        let overflow = try await loader.load(url: fixture.overflowURL)

        XCTAssertEqual(ChatAttachmentLoader.maxCharacters, 40_000)
        assertMetadata(
            exact,
            sourceURL: fixture.exactURL,
            originalCount: 40_000,
            includedCount: 40_000,
            isTruncated: false,
            contentStatus: "Full content"
        )
        assertMetadata(
            overflow,
            sourceURL: fixture.overflowURL,
            originalCount: 40_001,
            includedCount: 40_000,
            isTruncated: true,
            contentStatus: "Partial content"
        )

        XCTAssertEqual(exact.text.count, 40_000)
        XCTAssertEqual(overflow.text.count, 40_000)
        XCTAssertTrue(exact.text.hasSuffix(Wire.exactBoundary))
        XCTAssertTrue(overflow.text.hasSuffix(Wire.exactBoundary))
        XCTAssertFalse(overflow.text.contains(Wire.excludedBoundary))
        XCTAssertFalse(
            overflow.text.contains("Attachment truncated"),
            "the included source text must remain exactly N characters; disclosure is typed metadata"
        )
    }

    func testMultiAttachmentBlockMarksOnlyTheNPlusOneAttachmentPartial() async throws {
        let fixture = try makeBoundaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let loader = ChatAttachmentLoader()
        let exact = try await loader.load(url: fixture.exactURL)
        let overflow = try await loader.load(url: fixture.overflowURL)

        let attachments = [exact, overflow]
        let block = GlobalChatController.attachmentsBlock(attachments)

        XCTAssertEqual(attachments.filter { $0.isTruncated }.map(\.name), [Wire.overflowName])
        XCTAssertEqual(attachments.filter { !$0.isTruncated }.map(\.name), [Wire.exactName])
        XCTAssertEqual(occurrences(of: "Partial content", in: block), 1)
        XCTAssertEqual(occurrences(of: "Full content", in: block), 1)
        XCTAssertTrue(block.contains("[S1] \(Wire.exactName)"))
        XCTAssertTrue(block.contains("[S2] \(Wire.overflowName)"))
        XCTAssertTrue(block.contains(Wire.exactBoundary))
        XCTAssertFalse(block.contains(Wire.excludedBoundary))
        XCTAssertFalse(block.contains(Wire.forbiddenDefault))
    }

    private func assertMetadata(
        _ attachment: ChatAttachmentContext,
        sourceURL: URL,
        originalCount: Int,
        includedCount: Int,
        isTruncated: Bool,
        contentStatus: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(attachment.sourceURL, sourceURL, file: file, line: line)
        XCTAssertEqual(
            attachment.originalCharacterCount,
            originalCount,
            file: file,
            line: line
        )
        XCTAssertEqual(
            attachment.includedCharacterCount,
            includedCount,
            file: file,
            line: line
        )
        XCTAssertEqual(attachment.extractionMode, .plainText, file: file, line: line)
        XCTAssertEqual(attachment.isTruncated, isTruncated, file: file, line: line)
        XCTAssertEqual(attachment.durability, .sessionOnly, file: file, line: line)
        XCTAssertEqual(attachment.verificationState, .unverified, file: file, line: line)
        XCTAssertEqual(attachment.presentation.title, "Quick attachment", file: file, line: line)
        XCTAssertEqual(
            attachment.presentation.contentStatus,
            contentStatus,
            file: file,
            line: line
        )
        XCTAssertEqual(
            attachment.presentation.originalCharacterCount,
            originalCount,
            file: file,
            line: line
        )
        XCTAssertEqual(
            attachment.presentation.includedCharacterCount,
            includedCount,
            file: file,
            line: line
        )
        XCTAssertEqual(
            attachment.presentation.durabilityStatus,
            "Session only",
            file: file,
            line: line
        )
        XCTAssertEqual(
            attachment.presentation.verificationStatus,
            "Unverified",
            file: file,
            line: line
        )
        XCTAssertFalse(
            attachment.presentation.accessibilityDescription.contains(Wire.forbiddenDefault),
            file: file,
            line: line
        )
        XCTAssertTrue(
            attachment.presentation.accessibilityDescription.contains(String(originalCount)),
            file: file,
            line: line
        )
        XCTAssertTrue(
            attachment.presentation.accessibilityDescription.contains(String(includedCount)),
            file: file,
            line: line
        )
    }

    private func makeBoundaryFixture() throws -> (root: URL, exactURL: URL, overflowURL: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TAttach01-\(Wire.recordID)-v\(Wire.version)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let exactURL = root.appendingPathComponent(Wire.exactName)
        let overflowURL = root.appendingPathComponent(Wire.overflowName)
        let exactText = String(repeating: "N", count: 39_999) + Wire.exactBoundary
        let overflowText = exactText + Wire.excludedBoundary
        XCTAssertEqual(exactText.count, 40_000)
        XCTAssertEqual(overflowText.count, 40_001)
        XCTAssertEqual(Wire.nextVersion, Wire.version + 1)
        try exactText.write(to: exactURL, atomically: true, encoding: .utf8)
        try overflowText.write(to: overflowURL, atomically: true, encoding: .utf8)
        return (root, exactURL, overflowURL)
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var remainder = haystack[...]
        while let range = remainder.range(of: needle) {
            count += 1
            remainder = remainder[range.upperBound...]
        }
        return count
    }
}
