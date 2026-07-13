import Foundation
import PDFKit
@testable import SupraDocuments
import XCTest
import ZIPFoundation

final class AtomicExportTests: XCTestCase {
    private enum InjectedFailure: Error { case stop }

    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ACR-Export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var payload: DocumentExportPayload {
        .init(
            title: "Payment chronology",
            contentMarkdown: "Payment was due on March 3, 2024 [S1].",
            reviewWarning: "Verify before external use.",
            sources: [
                .init(
                    label: "S1",
                    documentName: "agreement.pdf",
                    locator: "p. 3",
                    excerpt: "Payment due March 3, 2024."
                )
            ]
        )
    }

    // ACR-EXPORT-001: every output format preserves an existing destination
    // when rendering fails, and no writer-owned temporary file is leaked.
    func testEveryFormatPreservesCanaryOnRenderFailure() throws {
        for format in DocumentExportFormat.allCases {
            let url = directory.appendingPathComponent("render-\(format.rawValue).\(format.fileExtension)")
            let canary = Data("old-\(format.rawValue)".utf8)
            try canary.write(to: url)

            XCTAssertThrowsError(
                try DocumentExportBuilder.write(
                    payload,
                    format: format,
                    to: url,
                    faultInjector: { stage in
                        if stage == .beforeRender { throw InjectedFailure.stop }
                    }
                )
            )
            XCTAssertEqual(try Data(contentsOf: url), canary, "render failure replaced \(format)")
        }
        XCTAssertTrue(temporaryArtifacts().isEmpty)
    }

    // ACR-EXPORT-002/003/004: write, validation, and atomic-install failures
    // preserve the old destination byte-for-byte for all five formats.
    func testEveryFormatPreservesCanaryOnWriterValidationAndInstallFailures() throws {
        let writerStages: [DurableFileWriter.FaultStage] = [.duringWrite, .beforeInstall]
        for format in DocumentExportFormat.allCases {
            for stage in writerStages {
                let url = directory.appendingPathComponent("\(stage.rawValue)-\(format.rawValue).\(format.fileExtension)")
                let canary = Data("canary-\(stage.rawValue)-\(format.rawValue)".utf8)
                try canary.write(to: url)
                let writer = DurableFileWriter { observed in
                    if observed == stage { throw InjectedFailure.stop }
                }

                XCTAssertThrowsError(
                    try DocumentExportBuilder.write(payload, format: format, to: url, writer: writer)
                )
                XCTAssertEqual(try Data(contentsOf: url), canary, "\(stage) replaced \(format)")
            }

            let validationURL = directory.appendingPathComponent("validation-\(format.rawValue).\(format.fileExtension)")
            let validationCanary = Data("validation-canary-\(format.rawValue)".utf8)
            try validationCanary.write(to: validationURL)
            XCTAssertThrowsError(
                try DocumentExportBuilder.write(
                    payload,
                    format: format,
                    to: validationURL,
                    faultInjector: { stage in
                        if stage == .beforeValidation { throw InjectedFailure.stop }
                    }
                )
            )
            XCTAssertEqual(try Data(contentsOf: validationURL), validationCanary)
        }
        XCTAssertTrue(temporaryArtifacts().isEmpty)
    }

    // ACR-EXPORT-005: cancellation follows the same rollback and cleanup path.
    func testCancellationPreservesCanaryAndCleansTemporaryFile() throws {
        let url = directory.appendingPathComponent("cancel.md")
        let canary = Data("existing-draft".utf8)
        try canary.write(to: url)

        XCTAssertThrowsError(
            try DocumentExportBuilder.write(
                payload,
                format: .markdown,
                to: url,
                faultInjector: { stage in
                    if stage == .beforeValidation {
                        throw CancellationError()
                    }
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try Data(contentsOf: url), canary)
        XCTAssertTrue(temporaryArtifacts().isEmpty)
    }

    // ACR-EXPORT-006: validators actually parse/open the declared format instead
    // of accepting magic bytes or extensions.
    func testValidatorsRejectMalformedDeclaredFormats() throws {
        let malformed: [(DocumentExportFormat, Data)] = [
            (.markdown, Data()),
            (.csv, Data("A,B\n1".utf8)),
            (.pdf, Data("%PDF-not-a-document".utf8))
        ]
        for (format, data) in malformed {
            let url = directory.appendingPathComponent("bad.\(format.fileExtension)")
            try data.write(to: url)
            XCTAssertThrowsError(try DocumentExportValidator.validate(url, as: format), "accepted malformed \(format)")
        }

        for format in [DocumentExportFormat.docx, .xlsx] {
            let url = directory.appendingPathComponent("missing-parts.\(format.fileExtension)")
            let archive = try XCTUnwrap(Archive(url: url, accessMode: .create, pathEncoding: nil))
            let data = Data("<?xml version=\"1.0\"?><root/>".utf8)
            try archive.addEntry(with: "unrelated.xml", type: .file, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
            XCTAssertThrowsError(try DocumentExportValidator.validate(url, as: format), "accepted incomplete \(format)")
        }

        let malformedXMLURL = directory.appendingPathComponent("malformed-xml.docx")
        let malformedArchive = try Archive(url: malformedXMLURL, accessMode: .create, pathEncoding: nil)
        try addEntry("[Content_Types].xml", contents: "<?xml version=\"1.0\"?><Types/>", to: malformedArchive)
        try addEntry("_rels/.rels", contents: "<?xml version=\"1.0\"?><Relationships/>", to: malformedArchive)
        try addEntry("word/document.xml", contents: "<w:document>", to: malformedArchive)
        XCTAssertThrowsError(try DocumentExportValidator.validate(malformedXMLURL, as: .docx))
    }

    private func addEntry(_ path: String, contents: String, to archive: Archive) throws {
        let data = Data(contents.utf8)
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
            data.subdata(in: Int(position)..<(Int(position) + size))
        }
    }

    private func temporaryArtifacts() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []).filter { $0.lastPathComponent.contains(".supra-tmp-") }
    }
}
