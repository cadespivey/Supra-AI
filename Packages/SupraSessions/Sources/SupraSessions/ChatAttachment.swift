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
/// directly. Heavy document formats (PDF, Word, spreadsheets, email) are rejected
/// with a nudge to open a matter, so the document pipeline handles them rather
/// than dumping unprocessed content into the model's context window.
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

    public init(ocr: any DocumentOCRService = VisionOCRService()) {
        self.ocr = ocr
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
            return ChatAttachmentContext(name: name, text: text)
        }

        if isPlainTextLike(family: family, utType: utType) {
            guard let text = readText(url)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                throw LoadFailure.unreadable(name: name)
            }
            return ChatAttachmentContext(name: name, text: text)
        }

        let kind = url.pathExtension.isEmpty ? "These" : url.pathExtension.uppercased()
        throw LoadFailure.openInMatter(name: name, kind: kind)
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
}
