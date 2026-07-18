import Foundation
import ZIPFoundation

struct WordStructureAdapter {
    private let archive: Archive
    private let policy: ImportPolicy

    init(archive: Archive, policy: ImportPolicy) {
        self.archive = archive
        self.policy = policy
    }

    func extract(documentXML: Data, normalizedBodyText: String) throws -> (ExtractedDocumentStructure, [String]) {
        let body = WordBodyCollector()
        let parser = XMLParser(data: documentXML)
        parser.delegate = body
        guard parser.parse() else {
            throw ExtractionError.malformed("Could not parse Word structure in word/document.xml.")
        }

        let numbering = try loadNumbering()
        let relationships = try loadRelationships()
        let auxiliary: [WordAuxiliaryKind: [String: String]] = [
            .footnote: try loadAuxiliary(path: "word/footnotes.xml", kind: .footnote),
            .endnote: try loadAuxiliary(path: "word/endnotes.xml", kind: .endnote),
            .comment: try loadAuxiliary(path: "word/comments.xml", kind: .comment),
        ]
        let builder = WordStructureBuilder(
            body: body.model,
            numbering: numbering,
            relationships: relationships,
            auxiliary: auxiliary,
            storyLoader: loadStory(path:),
            normalizedBodyText: normalizedBodyText
        )
        return try builder.build()
    }

    private func loadNumbering() throws -> WordNumberingModel {
        guard let data = try ZipArchiveReader.entryData(
            in: archive,
            path: "word/numbering.xml",
            policy: policy
        ) else { return WordNumberingModel() }
        try policy.validateXMLData(data)
        let collector = WordNumberingCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else {
            throw ExtractionError.malformed("Could not parse word/numbering.xml.")
        }
        return collector.model
    }

    private func loadRelationships() throws -> [String: String] {
        guard let data = try ZipArchiveReader.entryData(
            in: archive,
            path: "word/_rels/document.xml.rels",
            policy: policy
        ) else { return [:] }
        try policy.validateXMLData(data)
        let collector = WordRelationshipCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else {
            throw ExtractionError.malformed("Could not parse word/_rels/document.xml.rels.")
        }
        return collector.targets
    }

    private func loadAuxiliary(
        path: String,
        kind: WordAuxiliaryKind
    ) throws -> [String: String] {
        guard let data = try ZipArchiveReader.entryData(in: archive, path: path, policy: policy) else {
            return [:]
        }
        try policy.validateXMLData(data)
        let collector = WordAuxiliaryCollector(kind: kind)
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else {
            throw ExtractionError.malformed("Could not parse \(path).")
        }
        return collector.textByID
    }

    private func loadStory(path: String) throws -> String? {
        guard let data = try ZipArchiveReader.entryData(in: archive, path: path, policy: policy) else {
            return nil
        }
        try policy.validateXMLData(data)
        let collector = OOXMLTextCollector(
            textElement: "w:t",
            paragraphElement: "w:p",
            tabElement: "w:tab",
            breakElement: "w:br"
        )
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else {
            throw ExtractionError.malformed("Could not parse \(path).")
        }
        let text = TextNormalization.normalize(collector.text)
        return text.isEmpty ? nil : text
    }
}

private struct WordStructureBuilder {
    let body: WordBodyModel
    let numbering: WordNumberingModel
    let relationships: [String: String]
    let auxiliary: [WordAuxiliaryKind: [String: String]]
    let storyLoader: (String) throws -> String?
    let normalizedBodyText: String

