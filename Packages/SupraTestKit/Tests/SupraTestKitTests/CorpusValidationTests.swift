import Foundation
import SupraCore
import SupraDocuments
import SupraSessions
import SupraStore
@testable import SupraTestKit
import XCTest

/// Deterministic end-to-end validation over the committed seed corpus
/// (TestData/specs/*.json): regenerate each matter, import it with REAL Vision OCR,
/// index it, and assert every planted hidden fact is actually extracted (including
/// from OCR-only docs), the import report accounts for every file, and `.msg` is
/// reported unsupported. The chat-model Q&A/chronology + CourtListener live test
/// are exercised separately (TestData/VALIDATION-PLAN.md).
final class CorpusValidationTests: XCTestCase {

    func testSeededMattersExtractIndexAndExposeHiddenFacts() async throws {
        let specs = try loadSpecs()
        try XCTSkipIf(specs.isEmpty, "No specs in TestData/specs yet.")

        for (key, spec) in specs {
            try await validate(spec: spec, key: key)
        }
    }

    private func validate(spec: MatterSpec, key: String) async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("CorpusVal-\(key)-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let corpusDir = base.appendingPathComponent("corpus", isDirectory: true)
        try CorpusGenerator().write(matter: spec, to: corpusDir)

        let store = try makeStore(base)
        let matter = try store.matters.createMatter(name: spec.matterName)
        let storage = DocumentStorage(root: base.appendingPathComponent("storage", isDirectory: true))

        // Import with REAL on-device OCR so scanned PDFs/images are exercised.
        let importer = DocumentImportService(store: store, storage: storage, ocr: VisionOCRService())
        let outcome = try await importer.importSources([corpusDir], matterID: matter.id)
        _ = try await DocumentIndexingService(store: store, embedder: nil).indexMatter(matterID: matter.id)

        // Import report accounts for every authored document (+ any attachments).
        XCTAssertGreaterThanOrEqual(outcome.report.discoveredCount, spec.documents.count, "\(key): import report missing files")

        // .msg files are reported unsupported (not silently skipped).
        if spec.documents.contains(where: { $0.format == .msg }) {
            XCTAssertTrue(outcome.report.items.contains { $0.disposition == DocumentImportDisposition.unsupported.rawValue },
                          "\(key): a .msg should be reported unsupported")
        }

        // Build matter-wide extracted text + an OCR-only subset (email attachments
        // become child documents, so facts are checked matter-wide, not per-file).
        let documents = try store.documentLibrary.fetchDocuments(matterID: matter.id)
        let formatByFilename = Dictionary(spec.documents.map { ($0.filename, $0.format) }, uniquingKeysWith: { a, _ in a })
        var allText = ""
        var ocrText = ""
        for document in documents {
            let text = try store.documentIndex.fetchChunks(documentID: document.id).map(\.normalizedText).joined(separator: " ")
            allText += " " + text
            switch formatByFilename[document.displayName] {
            case .scanned_pdf, .image_png: ocrText += " " + text
            default: break
            }
        }

        // Each answerable question's key datum must be retrievable from the
        // extracted text (proves extraction + OCR + indexing surfaced the fact);
        // requiresOCR questions must be answerable from OCR'd text specifically.
        var checked = 0
        for qa in spec.answerKey.qa {
            if qa.expectedAnswer.uppercased().contains("NOT SUPPORTED") { continue }
            let tokens = Self.identifiers(in: qa.expectedAnswer)
            guard !tokens.isEmpty else { continue }
            checked += 1
            let haystack = (qa.requiresOCR == true) ? ocrText : allText
            XCTAssertTrue(
                tokens.contains { Self.tokenFound($0, in: haystack) },
                "\(key): no key datum from the expected answer was found\(qa.requiresOCR == true ? " in OCR'd text" : "") — Q=\"\(qa.question)\" A=\"\(qa.expectedAnswer)\" tokens=\(tokens.map(\.value))"
            )
        }
        XCTAssertGreaterThan(checked, 0, "\(key): no answer-key items had checkable identifiers")

        // OCR-only documents must have produced non-trivial text.
        for document in documents where formatByFilename[document.displayName] == .scanned_pdf || formatByFilename[document.displayName] == .image_png {
            let text = try store.documentIndex.fetchChunks(documentID: document.id).map(\.normalizedText).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertGreaterThan(text.count, 10, "\(key): OCR produced no text for \(document.displayName)")
        }
    }

    // MARK: - Identifier tokens (OCR-robust; an answer is "found" if ANY matches)

    private struct Token { var value: String; var kind: Kind; enum Kind { case digits, alnum, word } }

    /// Distinctive, verbatim-ish identifiers from an expected answer: numbers/dates
    /// (compared digits-only), alphanumeric ids like SUR-7741-FL (compared
    /// upper-alnum), and capitalized names (compared case-insensitively).
    private static func identifiers(in text: String) -> [Token] {
        var tokens: [Token] = []
        func matches(_ pattern: String) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range, in: text).map { String(text[$0]) }
            }
        }
        for run in matches("[0-9][0-9.,/-]*[0-9]") {
            let digits = run.filter(\.isNumber)
            if digits.count >= 3 { tokens.append(Token(value: digits, kind: .digits)) }
        }
        for id in matches("\\b[A-Za-z0-9][A-Za-z0-9-]{4,}\\b") where id.contains(where: \.isNumber) && id.contains(where: \.isLetter) {
            tokens.append(Token(value: id.uppercased().filter { $0.isLetter || $0.isNumber }, kind: .alnum))
        }
        for word in matches("\\b[A-Z][A-Za-z]{5,}\\b") {
            tokens.append(Token(value: word.lowercased(), kind: .word))
        }
        return tokens
    }

    private static func tokenFound(_ token: Token, in haystack: String) -> Bool {
        switch token.kind {
        case .digits: return haystack.filter(\.isNumber).contains(token.value)
        case .alnum: return haystack.uppercased().filter { $0.isLetter || $0.isNumber }.contains(token.value)
        case .word: return haystack.range(of: token.value, options: .caseInsensitive) != nil
        }
    }

    // MARK: - Loading

    private func loadSpecs() throws -> [(String, MatterSpec)] {
        let specsDir = repoRoot().appendingPathComponent("TestData/specs", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: specsDir, includingPropertiesForKeys: nil) else { return [] }
        return try files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { ($0.deletingPathExtension().lastPathComponent, try MatterSpec.decode(from: try Data(contentsOf: $0))) }
    }

    private func repoRoot() -> URL {
        // .../Packages/SupraTestKit/Tests/SupraTestKitTests/CorpusValidationTests.swift
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    private func makeStore(_ base: URL) throws -> SupraStore {
        let dir = base.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try SupraStore(url: dir.appendingPathComponent("test.sqlite"))
    }
}
