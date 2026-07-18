import Foundation
import PDFKit

/// Builds the bounded structural view promised by the PDF adapter: pages,
/// embedded/OCR line regions, form values, annotation text, and signature
/// presence. It deliberately does not infer tables or alternative reading order.
public enum PDFStructureAdapter {
    /// Rebuilds page and line-region structure from selected parts. This is the
    /// OCR/user-edit handoff: Vision boxes are carried by `boundingBoxesJSON`.
    public static func structure(for parts: [ExtractedPart]) -> ExtractedDocumentStructure {
        build(parts: parts, document: nil, ocrPageIndices: [])
    }

    /// Reflows text-bound regions against newly selected page revisions while
    /// retaining out-of-flow form/annotation metadata captured from the source PDF.
    public static func reflow(
        _ existing: ExtractedDocumentStructure,
        for parts: [ExtractedPart]
    ) -> ExtractedDocumentStructure {
        var rebuilt = structure(for: parts)
        let existingPages = Dictionary(
            uniqueKeysWithValues: existing.nodes
                .filter { $0.kind == .page }
                .map { ($0.partIndex, $0) }
        )
        for index in rebuilt.nodes.indices where rebuilt.nodes[index].kind == .page {
            let partIndex = rebuilt.nodes[index].partIndex
            guard let existingPage = existingPages[partIndex] else { continue }
            var merged = payloadObject(existingPage.payloadJSON)
            payloadObject(rebuilt.nodes[index].payloadJSON).forEach { merged[$0.key] = $0.value }
            rebuilt.nodes[index].payloadJSON = payloadJSON(merged)
        }

        let retained = existing.nodes.filter { node in
            guard node.kind == .region,
                  node.charStart == nil,
                  node.charEnd == nil,
                  node.textContent != nil else { return false }
            let semanticKind = payloadObject(node.payloadJSON)["semanticKind"] as? String
            return semanticKind == "form_field" || semanticKind == "annotation"
        }
        let existingKeys = Set(rebuilt.nodes.map(\.nodeKey))
        rebuilt.nodes.append(contentsOf: retained.filter { !existingKeys.contains($0.nodeKey) })
        let allKeys = Set(rebuilt.nodes.map(\.nodeKey))
        rebuilt.edges.append(contentsOf: existing.edges.filter {
            allKeys.contains($0.fromNodeKey) && allKeys.contains($0.toNodeKey)
        })
        return rebuilt
    }

    static func structure(
        for document: PDFDocument,
        parts: [ExtractedPart],
        ocrPageIndices: [Int]
    ) -> ExtractedDocumentStructure {
        build(parts: parts, document: document, ocrPageIndices: Set(ocrPageIndices))
    }

