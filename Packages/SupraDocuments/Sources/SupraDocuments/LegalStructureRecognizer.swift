import Foundation

/// Deterministic, format-agnostic recognition of legal units whose textual
/// conventions are stronger than their container format. The pass is additive:
/// it never changes extracted text or existing adapter nodes.
public enum LegalStructureRecognizer {
    public static func enrich(_ extraction: ExtractionResult) -> ExtractionResult {
        var result = extraction
        guard let rootKey = extraction.structure.nodes.first(where: { $0.parentNodeKey == nil })?.nodeKey else {
            return result
        }

        var nodes = extraction.structure.nodes.filter { !$0.nodeKey.hasPrefix("legal/") }
        var edges = extraction.structure.edges.filter {
            !$0.fromNodeKey.hasPrefix("legal/") && !$0.toNodeKey.hasPrefix("legal/")
        }
        var discoveryUnits: [DiscoveryUnit] = []

        for (partIndex, part) in extraction.parts.enumerated() where !part.text.isEmpty {
            let recognized = recognizeDiscovery(
                in: part.text,
                partIndex: partIndex,
                rootKey: rootKey,
                ordinalBase: 10_000 + partIndex * 1_000
            )
            nodes.append(contentsOf: recognized.nodes)
            edges.append(contentsOf: recognized.edges)
            discoveryUnits.append(contentsOf: recognized.units)

            let deposition = recognizeDeposition(
                in: part.text,
                partIndex: partIndex,
                rootKey: rootKey,
                ordinalBase: 10_500 + partIndex * 1_000
            )
            nodes.append(contentsOf: deposition.nodes)
            edges.append(contentsOf: deposition.edges)
        }

        let requestsByIdentity = Dictionary(grouping: discoveryUnits.filter { $0.kind == .request }) {
            $0.identity
        }
        for response in discoveryUnits where response.kind == .response {
            guard let requests = requestsByIdentity[response.identity], requests.count == 1,
                  let request = requests.first else { continue }
            edges.append(ExtractedStructureEdge(
                fromNodeKey: response.nodeKey,
                toNodeKey: request.nodeKey,
                kind: .respondsTo
            ))
        }

        result.structure = ExtractedDocumentStructure(nodes: nodes, edges: deduplicated(edges))
        return result
    }

    private enum DiscoveryKind {
        case request
        case response
    }

    private struct DiscoveryUnit {
        var nodeKey: String
        var kind: DiscoveryKind
        var family: String
        var number: String

        var identity: String { "\(family)|\(number)" }
    }

    private struct Recognition {
        var nodes: [ExtractedStructureNode]
        var edges: [ExtractedStructureEdge]
        var units: [DiscoveryUnit]
    }

    private struct Marker {
        var start: Int
        var response: Bool
        var family: String
        var number: String
    }

