import Foundation
@testable import SupraDocuments
import XCTest
import ZIPFoundation

final class HostileImportPolicyTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ACRHostileImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testACRIMPORT001RejectsExtensionSignatureMismatch() async throws {
        let disguised = directory.appendingPathComponent("pleading.txt")
        try Data("%PDF-1.7\nsynthetic".utf8).write(to: disguised)

        await assertViolation(.typeMismatch, from: ExtractionService().extract(fileURL: disguised))
    }

    func testACRIMPORT002RejectsOversizedSourceBeforeDecode() async throws {
        let oversized = directory.appendingPathComponent("oversized.txt")
        try Data(repeating: 0x41, count: 17).write(to: oversized)
        let service = ExtractionService(policy: ImportPolicy(maxInputBytes: 16))

        await assertViolation(.sourceTooLarge, from: service.extract(fileURL: oversized))
    }

    func testACRIMPORT003RejectsTraversalAndBackslashZIPEntries() async throws {
        for (name, hostilePath) in [
            ("traversal.docx", "../outside.xml"),
            ("backslash.docx", "word\\..\\outside.xml"),
            ("absolute.docx", "/absolute.xml")
        ] {
            let url = try makeArchive(name: name, entries: [
                ("word/document.xml", "<w:document/>"),
                (hostilePath, "synthetic")
            ])
            await assertViolation(.unsafeArchivePath, from: ExtractionService().extract(fileURL: url))
        }
    }

    func testACRIMPORT004RejectsCanonicalDuplicateZIPEntries() async throws {
        let url = try makeArchive(name: "duplicate.docx", entries: [
            ("word/document.xml", "<w:document/>"),
            ("word/cafe\u{301}.xml", "one"),
            ("word/café.xml", "two")
        ])

        await assertViolation(.duplicateArchiveEntry, from: ExtractionService().extract(fileURL: url))
    }

    func testACRIMPORT005RejectsZIPEntryCountAndCompressionRatio() async throws {
        let many = try makeArchive(name: "many.docx", entries: [
            ("word/document.xml", "<w:document/>"),
            ("word/a.xml", "a"),
            ("word/b.xml", "b")
        ])
        await assertViolation(
            .archiveEntryLimit,
            from: ExtractionService(policy: ImportPolicy(maxArchiveEntries: 2)).extract(fileURL: many)
        )

        let compressed = directory.appendingPathComponent("ratio.docx")
        let archive = try XCTUnwrap(Archive(url: compressed, accessMode: .create, pathEncoding: nil))
        try add(Data("<w:document/>".utf8), path: "word/document.xml", to: archive)
        try add(Data(repeating: 0x41, count: 8_192), path: "word/repeated.bin", to: archive, compression: .deflate)
        await assertViolation(
            .archiveCompressionRatio,
            from: ExtractionService(policy: ImportPolicy(maxArchiveCompressionRatio: 2)).extract(fileURL: compressed)
        )
    }

    func testACRIMPORT006RejectsSymlinkZIPEntry() async throws {
        let url = directory.appendingPathComponent("symlink.docx")
        let archive = try XCTUnwrap(Archive(url: url, accessMode: .create, pathEncoding: nil))
        try add(Data("<w:document/>".utf8), path: "word/document.xml", to: archive)
        try add(Data("../../outside".utf8), path: "word/link", to: archive, type: .symlink)

        await assertViolation(.archiveSpecialEntry, from: ExtractionService().extract(fileURL: url))
    }

    func testACRIMPORT007RejectsMIMEDepthAndAttachmentStorm() async throws {
        let nested = directory.appendingPathComponent("nested.eml")
        let nestedBody = """
        From: synthetic@example.invalid
        Content-Type: multipart/mixed; boundary="A"

        --A
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: multipart/mixed; boundary="C"

        --C
        Content-Type: text/plain

        bounded fixture
        --C--
        --B--
        --A--
        """
        try nestedBody.write(to: nested, atomically: true, encoding: .utf8)
        await assertViolation(
            .mimeDepthLimit,
            from: ExtractionService(policy: ImportPolicy(maxMIMEDepth: 2)).extract(fileURL: nested)
        )

        let storm = directory.appendingPathComponent("storm.eml")
        let stormBody = """
        From: synthetic@example.invalid
        Content-Type: multipart/mixed; boundary="S"

        --S
        Content-Type: application/octet-stream
        Content-Disposition: attachment; filename="one.txt"

        one
        --S
        Content-Type: application/octet-stream
        Content-Disposition: attachment; filename="two.txt"

        two
        --S--
        """
        try stormBody.write(to: storm, atomically: true, encoding: .utf8)
        await assertViolation(
            .attachmentCountLimit,
            from: ExtractionService(policy: ImportPolicy(maxAttachments: 1)).extract(fileURL: storm)
        )
    }

    func testACRIMPORT008RejectsXMLNodeAndDecodedTextLimits() async throws {
        let xml = directory.appendingPathComponent("nodes.xml")
        try "<r><a>1</a><b>2</b><c>3</c></r>".write(to: xml, atomically: true, encoding: .utf8)
        await assertViolation(
            .xmlNodeLimit,
            from: ExtractionService(policy: ImportPolicy(maxXMLNodes: 3)).extract(fileURL: xml)
        )

        let text = directory.appendingPathComponent("decoded.txt")
        try "123456789".write(to: text, atomically: true, encoding: .utf8)
        await assertViolation(
            .decodedTextLimit,
            from: ExtractionService(policy: ImportPolicy(maxDecodedTextBytes: 8)).extract(fileURL: text)
        )
    }

    private func assertViolation<T>(
        _ expected: ImportPolicyViolation.Code,
        from operation: @autoclosure () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected policy rejection \(expected.rawValue)", file: file, line: line)
        } catch let error as ExtractionError {
            guard case .policyViolation(let violation) = error else {
                return XCTFail("Expected policy violation, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(violation.code, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }

    private func makeArchive(name: String, entries: [(String, String)]) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let archive = try XCTUnwrap(Archive(url: url, accessMode: .create, pathEncoding: nil))
        for (path, contents) in entries {
            try add(Data(contents.utf8), path: path, to: archive)
        }
        return url
    }

    private func add(
        _ data: Data,
        path: String,
        to archive: Archive,
        type: Entry.EntryType = .file,
        compression: CompressionMethod = .none
    ) throws {
        try archive.addEntry(
            with: path,
            type: type,
            uncompressedSize: Int64(data.count),
            compressionMethod: compression
        ) { position, size in
            let start = Int(position)
            return data.subdata(in: start..<(start + size))
        }
    }
}
