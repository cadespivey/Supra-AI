import Foundation
import SupraCore
import SupraDocuments
import SupraStore

/// Produces an immutable, matter-scoped CSV snapshot of one Review Project.
/// The Store owns the atomic snapshot and completion checks; this service owns
/// deterministic serialization and durable file installation.
public final class CaseFileReviewExportService: @unchecked Sendable {
    public struct Completion: Sendable, Equatable {
        public let exportID: String
        public let matterID: String
        public let projectID: String
        public let managedRelativePath: String
        public let artifactSHA256: String
        public let snapshotProjectUpdatedAt: Date
        public let rowCount: Int
        public let actor: String
        public let exportedAt: Date

        public init(
            exportID: String,
            matterID: String,
            projectID: String,
            managedRelativePath: String,
            artifactSHA256: String,
            snapshotProjectUpdatedAt: Date,
            rowCount: Int,
            actor: String,
            exportedAt: Date
        ) {
            self.exportID = exportID
            self.matterID = matterID
            self.projectID = projectID
            self.managedRelativePath = managedRelativePath
            self.artifactSHA256 = artifactSHA256
            self.snapshotProjectUpdatedAt = snapshotProjectUpdatedAt
            self.rowCount = rowCount
            self.actor = actor
            self.exportedAt = exportedAt
        }
    }

    public typealias CompletionRecorder = (Completion) throws -> Void

    public enum ExportError: Error, LocalizedError, Equatable {
        case invalidGeneratedValues(String)
        case corruptSnapshot(String)
        case completionRecordingFailed(String)
        case partialFailure(recording: String, compensation: String)

        public var errorDescription: String? {
            switch self {
            case let .invalidGeneratedValues(cellID):
                "Review cell \(cellID) contains an unreadable generated-value snapshot."
            case let .corruptSnapshot(projectID):
                "Review Project \(projectID) contains an inconsistent snapshot."
            case let .completionRecordingFailed(detail):
                "The Review snapshot was not recorded and the prior file state was restored: \(detail)"
            case let .partialFailure(recording, compensation):
                "The Review snapshot file was installed, but recording failed (\(recording)) and rollback also failed (\(compensation))."
            }
        }
    }

    private enum PublicationError: Error {
        case installedArtifactChanged
        case installedArtifactNotRemoved
    }

