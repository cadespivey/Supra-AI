import Foundation
import SupraCore
import SupraDocuments
import SupraStore

/// Produces immutable, matter-scoped CSV and XLSX snapshots of one Review Project.
/// The Store owns the atomic snapshot and completion checks; this service owns
/// deterministic serialization and durable file installation.
public final class CaseFileReviewExportService: @unchecked Sendable {
    public struct Completion: Sendable, Equatable {
        public let exportID: String
        public let matterID: String
        public let projectID: String
        public let format: CaseFileReviewSnapshotExportFormat
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
            format: CaseFileReviewSnapshotExportFormat = .csv,
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
            self.format = format
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

    private struct ReviewRowProjection {
        let rowNumber: Int
        let finding: String
        let generatedValue: String
        let attorneyValue: String
        let currentValue: String
        let valueState: String
        let reviewState: String
        let reviewedBy: String
        let reviewedAt: Date?
        let supportState: String
        let supporting: [CaseFileReviewEvidenceEdgeRecord]
        let contrary: [CaseFileReviewEvidenceEdgeRecord]
        let cellID: String
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

    private static let matrixColumns = [
        TabularXLSXWorkbook.Column(header: "Row", width: 7),
        TabularXLSXWorkbook.Column(header: "Finding", width: 34),
        TabularXLSXWorkbook.Column(header: "Generated value", width: 38),
        TabularXLSXWorkbook.Column(header: "Attorney value", width: 38),
        TabularXLSXWorkbook.Column(header: "Current value", width: 42),
        TabularXLSXWorkbook.Column(header: "Value state", width: 14),
        TabularXLSXWorkbook.Column(header: "Review state", width: 16),
        TabularXLSXWorkbook.Column(header: "Reviewed by", width: 22),
        TabularXLSXWorkbook.Column(header: "Reviewed at (UTC)", width: 24),
        TabularXLSXWorkbook.Column(header: "Support state", width: 16),
        TabularXLSXWorkbook.Column(header: "Supporting source count", width: 22),
        TabularXLSXWorkbook.Column(header: "Contrary source count", width: 20),
        TabularXLSXWorkbook.Column(header: "Cell ID", width: 30),
    ]

    private static let sourceColumns = [
        TabularXLSXWorkbook.Column(header: "Finding row", width: 11),
        TabularXLSXWorkbook.Column(header: "Finding", width: 34),
        TabularXLSXWorkbook.Column(header: "Relationship", width: 14),
        TabularXLSXWorkbook.Column(header: "Source order", width: 13),
        TabularXLSXWorkbook.Column(header: "Citation", width: 12),
        TabularXLSXWorkbook.Column(header: "Document", width: 30),
        TabularXLSXWorkbook.Column(header: "Locator", width: 18),
        TabularXLSXWorkbook.Column(header: "Availability", width: 15),
        TabularXLSXWorkbook.Column(header: "Unavailable reason", width: 28),
        TabularXLSXWorkbook.Column(header: "Excerpt", width: 54),
        TabularXLSXWorkbook.Column(header: "Frozen source ID", width: 32),
        TabularXLSXWorkbook.Column(header: "Frozen document ID", width: 32),
        TabularXLSXWorkbook.Column(header: "Frozen revision ID", width: 32),
        TabularXLSXWorkbook.Column(header: "Cell ID", width: 30),
    ]

    private static let projectColumns = [
        TabularXLSXWorkbook.Column(header: "Field", width: 34),
        TabularXLSXWorkbook.Column(header: "Value", width: 76),
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
                format: completion.format,
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
        try export(
            matterID: matterID,
            projectID: projectID,
            actor: actor,
            format: .csv,
            at: exportedAt
        )
    }

    @discardableResult
    public func exportXLSX(
        matterID: String,
        projectID: String,
        actor: String,
        at exportedAt: Date = Date()
    ) throws -> URL {
        try export(
            matterID: matterID,
            projectID: projectID,
            actor: actor,
            format: .xlsx,
            at: exportedAt
        )
    }

