import Foundation
import SupraCore
import SupraDocuments
import SupraStore

/// Exports a saved generated output (Q&A or chronology) to PDF/Markdown/DOCX/
/// CSV/XLSX with inline citations + a source appendix + a review warning, into
/// app-managed storage, and records the export (plan §10). No raw imported
/// documents are embedded.
public final class DocumentExportService: @unchecked Sendable {
    public typealias CompletionRecorder = (DocumentExportRecord, AuditEventRecord) throws -> Void

    private let store: SupraStore
    private let storage: DocumentStorage
    private let fileWriter: DurableFileWriter
    private let completionRecorder: CompletionRecorder

    public init(
        store: SupraStore,
        storage: DocumentStorage = .makeDefault(),
        fileWriter: DurableFileWriter = DurableFileWriter(),
        completionRecorder: CompletionRecorder? = nil
    ) {
        self.store = store
        self.storage = storage
        self.fileWriter = fileWriter
        self.completionRecorder = completionRecorder ?? { export, auditEvent in
            try store.documentSources.recordExportCompletion(export, auditEvent: auditEvent)
        }
    }

    public enum ExportError: Error, LocalizedError {
        case outputNotFound
        case noActiveVersion
        case completionRecordingFailed(String)
        case partialFailure(recording: String, compensation: String)

        public var errorDescription: String? {
            switch self {
            case .outputNotFound: "The output to export was not found."
            case .noActiveVersion: "The output has no active version to export."
            case let .completionRecordingFailed(detail):
                "The export was not recorded and the file change was rolled back: \(detail)"
            case let .partialFailure(recording, compensation):
                "The export file was installed, but recording failed (\(recording)) and rollback also failed (\(compensation))."
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
        let previousData = try snapshotExistingFile(at: url)
        try DocumentExportBuilder.write(payload, format: format, to: url, writer: fileWriter)

        let relativePath = "exports/\(matterID)/\(fileName)"
        let exportRecord = DocumentExportRecord(
            structuredOutputID: structuredOutputID,
            structuredOutputVersionID: activeVersion.id,
            matterID: matterID,
            format: format.rawValue,
            managedRelativePath: relativePath
        )
        let auditEvent = AuditEventRecord(
            matterID: matterID,
            eventType: "export_completed",
            actor: "user",
            summary: "Exported \(output.title) as \(format.rawValue)",
            relatedTable: "structured_outputs",
            relatedID: structuredOutputID
        )
        do {
            try completionRecorder(exportRecord, auditEvent)
        } catch {
            let recordingDescription = error.localizedDescription
            do {
                try compensateFile(at: url, previousData: previousData)
            } catch {
                throw ExportError.partialFailure(
                    recording: recordingDescription,
                    compensation: error.localizedDescription
                )
            }
            throw ExportError.completionRecordingFailed(recordingDescription)
        }
        return url
    }

    /// `nil` means the path did not exist; non-nil data is an exact rollback
    /// snapshot. An unreadable existing artifact fails before rendering.
    private func snapshotExistingFile(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    private func compensateFile(at url: URL, previousData: Data?) throws {
        if let previousData {
            // The snapshot is restored exactly, even if it predates current
            // validators. It was the caller's preexisting artifact.
            try fileWriter.write(previousData, to: url) { _ in }
        } else if FileManager.default.fileExists(atPath: url.path) {
            // The snapshot proved this destination was absent before export;
            // remove only the newly installed, unrecorded artifact.
            try FileManager.default.removeItem(at: url)
        }
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
            // The saved version markdown already embeds a "## Sources" appendix
            // (generated alongside the answer). The export builder renders the
            // appendix from the structured `sources` rows, so strip the embedded
            // one to avoid duplicating it in Markdown/PDF/DOCX.
            contentMarkdown: rows.isEmpty ? version.contentMarkdown : Self.stripEmbeddedAppendix(version.contentMarkdown),
            reviewWarning: Self.reviewWarning,
            sources: rows
        )
    }

    private static func stripEmbeddedAppendix(_ markdown: String) -> String {
        guard let range = markdown.range(of: "\n## Sources", options: .backwards) else { return markdown }
        return String(markdown[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sanitize(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = String(title.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return cleaned.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-").prefix(60).description
    }
}