    private static let header = [
        "Row",
        "Finding",
        "Generated value",
        "Attorney value",
        "Current value",
        "Value state",
        "Review state",
        "Reviewed by",
        "Reviewed at (UTC)",
        "Support state",
        "Supporting source count",
        "Supporting sources",
        "Contrary source count",
        "Contrary sources",
        "Project",
        "Project status",
        "Project stale reason",
        "Matrix version",
        "Project ID",
        "Cell ID",
        "Source run ID",
        "Source output ID",
        "Source output version ID",
        "Project updated at (UTC)",
        "Exported at (UTC)",
    ]

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
        self.completionRecorder = completionRecorder ?? { completion in
            try store.caseFileReviews.recordSnapshotExportCompletion(
                matterID: completion.matterID,
                projectID: completion.projectID,
                exportID: completion.exportID,
                managedRelativePath: completion.managedRelativePath,
                artifactSHA256: completion.artifactSHA256,
                snapshotUpdatedAt: completion.snapshotProjectUpdatedAt,
                rowCount: completion.rowCount,
                actor: completion.actor,
                at: completion.exportedAt
            )
        }
    }

    @discardableResult
    public func exportCSV(
        matterID: String,
        projectID: String,
        actor: String,
        at exportedAt: Date = Date()
    ) throws -> URL {
        let snapshot = try store.caseFileReviews.fetchSnapshot(
            matterID: matterID,
            projectID: projectID
        )
        let data = try render(snapshot: snapshot, exportedAt: exportedAt)
        let baseFileName = "\(Self.safeFileStem(snapshot.project.title))-snapshot-v\(snapshot.table.versionIndex)-\(Self.filenameStamp(exportedAt)).csv"
        let directory = storage.exportsDirectory(forMatterID: matterID)
        let exportID = UUID().uuidString
        let collisionFileName = "\(String(baseFileName.dropLast(4)))-\(exportID.lowercased()).csv"
        var publication: (
            url: URL,
            fileName: String,
            identity: DurableFileWriter.InstalledFileIdentity
        )?
        for candidateFileName in [baseFileName, collisionFileName] {
            let candidate = directory.appendingPathComponent(
                candidateFileName,
                isDirectory: false
            )
            do {
                let identity = try fileWriter.writeNewOwned(
                    data,
                    to: candidate,
                    containedIn: storage.root
                ) { installedData in
                    try DocumentExportValidator.validate(installedData, as: .csv)
                }
                publication = (candidate, candidateFileName, identity)
                break
            } catch let error as DurableFileWriter.WriterError
                where error == .destinationExists && candidateFileName == baseFileName
            {
                continue
            }
        }
        guard let publication else {
            throw DurableFileWriter.WriterError.destinationExists
        }

        let completion = Completion(
            exportID: exportID,
            matterID: matterID,
            projectID: projectID,
            managedRelativePath: "exports/\(matterID)/\(publication.fileName)",
            artifactSHA256: DocumentStorage.sha256Hex(of: data),
            snapshotProjectUpdatedAt: snapshot.project.updatedAt,
            rowCount: snapshot.rows.count,
            actor: actor,
            exportedAt: exportedAt
        )
        do {
            try completionRecorder(completion)
        } catch {
            let recordingDescription = error.localizedDescription
            do {
                try compensateFile(
                    at: publication.url,
                    identity: publication.identity,
                    expectedData: data
                )
            } catch {
                throw ExportError.partialFailure(
                    recording: recordingDescription,
                    compensation: error.localizedDescription
                )
            }
            throw ExportError.completionRecordingFailed(recordingDescription)
        }
        return publication.url
    }

    private func render(
        snapshot: CaseFileReviewSnapshot,
        exportedAt: Date
    ) throws -> Data {
        var records = [Self.header]
        let orderedRows = snapshot.rows.sorted {
            if $0.row.ordinal != $1.row.ordinal {
                return $0.row.ordinal < $1.row.ordinal
            }
            return $0.row.id < $1.row.id
        }
        for item in orderedRows {
            guard item.row.ordinal >= 0,
                  item.evidence.allSatisfy({
                      $0.kind == "supporting" || $0.kind == "contrary"
                  }) else {
                throw ExportError.corruptSnapshot(snapshot.project.id)
            }
            let generatedValues: [String]
            do {
                generatedValues = try JSONDecoder().decode(
                    [String].self,
                    from: Data(item.generation.generatedValuesJSON.utf8)
                )
            } catch {
                throw ExportError.invalidGeneratedValues(item.cell.id)
            }
            let generatedValue = generatedValues.joined(separator: " · ")
            let attorneyValue = item.cell.attorneyValue ?? ""
            let currentValue: String
            switch item.cell.valueState {
            case "generated":
                guard item.cell.attorneyValue == nil else {
                    throw ExportError.corruptSnapshot(snapshot.project.id)
                }
                currentValue = generatedValue
            case "edited":
                guard let storedValue = item.cell.attorneyValue else {
                    throw ExportError.corruptSnapshot(snapshot.project.id)
                }
                currentValue = storedValue
            default:
                throw ExportError.corruptSnapshot(snapshot.project.id)
            }

            let supporting = Self.orderedEvidence(item.evidence, kind: "supporting")
            let contrary = Self.orderedEvidence(item.evidence, kind: "contrary")
            records.append([
                String(item.row.ordinal + 1),
                item.row.rowKey,
                generatedValue,
                attorneyValue,
                currentValue,
                item.cell.valueState,
                item.cell.reviewState,
                item.cell.reviewedBy ?? "",
                item.cell.reviewedAt.map(Self.iso8601) ?? "",
                item.cell.supportState,
                String(supporting.count),
                try supporting.map {
                    try Self.evidenceText($0, projectID: snapshot.project.id)
                }.joined(separator: "\r\n\r\n"),
                String(contrary.count),
                try contrary.map {
                    try Self.evidenceText($0, projectID: snapshot.project.id)
                }.joined(separator: "\r\n\r\n"),
                snapshot.project.title,
                snapshot.project.status,
                snapshot.project.staleReason ?? "",
                String(snapshot.table.versionIndex),
                snapshot.project.id,
                item.cell.id,
                snapshot.project.sourceRunID,
                snapshot.project.sourceOutputID,
                snapshot.project.sourceOutputVersionID,
                Self.iso8601(snapshot.project.updatedAt),
                Self.iso8601(exportedAt),
            ])
        }

        let body = records.map { record in
            record.map { value in
                Self.csvField(value)
            }.joined(separator: ",")
        }.joined(separator: "\r\n") + "\r\n"
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(contentsOf: body.utf8)
        return data
    }

    private static func orderedEvidence(
        _ evidence: [CaseFileReviewEvidenceEdgeRecord],
        kind: String
    ) -> [CaseFileReviewEvidenceEdgeRecord] {
        evidence.filter { $0.kind == kind }.sorted {
            if $0.ordinal != $1.ordinal { return $0.ordinal < $1.ordinal }
            return $0.id < $1.id
        }
    }

    private static func evidenceText(
        _ evidence: CaseFileReviewEvidenceEdgeRecord,
        projectID: String
    ) throws -> String {
        guard let locator = try? JSONDecoder().decode(
            DocumentSourceLocator.self,
            from: Data(evidence.locatorJSON.utf8)
        ) else {
            throw ExportError.corruptSnapshot(projectID)
        }
        var status = evidence.availability
        if let reason = evidence.unavailableReason, !reason.isEmpty {
            status += " (\(reason))"
        }
        var value = "[\(evidence.citationLabel)] \(evidence.frozenDocumentName) — \(locator.displayString) — \(status)"
        if !evidence.excerpt.isEmpty {
            value += "\r\n\(normalizeLineEndings(evidence.excerpt))"
        }
        return value
    }

    private func compensateFile(
        at url: URL,
        identity: DurableFileWriter.InstalledFileIdentity,
        expectedData: Data
    ) throws {
        let removed = try fileWriter.removeInstalledFile(
            matching: identity,
            at: url,
            containedIn: storage.root,
            expectedByteCount: expectedData.count
        ) { installedData in
            guard installedData == expectedData else {
                throw PublicationError.installedArtifactChanged
            }
        }
        guard removed else {
            throw PublicationError.installedArtifactNotRemoved
        }
    }

    private static func normalizeLineEndings(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
    }

    private static func csvField(_ value: String) -> String {
        let safe = CSVCellSanitizer.neutralize(normalizeLineEndings(value))
        let requiresQuotes = safe.unicodeScalars.contains { scalar in
            scalar.value == 0x2C || scalar.value == 0x22
                || scalar.value == 0x0D || scalar.value == 0x0A
        }
        guard requiresQuotes else { return safe }
        return "\"\(safe.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func filenameStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    private static func safeFileStem(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = String(title.unicodeScalars.map {
            allowed.contains($0) ? Character($0) : "-"
        })
        let stem = cleaned
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
            .prefix(60)
        return stem.isEmpty ? "Review" : String(stem)
    }
}
