import AppKit
import CoreText
import Foundation

enum RichPDFExportRenderer {
    private static let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
    private static let bodyRect = CGRect(x: 54, y: 64, width: 504, height: 674)

    static func render(_ payload: DocumentExportPayload) throws -> Data {
        let attributed = attributedDocument(RichExportDocument(payload: payload))
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let ranges = pageRanges(for: framesetter, totalLength: attributed.length)
        var mediaBox = pageRect
        let output = NSMutableData()
        let metadata = [kCGPDFContextTitle as String: payload.title] as CFDictionary
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, metadata) else {
            throw ExtractionError.fileUnreadable("Could not create PDF context.")
        }

        for (index, range) in ranges.enumerated() {
            context.beginPDFPage(nil)
            let path = CGPath(rect: bodyRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, range, path, nil)
            CTFrameDraw(frame, context)
            drawPageNumber(index + 1, total: ranges.count, in: context)
            context.endPDFPage()
        }
        context.closePDF()
        return output as Data
    }

    private static func pageRanges(for framesetter: CTFramesetter, totalLength: Int) -> [CFRange] {
        guard totalLength > 0 else { return [CFRange(location: 0, length: 0)] }
        let path = CGPath(rect: bodyRect, transform: nil)
        var ranges: [CFRange] = []
        var location = 0
        while location < totalLength {
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            let length = max(visible.length, 1)
            ranges.append(CFRange(location: location, length: length))
            location += length
        }
        return ranges
    }

    private static func drawPageNumber(_ page: Int, total: Int, in context: CGContext) {
        let text = NSAttributedString(
            string: "Page \(page) of \(total)",
            attributes: [
                .font: NSFont(name: "Helvetica", size: 9) ?? NSFont.systemFont(ofSize: 9),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        let line = CTLineCreateWithAttributedString(text)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        context.textPosition = CGPoint(x: (pageRect.width - width) / 2, y: 31)
        CTLineDraw(line, context)
    }

    private static func attributedDocument(_ document: RichExportDocument) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for block in document.blocks {
            switch block {
            case let .title(content):
                append(content, to: result, style: style(size: 22, weight: .bold, alignment: .center, after: 14))
            case let .reviewBanner(content):
                guard !plainText(content).isEmpty else { continue }
                append(
                    content,
                    to: result,
                    style: style(size: 10, weight: .semibold, color: .systemBrown, alignment: .center, after: 14)
                )
            case let .heading(level, content):
                let size: CGFloat = switch min(max(level, 1), 6) {
                case 1: 16
                case 2: 14
                case 3: 12
                default: 11
                }
                append(content, to: result, style: style(size: size, weight: .bold, before: 8, after: 6))
            case let .paragraph(content):
                append(content, to: result, style: style(size: 11, after: 7))
            case let .blockQuote(content):
                append(content, to: result, style: style(size: 11, italic: true, leftIndent: 18, after: 8))
            case let .unorderedList(items):
                for item in items {
                    append(item, prefix: "•  ", to: result, style: style(size: 11, leftIndent: 18, firstLineIndent: -12, after: 3))
                }
                appendSpacer(to: result, points: 4)
            case let .orderedList(start, items):
                for (offset, item) in items.enumerated() {
                    append(item, prefix: "\(start + offset).  ", to: result, style: style(size: 11, leftIndent: 24, firstLineIndent: -18, after: 3))
                }
                appendSpacer(to: result, points: 4)
            case let .table(table):
                appendTable(table, to: result)
            case let .sourceAppendix(sources):
                guard !sources.isEmpty else { continue }
                append([.text("Sources")], to: result, style: style(size: 14, weight: .bold, before: 14, after: 7))
                for source in sources {
                    var heading = "[\(source.label)] \(source.documentName) — \(source.locator)"
                    if !source.warnings.isEmpty { heading += " (\(source.warnings))" }
                    append([.strong(heading)], to: result, style: style(size: 10, after: 2))
                    if !source.excerpt.isEmpty {
                        append([.text(source.excerpt)], to: result, style: style(size: 10, color: .secondaryLabelColor, leftIndent: 12, after: 6))
                    }
                }
            }
        }
        return result
    }

    private static func appendTable(_ table: RichExportDocument.Table, to result: NSMutableAttributedString) {
        let header = table.headers.map(plainText).joined(separator: "   |   ")
        append([.strong(header)], to: result, style: style(size: 10, weight: .bold, monospaced: true, after: 3))
        for row in table.rows {
            append([.text(row.map(plainText).joined(separator: "   |   "))], to: result, style: style(size: 10, monospaced: true, after: 3))
        }
        appendSpacer(to: result, points: 5)
    }

    private static func appendSpacer(to result: NSMutableAttributedString, points: CGFloat) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = points
        paragraph.maximumLineHeight = points
        result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph]))
    }

    private static func append(
        _ inline: [RichExportDocument.Inline],
        prefix: String = "",
        to result: NSMutableAttributedString,
        style: [NSAttributedString.Key: Any]
    ) {
        let paragraph = NSMutableAttributedString(string: prefix, attributes: style)
        for node in inline {
            var attributes = style
            let value: String
            switch node {
            case let .text(text):
                value = text
            case let .emphasis(text):
                value = text
                attributes[.font] = font(size: fontSize(in: style), weight: .regular, italic: true)
            case let .strong(text):
                value = text
                attributes[.font] = font(size: fontSize(in: style), weight: .bold)
            case let .code(text):
                value = text
                attributes[.font] = NSFont(name: "Menlo-Regular", size: fontSize(in: style))
                    ?? NSFont.systemFont(ofSize: fontSize(in: style))
            case let .citation(label):
                value = "[\(label)]"
                attributes[.font] = font(size: fontSize(in: style), weight: .semibold)
                attributes[.foregroundColor] = NSColor.systemBlue
            case let .link(label, destination):
                value = "\(label) (\(destination))"
                attributes[.foregroundColor] = NSColor.linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            paragraph.append(NSAttributedString(string: value, attributes: attributes))
        }
        paragraph.append(NSAttributedString(string: "\n", attributes: style))
        result.append(paragraph)
    }

    private static func style(
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        italic: Bool = false,
        monospaced: Bool = false,
        color: NSColor = .labelColor,
        alignment: NSTextAlignment = .left,
        leftIndent: CGFloat = 0,
        firstLineIndent: CGFloat = 0,
        before: CGFloat = 0,
        after: CGFloat = 0
    ) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.headIndent = leftIndent
        paragraph.firstLineHeadIndent = leftIndent + firstLineIndent
        paragraph.paragraphSpacingBefore = before
        paragraph.paragraphSpacing = after
        paragraph.lineSpacing = 2
        let selectedFont = monospaced
            ? (NSFont(name: weight >= .bold ? "Menlo-Bold" : "Menlo-Regular", size: size)
                ?? NSFont.systemFont(ofSize: size, weight: weight))
            : font(size: size, weight: weight, italic: italic)
        return [
            .font: selectedFont,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
    }

    private static func font(size: CGFloat, weight: NSFont.Weight, italic: Bool = false) -> NSFont {
        let name: String
        if weight >= .bold {
            name = italic ? "Helvetica-BoldOblique" : "Helvetica-Bold"
        } else if italic {
            name = "Helvetica-Oblique"
        } else {
            name = "Helvetica"
        }
        return NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
    }

    private static func fontSize(in attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        (attributes[.font] as? NSFont)?.pointSize ?? 11
    }

    private static func plainText(_ nodes: [RichExportDocument.Inline]) -> String {
        nodes.map { node in
            switch node {
            case let .text(value), let .emphasis(value), let .strong(value), let .code(value): value
            case let .citation(label): "[\(label)]"
            case let .link(label, destination): "\(label) (\(destination))"
            }
        }.joined()
    }
}