    private static func build(
        parts: [ExtractedPart],
        document: PDFDocument?,
        ocrPageIndices: Set<Int>
    ) -> ExtractedDocumentStructure {
        guard !parts.isEmpty else { return ExtractedDocumentStructure(nodes: []) }
        var nodes = [ExtractedStructureNode(
            nodeKey: "document",
            partIndex: 0,
            ordinal: 0,
            kind: .document
        )]

        for (partIndex, part) in parts.enumerated() {
            let pageIndex = part.pageIndex ?? partIndex
            let page = document?.page(at: pageIndex)
            let pageKey = "pdf/page/\(partIndex)"
            let annotations = page?.annotations ?? []
            let signatureWidgets = annotations.filter {
                normalizedSubtype($0.type) == "Widget" && $0.widgetFieldType == .signature
            }
            let signatureFields = signatureWidgets.compactMap { annotation -> String? in
                guard let fieldName = annotation.fieldName, !fieldName.isEmpty else { return nil }
                return fieldName
            }
            var pagePayload: [String: Any] = [
                "pageIndex": pageIndex,
                "pageLabel": part.pageLabel ?? "\(pageIndex + 1)",
                "needsOCR": ocrPageIndices.contains(pageIndex)
                    || (document == nil && part.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                "signaturePresent": !signatureWidgets.isEmpty,
                "signatureFields": signatureFields,
            ]
            if let confidence = part.ocrConfidence {
                pagePayload["ocrConfidence"] = confidence
            }
            if let page {
                let bounds = page.bounds(for: .mediaBox)
                pagePayload["mediaBox"] = [
                    "width": Double(bounds.width),
                    "height": Double(bounds.height),
                ]
            }
            nodes.append(ExtractedStructureNode(
                nodeKey: pageKey,
                parentNodeKey: "document",
                partIndex: partIndex,
                ordinal: partIndex,
                kind: .page,
                payloadJSON: payloadJSON(pagePayload)
            ))

            let lineRegions = regions(for: part, page: page)
            for (regionIndex, region) in lineRegions.enumerated() {
                nodes.append(ExtractedStructureNode(
                    nodeKey: "\(pageKey)/region/\(regionIndex)",
                    parentNodeKey: pageKey,
                    partIndex: partIndex,
                    ordinal: regionIndex,
                    kind: .region,
                    charStart: region.range?.lowerBound,
                    charEnd: region.range?.upperBound,
                    payloadJSON: payloadJSON(region.payload)
                ))
            }

            var outOfFlowOrdinal = lineRegions.count
            var formIndex = 0
            var annotationIndex = 0
            for annotation in annotations {
                let subtype = normalizedSubtype(annotation.type)
                if subtype == "Widget" {
                    guard annotation.widgetFieldType != .signature,
                          let value = annotation.widgetStringValue?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                          !value.isEmpty else { continue }
                    var payload: [String: Any] = [
                        "semanticKind": "form_field",
                        "widgetType": widgetType(annotation.widgetFieldType),
                        "box": normalizedBox(annotation.bounds, in: page),
                    ]
                    if let fieldName = annotation.fieldName, !fieldName.isEmpty {
                        payload["fieldName"] = fieldName
                    }
                    nodes.append(ExtractedStructureNode(
                        nodeKey: "\(pageKey)/form/\(formIndex)",
                        parentNodeKey: pageKey,
                        partIndex: partIndex,
                        ordinal: outOfFlowOrdinal,
                        kind: .region,
                        textContent: value,
                        payloadJSON: payloadJSON(payload)
                    ))
                    formIndex += 1
                    outOfFlowOrdinal += 1
                } else if let contents = annotation.contents?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !contents.isEmpty {
                    var payload: [String: Any] = [
                        "semanticKind": "annotation",
                        "subtype": subtype,
                        "box": normalizedBox(annotation.bounds, in: page),
                    ]
                    if let userName = annotation.userName, !userName.isEmpty {
                        payload["userName"] = userName
                    }
                    nodes.append(ExtractedStructureNode(
                        nodeKey: "\(pageKey)/annotation/\(annotationIndex)",
                        parentNodeKey: pageKey,
                        partIndex: partIndex,
                        ordinal: outOfFlowOrdinal,
                        kind: .region,
                        textContent: contents,
                        payloadJSON: payloadJSON(payload)
                    ))
                    annotationIndex += 1
                    outOfFlowOrdinal += 1
                }
            }
        }
        return ExtractedDocumentStructure(nodes: nodes)
    }

    private struct Region {
        var range: Range<Int>?
        var payload: [String: Any]
    }

    private static func regions(for part: ExtractedPart, page: PDFPage?) -> [Region] {
        let lines = part.text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return [] }
        let boxes = ocrBoxes(part.boundingBoxesJSON)
        if !boxes.isEmpty {
            return rangedRegions(
                lines: lines,
                in: part.text,
                payload: { index in
                    var payload: [String: Any] = ["semanticKind": "ocr_line"]
                    if boxes.indices.contains(index) {
                        payload["box"] = boxes[index].box
                        if let confidence = boxes[index].confidence {
                            payload["confidence"] = confidence
                        }
                    }
                    return payload
                }
            )
        }
        if let page,
           let selection = page.selection(for: page.bounds(for: .mediaBox)) {
            let selections = selection.selectionsByLine()
            let selectedLines = selections.compactMap { selection -> (String, [String: Any])? in
                guard let raw = selection.string else { return nil }
                let line = TextNormalization.normalize(raw)
                guard !line.isEmpty else { return nil }
                return (
                    line,
                    [
                        "semanticKind": "embedded_line",
                        "box": normalizedBox(selection.bounds(for: page), in: page),
                    ]
                )
            }
            if !selectedLines.isEmpty {
                return rangedRegions(
                    lines: selectedLines.map(\.0),
                    in: part.text,
                    payload: { selectedLines[$0].1 }
                )
            }
        }
        return rangedRegions(
            lines: lines,
            in: part.text,
            payload: { _ in ["semanticKind": "embedded_line"] }
        )
    }

    private static func rangedRegions(
        lines: [String],
        in text: String,
        payload: (Int) -> [String: Any]
    ) -> [Region] {
        var cursor = text.startIndex
        return lines.enumerated().compactMap { index, line in
            guard let match = text.range(of: line, range: cursor..<text.endIndex) else { return nil }
            let lower = text.distance(from: text.startIndex, to: match.lowerBound)
            let upper = text.distance(from: text.startIndex, to: match.upperBound)
            cursor = match.upperBound
            return Region(range: lower..<upper, payload: payload(index))
        }
    }

    private struct OCRBox {
        var box: [String: Double]
        var confidence: Double?
    }

    private static func ocrBoxes(_ json: String?) -> [OCRBox] {
        guard let json,
              let data = json.data(using: .utf8),
              let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return objects.compactMap { object in
            guard let x = number(object["x"]),
                  let y = number(object["y"]),
                  let width = number(object["w"] ?? object["width"]),
                  let height = number(object["h"] ?? object["height"]) else { return nil }
            return OCRBox(
                box: ["x": x, "y": y, "width": width, "height": height],
                confidence: number(object["confidence"])
            )
        }
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func normalizedBox(_ bounds: CGRect, in page: PDFPage?) -> [String: Double] {
        guard let page else {
            return [
                "x": Double(bounds.minX), "y": Double(bounds.minY),
                "width": Double(bounds.width), "height": Double(bounds.height),
            ]
        }
        let pageBounds = page.bounds(for: .mediaBox)
        guard pageBounds.width > 0, pageBounds.height > 0 else {
            return ["x": 0, "y": 0, "width": 0, "height": 0]
        }
        return [
            "x": unit((bounds.minX - pageBounds.minX) / pageBounds.width),
            "y": unit((bounds.minY - pageBounds.minY) / pageBounds.height),
            "width": unit(bounds.width / pageBounds.width),
            "height": unit(bounds.height / pageBounds.height),
        ]
    }

    private static func unit(_ value: CGFloat) -> Double {
        Double(min(1, max(0, value)))
    }

    private static func normalizedSubtype(_ type: String?) -> String {
        (type ?? "Unknown").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func widgetType(_ type: PDFAnnotationWidgetSubtype) -> String {
        switch type {
        case .button: "button"
        case .choice: "choice"
        case .signature: "signature"
        case .text: "text"
        default: "unknown"
        }
    }

    private static func payloadObject(_ json: String?) -> [String: Any] {
        guard let json,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private static func payloadJSON(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