    func build() throws -> (ExtractedDocumentStructure, [String]) {
        let ranges = locateParagraphs()
        var nodes = [ExtractedStructureNode(
            nodeKey: "document",
            partIndex: 0,
            ordinal: 0,
            kind: .document
        )]
        var edges: [ExtractedStructureEdge] = []
        var paragraphNodeKeys: [Int: String] = [:]
        var tableParagraphs = Set<Int>()

        for (tableIndex, table) in body.tables.enumerated() {
            let tableKey = "body/table/\(tableIndex)"
            let tableOrdinal = table.rows.flatMap(\.cells).flatMap(\.paragraphIndices).min() ?? tableIndex
            nodes.append(ExtractedStructureNode(
                nodeKey: tableKey,
                parentNodeKey: "document",
                partIndex: 0,
                ordinal: tableOrdinal,
                kind: .table
            ))
            let explicitHeaders = table.rows.indices.filter { table.rows[$0].isHeader }
            let headerRows = explicitHeaders.isEmpty && !table.rows.isEmpty ? [0] : explicitHeaders
            var headerKeyByColumn: [Int: String] = [:]

            for (rowIndex, row) in table.rows.enumerated() {
                let rowKey = "\(tableKey)/row/\(rowIndex)"
                nodes.append(ExtractedStructureNode(
                    nodeKey: rowKey,
                    parentNodeKey: tableKey,
                    partIndex: 0,
                    ordinal: rowIndex,
                    kind: .tableRow,
                    payloadJSON: json(["header": headerRows.contains(rowIndex), "row": rowIndex])
                ))
                for (columnIndex, cell) in row.cells.enumerated() {
                    tableParagraphs.formUnion(cell.paragraphIndices)
                    let cellKey = "\(rowKey)/cell/\(columnIndex)"
                    let cellRange = combinedRange(cell.paragraphIndices, ranges: ranges)
                    nodes.append(ExtractedStructureNode(
                        nodeKey: cellKey,
                        parentNodeKey: rowKey,
                        partIndex: 0,
                        ordinal: columnIndex,
                        kind: .tableCell,
                        charStart: cellRange?.start,
                        charEnd: cellRange?.end,
                        payloadJSON: json([
                            "column": columnIndex,
                            "header": headerRows.contains(rowIndex),
                            "row": rowIndex,
                        ])
                    ))
                    for paragraphIndex in cell.paragraphIndices {
                        paragraphNodeKeys[paragraphIndex] = cellKey
                    }
                    if headerRows.contains(rowIndex) {
                        headerKeyByColumn[columnIndex] = cellKey
                    } else if let headerKey = headerKeyByColumn[columnIndex] {
                        edges.append(ExtractedStructureEdge(
                            fromNodeKey: cellKey,
                            toNodeKey: headerKey,
                            kind: .headerFor
                        ))
                    }
                }
            }
        }

        var currentListKey: String?
        var currentListNumID: String?
        var listSequence = 0
        var priorListItemByLevel: [Int: String] = [:]
        for (paragraphIndex, paragraph) in body.paragraphs.enumerated() where !tableParagraphs.contains(paragraphIndex) {
            guard let range = ranges[paragraphIndex] else { continue }
            if let numID = paragraph.numID {
                if currentListKey == nil || currentListNumID != numID {
                    currentListKey = "body/list/\(listSequence)"
                    currentListNumID = numID
                    listSequence += 1
                    priorListItemByLevel.removeAll()
                    nodes.append(ExtractedStructureNode(
                        nodeKey: currentListKey!,
                        parentNodeKey: "document",
                        partIndex: 0,
                        ordinal: paragraphIndex,
                        kind: .list,
                        payloadJSON: json(["numId": numID])
                    ))
                }
                let level = max(0, paragraph.level ?? 0)
                let parent = level == 0
                    ? currentListKey!
                    : (stride(from: level - 1, through: 0, by: -1)
                        .compactMap { priorListItemByLevel[$0] }.first ?? currentListKey!)
                let key = "\(currentListKey!)/item/\(paragraphIndex)"
                var payload: [String: Any] = ["level": level, "numId": numID]
                if let definition = numbering.definition(numID: numID, level: level) {
                    payload["start"] = definition.start
                    payload["format"] = definition.format
                    payload["levelText"] = definition.levelText
                    payload["restart"] = definition.restart
                }
                nodes.append(ExtractedStructureNode(
                    nodeKey: key,
                    parentNodeKey: parent,
                    partIndex: 0,
                    ordinal: paragraphIndex,
                    kind: .listItem,
                    charStart: range.start,
                    charEnd: range.end,
                    payloadJSON: json(payload)
                ))
                paragraphNodeKeys[paragraphIndex] = key
                priorListItemByLevel[level] = key
                priorListItemByLevel = priorListItemByLevel.filter { $0.key <= level }
            } else {
                currentListKey = nil
                currentListNumID = nil
                priorListItemByLevel.removeAll()
                let key = "body/paragraph/\(paragraphIndex)"
                nodes.append(ExtractedStructureNode(
                    nodeKey: key,
                    parentNodeKey: "document",
                    partIndex: 0,
                    ordinal: paragraphIndex,
                    kind: .paragraph,
                    charStart: range.start,
                    charEnd: range.end
                ))
                paragraphNodeKeys[paragraphIndex] = key
            }
        }

        for (paragraphIndex, paragraph) in body.paragraphs.enumerated() {
            guard let parentKey = paragraphNodeKeys[paragraphIndex],
                  let paragraphRange = ranges[paragraphIndex] else { continue }
            for (index, insertion) in paragraph.insertions.enumerated() {
                guard let insertionRange = locate(
                    insertion,
                    inside: paragraphRange,
                    in: normalizedBodyText
                ) else { continue }
                nodes.append(ExtractedStructureNode(
                    nodeKey: "\(parentKey)/tracked-insertion/\(index)",
                    parentNodeKey: parentKey,
                    partIndex: 0,
                    ordinal: index,
                    kind: .trackedInsertion,
                    charStart: insertionRange.start,
                    charEnd: insertionRange.end
                ))
            }
            for (index, deletion) in paragraph.deletions.enumerated() where !deletion.isEmpty {
                nodes.append(ExtractedStructureNode(
                    nodeKey: "\(parentKey)/tracked-deletion/\(index)",
                    parentNodeKey: parentKey,
                    partIndex: 0,
                    ordinal: index,
                    kind: .trackedDeletion,
                    textContent: deletion
                ))
            }
        }

        for (kind, textByID) in auxiliary {
            for (id, text) in textByID.sorted(by: { $0.key < $1.key }) where !text.isEmpty {
                guard let paragraphIndex = anchorParagraph(kind: kind, id: id),
                      let targetKey = paragraphNodeKeys[paragraphIndex] else { continue }
                let key = "notes/\(kind.rawValue)/\(id)"
                nodes.append(ExtractedStructureNode(
                    nodeKey: key,
                    parentNodeKey: "document",
                    partIndex: 0,
                    ordinal: paragraphIndex,
                    kind: kind.nodeKind,
                    textContent: text,
                    payloadJSON: json(["id": id])
                ))
                edges.append(ExtractedStructureEdge(
                    fromNodeKey: key,
                    toNodeKey: targetKey,
                    kind: .anchorOf
                ))
            }
        }

        for (sectionIndex, section) in body.sections.enumerated() {
            let sectionKey = "body/section/\(sectionIndex)"
            nodes.append(ExtractedStructureNode(
                nodeKey: sectionKey,
                parentNodeKey: "document",
                partIndex: 0,
                ordinal: body.paragraphs.count + sectionIndex,
                kind: .section
            ))
            for (referenceIndex, reference) in section.references.enumerated() {
                guard let target = relationships[reference.relationshipID],
                      let storyPath = relationshipPath(target),
                      let text = try storyLoader(storyPath) else { continue }
                nodes.append(ExtractedStructureNode(
                    nodeKey: "\(sectionKey)/\(reference.kind.rawValue)/\(referenceIndex)",
                    parentNodeKey: sectionKey,
                    partIndex: 0,
                    ordinal: referenceIndex,
                    kind: reference.kind,
                    textContent: text,
                    payloadJSON: json([
                        "relationshipId": reference.relationshipID,
                        "target": storyPath,
                        "type": reference.type,
                    ])
                ))
            }
        }

        let warnings = body.hasTrackedChanges
            ? ["Tracked changes were detected; final-state text is selected and insertions/deletions are preserved in document structure."]
            : []
        return (ExtractedDocumentStructure(nodes: nodes, edges: edges), warnings)
    }

