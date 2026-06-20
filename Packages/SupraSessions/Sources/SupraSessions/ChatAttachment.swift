import Foundation
import SupraDocuments
import UniformTypeIdentifiers

/// A lightweight attachment for a global chat: a filename plus the text the model
/// should see. Built by `ChatAttachmentLoader` (OCR for images, raw read for text)
/// and injected into the prompt by `GlobalChatController`.
public struct ChatAttachmentContext: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let text: String

    public init(id: String = UUID().uuidString, name: String, text: String) {
        self.id = id
        self.name = name
        self.text = text
    }
}

/// Turns a picked file into a `ChatAttachmentContext` for a global chat.
///
/// Images/screenshots are OCR'd to text; plain-text/markdown/html/xml are read
/// directly; documents (PDF, Word, spreadsheets, email, RTF) have their text
/// extracted via `ExtractionService` — with an OCR fallback for scanned PDFs —
/// and capped so a large file can't overflow the model's context window. This
/// lets the chat's "+" button analyze documents inline rather than turning them
/// away.
public struct ChatAttachmentLoader: Sendable {
    public enum LoadFailure: Error, LocalizedError, Equatable {
        case openInMatter(name: String, kind: String)
        case unreadable(name: String)
        case empty(name: String)

        public var errorDescription: String? {
            switch self {
            case let .openInMatter(name, kind):
                return "\(kind) files aren't supported in global chat. Open a matter to import and analyze “\(name)”."
            case let .unreadable(name):
                return "Couldn't read “\(name)” as text."
            case let .empty(name):
                return "No text was found in “\(name)”."
            }
        }
    }

    private let ocr: any DocumentOCRService
    private let extractor: ExtractionService

    public init(
        ocr: any DocumentOCRService = VisionOCRService(),
        extractor: ExtractionService = ExtractionService()
    ) {
        self.ocr = ocr
        self.extractor = extractor
    }

    public func load(url: URL) async throws -> ChatAttachmentContext {
        let name = url.lastPathComponent
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let family = SupportedDocumentTypes.format(for: url)?.family
        let utType = UTType(filenameExtension: url.pathExtension.lowercased())

        if family == .image || (utType?.conforms(to: .image) ?? false) {
            let result = try await ocr.recognizeImage(at: url)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw LoadFailure.empty(name: name) }
            return ChatAttachmentContext(name: name, text: Self.capped(text))
        }

        if isPlainTextLike(family: family, utType: utType) {
            guard let text = readText(url)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                throw LoadFailure.unreadable(name: name)
            }
            return ChatAttachmentContext(name: name, text: Self.capped(text))
        }

        // Documents (PDF, Word, spreadsheet, email, RTF) — extract their text so
        // they can be analyzed inline rather than turned away.
        guard family != nil else { throw LoadFailure.unreadable(name: name) }
        return try await loadDocument(url: url, name: name, family: family)
    }

    private func loadDocument(
        url: URL,
        name: String,
        family: SupportedDocumentTypes.ExtractionFamily?
    ) async throws -> ChatAttachmentContext {
        let result: ExtractionResult
        do {
            result = try await extractor.extract(fileURL: url)
        } catch {
            throw LoadFailure.unreadable(name: name)
        }
        var text = result.combinedText.trimmingCharacters(in: .whitespacesAndNewlines)

        // A scanned PDF has no embedded text; OCR its rendered pages instead.
        if text.isEmpty, result.needsOCR, family == .pdf {
            let pages = try await ocr.recognizePDFPages(at: url, pageIndices: nil)
            text = pages
                .sorted { $0.key < $1.key }
                .map(\.value.text)
                .joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !text.isEmpty else { throw LoadFailure.empty(name: name) }
        return ChatAttachmentContext(name: name, text: Self.capped(text))
    }

    private func isPlainTextLike(family: SupportedDocumentTypes.ExtractionFamily?, utType: UTType?) -> Bool {
        switch family {
        case .plainText, .markdown, .html, .xml:
            return true
        default:
            return utType?.conforms(to: .text) ?? false
        }
    }

    private func readText(_ url: URL) -> String? {
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        if let data = try? Data(contentsOf: url) { return String(data: data, encoding: .utf8) }
        return nil
    }

    /// Caps an attachment's injected text so a large document can't overflow the
    /// model's context window; the model still sees a substantial excerpt.
    static let maxCharacters = 40_000

    static func capped(_ text: String) -> String {
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(maxCharacters))
            + "\n\n[Attachment truncated to the first \(maxCharacters) characters for analysis.]"
    }
}