    private static func recognizeDiscovery(
        in text: String,
        partIndex: Int,
        rootKey: String,
        ordinalBase: Int
    ) -> Recognition {
        let pattern = #"(?im)^[ \t]*(?:(response)[ \t]+to[ \t]+)?(request|interrogatory)(?:[ \t]+for[ \t]+production)?[ \t]+(?:no\.?|number)[ \t]*([A-Za-z0-9.-]+)[ \t]*[:.)-]?[ \t]*"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return Recognition(nodes: [], edges: [], units: [])
        }
        let matches = expression.matches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        )
        let markers: [Marker] = matches.compactMap { match in
            guard let fullRange = Range(match.range, in: text),
                  let familyRange = Range(match.range(at: 2), in: text),
                  let numberRange = Range(match.range(at: 3), in: text) else { return nil }
            let rawFamily = String(text[familyRange]).lowercased()
            let matchedPrefix = String(text[fullRange]).lowercased()
            let family = rawFamily == "interrogatory" ? "interrogatory"
                : (matchedPrefix.contains("for production") ? "production" : "request")
            return Marker(
                start: text.distance(from: text.startIndex, to: fullRange.lowerBound),
                response: match.range(at: 1).location != NSNotFound,
                family: family,
                number: String(text[numberRange]).uppercased()
            )
        }
        guard !markers.isEmpty else { return Recognition(nodes: [], edges: [], units: []) }

        var nodes: [ExtractedStructureNode] = []
        var edges: [ExtractedStructureEdge] = []
        var units: [DiscoveryUnit] = []
        for (index, marker) in markers.enumerated() {
            let tentativeEnd = index + 1 < markers.count ? markers[index + 1].start : text.count
            let end = trimmedEnd(in: text, start: marker.start, end: tentativeEnd)
            guard end > marker.start else { continue }
            let kind: DiscoveryKind = marker.response ? .response : .request
            let key = "legal/part/\(partIndex)/discovery/\(marker.response ? "response" : "request")/\(marker.number)/\(index)"
            nodes.append(ExtractedStructureNode(
                nodeKey: key,
                parentNodeKey: rootKey,
                partIndex: partIndex,
                ordinal: ordinalBase + index,
                kind: marker.response ? .discoveryResponse : .discoveryRequest,
                charStart: marker.start,
                charEnd: end,
                payloadJSON: payloadJSON([
                    "semanticKind": marker.response ? "discovery_response" : "discovery_request",
                    "family": marker.family,
                    "number": marker.number,
                ])
            ))
            let unit = DiscoveryUnit(
                nodeKey: key,
                kind: kind,
                family: marker.family,
                number: marker.number
            )
            units.append(unit)

            if marker.response {
                let objectionPattern = #"(?i)(?:subject[ \t]+to[ \t]+[^.;\n]*objection|objection[ \t]*:[^\n]*)"#
                if let objectionExpression = try? NSRegularExpression(pattern: objectionPattern) {
                    let searchRange = stringRange(start: marker.start, end: end, in: text)
                    for (objectionIndex, match) in objectionExpression.matches(in: text, range: searchRange).enumerated() {
                        guard let range = Range(match.range, in: text) else { continue }
                        let start = text.distance(from: text.startIndex, to: range.lowerBound)
                        let objectionEnd = text.distance(from: text.startIndex, to: range.upperBound)
                        let objectionKey = "\(key)/objection/\(objectionIndex)"
                        nodes.append(ExtractedStructureNode(
                            nodeKey: objectionKey,
                            parentNodeKey: rootKey,
                            partIndex: partIndex,
                            ordinal: ordinalBase + 500 + index * 10 + objectionIndex,
                            kind: .objection,
                            charStart: start,
                            charEnd: objectionEnd,
                            payloadJSON: payloadJSON([
                                "semanticKind": "objection",
                                "family": marker.family,
                                "number": marker.number,
                            ])
                        ))
                        edges.append(ExtractedStructureEdge(
                            fromNodeKey: objectionKey,
                            toNodeKey: key,
                            kind: .respondsTo
                        ))
                    }
                }
            }
        }
        return Recognition(nodes: nodes, edges: edges, units: units)
    }

    private struct DepositionMarker {
        var start: Int
        var speaker: Character
        var line: String?
    }

    private static func recognizeDeposition(
        in text: String,
        partIndex: Int,
        rootKey: String,
        ordinalBase: Int
    ) -> (nodes: [ExtractedStructureNode], edges: [ExtractedStructureEdge]) {
        let pattern = #"(?m)^[ \t]*(?:(\d+)[ \t]+)?([QA])[.][ \t]+"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return ([], []) }
        let matches = expression.matches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        )
        let markers: [DepositionMarker] = matches.compactMap { match in
            guard let range = Range(match.range, in: text),
                  let speakerRange = Range(match.range(at: 2), in: text),
                  let speaker = text[speakerRange].first else { return nil }
            let line = Range(match.range(at: 1), in: text).map { String(text[$0]) }
            return DepositionMarker(
                start: text.distance(from: text.startIndex, to: range.lowerBound),
                speaker: speaker,
                line: line
            )
        }
        guard markers.count >= 2 else { return ([], []) }

        var nodes: [ExtractedStructureNode] = []
        var edges: [ExtractedStructureEdge] = []
        var pairIndex = 0
        for index in 1..<markers.count where markers[index - 1].speaker == "Q" && markers[index].speaker == "A" {
            let question = markers[index - 1]
            let answer = markers[index]
            let questionEnd = trimmedEnd(in: text, start: question.start, end: answer.start)
            let answerTentativeEnd = index + 1 < markers.count ? markers[index + 1].start : text.count
            let answerEnd = trimmedEnd(in: text, start: answer.start, end: answerTentativeEnd)
            guard questionEnd > question.start, answerEnd > answer.start else { continue }

            let questionKey = "legal/part/\(partIndex)/deposition/question/\(pairIndex)"
            let answerKey = "legal/part/\(partIndex)/deposition/answer/\(pairIndex)"
            var questionPayload: [String: Any] = ["semanticKind": "deposition_question"]
            var answerPayload: [String: Any] = ["semanticKind": "deposition_answer"]
            if let line = question.line { questionPayload["line"] = line }
            if let line = answer.line { answerPayload["line"] = line }
            nodes.append(ExtractedStructureNode(
                nodeKey: questionKey,
                parentNodeKey: rootKey,
                partIndex: partIndex,
                ordinal: ordinalBase + pairIndex * 2,
                kind: .depositionQuestion,
                charStart: question.start,
                charEnd: questionEnd,
                payloadJSON: payloadJSON(questionPayload)
            ))
            nodes.append(ExtractedStructureNode(
                nodeKey: answerKey,
                parentNodeKey: rootKey,
                partIndex: partIndex,
                ordinal: ordinalBase + pairIndex * 2 + 1,
                kind: .depositionAnswer,
                charStart: answer.start,
                charEnd: answerEnd,
                payloadJSON: payloadJSON(answerPayload)
            ))
            edges.append(ExtractedStructureEdge(
                fromNodeKey: answerKey,
                toNodeKey: questionKey,
                kind: .respondsTo
            ))
            pairIndex += 1
        }
        return (nodes, edges)
    }

    private static func trimmedEnd(in text: String, start: Int, end: Int) -> Int {
        guard end > start else { return start }
        let lower = text.index(text.startIndex, offsetBy: start)
        var upper = text.index(text.startIndex, offsetBy: end)
        while upper > lower {
            let previous = text.index(before: upper)
            if text[previous].isWhitespace { upper = previous } else { break }
        }
        return text.distance(from: text.startIndex, to: upper)
    }

    private static func stringRange(start: Int, end: Int, in text: String) -> NSRange {
        let lower = text.index(text.startIndex, offsetBy: start)
        let upper = text.index(text.startIndex, offsetBy: end)
        return NSRange(lower..<upper, in: text)
    }

    private static func payloadJSON(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func deduplicated(_ edges: [ExtractedStructureEdge]) -> [ExtractedStructureEdge] {
        var identities = Set<String>()
        return edges.filter { edge in
            identities.insert("\(edge.fromNodeKey)|\(edge.toNodeKey)|\(edge.kind.rawValue)").inserted
        }
    }
}
