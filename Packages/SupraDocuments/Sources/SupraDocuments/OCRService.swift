import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import SupraCore
import Vision

/// Result of OCR over one image or PDF page (plan §6.2). Confidence is the mean
/// recognition confidence in 0...1; bounding boxes (normalized) support best-effort
/// highlights (WO 40).
public struct OCRTextResult: Sendable, Equatable {
    public var text: String
    public var confidence: Double
    public var boundingBoxesJSON: String?

    public init(text: String, confidence: Double, boundingBoxesJSON: String? = nil) {
        self.text = text
        self.confidence = confidence
        self.boundingBoxesJSON = boundingBoxesJSON
    }
}

/// On-device OCR for image files and scanned PDF pages. Abstracted so the import
/// pipeline can be tested with mocked OCR results (plan §15.3).
public protocol DocumentOCRService: Sendable {
    func recognizeImage(at url: URL) async throws -> OCRTextResult
    func recognizePDFPages(at url: URL, pageIndices: [Int]?) async throws -> [Int: OCRTextResult]
}

/// Below this mean confidence, OCR output is treated as low-confidence and the
/// document is flagged for review (plan §6.2, §8.4).
public enum OCRPolicy {
    public static let lowConfidenceThreshold = 0.5
}

/// Vision-backed on-device OCR.
public struct VisionOCRService: DocumentOCRService {
    private let renderScale: CGFloat
    private let policy: ImportPolicy

    public init(renderScale: CGFloat = 2.0, policy: ImportPolicy = .default) {
        self.renderScale = renderScale
        self.policy = policy
    }

    public func recognizeImage(at url: URL) async throws -> OCRTextResult {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ExtractionError.fileUnreadable("Could not decode image for OCR.")
        }
        let pixels = Int64(cgImage.width).multipliedReportingOverflow(by: Int64(cgImage.height))
        if pixels.overflow || pixels.partialValue > Int64(policy.maxPixels) {
            throw ExtractionError.policyViolation(
                ImportPolicyViolation(.pixelLimit, "Image exceeds the \(policy.maxPixels)-pixel OCR limit.")
            )
        }
        return try Self.recognize(cgImage: cgImage)
    }

    public func recognizePDFPages(at url: URL, pageIndices: [Int]?) async throws -> [Int: OCRTextResult] {
        guard let document = PDFDocument(url: url) else {
            throw ExtractionError.malformed("Could not open PDF for OCR.")
        }
        let indices = pageIndices ?? Array(0..<document.pageCount)
        if indices.count > policy.maxPages {
            throw ExtractionError.policyViolation(
                ImportPolicyViolation(.pageLimit, "PDF exceeds the \(policy.maxPages)-page OCR limit.")
            )
        }
        var results: [Int: OCRTextResult] = [:]
        var renderedPixels: Double = 0
        for index in indices {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            renderedPixels += max(1, bounds.width * renderScale) * max(1, bounds.height * renderScale)
            if renderedPixels > Double(policy.maxPixels) {
                throw ExtractionError.policyViolation(
                    ImportPolicyViolation(.pixelLimit, "PDF OCR exceeds the \(policy.maxPixels)-pixel limit.")
                )
            }
            guard let cgImage = render(page: page) else { continue }
            results[index] = try Self.recognize(cgImage: cgImage)
        }
        return results
    }

    private func render(page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let width = max(1, Int(bounds.width * renderScale))
        let height = max(1, Int(bounds.height * renderScale))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: renderScale, y: renderScale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    static func recognize(cgImage: CGImage) throws -> OCRTextResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        let observations = request.results ?? []
        var lines: [String] = []
        var confidences: [Float] = []
        var boxes: [[String: Double]] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            lines.append(candidate.string)
            confidences.append(candidate.confidence)
            let box = observation.boundingBox
            boxes.append([
                "x": Double(box.origin.x), "y": Double(box.origin.y),
                "w": Double(box.size.width), "h": Double(box.size.height),
                "confidence": Double(candidate.confidence)
            ])
        }
        let meanConfidence = confidences.isEmpty ? 0 : Double(confidences.reduce(0, +)) / Double(confidences.count)
        let boxesJSON = (try? JSONSerialization.data(withJSONObject: boxes)).flatMap { String(data: $0, encoding: .utf8) }
        return OCRTextResult(
            text: TextNormalization.normalize(lines.joined(separator: "\n")),
            confidence: meanConfidence,
            boundingBoxesJSON: boxesJSON
        )
    }
}
