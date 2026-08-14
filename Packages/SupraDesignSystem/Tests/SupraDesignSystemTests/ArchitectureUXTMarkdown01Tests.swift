import AppKit
import Foundation
import SwiftUI
@testable import SupraDesignSystem
import XCTest

/// T-MARKDOWN-01
///
/// Expected RED: the citation-aware block renderer and the saved-output line preview are still
/// app-local types. `SupraDesignSystem` has no shared Markdown presentation, parser, or citation
/// linker, so this test must fail to compile on those missing symbols before production moves.
final class ArchitectureUXTMarkdown01Tests: XCTestCase {
    func testParserStreamingTablesAndCitationTapWiresAreExact() throws {
        let blocks = SupraMarkdownParser.parse(MarkdownWire.markdown)
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: MarkdownWire.marker),
            .paragraph("Paragraph **record-713** [S7]."),
            .bulletList(["version 7", "version 8"]),
            .numberedList(["first", "second"]),
            .quote("quoted record-713"),
            .table(
                headers: ["Record", "Version"],
                rows: [["record-713", "7"]],
                aligns: [.leading, .trailing]
            ),
            .codeBlock("let version = 7"),
            .rule,
        ])

        let partial = SupraMarkdownParser.parse("```swift\nlet version = 8")
        XCTAssertEqual(partial, [.codeBlock("let version = 8")])

        let citationText = "\(MarkdownWire.marker) [S7] [S8] /[S7]"
        let linked = SupraMarkdownCitationLinker.linkedText(citationText, labels: ["S7"])
        XCTAssertEqual(
            linked,
            #"T_MARKDOWN_01_WIRE_731 [\[S7\]](supracite://S7) [S8] /[S7]"#
        )
        XCTAssertEqual(
            SupraMarkdownCitationLinker.label(from: try XCTUnwrap(URL(string: "supracite://s7"))),
            "S7"
        )
        XCTAssertNil(
            SupraMarkdownCitationLinker.label(from: try XCTUnwrap(URL(string: "https://example.invalid/S7")))
        )
        var tappedLabels: [String] = []
        XCTAssertTrue(SupraMarkdownCitationLinker.route(
            try XCTUnwrap(URL(string: "supracite://s7")),
            onCitationTap: { tappedLabels.append($0) }
        ))
        XCTAssertEqual(tappedLabels, ["S7"])
        XCTAssertFalse(SupraMarkdownCitationLinker.route(
            try XCTUnwrap(URL(string: "https://example.invalid/S7")),
            onCitationTap: { tappedLabels.append($0) }
        ))
        XCTAssertEqual(tappedLabels, ["S7"])

        let exactPlan = blocks.map(String.init(describing:)).joined(separator: "|")
        XCTAssertTrue(exactPlan.contains(MarkdownWire.marker))
        XCTAssertTrue(exactPlan.contains(MarkdownWire.recordID))
        XCTAssertFalse(exactPlan.contains(MarkdownWire.forbiddenDefault))
    }

    @MainActor
    func testAssistantAndSavedOutputPresentationsRemainPixelEquivalent() throws {
        let assistant = try pixels(
            AnyView(SupraMarkdownView(
                text: MarkdownWire.markdown,
                presentation: .assistantResponse,
                citationLabels: ["S7"],
                onCitationTap: { _ in }
            ))
        )
        let legacyAssistant = try pixels(AnyView(LegacyAssistantReference()))
        XCTAssertEqual(assistant.width, legacyAssistant.width)
        XCTAssertEqual(assistant.height, legacyAssistant.height)
        XCTAssertEqual(assistant.bytes, legacyAssistant.bytes)

        let savedOutput = try pixels(
            AnyView(SupraMarkdownView(
                text: MarkdownWire.markdown,
                presentation: .savedOutput
            ))
        )
        let legacySavedOutput = try pixels(AnyView(LegacySavedOutputReference()))
        XCTAssertEqual(savedOutput.width, legacySavedOutput.width)
        XCTAssertEqual(savedOutput.height, legacySavedOutput.height)
        XCTAssertEqual(savedOutput.bytes, legacySavedOutput.bytes)
    }

    func testBothAppSurfacesUseSharedRendererAndRetainChatAccessibilityContract() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SupraDesignSystemTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // SupraDesignSystem
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository
        let chat = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Apps/SupraAI/SupraAI/GlobalChatsView.swift"),
            encoding: .utf8
        )
        let output = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Apps/SupraAI/SupraAI/Outputs/OutputDetailView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(chat.contains("SupraMarkdownView("))
        XCTAssertTrue(chat.contains("presentation: .assistantResponse"))
        XCTAssertFalse(chat.contains("struct MarkdownView: View"))
        XCTAssertFalse(chat.contains("enum MarkdownParser"))
        XCTAssertTrue(chat.contains(".accessibilityElement(children: .ignore)"))
        XCTAssertTrue(chat.contains(".accessibilityLabel(Text(displayContent))"))

        XCTAssertTrue(output.contains("SupraMarkdownView("))
        XCTAssertTrue(output.contains("presentation: .savedOutput"))
        XCTAssertFalse(output.contains("struct MarkdownPreview: View"))
        XCTAssertFalse((chat + output).contains(MarkdownWire.forbiddenDefault))
    }

    @MainActor
    private func pixels(_ content: AnyView) throws -> PixelSnapshot {
        let renderer = ImageRenderer(content:
            content
                .frame(width: 620, alignment: .leading)
                .padding(12)
                .background(Color.white)
                .environment(\.colorScheme, .light)
        )
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let data = try XCTUnwrap(image.dataProvider?.data)
        return PixelSnapshot(width: image.width, height: image.height, bytes: data as Data)
    }

    private struct PixelSnapshot: Equatable {
        let width: Int
        let height: Int
        let bytes: Data
    }
}

