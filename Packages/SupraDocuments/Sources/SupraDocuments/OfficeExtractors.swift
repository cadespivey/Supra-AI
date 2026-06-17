import AppKit
import Foundation
import SupraCore
import ZIPFoundation

/// Reads named entries from a ZIP container (.docx/.xlsx) via the pinned
/// ZIPFoundation library.
enum ZipArchiveReader {
    static func entryData(in url: URL, path: String) throws -> Data? {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read, pathEncoding: nil)
        } catch {
            throw ExtractionError.malformed("Not a readable archive: \(error.localizedDescription)")
        }
        guard let entry = archive[path] else { return nil }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return data
    }

    static func entryPaths(in url: URL) throws -> [String] {
        guard let archive = try? Archive(url: url, accessMode: .read, pathEncoding: nil) else {
            throw ExtractionError.malformed("Not a readable archive.")
        }
        return archive.map { $0.path }
    }
}

/// Extracts Word documents. `.docx`/`.dotx` are parsed from Office Open XML
/// (background-safe, no AppKit); legacy `.doc` falls back to NSAttributedString.
public struct WordExtractor: DocumentExtractor {
    public init() {}

    public func extract(fileURL: URL) async throws -> ExtractionResult {
        let ext = fileURL.pathExtension.lowercased()
        if ext == "doc" {
            let text = try await AppKitDocumentText.text(from: fileURL, type: .docFormat)
            let part = ExtractedPart(sourceKind: .convertedDocument, text: TextNormalization.normalize(text))
            return ExtractionResult(parts: [part], method: "nsattributedstring-doc")
        }

        guard let documentXML = try ZipArchiveReader.entryData(in: fileURL, path: "word/document.xml") else {
            throw ExtractionError.malformed("Missing word/document.xml.")
        }
        let collector = OOXMLTextCollector(textElement: "w:t", paragraphElement: "w:p", tabElement: "w:tab", breakElement: "w:br")
        let parser = XMLParser(data: documentXML)
        parser.delegate = collector
        guard parser.parse() else {
            throw ExtractionError.malformed("Could not parse word/document.xml.")
        }
        let part = ExtractedPart(sourceKind: .convertedDocument, text: TextNormalization.normalize(collector.text))
        return ExtractionResult(parts: [part], method: "ooxml-word")
    }
}

/// Extracts RTF text via NSAttributedString (off the WebKit path, so safe).
public struct RichTextExtractor: DocumentExtractor {
    public init() {}

    public func extract(fileURL: URL) async throws -> ExtractionResult {
        let text = try await AppKitDocumentText.text(from: fileURL, type: .rtf)
        let part = ExtractedPart(sourceKind: .convertedDocument, text: TextNormalization.normalize(text))
        return ExtractionResult(parts: [part], method: "nsattributedstring-rtf")
    }
}

/// NSAttributedString-backed reader for RTF / legacy DOC. Runs on the main actor
/// because AppKit document loading is safest there.
enum AppKitDocumentText {
    @MainActor
    static func text(from url: URL, type: NSAttributedString.DocumentType) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ExtractionError.fileUnreadable(error.localizedDescription)
        }
        do {
            let attributed = try NSAttributedString(
                data: data,
                options: [.documentType: type],
                documentAttributes: nil
            )
            return attributed.string
        } catch {
            throw ExtractionError.malformed("Could not read \(url.pathExtension): \(error.localizedDescription)")
        }
    }
}

/// Collects text from an Office Open XML body, inserting newlines at paragraph
/// boundaries and tabs for tab elements.
final class OOXMLTextCollector: NSObject, XMLParserDelegate {
    private let textElement: String
    private let paragraphElement: String
    private let tabElement: String
    private let breakElement: String
    private var capturing = false
    private var fragments: [String] = []

    init(textElement: String, paragraphElement: String, tabElement: String, breakElement: String) {
        self.textElement = textElement
        self.paragraphElement = paragraphElement
        self.tabElement = tabElement
        self.breakElement = breakElement
    }

    var text: String { fragments.joined() }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        switch elementName {
        case textElement: capturing = true
        case tabElement: fragments.append("\t")
        case breakElement: fragments.append("\n")
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { fragments.append(string) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case textElement: capturing = false
        case paragraphElement: fragments.append("\n")
        default: break
        }
    }
}