    private func export(
        matterID: String,
        projectID: String,
        actor: String,
        format: CaseFileReviewSnapshotExportFormat,
        at exportedAt: Date
    ) throws -> URL {
        let snapshot = try store.caseFileReviews.fetchSnapshot(
            matterID: matterID,
            projectID: projectID
        )
        let data: Data
        switch format {
        case .csv:
            data = try renderCSV(snapshot: snapshot, exportedAt: exportedAt)
        case .xlsx:
            data = try renderXLSX(snapshot: snapshot, exportedAt: exportedAt)
        }
        let baseStem = "\(Self.safeFileStem(snapshot.project.title))-snapshot-v\(snapshot.table.versionIndex)-\(Self.filenameStamp(exportedAt))"
        let baseFileName = "\(baseStem).\(format.fileExtension)"
        let directory = storage.exportsDirectory(forMatterID: matterID)
        let exportID = UUID().uuidString
        let collisionFileName = "\(baseStem)-\(exportID.lowercased()).\(format.fileExtension)"
        let documentFormat = Self.documentExportFormat(format)
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
                    try DocumentExportValidator.validate(installedData, as: documentFormat)
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
            format: format,
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

    private func renderCSV(
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

    private func renderXLSX(
        snapshot: CaseFileReviewSnapshot,
        exportedAt: Date
    ) throws -> Data {
        let rows = try Self.reviewRows(snapshot)
        let matrixRows: [[TabularXLSXWorkbook.Cell]] = rows.map { row in
            let reviewedAt: TabularXLSXWorkbook.Cell = row.reviewedAt.map {
                .dateTime($0)
            } ?? .text("")
            return [
                .integer(row.rowNumber),
                .text(row.finding),
                .text(row.generatedValue),
                .text(row.attorneyValue),
                Self.currentValueCell(row.currentValue, valueState: row.valueState),
                Self.valueStateCell(row.valueState),
                Self.reviewStateCell(row.reviewState),
                .text(row.reviewedBy),
                reviewedAt,
                Self.supportStateCell(row.supportState),
                .integer(row.supporting.count),
                .integer(row.contrary.count),
                .text(row.cellID),
            ]
        }

        var sourceRows: [[TabularXLSXWorkbook.Cell]] = []
        for row in rows {
            for evidence in row.supporting + row.contrary {
                let locator = try Self.evidenceLocator(
                    evidence,
                    projectID: snapshot.project.id
                )
                sourceRows.append([
                    .integer(row.rowNumber),
                    .text(row.finding),
                    Self.relationshipCell(evidence.kind),
                    .integer(evidence.ordinal + 1),
                    .text(evidence.citationLabel),
                    .text(evidence.frozenDocumentName),
                    .text(locator.displayString),
                    Self.availabilityCell(evidence.availability),
                    Self.unavailableReasonCell(evidence.unavailableReason),
                    .text(Self.normalizeWorkbookLineEndings(evidence.excerpt)),
                    .text(evidence.frozenOutputSourceID),
                    .text(evidence.frozenDocumentID),
                    .text(evidence.frozenRevisionID),
                    .text(row.cellID),
                ])
            }
        }

        let reviewedCount = rows.count { $0.reviewState == "reviewed" }
        let needsReviewCount = rows.count { $0.reviewState == "needs_review" }
        let editedCount = rows.count { $0.valueState == "edited" }
        let evidenceAttentionCount = rows.count {
            !$0.contrary.isEmpty || $0.supportState != "supported"
        }
        let supportingSourceCount = rows.reduce(0) { $0 + $1.supporting.count }
        let contrarySourceCount = rows.reduce(0) { $0 + $1.contrary.count }
        let projectRows: [[TabularXLSXWorkbook.Cell]] = [
            Self.projectRow("Snapshot schema version", value: .integer(1)),
            Self.projectRow("Project", value: .text(snapshot.project.title)),
            Self.projectRow(
                "Project status",
                value: Self.projectStatusCell(snapshot.project.status)
            ),
            Self.projectRow(
                "Project stale reason",
                value: Self.unavailableReasonCell(snapshot.project.staleReason)
            ),
            Self.projectRow("Matrix version", value: .integer(snapshot.table.versionIndex)),
            Self.projectRow("Finding count", value: .integer(rows.count)),
            Self.projectRow("Reviewed findings", value: .integer(reviewedCount)),
            Self.projectRow("Needs-review findings", value: .integer(needsReviewCount)),
            Self.projectRow("Edited findings", value: .integer(editedCount)),
            Self.projectRow(
                "Evidence-attention findings",
                value: .integer(evidenceAttentionCount)
            ),
            Self.projectRow(
                "Supporting source count",
                value: .integer(supportingSourceCount)
            ),
            Self.projectRow("Contrary source count", value: .integer(contrarySourceCount)),
            Self.projectRow(
                "Scope",
                value: .text("All saved findings (presentation filters ignored)")
            ),
            Self.projectRow("Project ID", value: .text(snapshot.project.id)),
            Self.projectRow("Source run ID", value: .text(snapshot.project.sourceRunID)),
            Self.projectRow("Source output ID", value: .text(snapshot.project.sourceOutputID)),
            Self.projectRow(
                "Source output version ID",
                value: .text(snapshot.project.sourceOutputVersionID)
            ),
            Self.projectRow(
                "Project updated at (UTC)",
                value: .dateTime(snapshot.project.updatedAt)
            ),
            Self.projectRow("Exported at (UTC)", value: .dateTime(exportedAt)),
        ]

        return try TabularXLSXRenderer.render(TabularXLSXWorkbook(sheets: [
            .init(
                name: "Matrix",
                tableName: "ReviewMatrix",
                columns: Self.matrixColumns,
                rows: matrixRows,
                freezeRows: 1,
                freezeColumns: 2,
                showsGridLines: false,
                hasAutoFilter: true
            ),
            .init(
                name: "Sources",
                tableName: "ReviewSources",
                columns: Self.sourceColumns,
                rows: sourceRows,
                freezeRows: 1,
                freezeColumns: 2,
                showsGridLines: false,
                hasAutoFilter: true
            ),
            .init(
                name: "Project",
                tableName: "ReviewProject",
                columns: Self.projectColumns,
                rows: projectRows,
                freezeRows: 1,
                freezeColumns: 0,
                showsGridLines: false,
                hasAutoFilter: true
            ),
        ]))
    }

    private static func reviewRows(
        _ snapshot: CaseFileReviewSnapshot
    ) throws -> [ReviewRowProjection] {
        try snapshot.rows.sorted {
            if $0.row.ordinal != $1.row.ordinal {
                return $0.row.ordinal < $1.row.ordinal
            }
            return $0.row.id < $1.row.id
        }.map { item in
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
            return ReviewRowProjection(
                rowNumber: item.row.ordinal + 1,
                finding: item.row.rowKey,
                generatedValue: generatedValue,
                attorneyValue: attorneyValue,
                currentValue: currentValue,
                valueState: item.cell.valueState,
                reviewState: item.cell.reviewState,
                reviewedBy: item.cell.reviewedBy ?? "",
                reviewedAt: item.cell.reviewedAt,
                supportState: item.cell.supportState,
                supporting: orderedEvidence(item.evidence, kind: "supporting"),
                contrary: orderedEvidence(item.evidence, kind: "contrary"),
                cellID: item.cell.id
            )
        }
    }

    private static func currentValueCell(
        _ value: String,
        valueState: String
    ) -> TabularXLSXWorkbook.Cell {
        valueState == "edited" ? .text(value, style: .information) : .text(value)
    }

    private static func valueStateCell(_ value: String) -> TabularXLSXWorkbook.Cell {
        value == "edited" ? .text(value, style: .information) : .text(value)
    }

    private static func reviewStateCell(_ value: String) -> TabularXLSXWorkbook.Cell {
        value == "reviewed"
            ? .text(value, style: .positive)
            : .text(value, style: .attention)
    }

    private static func supportStateCell(_ value: String) -> TabularXLSXWorkbook.Cell {
        value == "supported"
            ? .text(value, style: .positive)
            : .text(value, style: .attention)
    }

    private static func relationshipCell(_ value: String) -> TabularXLSXWorkbook.Cell {
        value == "supporting"
            ? .text(value, style: .positive)
            : .text(value, style: .attention)
    }

    private static func availabilityCell(_ value: String) -> TabularXLSXWorkbook.Cell {
        value == "available"
            ? .text(value, style: .positive)
            : .text(value, style: .attention)
    }

    private static func unavailableReasonCell(
        _ value: String?
    ) -> TabularXLSXWorkbook.Cell {
        guard let value, !value.isEmpty else { return .text("") }
        return .text(value, style: .attention)
    }

    private static func projectStatusCell(_ value: String) -> TabularXLSXWorkbook.Cell {
        value == "active"
            ? .text(value, style: .positive)
            : .text(value, style: .attention)
    }

    private static func projectRow(
        _ field: String,
        value: TabularXLSXWorkbook.Cell
    ) -> [TabularXLSXWorkbook.Cell] {
        [.text(field, style: .muted), value]
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
        let locator = try evidenceLocator(evidence, projectID: projectID)
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

    private static func evidenceLocator(
        _ evidence: CaseFileReviewEvidenceEdgeRecord,
        projectID: String
    ) throws -> DocumentSourceLocator {
        guard let locator = try? JSONDecoder().decode(
            DocumentSourceLocator.self,
            from: Data(evidence.locatorJSON.utf8)
        ) else {
            throw ExportError.corruptSnapshot(projectID)
        }
        return locator
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

    private static func normalizeWorkbookLineEndings(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func documentExportFormat(
        _ format: CaseFileReviewSnapshotExportFormat
    ) -> DocumentExportFormat {
        switch format {
        case .csv: .csv
        case .xlsx: .xlsx
        }
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
