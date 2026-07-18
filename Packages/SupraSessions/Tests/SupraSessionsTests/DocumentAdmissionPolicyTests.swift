import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

final class DocumentAdmissionPolicyTests: XCTestCase {
    func testTACC08EncryptedSourcesAreRejectedWithoutManagedResidue() async throws {
        // T-ACC-08 expected RED: encrypted_source does not exist; the locked PDF
        // enters OCR/review, while encrypted OOXML/ZIP inputs are copied before
        // their extractors fail. All three therefore leave managed residue.
        let fixture = try makeFixture()
        let lockedPDF = repositoryRoot
            .appendingPathComponent("TestData/Synthetic Document Intelligence Benchmark/Restricted/privileged-locked.pdf")
        let encryptedOOXML = fixture.sourceRoot.appendingPathComponent("agile-encrypted.docx")
        try makeEncryptedOOXMLProbe().write(to: encryptedOOXML)
        let encryptedZIP = fixture.sourceRoot.appendingPathComponent("entry-encrypted.docx")
        try makeEncryptedZIPProbe().write(to: encryptedZIP)

        let outcome = try await fixture.service.importSources(
            [lockedPDF, encryptedOOXML, encryptedZIP],
            matterID: fixture.matterID
        )

        let rows = try fixture.store.documentJobs.fetchSources(batchID: outcome.batchID)
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.state == DocumentImportSourceState.rejected.rawValue })
        XCTAssertTrue(rows.allSatisfy { $0.rejectionCode == "encrypted_source" })
        XCTAssertTrue(rows.allSatisfy {
            $0.reason == "Password-protected or encrypted files cannot be imported. Remove encryption from a copy and try again."
        })
        XCTAssertTrue(rows.allSatisfy { $0.documentID == nil && $0.blobSHA256 == nil })

        XCTAssertEqual(outcome.report.items.count, 3)
        XCTAssertTrue(outcome.report.items.allSatisfy { $0.disposition == DocumentImportSourceState.rejected.rawValue })
        XCTAssertTrue(outcome.report.items.allSatisfy { $0.rejectionCode == "encrypted_source" })
        XCTAssertTrue(outcome.report.items.allSatisfy {
            $0.reason == "Password-protected or encrypted files cannot be imported. Remove encryption from a copy and try again."
        })
        XCTAssertTrue(try fixture.store.documentLibrary.fetchDocuments(matterID: fixture.matterID).isEmpty)
        XCTAssertTrue(try fixture.store.documentLibrary.fetchBlobs(limit: 10).isEmpty)
    }

    func testTACC09LegacyXlsAndMsgAreUnsupportedBeforeCopyWhileParserFailureRemainsFailed() async throws {
        // T-ACC-09 expected RED: .xls/.msg are treated as supported through
        // admission, so each creates a blob/document and only then reports an
        // unsupported extraction instead of a pre-copy policy disposition.
        let fixture = try makeFixture()
        let legacyXLS = fixture.sourceRoot.appendingPathComponent("legacy-ledger.xls")
        let legacyMSG = fixture.sourceRoot.appendingPathComponent("legacy-message.msg")
        let corruptDOCX = fixture.sourceRoot.appendingPathComponent("supported-but-corrupt.docx")
        try makeOLEProbe().write(to: legacyXLS)
        try makeOLEProbe().write(to: legacyMSG)
        try Data("not a zip archive".utf8).write(to: corruptDOCX)

        let outcome = try await fixture.service.importSources(
            [legacyXLS, legacyMSG, corruptDOCX],
            matterID: fixture.matterID
        )

        let rows = Dictionary(uniqueKeysWithValues: try fixture.store.documentJobs
            .fetchSources(batchID: outcome.batchID)
            .map { ($0.sourceDisplayPath, $0) })
        let xls = try XCTUnwrap(rows[legacyXLS.lastPathComponent])
        let msg = try XCTUnwrap(rows[legacyMSG.lastPathComponent])
        let corrupt = try XCTUnwrap(rows[corruptDOCX.lastPathComponent])
        XCTAssertEqual(xls.state, DocumentImportSourceState.unsupportedByPolicy.rawValue)
        XCTAssertEqual(msg.state, DocumentImportSourceState.unsupportedByPolicy.rawValue)
        XCTAssertEqual(corrupt.state, DocumentImportSourceState.failed.rawValue)
        XCTAssertEqual(xls.reason, "Legacy .xls files are not imported. Export the file as .xlsx and try again.")
        XCTAssertEqual(msg.reason, "Outlook .msg files are not imported. Export the message as .eml and try again.")
        XCTAssertNil(xls.documentID)
        XCTAssertNil(xls.blobSHA256)
        XCTAssertNil(msg.documentID)
        XCTAssertNil(msg.blobSHA256)
        XCTAssertNotNil(corrupt.documentID)
        XCTAssertNotNil(corrupt.blobSHA256)

        let report = Dictionary(uniqueKeysWithValues: outcome.report.items.map { ($0.displayName, $0) })
        XCTAssertEqual(report[legacyXLS.lastPathComponent]?.disposition, DocumentImportSourceState.unsupportedByPolicy.rawValue)
        XCTAssertEqual(report[legacyMSG.lastPathComponent]?.disposition, DocumentImportSourceState.unsupportedByPolicy.rawValue)
        XCTAssertEqual(report[legacyXLS.lastPathComponent]?.reason, xls.reason)
        XCTAssertEqual(report[legacyMSG.lastPathComponent]?.reason, msg.reason)
        XCTAssertEqual(outcome.report.failedCount, 3)

        let documents = try fixture.store.documentLibrary.fetchDocuments(matterID: fixture.matterID)
        XCTAssertEqual(documents.map(\.displayName), [corruptDOCX.lastPathComponent])
        XCTAssertEqual(try fixture.store.documentLibrary.fetchBlobs(limit: 10).count, 1)
    }

    func testTACC11LegacyDocIsLossyReviewEvidenceButCannotClaimCompleteScope() async throws {
        // T-ACC-11 expected RED: an RTF-backed legacy .doc is rejected as a
        // type mismatch; no converted_lossy lineage, review state, preliminary
        // retrieval disclosure, or completeness blocker exists.
        let fixture = try makeFixture()
        let legacyDOC = fixture.sourceRoot.appendingPathComponent("legacy-numbered-table.doc")
        let rtf = #"{\rtf1\ansi LOSSY_DOC_CANARY\par 1. First numbered duty\par \trowd\cellx2500 Amount\cell $7,431\cell\row}"#
        try Data(rtf.utf8).write(to: legacyDOC)

        _ = try await fixture.service.importSources([legacyDOC], matterID: fixture.matterID)

        let document = try XCTUnwrap(
            fixture.store.documentLibrary.fetchDocuments(matterID: fixture.matterID).first
        )
        XCTAssertEqual(document.status, MatterDocumentStatus.needsReview.rawValue)
        XCTAssertEqual(document.extractionStatus, DocumentExtractionStatus.extracted.rawValue)
        XCTAssertTrue(document.extractionMethod?.hasPrefix("converted_lossy@toolchain:") == true)
        let warningsJSON = try XCTUnwrap(document.extractionWarningsJSON)
        let warnings = try JSONDecoder().decode([String].self, from: Data(warningsJSON.utf8))
        XCTAssertEqual(warnings, [
            "converted_lossy: Legacy .doc conversion can lose tables, numbering, and layout. Convert the file to .docx or PDF and review the extracted text."
        ])

        _ = try await DocumentIndexingService(store: fixture.store, embedder: nil)
            .indexMatter(matterID: fixture.matterID)
        let retrieval = DocumentRetrievalService(store: fixture.store, embedder: nil)
        let result = try await retrieval.retrieve(
            matterID: fixture.matterID,
            query: "LOSSY_DOC_CANARY",
            scope: .wholeMatter
        )
        XCTAssertTrue(result.sources.contains { $0.documentID == document.id })
        XCTAssertFalse(result.readiness.isFullyReady)
        XCTAssertEqual(result.readiness.pendingDocuments, 1)
        XCTAssertEqual(
            result.incompleteScopeWarning,
            "This scope includes converted_lossy legacy .doc content. Convert the file to .docx or PDF and review the extracted text before making completeness or negative claims."
        )
    }

    private var repositoryRoot: URL {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 { root.deleteLastPathComponent() }
        return root
    }

    private func makeFixture() throws -> AdmissionFixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdmissionPolicyTests-\(UUID().uuidString)", isDirectory: true)
        let sourceRoot = base.appendingPathComponent("Sources", isDirectory: true)
        let storageRoot = base.appendingPathComponent("Managed", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let store = try SupraStore(url: base.appendingPathComponent("test.sqlite"))
        let matter = try store.matters.createMatter(name: "Synthetic admission policy")
        return AdmissionFixture(
            store: store,
            matterID: matter.id,
            sourceRoot: sourceRoot,
            service: DocumentImportService(
                store: store,
                storage: DocumentStorage(root: storageRoot),
                ocr: nil
            )
        )
    }

    private func makeOLEProbe() -> Data {
        Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1] + Array(repeating: 0, count: 512))
    }

    private func makeEncryptedOOXMLProbe() -> Data {
        var data = makeOLEProbe()
        data.append("EncryptionInfo".data(using: .utf16LittleEndian)!)
        data.append("EncryptedPackage".data(using: .utf16LittleEndian)!)
        return data
    }

    /// Minimal ZIP with one entry whose local and central-directory general
    /// purpose flags set bit 0 (traditional encrypted-entry marker).
    private func makeEncryptedZIPProbe() -> Data {
        let name = Data("word/document.xml".utf8)
        let body = Data("ENCRYPTED-CONTENT".utf8)
        var local = Data()
        local.appendLE(UInt32(0x04034B50))
        local.appendLE(UInt16(20))
        local.appendLE(UInt16(1))
        local.appendLE(UInt16(0))
        local.appendLE(UInt16(0))
        local.appendLE(UInt16(0))
        local.appendLE(UInt32(0))
        local.appendLE(UInt32(body.count))
        local.appendLE(UInt32(body.count))
        local.appendLE(UInt16(name.count))
        local.appendLE(UInt16(0))
        local.append(name)
        local.append(body)

        var central = Data()
        central.appendLE(UInt32(0x02014B50))
        central.appendLE(UInt16(20))
        central.appendLE(UInt16(20))
        central.appendLE(UInt16(1))
        central.appendLE(UInt16(0))
        central.appendLE(UInt16(0))
        central.appendLE(UInt16(0))
        central.appendLE(UInt32(0))
        central.appendLE(UInt32(body.count))
        central.appendLE(UInt32(body.count))
        central.appendLE(UInt16(name.count))
        central.appendLE(UInt16(0))
        central.appendLE(UInt16(0))
        central.appendLE(UInt16(0))
        central.appendLE(UInt16(0))
        central.appendLE(UInt32(0))
        central.appendLE(UInt32(0))
        central.append(name)

        var archive = local
        let centralOffset = archive.count
        archive.append(central)
        archive.appendLE(UInt32(0x06054B50))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(1))
        archive.appendLE(UInt16(1))
        archive.appendLE(UInt32(central.count))
        archive.appendLE(UInt32(centralOffset))
        archive.appendLE(UInt16(0))
        return archive
    }
}

private struct AdmissionFixture {
    let store: SupraStore
    let matterID: String
    let sourceRoot: URL
    let service: DocumentImportService
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
