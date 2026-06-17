import Foundation
import SupraCore
import SupraDocuments
import SupraStore

/// Exports a saved generated output (Q&A or chronology) to PDF/Markdown/DOCX/
/// CSV/XLSX with inline citations + a source appendix + a review warning, into
/// app-managed storage, and records the export (plan §10). No raw imported
/// documents are embedded.
public final class DocumentExportService: @unchecked Sendable {
    private let store: SupraStore
    private let storage: DocumentStorage

    public init(store: SupraStore, storage: DocumentStorage = .makeDefault()) {
        self.store = store
        self.storage = storage
    }

    public enum ExportError: Error, LocalizedError {
        case outputNotFound
        case noActiveVersion

        public var errorDescription: String? {
            switch self {
            case .outputNotFound: "The output to export was not found."
            case .noActiveVersion: "The output has no active version to export."
            }
        }
    }

    private static let reviewWarning = "Machine-generated from your local documents. Verify every citation against the source before relying on or sharing this."

    @discardableResult
    public func export(matterID: String, structuredOutputID: String, format: DocumentExportFormat) throws -> URL {
        guard let output = try store.structuredOutputs.fetchOutputs(matterID: matterID).first(where: { $0.id == structuredOutputID }) else {
            throw ExportError.outputNotFound
        }
        let versions = try store.structuredOutputs.fetchVersions(structuredOutputID: structuredOutputID)
        guard let activeVersion = versions.first(where: { $0.id == output.activeVersionID }) ?? versions.first else {
            throw ExportError.noActiveVersion
        }

        let payload = try makePayload(output: output, version: activeVersion, matterID: matterID)
        let directory = storage.exportsDirectory(forMatterID: matterID)
        let fileName = "\(sanitize(output.title))-v\(activeVersion.versionIndex).\(format.fileExtension)"
        let url = directory.appendingPathComponent(fileName)
        try DocumentExportBuilder.write(payload, format: format, to: url)

        let relativePath = "exports/\(matterID)/\(fileName)"
        _ = try store.documentSources.recordExport(
            DocumentExportRecord(
                structuredOutputID: structuredOutputID,
                structuredOutputVersionID: activeVersion.id,
                matterID: matterID,
                format: format.rawValue,
                managedRelativePath: relativePath
            )
        )
        _ = try? store.auditEvents.recordEvent(
            matterID: matterID, eventType: "export_completed", actor: "user",
            summary: "Exported \(output.title) as \(format.rawValue)",
            relatedTable: "structured_outputs", relatedID: structuredOutputID
        )
        return url
    }

    private func makePayload(output: StructuredOutputRecord, version: StructuredOutputVersionRecord, matterID: String) throws -> DocumentExportPayload {
        let sourceRows = try store.documentSources.fetchSources(structuredOutputVersionID: version.id)
        let nameByID = Dictionary((try? store.documentLibrary.fetchDocuments(matterID: matterID))?.map { ($0.id, $0.displayName) } ?? [], uniquingKeysWith: { a, _ in a })
        let rows: [DocumentExportPayload.SourceRow] = sourceRows.map { source in
            let locator = (try? JSONDecoder().decode(DocumentSourceLocator.self, from: Data(source.locatorJSON.utf8)))
            let warnings = (source.warningsJSON.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) }) ?? []
            return DocumentExportPayload.SourceRow(
                label: source.citationLabel,
                documentName: source.documentID.flatMap { nameByID[$0] } ?? "Document",
                locator: locator?.displayString ?? "",
                excerpt: source.excerpt,
                warnings: warnings.joined(separator: "; ")
            )
        }
        return DocumentExportPayload(
            title: output.title,
            contentMarkdown: version.contentMarkdown,
            reviewWarning: Self.reviewWarning,
            sources: rows
        )
    }

    private func sanitize(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = String(title.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return cleaned.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-").prefix(60).description
    }
}
