import Foundation
import SupraCore
import UniformTypeIdentifiers

/// Policy for which file types Milestone 3 import accepts and how each maps to a
/// `DocumentSourceKind` and an extraction family. Unsupported files are not
/// silently skipped — they are recorded in the import report as `unsupported`.
public enum SupportedDocumentTypes {
    public static let legacyXLSGuidance =
        "Legacy .xls files are not imported. Export the file as .xlsx and try again."
    public static let legacyMSGGuidance =
        "Outlook .msg files are not imported. Export the message as .eml and try again."
    public static let legacyDOCLossyWarning =
        "converted_lossy: Legacy .doc conversion can lose tables, numbering, and layout. Convert the file to .docx or PDF and review the extracted text."

    /// The extraction family that handles a given input format. Drives which
    /// adapter (Apple framework vs. bundled tool) processes the file.
    public enum ExtractionFamily: String, Sendable, Hashable {
        case pdf
        case image
        case plainText
        case markdown
        case richText
        case html
        case xml
        case word
        case spreadsheet
        case email
    }

    public struct Format: Sendable, Hashable {
        public let family: ExtractionFamily
        public let sourceKind: DocumentSourceKind
        /// Lowercased file extensions, without the dot.
        public let fileExtensions: [String]

        public init(family: ExtractionFamily, sourceKind: DocumentSourceKind, fileExtensions: [String]) {
            self.family = family
            self.sourceKind = sourceKind
            self.fileExtensions = fileExtensions
        }
    }

    /// All supported input formats (plan §3.1). `.heic` is included but its
    /// availability is gated by native decoding at runtime (§17 open decision).
    public static let formats: [Format] = [
        Format(family: .pdf, sourceKind: .pdfPage, fileExtensions: ["pdf"]),
        Format(family: .image, sourceKind: .image, fileExtensions: ["png", "jpg", "jpeg", "tif", "tiff", "heic"]),
        Format(family: .plainText, sourceKind: .text, fileExtensions: ["txt"]),
        Format(family: .markdown, sourceKind: .markdown, fileExtensions: ["md", "markdown"]),
        Format(family: .richText, sourceKind: .convertedDocument, fileExtensions: ["rtf"]),
        Format(family: .html, sourceKind: .html, fileExtensions: ["html", "htm"]),
        Format(family: .xml, sourceKind: .xml, fileExtensions: ["xml"]),
        Format(family: .word, sourceKind: .convertedDocument, fileExtensions: ["doc", "docx", "dotx"]),
        Format(family: .spreadsheet, sourceKind: .spreadsheetCellRange, fileExtensions: ["xls", "xlsx"]),
        Format(family: .email, sourceKind: .emailBody, fileExtensions: ["eml", "msg"])
    ]

    private static let formatByExtension: [String: Format] = {
        var map: [String: Format] = [:]
        for format in formats {
            for ext in format.fileExtensions {
                map[ext] = format
            }
        }
        return map
    }()

    /// The set of accepted lowercased extensions.
    public static let supportedExtensions: Set<String> = Set(formatByExtension.keys)

    /// Returns the format for a file URL, or nil if the type is unsupported.
    public static func format(for url: URL) -> Format? {
        formatByExtension[url.pathExtension.lowercased()]
    }

    public static func format(forExtension ext: String) -> Format? {
        formatByExtension[ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) ]
    }

    public static func isSupported(_ url: URL) -> Bool {
        format(for: url) != nil
    }

    /// Legacy formats intentionally shown by the picker so the app can give an
    /// accountable conversion disposition instead of silently hiding them.
    /// They are rejected by the import orchestrator before managed storage.
    public static func unsupportedByPolicyReason(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "xls": legacyXLSGuidance
        case "msg": legacyMSGGuidance
        default: nil
        }
    }

    /// The UTTypes accepted by file/folder import pickers.
    public static func contentTypes() -> [UTType] {
        supportedExtensions.compactMap { UTType(filenameExtension: $0) }
    }
}