    private func locateParagraphs() -> [Int: CharacterRange] {
        var result: [Int: CharacterRange] = [:]
        var cursor = normalizedBodyText.startIndex
        for (index, paragraph) in body.paragraphs.enumerated() {
            let needle = TextNormalization.normalize(paragraph.text)
            guard !needle.isEmpty,
                  let range = normalizedBodyText.range(
                    of: needle,
                    range: cursor..<normalizedBodyText.endIndex
                  ) else { continue }
            result[index] = CharacterRange(
                start: normalizedBodyText.distance(from: normalizedBodyText.startIndex, to: range.lowerBound),
                end: normalizedBodyText.distance(from: normalizedBodyText.startIndex, to: range.upperBound)
            )
            cursor = range.upperBound
        }
        return result
    }

    private func combinedRange(
        _ paragraphIndices: [Int],
        ranges: [Int: CharacterRange]
    ) -> CharacterRange? {
        let values = paragraphIndices.compactMap { ranges[$0] }
        guard let start = values.map(\.start).min(), let end = values.map(\.end).max() else {
            return nil
        }
        return CharacterRange(start: start, end: end)
    }

    private func locate(
        _ needle: String,
        inside container: CharacterRange,
        in text: String
    ) -> CharacterRange? {
        guard !needle.isEmpty else { return nil }
        let lower = text.index(text.startIndex, offsetBy: container.start)
        let upper = text.index(text.startIndex, offsetBy: container.end)
        let candidates = [needle, needle.trimmingCharacters(in: .whitespacesAndNewlines)]
        for candidate in candidates where !candidate.isEmpty {
            if let range = text.range(of: candidate, range: lower..<upper) {
                return CharacterRange(
                    start: text.distance(from: text.startIndex, to: range.lowerBound),
                    end: text.distance(from: text.startIndex, to: range.upperBound)
                )
            }
        }
        return nil
    }

