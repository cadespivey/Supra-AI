import Foundation
import SupraExports

enum RichDOCXExportRenderer {
    private struct SourceAnchor {
        var name: String
        var bookmarkID: Int
    }

    static func render(_ payload: DocumentExportPayload) throws -> Data {
        let semantic = RichExportDocument(payload: payload)
        let hyperlinkRelationships = externalHyperlinkRelationships(in: semantic)
        let hyperlinkIDs = Dictionary(
            uniqueKeysWithValues: hyperlinkRelationships.map { ($0.target, $0.id) }
        )
        let sourceAnchors = makeSourceAnchors(semantic)
        var body: [BodyElement] = []
        var orderedListIndex = 0
        var orderedStarts: [Int] = []

        func makeParagraph(
            _ content: [RichExportDocument.Inline],
            style: String,
            props: ParaProps = ParaProps()
        ) -> OoxmlParagraph {
            paragraph(
                content,
                style: style,
                props: props,
                hyperlinkIDs: hyperlinkIDs,
                sourceAnchors: sourceAnchors
            )
        }

        for block in semantic.blocks {
            switch block {
            case let .title(content):
                body.append(.paragraph(makeParagraph(content, style: "ExportTitle")))
            case let .reviewBanner(content):
                guard !plainText(content).isEmpty else { continue }
                body.append(.paragraph(makeParagraph(content, style: "ReviewBanner")))
            case let .heading(level, content):
                body.append(.paragraph(makeParagraph(content, style: "ExportHeading\(min(max(level, 1), 6))")))
            case let .paragraph(content):
                body.append(.paragraph(makeParagraph(content, style: "ExportBody")))
            case let .blockQuote(content):
                body.append(.paragraph(makeParagraph(content, style: "ExportQuote")))
            case let .unorderedList(items):
                for item in items {
                    body.append(.paragraph(makeParagraph(
                        item,
                        style: "ExportList",
                        props: ParaProps(numberingLevel: 0, numberingID: 1)
                    )))
                }
            case let .orderedList(start, items):
                orderedStarts.append(start)
                let numberingID = orderedListIndex + 2
                orderedListIndex += 1
                for item in items {
                    body.append(.paragraph(makeParagraph(
                        item,
                        style: "ExportList",
                        props: ParaProps(numberingLevel: 0, numberingID: numberingID)
                    )))
                }
            case let .table(table):
                body.append(.table(ooxmlTable(
                    table,
                    hyperlinkIDs: hyperlinkIDs,
                    sourceAnchors: sourceAnchors
                )))
            case let .sourceAppendix(sources):
                guard !sources.isEmpty else { continue }
                body.append(.paragraph(makeParagraph([.text("Sources")], style: "SourceHeading")))
                body.append(.table(sourceTable(sources, sourceAnchors: sourceAnchors)))
            }
        }

        let section = SectionProps(
            pageWidthTwips: 12_240,
            pageHeightTwips: 15_840,
            marginTopTwips: 1_440,
            marginRightTwips: 1_440,
            marginBottomTwips: 1_440,
            marginLeftTwips: 1_440,
            defaultHeaderRelId: "rIdHeader1",
            defaultFooterRelId: "rIdFooter1",
            pageNumberStart: 1,
            headerDistanceTwips: 708,
            footerDistanceTwips: 708
        )
        let documentXML = OoxmlWriter.documentXML(OoxmlDocument(body: body, section: section))
        let package = DocxPackage.richExport(
            documentXML: documentXML,
            stylesXML: StyleSheetCompiler.richExportStylesXML(),
            settingsXML: StyleSheetCompiler.settingsXML(),
            numberingXML: numberingXML(orderedStarts: orderedStarts),
            headerXML: headerXML(title: payload.title),
            footerXML: footerXML,
            hyperlinks: hyperlinkRelationships
        )
        return try package.render()
    }

    private static func paragraph(
        _ content: [RichExportDocument.Inline],
        style: String,
        props: ParaProps = ParaProps(),
        hyperlinkIDs: [String: String],
        sourceAnchors: [String: SourceAnchor]
    ) -> OoxmlParagraph {
        OoxmlParagraph(
            style: style,
            props: props,
            runs: runs(content, hyperlinkIDs: hyperlinkIDs, sourceAnchors: sourceAnchors)
        )
    }

    private static func runs(
        _ content: [RichExportDocument.Inline],
        hyperlinkIDs: [String: String],
        sourceAnchors: [String: SourceAnchor]
    ) -> [OoxmlRun] {
        content.map { inline in
            switch inline {
            case let .text(value):
                .text(value)
            case let .emphasis(value):
                .text(value, props: RunProps(italic: true))
            case let .strong(value):
                .text(value, props: RunProps(bold: true))
            case let .code(value):
                .text(value, props: RunProps(fontHalfPoints: 20, fontName: "Menlo"))
            case let .citation(label):
                if let anchor = sourceAnchors[label] {
                    .internalHyperlink(
                        "[\(label)]",
                        anchor: anchor.name,
                        props: RunProps(bold: true, underline: true, colorHex: "2E74B5")
                    )
                } else {
                    .text("[\(label)]", props: RunProps(bold: true))
                }
            case let .link(label, destination):
                if let relationshipID = hyperlinkIDs[destination] {
                    .externalHyperlink(
                        label,
                        relationshipID: relationshipID,
                        props: RunProps(underline: true, colorHex: "2E74B5")
                    )
                } else {
                    .text("\(label) (\(destination))", props: RunProps(underline: true, colorHex: "2E74B5"))
                }
            }
        }
    }

