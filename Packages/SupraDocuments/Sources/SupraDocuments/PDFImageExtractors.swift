import Foundation
import PDFKit
import SupraCore

/// Extracts embedded text from PDFs page by page (PDFKit). Pages/documents with
/// little or no text are flagged `needsOCR` for the OCR step (WO 36).
public struct PDFExtractor: DocumentExtractor {
    /// Below this many non-whitespace characters per page on average, the PDF is
    /// treated as scanned and routed to OCR.
    private let lowTextPerPageThreshold: Int

    public init(lowTextPerPageThreshold: Int = 16) {
        self.lowTextPerPageThreshold = lowTextPerPageThreshold
    }

    public func extract(fileURL: URL) async throws -> ExtractionResult {
        guard let document = PDFDocument(url: fileURL) else {
            throw ExtractionError.malformed("Could not open PDF.")
        }
        let pageCount = document.pageCount
        guard pageCount > 0 else {
            throw ExtractionError.malformed("PDF has no pages.")
        }

        var parts: [ExtractedPart] = []
        var totalChars = 0
        for index in 0..<pageCount {
            guard let page = document.page(at: index) else { continue }
            let text = TextNormalization.normalize(page.string ?? "")
            totalChars += text.filter { !$0.isWhitespace }.count
            parts.append(ExtractedPart(
                sourceKind: .pdfPage,
                text: text,
                pageIndex: index,
                pageLabel: page.label ?? "\(index + 1)"
            ))
        }

        let needsOCR = totalChars < lowTextPerPageThreshold * pageCount
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
            metadataCreatedAt: attributes?[PDFDocumentAttribute.creationDateAttribute] as? Date,
            metadataModifiedAt: attributes?[PDFDocumentAttribute.modificationDateAttribute] as? Date
        )
    }
}

/// Images carry no embedded text; they are always routed to OCR (WO 36). The
/// extractor emits a single image part as a placeholder locator.
public struct ImageExtractor: DocumentExtractor {
    public init() {}

    public func extract(fileURL: URL) async throws -> ExtractionResult {
        let part = ExtractedPart(sourceKind: .image, text: "", pageIndex: 0, pageLabel: "1")
        return ExtractionResult(
            parts: [part],
            method: "image",
            warnings: ["Image requires OCR to extract text."],
            needsOCR: true
        )
    }
}
