import Foundation
import ImageIO
import PDFKit
import SupraCore

/// Extracts embedded text from PDFs page by page (PDFKit). Each page with little
/// or no text is flagged for OCR in `ocrPageIndices`, and `needsOCR` is set when
/// any page needs it (WO 36).
public struct PDFExtractor: DocumentExtractor {
    /// Below this many non-whitespace characters on a page, that page is treated
    /// as scanned and routed to OCR.
    private let lowTextPerPageThreshold: Int
    private let policy: ImportPolicy

    public init(lowTextPerPageThreshold: Int = 16, policy: ImportPolicy = .default) {
        self.lowTextPerPageThreshold = lowTextPerPageThreshold
        self.policy = policy
    }

    public func extract(fileURL: URL) async throws -> ExtractionResult {
        guard let document = PDFDocument(url: fileURL) else {
            throw ExtractionError.malformed("Could not open PDF.")
        }
        let pageCount = document.pageCount
        guard pageCount > 0 else {
            throw ExtractionError.malformed("PDF has no pages.")
        }
        guard pageCount <= policy.maxPages else {
            throw ImportPolicyViolation(.pageLimit, "PDF exceeds the \(policy.maxPages)-page limit.")
        }

        var parts: [ExtractedPart] = []
        var ocrPageIndices: [Int] = []
        var totalPixels = 0.0
        for index in 0..<pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            totalPixels += max(1, bounds.width * 2) * max(1, bounds.height * 2)
            guard totalPixels <= Double(policy.maxPixels) else {
                throw ImportPolicyViolation(.pixelLimit, "PDF rendering exceeds the \(policy.maxPixels)-pixel limit.")
            }
            let text = TextNormalization.normalize(page.string ?? "")
            if text.filter({ !$0.isWhitespace }).count < lowTextPerPageThreshold {
                ocrPageIndices.append(index)
            }
            parts.append(ExtractedPart(
                sourceKind: .pdfPage,
                text: text,
                pageIndex: index,
                pageLabel: page.label ?? "\(index + 1)"
            ))
        }
        try policy.validateDecodedText(parts.map(\.text).joined(separator: "\n\n"))

        let needsOCR = !ocrPageIndices.isEmpty
        var warnings: [String] = []
        if needsOCR {
            warnings.append("PDF has little embedded text; OCR recommended.")
        }

        let attributes = document.documentAttributes
        return ExtractionResult(
            parts: parts,
            method: "pdfkit",
            warnings: warnings,
            needsOCR: needsOCR,
            ocrPageIndices: ocrPageIndices,
            metadataCreatedAt: attributes?[PDFDocumentAttribute.creationDateAttribute] as? Date,
            metadataModifiedAt: attributes?[PDFDocumentAttribute.modificationDateAttribute] as? Date
        )
    }
}

/// Images carry no embedded text; they are always routed to OCR (WO 36). The
/// extractor emits a single image part as a placeholder locator.
public struct ImageExtractor: DocumentExtractor {
    private let policy: ImportPolicy

    public init(policy: ImportPolicy = .default) { self.policy = policy }

    public func extract(fileURL: URL) async throws -> ExtractionResult {
        if let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
           let height = properties[kCGImagePropertyPixelHeight] as? NSNumber {
            let pixels = width.int64Value.multipliedReportingOverflow(by: height.int64Value)
            if pixels.overflow || pixels.partialValue > Int64(policy.maxPixels) {
                throw ImportPolicyViolation(.pixelLimit, "Image exceeds the \(policy.maxPixels)-pixel limit.")
            }
        }
        let part = ExtractedPart(sourceKind: .image, text: "", pageIndex: 0, pageLabel: "1")
        return ExtractionResult(
            parts: [part],
            method: "image",
            warnings: ["Image requires OCR to extract text."],
            needsOCR: true,
            ocrPageIndices: [0]
        )
    }
}