    private static func ooxmlTable(
        _ table: RichExportDocument.Table,
        hyperlinkIDs: [String: String],
        sourceAnchors: [String: SourceAnchor]
    ) -> OoxmlTable {
        let columnCount = max(table.headers.count, 1)
        let width = 9_360
        let columnWidth = width / columnCount
        let grid = Array(repeating: columnWidth, count: columnCount)
        let border = Border(val: "single", size: 4, space: 0, color: "B7B7B7")
        let borders = Borders(top: border, left: border, bottom: border, right: border, insideH: border, insideV: border)
        var rows: [[OoxmlCell]] = [
            table.headers.enumerated().map { index, content in
                return OoxmlCell(
                    widthTwips: columnWidth,
                    borders: borders,
                    content: [paragraph(
                        content,
                        style: "ExportTableHeader",
                        props: ParaProps(jc: alignment(table.alignments[safe: index] ?? .leading)),
                        hyperlinkIDs: hyperlinkIDs,
                        sourceAnchors: sourceAnchors
                    )],
                    shadingFill: "F2F4F7",
                    verticalAlignment: "center"
                )
            },
        ]
        rows.append(contentsOf: table.rows.map { row in
            row.enumerated().map { index, content in
                OoxmlCell(
                    widthTwips: columnWidth,
                    borders: borders,
                    content: [paragraph(
                        content,
                        style: "ExportTableBody",
                        props: ParaProps(jc: alignment(table.alignments[safe: index] ?? .leading)),
                        hyperlinkIDs: hyperlinkIDs,
                        sourceAnchors: sourceAnchors
                    )],
                    verticalAlignment: "center"
                )
            }
        })
        return OoxmlTable(
            widthTwips: width,
            borders: borders,
            grid: grid,
            rows: rows,
            cellMarginTwips: 120,
            indentTwips: 120,
            cellMarginTopTwips: 80,
            cellMarginBottomTwips: 80
        )
    }

    private static func sourceTable(
        _ sources: [RichExportDocument.Source],
        sourceAnchors: [String: SourceAnchor]
    ) -> OoxmlTable {
        let widths = [1_700, 1_700, 1_100, 1_700, 3_160]
        let headers = ["Relationship ID", "Document", "Locator", "Warnings", "Excerpt"]
        let border = Border(val: "single", size: 4, space: 0, color: "B7B7B7")
        let borders = Borders(top: border, left: border, bottom: border, right: border, insideH: border, insideV: border)
        var rows: [[OoxmlCell]] = [
            zip(headers, widths).map { label, width in
                OoxmlCell(
                    widthTwips: width,
                    borders: borders,
                    content: [OoxmlParagraph(
                        style: "ExportTableHeader",
                        runs: [.text(label)]
                    )],
                    shadingFill: "F2F4F7",
                    verticalAlignment: "center"
                )
            },
        ]
        rows.append(contentsOf: sources.enumerated().map { sourceIndex, source in
            let values = [source.label, source.documentName, source.locator, source.warnings, source.excerpt]
            return zip(values.indices, zip(values, widths)).map { valueIndex, pair in
                let (value, width) = pair
                var runs: [OoxmlRun] = [.text(value)]
                if valueIndex == 0,
                   let anchor = sourceAnchors[source.label],
                   anchor.bookmarkID == sourceIndex + 1 {
                    runs = [
                        .bookmarkStart(id: anchor.bookmarkID, name: anchor.name),
                        .text(value),
                        .bookmarkEnd(id: anchor.bookmarkID),
                    ]
                }
                return OoxmlCell(
                    widthTwips: width,
                    borders: borders,
                    content: [OoxmlParagraph(style: "SourceBody", runs: runs)],
                    verticalAlignment: "center"
                )
            }
        })
        return OoxmlTable(
            widthTwips: widths.reduce(0, +),
            borders: borders,
            grid: widths,
            rows: rows,
            cellMarginTwips: 120,
            indentTwips: 120,
            cellMarginTopTwips: 80,
            cellMarginBottomTwips: 80
        )
    }

    private static func alignment(_ value: RichExportDocument.TableAlignment) -> Jc {
        switch value {
        case .leading: .left
        case .center: .center
        case .trailing: .right
        }
    }