private struct LegacyAssistantReference: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(inline(Wire.marker)).font(.title2.weight(.bold)).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
            Text(inline("Paragraph **record-713** [\\[S7\\]](supracite://S7)."))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                listRow(marker: "•", text: "version 7")
                listRow(marker: "•", text: "version 8")
            }
            VStack(alignment: .leading, spacing: 3) {
                listRow(marker: "1.", text: "first")
                listRow(marker: "2.", text: "second")
            }
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                Text(inline("quoted record-713"))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text(inline("Record")).font(.callout.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                    Text(inline("Version")).font(.callout.weight(.semibold)).frame(maxWidth: .infinity, alignment: .trailing)
                }
                Divider()
                GridRow {
                    Text(inline("record-713")).frame(maxWidth: .infinity, alignment: .leading)
                    Text(inline("7")).frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.15)))
            ScrollView(.horizontal, showsIndicators: false) {
                Text("let version = 7")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            Divider()
        }
    }

    private enum Wire {
        static let marker = "T_MARKDOWN_01_WIRE_731"
    }

    private func listRow(marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker).foregroundStyle(.secondary).monospacedDigit()
            Text(inline(text)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(text)
    }
}

private struct LegacySavedOutputReference: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                lineView(line)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lines: [String] {
        MarkdownWire.markdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    @ViewBuilder
    private func lineView(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("### ") {
            Text(trimmed.dropFirst(4)).font(.subheadline.weight(.semibold))
        } else if trimmed.hasPrefix("## ") {
            Text(trimmed.dropFirst(3)).font(.headline)
        } else if trimmed.hasPrefix("# ") {
            Text(trimmed.dropFirst(2)).font(.title3.weight(.bold))
        } else if trimmed.isEmpty {
            Color.clear.frame(height: 2)
        } else {
            Text(inline(line)).font(.callout).textSelection(.enabled)
        }
    }

    private func inline(_ line: String) -> AttributedString {
        (try? AttributedString(
            markdown: line,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(line)
    }
}

private enum MarkdownWire {
    static let marker = "T_MARKDOWN_01_WIRE_731"
    static let recordID = "record-713"
    static let forbiddenDefault = "DEFAULT-000"

    static let markdown = """
    # T_MARKDOWN_01_WIRE_731

    Paragraph **record-713** [S7].

    - version 7
    - version 8

    1. first
    2. second

    > quoted record-713

    | Record | Version |
    |:---|---:|
    | record-713 | 7 |

    ```swift
    let version = 7
    ```

    ---
    """
}
