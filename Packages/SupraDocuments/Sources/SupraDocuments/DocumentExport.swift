import Foundation
import SupraCore

public enum DocumentExportFormat: String, Sendable, CaseIterable, Codable {
    case pdf
    case markdown
    case docx
    case csv
    case xlsx

    public var fileExtension: String { self == .markdown ? "md" : rawValue }
}

/// The data needed to export a generated output with its citations + source
/// appendix (plan §10.3). Carries no raw imported documents.
public struct DocumentExportPayload: Sendable, Equatable {
    public struct SourceRow: Sendable, Equatable {
        public var label: String
        public var documentName: String
        public var locator: String
        public var excerpt: String
        public var warnings: String

        public init(label: String, documentName: String, locator: String, excerpt: String, warnings: String = "") {
            self.label = label
            self.documentName = documentName
            self.locator = locator
            self.excerpt = excerpt
            self.warnings = warnings
        }
    }

    public var title: String
    public var contentMarkdown: String
    public var reviewWarning: String
    public var sources: [SourceRow]

    public init(title: String, contentMarkdown: String, reviewWarning: String, sources: [SourceRow]) {
        self.title = title
        self.contentMarkdown = contentMarkdown
        self.reviewWarning = reviewWarning
        self.sources = sources
    }

    /// Plain text rendering used for PDF/DOCX (output + warning + appendix).
    var plainText: String {
        var lines = [title, "", reviewWarning, "", contentMarkdown]
        if !sources.isEmpty {
            lines.append("")
            lines.append("Sources")
            for source in sources {
                var line = "[\(source.label)] \(source.documentName) — \(source.locator)"
                if !source.warnings.isEmpty { line += " (\(source.warnings))" }
                lines.append(line)
                if !source.excerpt.isEmpty { lines.append("    \(source.excerpt)") }
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Writes a generated output to disk in the requested format with inline
/// citations + a source appendix + a review warning. No raw imported documents
/// are embedded (plan §10.3).
public enum DocumentExportBuilder {
    public enum FaultStage: String, Sendable {
        case beforeRender
        case beforeValidation
    }

    public typealias FaultInjector = (FaultStage) throws -> Void

    /// Renders and validates the complete immutable payload without creating a
    /// filesystem entry. Publication coordinators use this to bind a Store-owned
    /// intent to the exact bytes before a create-only public install.
    public static func renderValidatedData(
        _ payload: DocumentExportPayload,
        format: DocumentExportFormat,
        faultInjector: FaultInjector = { _ in }
    ) throws -> Data {
        try Task.checkCancellation()
        try faultInjector(.beforeRender)
        try Task.checkCancellation()
        let data = try render(payload, format: format)
        try Task.checkCancellation()
        try faultInjector(.beforeValidation)
        try DocumentExportValidator.validate(data, as: format)
        return data
    }

    public static func write(
        _ payload: DocumentExportPayload,
        format: DocumentExportFormat,
        to url: URL,
        writer: DurableFileWriter = DurableFileWriter(),
        faultInjector: FaultInjector = { _ in }
    ) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Task.checkCancellation()
        try faultInjector(.beforeRender)
        try Task.checkCancellation()
        let data = try render(payload, format: format)
        try Task.checkCancellation()
        try writer.write(data, to: url) { temporaryURL in
            try faultInjector(.beforeValidation)
            try DocumentExportValidator.validate(temporaryURL, as: format)
        }
    }

    private static func render(_ payload: DocumentExportPayload, format: DocumentExportFormat) throws -> Data {
        switch format {
        case .markdown:
            return renderMarkdown(payload)
        case .csv:
            return renderCSV(payload)
        case .pdf:
            return try renderPDF(payload)
        case .docx:
            return try renderDOCX(payload)
        case .xlsx:
            return try renderXLSX(payload)
        }
    }

    // MARK: - Markdown

    private static func renderMarkdown(_ payload: DocumentExportPayload) -> Data {
        var text = "# \(payload.title)\n\n> \(payload.reviewWarning)\n\n\(payload.contentMarkdown)\n"
        if !payload.sources.isEmpty {
            text += "\n## Sources\n"
            for source in payload.sources {
                text += "- **[\(source.label)]** \(source.documentName) — \(source.locator)"
                text += source.warnings.isEmpty ? "\n" : " ⚠️ \(source.warnings)\n"
                if !source.excerpt.isEmpty { text += "  > \(source.excerpt)\n" }
            }
        }
        return Data(text.utf8)
    }

    // MARK: - CSV (source appendix table)

    private static func renderCSV(_ payload: DocumentExportPayload) -> Data {
        var rows = ["Label,Document,Locator,Warnings,Excerpt"]
        for source in payload.sources {
            rows.append([source.label, source.documentName, source.locator, source.warnings, source.excerpt].map(csvField).joined(separator: ","))
        }
        return Data(rows.joined(separator: "\n").utf8)
    }

    private static func csvField(_ value: String) -> String {
        let safe = CSVCellSanitizer.neutralize(value)
        return "\"\(safe.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    // MARK: - Rich renderers

    private static func renderPDF(_ payload: DocumentExportPayload) throws -> Data {
        try RichPDFExportRenderer.render(payload)
    }

    private static func renderDOCX(_ payload: DocumentExportPayload) throws -> Data {
        try RichDOCXExportRenderer.render(payload)
    }

    private static func renderXLSX(_ payload: DocumentExportPayload) throws -> Data {
        try RichXLSXExportRenderer.render(payload)
    }
}
