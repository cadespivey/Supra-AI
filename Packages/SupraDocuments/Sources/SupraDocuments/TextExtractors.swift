import Foundation
import SupraCore

/// Shared text normalization: unify line endings, strip trailing spaces, and
/// collapse runs of blank lines. Deterministic so checksums/chunking are stable.
public enum TextNormalization {
    public static func normalize(_ text: String) -> String {
        let unified = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = unified.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "\u{00A0}", with: " ") }
            .map { String($0).trimmingTrailingWhitespace() }
        // Collapse any run of consecutive blank lines to one.
        var collapsed: [String] = []
        var blankRun = 0
        for line in lines {
            if line.isEmpty {
                blankRun += 1
                if blankRun <= 1 { collapsed.append(line) }
            } else {
                blankRun = 0
                collapsed.append(line)
            }
        }
        lines = collapsed
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    func trimmingTrailingWhitespace() -> String {
        var view = self[...]
        while let last = view.last, last == " " || last == "\t" {
            view = view.dropLast()
        }
        return String(view)
    }
}

/// Reads .txt / .md as UTF-8 (falling back to common encodings).
public struct PlainTextExtractor: DocumentExtractor {
    public init() {}

    public func extract(fileURL: URL) async throws -> ExtractionResult {
        let text = try DocumentTextLoader.readString(at: fileURL)
        let kind = SupportedDocumentTypes.format(for: fileURL)?.sourceKind ?? .text
        let normalized = TextNormalization.normalize(text)
        let part = ExtractedPart(sourceKind: kind, text: normalized)
        return ExtractionResult(parts: [part], method: "plain-text")
    }
}

/// Extracts text content + attribute values from an XML document.
public struct XMLTextExtractor: DocumentExtractor {
    public init() {}

    public func extract(fileURL: URL) async throws -> ExtractionResult {
        let data = try DocumentTextLoader.readData(at: fileURL)
        let collector = XMLTextCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        let ok = parser.parse()
        let text: String
        var warnings: [String] = []
        if ok, !collector.text.isEmpty {
            text = collector.text
        } else {
            // Fall back to raw text if the document is not well-formed XML.
            warnings.append("XML not well-formed; extracted raw text.")
            text = (try? DocumentTextLoader.readString(at: fileURL)) ?? ""
        }
        let part = ExtractedPart(sourceKind: .xml, text: TextNormalization.normalize(text))
        return ExtractionResult(parts: [part], method: "xml", warnings: warnings)
    }
}

private final class XMLTextCollector: NSObject, XMLParserDelegate {
    private(set) var fragments: [String] = []
    var text: String { fragments.joined(separator: " ") }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        for value in attributeDict.values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { fragments.append(trimmed) }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { fragments.append(trimmed) }
    }
}

/// Strips HTML to readable text without WebKit (so it is safe to run off the main
/// thread in the import pipeline).
public struct HTMLTextExtractor: DocumentExtractor {
    public init() {}

    public func extract(fileURL: URL) async throws -> ExtractionResult {
        let html = try DocumentTextLoader.readString(at: fileURL)
        let text = HTMLToText.convert(html)
        let part = ExtractedPart(sourceKind: .html, text: TextNormalization.normalize(text))
        return ExtractionResult(parts: [part], method: "html-strip")
    }
}

/// Minimal, deterministic HTML→text: drops script/style, removes tags, decodes
/// common entities, and inserts line breaks for block elements.
public enum HTMLToText {
    public static func convert(_ html: String) -> String {
        var s = html
        s = removeBlocks(named: "script", in: s)
        s = removeBlocks(named: "style", in: s)
        // Block-level tags become newlines; <br> too.
        let blockBreaks = ["</p>", "</div>", "</li>", "</tr>", "</h1>", "</h2>", "</h3>",
                           "</h4>", "</h5>", "</h6>", "<br>", "<br/>", "<br />", "</section>"]
        for token in blockBreaks {
            s = s.replacingOccurrences(of: token, with: "\n", options: .caseInsensitive)
        }
        s = stripTags(s)
        s = decodeEntities(s)
        return s
    }

    private static func removeBlocks(named tag: String, in html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<\(tag)[^>]*>.*?</\(tag)>", options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return html
        }
        let range = NSRange(html.startIndex..., in: html)
        return regex.stringByReplacingMatches(in: html, range: range, withTemplate: " ")
    }

    private static func stripTags(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) else { return html }
        let range = NSRange(html.startIndex..., in: html)
        return regex.stringByReplacingMatches(in: html, range: range, withTemplate: " ")
    }

    static func decodeEntities(_ text: String) -> String {
        var s = text
        let named: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&nbsp;": " "
        ]
        for (entity, replacement) in named {
            s = s.replacingOccurrences(of: entity, with: replacement)
        }
        // Numeric decimal entities.
        if let regex = try? NSRegularExpression(pattern: "&#([0-9]+);") {
            let matches = regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed()
            for match in matches {
                guard let codeRange = Range(match.range(at: 1), in: s),
                      let full = Range(match.range, in: s),
                      let code = UInt32(s[codeRange]),
                      let scalar = Unicode.Scalar(code) else { continue }
                s.replaceSubrange(full, with: String(scalar))
            }
        }
        return s
    }
}

/// Shared file readers with encoding fallbacks.
public enum DocumentTextLoader {
    public static func readData(at url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw ExtractionError.fileUnreadable(error.localizedDescription)
        }
    }

    public static func readString(at url: URL) throws -> String {
        let data = try readData(at: url)
        for encoding: String.Encoding in [.utf8, .utf16, .isoLatin1, .windowsCP1252] {
            if let string = String(data: data, encoding: encoding) {
                return string
            }
        }
        throw ExtractionError.fileUnreadable("Unknown text encoding.")
    }
}
