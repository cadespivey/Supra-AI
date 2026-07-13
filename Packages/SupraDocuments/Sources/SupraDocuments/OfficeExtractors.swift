import AppKit
import Foundation
import SupraCore
import ZIPFoundation

/// Reads named entries from a ZIP container (.docx/.xlsx) via the pinned
/// ZIPFoundation library.
enum ZipArchiveReader {
    /// Caps a single decompressed entry so a malicious "zip bomb" (a tiny entry
    /// that inflates to gigabytes) cannot exhaust memory. 256 MB is far beyond any
    /// legitimate Office part while still bounding worst-case extraction.
    static let maxUncompressedEntryBytes = 256 * 1024 * 1024

    static func validatedArchive(at url: URL, policy: ImportPolicy) throws -> Archive {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read, pathEncoding: nil)
        } catch {
            throw ExtractionError.malformed("Not a readable archive: \(error.localizedDescription)")
        }

        var canonicalPaths = Set<String>()
        var expandedBytes = 0
        var entryCount = 0
        for entry in archive {
            try Task.checkCancellation()
            entryCount += 1
            if entryCount > policy.maxArchiveEntries {
                throw ImportPolicyViolation(
                    .archiveEntryLimit,
                    "Archive exceeds the \(policy.maxArchiveEntries)-entry limit."
                )
            }
            guard entry.type == .file || entry.type == .directory else {
                throw ImportPolicyViolation(.archiveSpecialEntry, "Archive contains a link or special entry.")
            }
            let canonical = try canonicalArchivePath(entry.path)
            guard canonicalPaths.insert(canonical).inserted else {
                throw ImportPolicyViolation(
                    .duplicateArchiveEntry,
                    "Archive contains duplicate canonical paths."
                )
            }
            guard entry.uncompressedSize <= UInt64(Int.max) else {
                throw ImportPolicyViolation(.expandedBytesLimit, "Archive expanded size is not representable.")
            }
            let bytes = Int(entry.uncompressedSize)
            let (next, overflow) = expandedBytes.addingReportingOverflow(bytes)
            if overflow || next > policy.maxArchiveExpandedBytes {
                throw ImportPolicyViolation(
                    .expandedBytesLimit,
                    "Archive exceeds the \(policy.maxArchiveExpandedBytes)-byte expanded limit."
                )
            }
            expandedBytes = next

            if entry.uncompressedSize > 0 {
                let ratio = Double(entry.uncompressedSize) / Double(max(UInt64(1), entry.compressedSize))
                if ratio > policy.maxArchiveCompressionRatio {
                    throw ImportPolicyViolation(
                        .archiveCompressionRatio,
                        "Archive entry exceeds the \(policy.maxArchiveCompressionRatio):1 compression-ratio limit."
                    )
                }
            }
        }
        return archive
    }

    static func entryData(in url: URL, path: String, policy: ImportPolicy = .default) throws -> Data? {
        let archive = try validatedArchive(at: url, policy: policy)
        return try entryData(in: archive, path: path, policy: policy)
    }

    /// Reads from an archive that has already passed `validatedArchive`. Keeping
    /// the validated handle avoids an O(entries × parts) rescan for workbooks.
    static func entryData(in archive: Archive, path: String, policy: ImportPolicy) throws -> Data? {
        guard let entry = archive[path] else { return nil }
        // Reject based on the declared size first (cheap), then enforce a running
        // cap while extracting in case the header understates the real size.
        let entryLimit = min(maxUncompressedEntryBytes, policy.maxArchiveExpandedBytes)
        if entry.uncompressedSize > UInt64(entryLimit) {
            throw ImportPolicyViolation(.expandedBytesLimit, "Archive entry '\(path)' is too large to extract safely.")
        }
        var data = Data()
        do {
            _ = try archive.extract(entry) { chunk in
                if data.count + chunk.count > entryLimit {
                    throw ImportPolicyViolation(.expandedBytesLimit, "Archive entry '\(path)' exceeded the safe extraction limit.")
                }
                data.append(chunk)
            }
        } catch let error as ImportPolicyViolation {
            throw error
        } catch let error as ExtractionError {
            throw error
        } catch {
            throw ExtractionError.malformed("Could not extract '\(path)': \(error.localizedDescription)")
        }
        return data
    }

    static func entryPaths(in url: URL, policy: ImportPolicy = .default) throws -> [String] {
        let archive = try validatedArchive(at: url, policy: policy)
        return archive.map { $0.path }
    }

    private static func canonicalArchivePath(_ rawPath: String) throws -> String {
        let slashPath = rawPath.replacingOccurrences(of: "\\", with: "/")
        guard !slashPath.hasPrefix("/"),
              !slashPath.hasPrefix("~"),
              slashPath.range(of: #"^[A-Za-z]:"#, options: .regularExpression) == nil else {
            throw ImportPolicyViolation(.unsafeArchivePath, "Archive contains an absolute path.")
        }
        var components: [String] = []
        let rawComponents = slashPath.split(separator: "/", omittingEmptySubsequences: false)
        for (index, component) in rawComponents.enumerated() {
            let value = String(component)
            let isAllowedDirectoryTerminator = value.isEmpty && index == rawComponents.count - 1
            guard !value.isEmpty || isAllowedDirectoryTerminator else {
                throw ImportPolicyViolation(.unsafeArchivePath, "Archive contains an empty path component.")
            }
            guard value != ".", value != ".." else {
                throw ImportPolicyViolation(.unsafeArchivePath, "Archive path traversal is not allowed.")
            }
            if !value.isEmpty { components.append(value) }
        }
        guard !components.isEmpty else {
            throw ImportPolicyViolation(.unsafeArchivePath, "Archive contains an empty path.")
        }
        return components.joined(separator: "/")
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }
}