    private static func externalHyperlinkRelationships(
        in document: RichExportDocument
    ) -> [DocxHyperlinkRelationship] {
        var destinations: [String] = []
        var seen: Set<String> = []

        func collect(_ content: [RichExportDocument.Inline]) {
            for case let .link(_, destination) in content
                where isSafeExternalHyperlink(destination) && seen.insert(destination).inserted {
                destinations.append(destination)
            }
        }

        for block in document.blocks {
            switch block {
            case let .title(content),
                 let .reviewBanner(content),
                 let .heading(_, content),
                 let .paragraph(content),
                 let .blockQuote(content):
                collect(content)
            case let .unorderedList(items), let .orderedList(_, items):
                items.forEach(collect)
            case let .table(table):
                table.headers.forEach(collect)
                table.rows.flatMap { $0 }.forEach(collect)
            case .sourceAppendix:
                break
            }
        }

        return destinations.enumerated().map { offset, destination in
            DocxHyperlinkRelationship(id: "rIdHyperlink\(offset + 1)", target: destination)
        }
    }

    private static func isSafeExternalHyperlink(_ destination: String) -> Bool {
        guard let scheme = URLComponents(string: destination)?.scheme?.lowercased() else {
            return false
        }
        return ["http", "https", "mailto"].contains(scheme)
    }

    private static func makeSourceAnchors(
        _ document: RichExportDocument
    ) -> [String: SourceAnchor] {
        var anchors: [String: SourceAnchor] = [:]
        var usedNames: Set<String> = []
        for block in document.blocks {
            guard case let .sourceAppendix(sources) = block else { continue }
            for (index, source) in sources.enumerated() where anchors[source.label] == nil {
                let base = sourceAnchorBase(source.label)
                var name = base
                var suffix = 2
                while !usedNames.insert(name).inserted {
                    let suffixText = "_\(suffix)"
                    name = String(base.prefix(max(1, 40 - suffixText.count))) + suffixText
                    suffix += 1
                }
                anchors[source.label] = SourceAnchor(name: name, bookmarkID: index + 1)
            }
        }
        return anchors
    }

    private static func sourceAnchorBase(_ label: String) -> String {
        let ascii = label.unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 95:
                Character(String(scalar))
            default:
                "_"
            }
        }
        let suffix = String(ascii).isEmpty ? "source" : String(ascii)
        return String("_supra_\(suffix)".prefix(40))
    }

    private static func headerXML(title: String) -> String {
        let titleRun = OoxmlWriter.runXML(.text(
            title,
            props: RunProps(fontHalfPoints: 18, fontName: "Calibri", colorHex: "666666")
        ))
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p><w:pPr><w:jc w:val="right"/></w:pPr>\(titleRun)</w:p></w:hdr>
        """
    }

    private static let footerXML: String = {
        let runs = [
            OoxmlRun.text("Page ", props: RunProps(fontHalfPoints: 18, fontName: "Calibri", colorHex: "666666")),
            OoxmlRun(.fieldChar(.begin)),
            OoxmlRun(.instrText(" PAGE ")),
            OoxmlRun(.fieldChar(.separate)),
            OoxmlRun.text("1", props: RunProps(fontHalfPoints: 18, fontName: "Calibri", colorHex: "666666")),
            OoxmlRun(.fieldChar(.end)),
            OoxmlRun.text(" of ", props: RunProps(fontHalfPoints: 18, fontName: "Calibri", colorHex: "666666")),
            OoxmlRun(.fieldChar(.begin)),
            OoxmlRun(.instrText(" NUMPAGES ")),
            OoxmlRun(.fieldChar(.separate)),
            OoxmlRun.text("1", props: RunProps(fontHalfPoints: 18, fontName: "Calibri", colorHex: "666666")),
            OoxmlRun(.fieldChar(.end)),
        ].map(OoxmlWriter.runXML).joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p><w:pPr><w:jc w:val="right"/></w:pPr>\(runs)</w:p></w:ftr>
        """
    }()

    private static func numberingXML(orderedStarts: [Int]) -> String {
        let instances = orderedStarts.enumerated().map { offset, start in
            #"<w:num w:numId="\#(offset + 2)"><w:abstractNumId w:val="1"/><w:lvlOverride w:ilvl="0"><w:startOverride w:val="\#(max(start, 1))"/></w:lvlOverride></w:num>"#
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="singleLevel"/><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="•"/><w:lvlJc w:val="left"/><w:pPr><w:tabs><w:tab w:val="num" w:pos="720"/></w:tabs><w:spacing w:after="160" w:line="280" w:lineRule="auto"/><w:ind w:left="720" w:hanging="360"/></w:pPr><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri"/></w:rPr></w:lvl></w:abstractNum>
          <w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="singleLevel"/><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/><w:lvlJc w:val="left"/><w:pPr><w:tabs><w:tab w:val="num" w:pos="720"/></w:tabs><w:spacing w:after="160" w:line="280" w:lineRule="auto"/><w:ind w:left="720" w:hanging="360"/></w:pPr><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri"/></w:rPr></w:lvl></w:abstractNum>
          <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
          \(instances)
        </w:numbering>
        """
    }

    private static func plainText(_ content: [RichExportDocument.Inline]) -> String {
        content.map { inline in
            switch inline {
            case let .text(value), let .emphasis(value), let .strong(value), let .code(value): value
            case let .citation(label): "[\(label)]"
            case let .link(label, _): label
            }
        }.joined()
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
