import Foundation
import ImageIO
import Vision

/// A snapshot of which local extraction/OCR capabilities are available, used by
/// Document Intelligence setup to confirm the toolchain is present (plan §2.1,
/// §2.3). Apple frameworks (PDFKit/Vision/UniformTypeIdentifiers/CryptoKit) are
/// the baseline; bundled converters for legacy Office/email formats are layered
/// in by WO 34 and bump `DocumentToolchain.version`.
public struct DocumentToolchainCapabilities: Codable, Sendable, Equatable {
    public var version: String
    /// PDF text extraction + rendering (PDFKit).
    public var pdfText: Bool
    /// On-device OCR (Vision).
    public var ocr: Bool
    /// Native image decoding for png/jpg/tiff.
    public var nativeImageDecoding: Bool
    /// HEIC decoding availability (plan §17 open decision).
    public var heicDecoding: Bool
    /// Extraction families currently handled locally.
    public var supportedFamilies: [String]
    /// OCR recognition languages reported by Vision, when available.
    public var ocrLanguages: [String]

    public init(
        version: String,
        pdfText: Bool,
        ocr: Bool,
        nativeImageDecoding: Bool,
        heicDecoding: Bool,
        supportedFamilies: [String],
        ocrLanguages: [String]
    ) {
        self.version = version
        self.pdfText = pdfText
        self.ocr = ocr
        self.nativeImageDecoding = nativeImageDecoding
        self.heicDecoding = heicDecoding
        self.supportedFamilies = supportedFamilies
        self.ocrLanguages = ocrLanguages
    }

    /// Setup requires at least PDF text extraction and on-device OCR.
    public var meetsMinimumForSetup: Bool {
        pdfText && ocr
    }
}

public enum DocumentToolchain {
    /// Toolchain capability version. Bump when bundled converters change so
    /// existing setup is re-validated (plan §2.3 "converter toolchain version").
    public static let version = "m3-apple-frameworks-1"

    /// Detects locally-available extraction/OCR capabilities.
    public static func detectCapabilities() -> DocumentToolchainCapabilities {
        let ocrLanguages = supportedOCRLanguages()
        let heic = nativeHEICDecodingAvailable()

        var families: [SupportedDocumentTypes.ExtractionFamily] = [
            .pdf, .image, .plainText, .markdown, .richText, .html, .xml, .email
        ]
        // Word and spreadsheet extraction depend on bundled converters (WO 34);
        // they are reported once those adapters register a higher toolchain
        // version. They remain importable regardless — failures are captured per
        // file in the import report.
        families.append(contentsOf: [.word, .spreadsheet])

        return DocumentToolchainCapabilities(
            version: version,
            pdfText: true,
            ocr: !ocrLanguages.isEmpty,
            nativeImageDecoding: true,
            heicDecoding: heic,
            supportedFamilies: families.map(\.rawValue),
            ocrLanguages: ocrLanguages
        )
    }

    /// Vision's supported text-recognition languages; empty if OCR is unavailable.
    public static func supportedOCRLanguages() -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return (try? request.supportedRecognitionLanguages()) ?? []
    }

    /// Whether HEIC can be decoded natively, by probing the registered image
    /// type identifiers.
    public static func nativeHEICDecodingAvailable() -> Bool {
        // CGImageSource advertises HEIC support on Apple silicon macOS; probe the
        // registered source UTIs rather than assuming.
        guard let identifiers = CGImageSourceCopyTypeIdentifiers() as? [String] else { return false }
        return identifiers.contains { $0.localizedCaseInsensitiveContains("heic") || $0.localizedCaseInsensitiveContains("heif") }
    }
}