/// Extracts Word documents. `.docx`/`.dotx` are parsed from Office Open XML
/// (background-safe, no AppKit); legacy `.doc` falls back to NSAttributedString.
public struct WordExtractor: DocumentExtractor {
    private let policy: ImportPolicy

    public init(policy: ImportPolicy = .default) { self.policy = policy }

    public func extract(fileURL: URL) async throws -> ExtractionResult {
        let ext = fileURL.pathExtension.lowercased()
        if ext == "doc" {
            let text = try await AppKitDocumentText.text(from: fileURL, type: .docFormat, policy: policy)
            try policy.validateDecodedText(text)
            let part = ExtractedPart(sourceKind: .convertedDocument, text: TextNormalization.normalize(text))
            return ExtractionResult(parts: [part], method: "nsattributedstring-doc")
        }

        guard let documentXML = try ZipArchiveReader.entryData(in: fileURL, path: "word/document.xml", policy: policy) else {
            throw ExtractionError.malformed("Missing word/document.xml.")
        }
        try policy.validateXMLData(documentXML)
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
    private let policy: ImportPolicy

    public init(policy: ImportPolicy = .default) { self.policy = policy }

    public func extract(fileURL: URL) async throws -> ExtractionResult {
        let text = try await AppKitDocumentText.text(from: fileURL, type: .rtf, policy: policy)
        try policy.validateDecodedText(text)
        let part = ExtractedPart(sourceKind: .convertedDocument, text: TextNormalization.normalize(text))
        return ExtractionResult(parts: [part], method: "nsattributedstring-rtf")
    }
}

/// NSAttributedString-backed reader for RTF / legacy DOC. Runs on the main actor
/// because AppKit document loading is safest there.
enum AppKitDocumentText {
    @MainActor
    static func text(from url: URL, type: NSAttributedString.DocumentType, policy: ImportPolicy) throws -> String {
        let data: Data
        do {
            data = try DocumentTextLoader.readData(at: url, maxBytes: policy.maxInputBytes)
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