    private func anchorParagraph(kind: WordAuxiliaryKind, id: String) -> Int? {
        body.paragraphs.indices.first { index in
            let paragraph = body.paragraphs[index]
            switch kind {
            case .footnote: return paragraph.footnoteIDs.contains(id)
            case .endnote: return paragraph.endnoteIDs.contains(id)
            case .comment: return paragraph.commentIDs.contains(id)
            }
        }
    }

    private func relationshipPath(_ target: String) -> String? {
        let normalized = target.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.contains("..") else { return nil }
        if normalized.hasPrefix("/") { return String(normalized.dropFirst()) }
        if normalized.hasPrefix("word/") { return normalized }
        return "word/\(normalized)"
    }

    private func json(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

private struct CharacterRange {
    let start: Int
    let end: Int
}

private struct WordBodyModel {
    var paragraphs: [WordParagraph] = []
    var tables: [WordTable] = []
    var sections: [WordSection] = []
    var hasTrackedChanges = false
}

private struct WordParagraph {
    var text: String
    var numID: String?
    var level: Int?
    var insertions: [String]
    var deletions: [String]
    var footnoteIDs: [String]
    var endnoteIDs: [String]
    var commentIDs: [String]
}

private struct WordTable {
    var rows: [WordTableRow] = []
}

private struct WordTableRow {
    var isHeader = false
    var cells: [WordTableCell] = []
}

private struct WordTableCell {
    var paragraphIndices: [Int] = []
}

private struct WordSection {
    var references: [WordStoryReference] = []
}

private struct WordStoryReference {
    let kind: DocumentStructureNodeKind
    let type: String
    let relationshipID: String
}

private final class WordParagraphBuilder {
    var text = ""
    var numID: String?
    var level: Int?
    var insertions: [String] = []
    var deletions: [String] = []
    var footnoteIDs: [String] = []
    var endnoteIDs: [String] = []
    var commentIDs: [String] = []

    func value() -> WordParagraph {
        WordParagraph(
            text: text,
            numID: numID,
            level: level,
            insertions: insertions,
            deletions: deletions,
            footnoteIDs: footnoteIDs,
            endnoteIDs: endnoteIDs,
            commentIDs: commentIDs
        )
    }
}

private final class WordBodyCollector: NSObject, XMLParserDelegate {
    private(set) var model = WordBodyModel()
    private var paragraph: WordParagraphBuilder?
    private var tableIndex: Int?
    private var rowIndex: Int?
    private var cellIndex: Int?
    private var sectionIndex: Int?
    private var capture: Capture?
    private var insertionDepth = 0
    private var deletionDepth = 0
    private var insertionText = ""
    private var deletionText = ""

    private enum Capture { case selected, deletion }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        switch local(elementName) {
        case "tbl":
            model.tables.append(WordTable())
            tableIndex = model.tables.count - 1
        case "tr":
            guard let tableIndex else { break }
            model.tables[tableIndex].rows.append(WordTableRow())
            rowIndex = model.tables[tableIndex].rows.count - 1
        case "tblHeader":
            if let tableIndex, let rowIndex {
                model.tables[tableIndex].rows[rowIndex].isHeader = true
            }
        case "tc":
            guard let tableIndex, let rowIndex else { break }
            model.tables[tableIndex].rows[rowIndex].cells.append(WordTableCell())
            cellIndex = model.tables[tableIndex].rows[rowIndex].cells.count - 1
        case "p":
            paragraph = WordParagraphBuilder()
        case "numId":
            paragraph?.numID = attribute("val", in: attributeDict)
        case "ilvl":
            paragraph?.level = attribute("val", in: attributeDict).flatMap(Int.init)
        case "t":
            capture = deletionDepth > 0 ? .deletion : .selected
        case "delText":
            capture = .deletion
        case "tab":
            appendSelected("\t")
        case "br", "cr":
            appendSelected("\n")
        case "ins":
            insertionDepth += 1
            if insertionDepth == 1 { insertionText = "" }
            model.hasTrackedChanges = true
        case "del":
            deletionDepth += 1
            if deletionDepth == 1 { deletionText = "" }
            model.hasTrackedChanges = true
        case "footnoteReference":
            if let id = attribute("id", in: attributeDict) { paragraph?.footnoteIDs.append(id) }
        case "endnoteReference":
            if let id = attribute("id", in: attributeDict) { paragraph?.endnoteIDs.append(id) }
        case "commentRangeStart", "commentReference":
            if let id = attribute("id", in: attributeDict),
               paragraph?.commentIDs.contains(id) == false {
                paragraph?.commentIDs.append(id)
            }
        case "sectPr":
            model.sections.append(WordSection())
            sectionIndex = model.sections.count - 1
        case "headerReference", "footerReference":
            guard let sectionIndex,
                  let relationshipID = attribute("id", in: attributeDict) else { break }
            let kind: DocumentStructureNodeKind = local(elementName) == "headerReference" ? .header : .footer
            model.sections[sectionIndex].references.append(WordStoryReference(
                kind: kind,
                type: attribute("type", in: attributeDict) ?? "default",
                relationshipID: relationshipID
            ))
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        switch capture {
        case .selected:
            paragraph?.text += string
            if insertionDepth > 0 { insertionText += string }
        case .deletion:
            deletionText += string
        case nil:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch local(elementName) {
        case "t", "delText":
            capture = nil
        case "ins":
            insertionDepth -= 1
            if insertionDepth == 0, !insertionText.isEmpty {
                paragraph?.insertions.append(insertionText)
            }
        case "del":
            deletionDepth -= 1
            if deletionDepth == 0, !deletionText.isEmpty {
                paragraph?.deletions.append(deletionText)
            }
        case "p":
            guard let paragraph else { break }
            let index = model.paragraphs.count
            model.paragraphs.append(paragraph.value())
            if let tableIndex, let rowIndex, let cellIndex {
                model.tables[tableIndex].rows[rowIndex].cells[cellIndex].paragraphIndices.append(index)
            }
            self.paragraph = nil
        case "tc": cellIndex = nil
        case "tr": rowIndex = nil
        case "tbl": tableIndex = nil
        case "sectPr": sectionIndex = nil
        default: break
        }
    }

    private func appendSelected(_ value: String) {
        guard deletionDepth == 0 else {
            deletionText += value
            return
        }
        paragraph?.text += value
        if insertionDepth > 0 { insertionText += value }
    }
}

private struct WordNumberLevel {
    var start = 1
    var format = "decimal"
    var levelText = ""
    var restart = false
}

private struct WordNumberingModel {
    var levelsByAbstractID: [String: [Int: WordNumberLevel]] = [:]
    var abstractIDByNumID: [String: String] = [:]
    var startOverrideByNumID: [String: [Int: Int]] = [:]

    func definition(numID: String, level: Int) -> WordNumberLevel? {
        guard let abstractID = abstractIDByNumID[numID] else { return nil }
        guard var definition = levelsByAbstractID[abstractID]?[level] else { return nil }
        if let override = startOverrideByNumID[numID]?[level] {
            definition.start = override
            definition.restart = true
        }
        return definition
    }
}

private final class WordNumberingCollector: NSObject, XMLParserDelegate {
    private(set) var model = WordNumberingModel()
    private var abstractID: String?
    private var levelIndex: Int?
    private var level = WordNumberLevel()
    private var numID: String?
    private var overrideLevel: Int?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        switch local(elementName) {
        case "abstractNum": abstractID = attribute("abstractNumId", in: attributeDict)
        case "lvl":
            levelIndex = attribute("ilvl", in: attributeDict).flatMap(Int.init)
            level = WordNumberLevel()
        case "start": level.start = attribute("val", in: attributeDict).flatMap(Int.init) ?? 1
        case "numFmt": level.format = attribute("val", in: attributeDict) ?? "decimal"
        case "lvlText": level.levelText = attribute("val", in: attributeDict) ?? ""
        case "num": numID = attribute("numId", in: attributeDict)
        case "abstractNumId":
            if let numID, let value = attribute("val", in: attributeDict) {
                model.abstractIDByNumID[numID] = value
            }
        case "lvlOverride":
            overrideLevel = attribute("ilvl", in: attributeDict).flatMap(Int.init)
        case "startOverride":
            if let numID, let overrideLevel,
               let value = attribute("val", in: attributeDict).flatMap(Int.init) {
                model.startOverrideByNumID[numID, default: [:]][overrideLevel] = value
            }
        default: break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch local(elementName) {
        case "lvl":
            if let abstractID, let levelIndex {
                model.levelsByAbstractID[abstractID, default: [:]][levelIndex] = level
            }
            levelIndex = nil
        case "abstractNum": abstractID = nil
        case "lvlOverride": overrideLevel = nil
        case "num": numID = nil
        default: break
        }
    }
}

private final class WordRelationshipCollector: NSObject, XMLParserDelegate {
    private(set) var targets: [String: String] = [:]

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        guard local(elementName) == "Relationship",
              let id = attribute("Id", in: attributeDict),
              let target = attribute("Target", in: attributeDict) else { return }
        targets[id] = target
    }
}

private enum WordAuxiliaryKind: String, Hashable {
    case footnote
    case endnote
    case comment

    var nodeKind: DocumentStructureNodeKind {
        switch self {
        case .footnote: .footnote
        case .endnote: .endnote
        case .comment: .comment
        }
    }
}

private final class WordAuxiliaryCollector: NSObject, XMLParserDelegate {
    private let kind: WordAuxiliaryKind
    private(set) var textByID: [String: String] = [:]
    private var currentID: String?
    private var fragments: [String] = []
    private var capturing = false

    init(kind: WordAuxiliaryKind) {
        self.kind = kind
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        switch local(elementName) {
        case kind.rawValue:
            currentID = attribute("id", in: attributeDict)
            fragments = []
        case "t": capturing = currentID != nil
        case "tab": if currentID != nil { fragments.append("\t") }
        case "br", "cr": if currentID != nil { fragments.append("\n") }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { fragments.append(string) }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch local(elementName) {
        case "t": capturing = false
        case "p": if currentID != nil { fragments.append("\n") }
        case kind.rawValue:
            if let currentID {
                textByID[currentID] = TextNormalization.normalize(fragments.joined())
            }
            currentID = nil
            fragments = []
        default: break
        }
    }
}

private func local(_ qualifiedName: String) -> String {
    qualifiedName.split(separator: ":").last.map(String.init) ?? qualifiedName
}

private func attribute(_ localName: String, in attributes: [String: String]) -> String? {
    attributes.first { key, _ in
        key == localName || key.split(separator: ":").last.map(String.init) == localName
    }?.value
}
