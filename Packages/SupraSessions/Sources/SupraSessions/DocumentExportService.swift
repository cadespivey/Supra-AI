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
    private let completionRecorder: CompletionRecorder?

    public init(
        store: SupraStore,
        storage: DocumentStorage = .makeDefault(),
        fileWriter: DurableFileWriter = DurableFileWriter(),
        completionRecorder: CompletionRecorder? = nil
    ) {
        self.store = store
        self.storage = storage
        self.fileWriter = fileWriter
        self.completionRecorder = completionRecorder
    }

    public enum ExportError: Error, LocalizedError {
        case outputNotFound
        case noActiveVersion
        case selectedVersionUnavailable
        case assuranceBlocked(String)
        case completionRecordingFailed(String)
        case partialFailure(recording: String, compensation: String)
        case publicationRecoveryRequired(String)
        case filenameAllocationFailed

        public var errorDescription: String? {
            switch self {
            case .outputNotFound: "The output to export was not found."
            case .noActiveVersion: "The output has no active version to export."
            case .selectedVersionUnavailable: "The selected output version is unavailable."
            case let .assuranceBlocked(state):
                "The output cannot be exported while its assurance state is \(state)."
            case let .completionRecordingFailed(detail):
                "The export was not recorded and the file change was rolled back: \(detail)"
            case let .partialFailure(recording, compensation):
                "The export file was installed, but recording failed (\(recording)) and rollback also failed (\(compensation))."
            case let .publicationRecoveryRequired(detail):
                "The export reached an uncertain publication state and requires recovery: \(detail)"
            case .filenameAllocationFailed:
                "A unique export filename could not be allocated."
            }
        }
    }

    private static let reviewWarning = "Machine-generated from your local documents. Verify every citation against the source before relying on or sharing this."

    @discardableResult
    public func export(
        matterID: String,
        structuredOutputID: String,
        structuredOutputVersionID: String? = nil,
        format: DocumentExportFormat
    ) throws -> URL {
        guard let output = try store.structuredOutputs.fetchOutputs(matterID: matterID).first(where: { $0.id == structuredOutputID }) else {
            throw ExportError.outputNotFound
        }
        let versions = try store.structuredOutputs.fetchVersions(structuredOutputID: structuredOutputID)
        guard let requestedVersionID = structuredOutputVersionID ?? output.activeVersionID else {
            throw ExportError.noActiveVersion
        }
        guard let selectedVersion = versions.first(where: { $0.id == requestedVersionID }) else {
            throw ExportError.selectedVersionUnavailable
        }
        let verificationStatus = OutputVerificationStatus(rawValue: selectedVersion.verificationStatus)
            ?? .legacyUnverified
        let assurance = OutputAssurancePresentation.state(
            rawValue: selectedVersion.assuranceState,
            verificationStatus: verificationStatus
        )
        guard verificationStatus == .allSupported,
              OutputAssurancePresentation.isExportEligible(assurance) else {
            throw ExportError.assuranceBlocked(OutputAssurancePresentation.text(for: assurance))
        }
        if output.outputType == StructuredOutputType.documentExhaustiveList.rawValue {
            guard let rawAssurance = selectedVersion.assuranceState,
                  let exactAssurance = OutputAssuranceState(rawValue: rawAssurance),
                  let proofRun = try store.corpusAnalysis.fetchExactExportRun(
                      matterID: matterID,
                      structuredOutputVersionID: selectedVersion.id
                  ),
                  proofRun.assuranceState == exactAssurance.rawValue else {
                throw ExportError.assuranceBlocked(
                    "Exhaustive output is not linked to one matching persisted exact corpus proof."
                )
            }
        }

        let payload = try makePayload(output: output, version: selectedVersion, matterID: matterID)
        let rendered = try DocumentExportBuilder.renderValidatedData(payload, format: format)
        let directory = storage.exportsDirectory(forMatterID: matterID)
        let sanitizedTitle = sanitize(output.title)
        let stem = sanitizedTitle.isEmpty ? "Export" : sanitizedTitle

        for _ in 1...100 {
            try Task.checkCancellation()
            let intentID = UUID().uuidString.lowercased()
            let fileName = "\(stem)-v\(selectedVersion.versionIndex)-\(intentID).\(format.fileExtension)"
            let url = directory.appendingPathComponent(fileName, isDirectory: false)
            let intent: DraftArtifactIntentRecord
            do {
                intent = try store.draftArtifacts.prepareStructuredOutputExportIntent(
                    matterID: matterID,
                    structuredOutputID: structuredOutputID,
                    structuredOutputVersionID: selectedVersion.id,
                    workProductVersion: selectedVersion.versionIndex,
                    format: Self.intentFormat(format),
                    fileName: fileName,
                    output: rendered,
                    id: intentID
                )
            } catch DraftArtifactIntentError.fileNameReserved {
                continue
            }

            let installedIdentity: DurableFileWriter.InstalledFileIdentity
            do {
                installedIdentity = try fileWriter.writeNewOwned(
                    rendered,
                    to: url,
                    containedIn: storage.root
                ) { candidate in
                    guard candidate == rendered else {
                        throw DraftArtifactIntentError.installedArtifactMismatch
                    }
                    try DocumentExportValidator.validate(candidate, as: format)
                }
            } catch DurableFileWriter.WriterError.destinationExists {
                try? store.draftArtifacts.abortIntent(id: intent.id)
                continue
            } catch let DurableFileWriter.WriterError.createOnlyRollbackSynchronizationFailed(detail) {
                try? store.draftArtifacts.markRecoveryRequired(id: intent.id)
                throw ExportError.publicationRecoveryRequired(detail)
            } catch let DurableFileWriter.WriterError.postInstallStateUncertain(detail) {
                try? store.draftArtifacts.markRecoveryRequired(id: intent.id)
                throw ExportError.publicationRecoveryRequired(detail)
            } catch let DurableFileWriter.WriterError.managedTemporaryCleanupUncertain(name, detail) {
                try? store.draftArtifacts.markRecoveryRequired(id: intent.id)
                throw ExportError.publicationRecoveryRequired("\(name): \(detail)")
            } catch {
                try? store.draftArtifacts.abortIntent(id: intent.id)
                throw error
            }

            do {
                let exportRecord = try store.draftArtifacts.structuredOutputExportPreview(
                    intentID: intent.id
                )
                let auditEvent = try store.draftArtifacts.auditEventPreview(intentID: intent.id)
                if let completionRecorder {
                    try completionRecorder(exportRecord, auditEvent)
                }
                let installed = try fileWriter.durablyValidatedInstalledFileData(
                    matching: installedIdentity,
                    at: url,
                    containedIn: storage.root,
                    expectedByteCount: intent.outputByteSize
                ) { candidate in
                    guard candidate.count == intent.outputByteSize,
                          DocumentStorage.sha256Hex(of: candidate) == intent.outputSHA256 else {
                        throw DraftArtifactIntentError.installedArtifactMismatch
                    }
                    try DocumentExportValidator.validate(candidate, as: format)
                }
                if completionRecorder == nil {
                    try store.draftArtifacts.finalizeIntent(
                        id: intent.id,
                        installedOutput: installed
                    )
                }
                _ = try store.draftArtifacts.verifyCompletedStructuredOutputExportIntent(
                    id: intent.id,
                    installedOutput: installed
                )
            } catch {
                let recordingDescription = error.localizedDescription
                do {
                    try removeInstalledExport(
                        at: url,
                        format: format,
                        expectedIdentity: installedIdentity,
                        intent: intent
                    )
                    try store.draftArtifacts.abortIntent(id: intent.id)
                } catch {
                    try? store.draftArtifacts.markRecoveryRequired(id: intent.id)
                    throw ExportError.partialFailure(
                        recording: recordingDescription,
                        compensation: error.localizedDescription
                    )
                }
                throw ExportError.completionRecordingFailed(recordingDescription)
            }
            return url
        }
        throw ExportError.filenameAllocationFailed
    }

    private func removeInstalledExport(
        at url: URL,
        format: DocumentExportFormat,
        expectedIdentity: DurableFileWriter.InstalledFileIdentity,
        intent: DraftArtifactIntentRecord
    ) throws {
        let removed = try fileWriter.removeInstalledFile(
            matching: expectedIdentity,
            at: url,
            containedIn: storage.root,
            expectedByteCount: intent.outputByteSize,
            missingIsSuccess: true,
            contentValidator: { candidate in
                guard DocumentStorage.sha256Hex(of: candidate) == intent.outputSHA256 else {
                    throw DraftArtifactIntentError.installedArtifactMismatch
                }
                try DocumentExportValidator.validate(candidate, as: format)
            }
        )
        guard removed else { throw DraftArtifactIntentError.installedArtifactMismatch }
    }

    private static func intentFormat(_ format: DocumentExportFormat) -> DraftArtifactIntentFormat {
        switch format {
        case .pdf: .pdf
        case .markdown: .markdown
        case .docx: .docx
        case .csv: .csv
        case .xlsx: .xlsx
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
        let verificationStatus = OutputVerificationStatus(rawValue: version.verificationStatus)
            ?? .legacyUnverified
        let assurance = OutputAssurancePresentation.state(
            rawValue: version.assuranceState,
            verificationStatus: verificationStatus
        )
        return DocumentExportPayload(
            title: output.title,
            // The saved version markdown already embeds a "## Sources" appendix
            // (generated alongside the answer). The export builder renders the
            // appendix from the structured `sources` rows, so strip the embedded
            // one to avoid duplicating it in Markdown/PDF/DOCX.
            contentMarkdown: rows.isEmpty ? version.contentMarkdown : Self.stripEmbeddedAppendix(version.contentMarkdown),
            reviewWarning: "Assurance: \(OutputAssurancePresentation.text(for: assurance))\n\n\(Self.reviewWarning)",
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
