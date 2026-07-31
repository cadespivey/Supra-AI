import CoreGraphics
import Foundation

/// One Vision-normalized OCR line prepared for display. Coordinates use Vision's
/// bottom-left origin and remain normalized until the view's final aspect-fit size
/// is known.
public struct OCRPreviewRegion: Sendable, Identifiable, Equatable {
    public var id: Int
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var confidence: Double
    public var text: String?
    public var isHighlighted: Bool

    public init(
        id: Int,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        confidence: Double,
        text: String?,
        isHighlighted: Bool
    ) {
        self.id = id
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.confidence = confidence
        self.text = text
        self.isHighlighted = isHighlighted
    }
}

/// Parsed overlay state. Schema 0 is the historical bare-array payload; schema 1
/// is the versioned envelope emitted by current OCR.
public struct OCRPreviewOverlay: Sendable, Equatable {
    public var schemaVersion: Int
    public var regions: [OCRPreviewRegion]
    public var warning: String?

    public init(schemaVersion: Int, regions: [OCRPreviewRegion], warning: String? = nil) {
        self.schemaVersion = schemaVersion
        self.regions = regions
        self.warning = warning
    }

    public static let empty = OCRPreviewOverlay(schemaVersion: 0, regions: [])
}

public enum OCRPreviewOverlayParser {
    private struct Envelope: Decodable {
        var schemaVersion: Int
        var regions: [EncodedRegion]
    }

    private struct EncodedRegion: Decodable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        var confidence: Double
        var text: String?

        private enum CodingKeys: String, CodingKey {
            case x, y, confidence, text
            case width = "w"
            case height = "h"
        }
    }

    public static func parse(_ json: String?, highlightedText: String? = nil) -> OCRPreviewOverlay {
        guard let json, !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = json.data(using: .utf8) else {
            return .empty
        }
        let trimmed = json.drop { $0.isWhitespace }
        let schemaVersion: Int
        let encoded: [EncodedRegion]
        do {
            if trimmed.first == "[" {
                schemaVersion = 0
                encoded = try JSONDecoder().decode([EncodedRegion].self, from: data)
            } else {
                let envelope = try JSONDecoder().decode(Envelope.self, from: data)
                guard envelope.schemaVersion == 1 else {
                    return OCRPreviewOverlay(
                        schemaVersion: envelope.schemaVersion,
                        regions: [],
                        warning: "OCR highlight data uses an unsupported version."
                    )
                }
                schemaVersion = envelope.schemaVersion
                encoded = envelope.regions
            }
        } catch {
            return OCRPreviewOverlay(
                schemaVersion: 0,
                regions: [],
                warning: "OCR highlight data could not be displayed safely."
            )
        }

        guard encoded.allSatisfy(isValid) else {
            return OCRPreviewOverlay(
                schemaVersion: schemaVersion,
                regions: [],
                warning: "OCR highlight data could not be displayed safely."
            )
        }
        let normalizedHighlight = normalized(highlightedText)
        let regions = encoded.enumerated().map { index, item in
            let normalizedText = normalized(item.text)
            let highlighted = !normalizedHighlight.isEmpty
                && !normalizedText.isEmpty
                && (normalizedText.contains(normalizedHighlight) || normalizedHighlight.contains(normalizedText))
            return OCRPreviewRegion(
                id: index,
                x: item.x,
                y: item.y,
                width: item.width,
                height: item.height,
                confidence: item.confidence,
                text: item.text,
                isHighlighted: highlighted
            )
        }
        return OCRPreviewOverlay(schemaVersion: schemaVersion, regions: regions)
    }

    private static func isValid(_ region: EncodedRegion) -> Bool {
        let values = [region.x, region.y, region.width, region.height, region.confidence]
        return values.allSatisfy(\.isFinite)
            && region.x >= 0
            && region.y >= 0
            && region.width > 0
            && region.height > 0
            && region.x + region.width <= 1
            && region.y + region.height <= 1
            && (0...1).contains(region.confidence)
    }

    private static func normalized(_ text: String?) -> String {
        (text ?? "")
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

public enum OCRPreviewGeometry {
    public static func aspectFitRect(imageSize: CGSize, containerSize: CGSize) -> CGRect? {
        guard imageSize.width > 0, imageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else { return nil }
        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (containerSize.width - size.width) / 2,
            y: (containerSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Converts Vision's bottom-left normalized coordinates into AppKit/SwiftUI's
    /// top-left display coordinates inside the final aspect-fit image rectangle.
    public static func displayRect(
        for region: OCRPreviewRegion,
        imageSize: CGSize,
        containerSize: CGSize
    ) -> CGRect? {
        guard let fitted = aspectFitRect(imageSize: imageSize, containerSize: containerSize) else {
            return nil
        }
        return CGRect(
            x: fitted.minX + CGFloat(region.x) * fitted.width,
            y: fitted.minY + CGFloat(1 - region.y - region.height) * fitted.height,
            width: CGFloat(region.width) * fitted.width,
            height: CGFloat(region.height) * fitted.height
        )
    }
}
