import CryptoKit
import Foundation
import SupraResearch
import SupraStore

/// One immutable provider result selected by the user for deliberate promotion
/// into a matter. Encoding retains the normalized record and its raw provider
/// payload; the snapshot is never silently added to prompts or matter storage.
public enum PublicRecordSnapshot: Sendable, Equatable {
    case sec(SecFilingRecord)
    case cfpb(CfpbComplaintRecord)
    case nlrb(NlrbCaseRecord)

    public var id: String {
        switch self {
        case let .sec(record): "sec:\(record.accessionNumber)"
        case let .cfpb(record): "cfpb:\(record.complaintId)"
        case let .nlrb(record): "nlrb:\(record.caseNumber)"
        }
    }

    public var providerName: String {
        switch self {
        case .sec: "SEC EDGAR"
        case .cfpb: "CFPB Consumer Complaint Database"
        case .nlrb: "NLRB official export"
        }
    }

    public var sourceURL: String {
        switch self {
        case let .sec(record): record.primaryDocumentUrl ?? record.filingUrl
        case let .cfpb(record): record.sourceUrl
        case let .nlrb(record): record.sourceUrl
        }
    }

    public var fileName: String {
        let stem: String
        switch self {
        case let .sec(record): stem = "SEC-\(record.accessionNumber)"
        case let .cfpb(record): stem = "CFPB-Complaint-\(record.complaintId)"
        case let .nlrb(record): stem = "NLRB-Case-\(record.caseNumber)"
        }
        let safe = stem.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" ? Character(scalar) : "-"
        }
        return String(safe) + ".txt"
    }

    public func retainedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let payload: Data
        switch self {
        case let .sec(record): payload = try encoder.encode(record)
        case let .cfpb(record): payload = try encoder.encode(record)
        case let .nlrb(record): payload = try encoder.encode(record)
        }
        guard let json = String(data: payload, encoding: .utf8) else {
            throw PublicRecordMatterHandoffFailure(
                stage: .snapshotFailed,
                message: "The selected public record could not be encoded. Open the official record and try again."
            )
        }
        let limitation: String
        switch self {
        case .cfpb:
            limitation = "This complaint is a consumer allegation, not an agency finding or legal conclusion."
        case .sec:
            limitation = "This is a filing record as published by the SEC, not a legal conclusion. Confirm the current official filing before relying on it."
        case .nlrb:
            limitation = "This record describes an official export row and allegations as filed, not an agency finding or legal conclusion."
        }
        let text = """
        PUBLIC RECORD SNAPSHOT
        Provider: \(providerName)
        Record identity: \(id)
        Official source: \(sourceURL)
        Limitation: \(limitation)

        Normalized provider record and retained raw fields:
        \(json)
        """
        return Data(text.utf8)
    }
}

public struct PublicRecordMatterHandoffReceipt: Sendable, Equatable {
    public let snapshotID: String
    public let matterID: String
    public let documentID: String
    public let importBatchID: String?
    public let readinessReceipt: DocumentReadinessReceipt
    public let reusedExistingDocument: Bool
}

public struct PublicRecordMatterHandoffFailure: Error, LocalizedError, Sendable, Equatable {
    public enum Stage: String, Sendable, Equatable {
        case snapshotFailed
        case importFailed
        case indexingFailed
        case readinessFailed
    }

    public let stage: Stage
    public let message: String

    public var errorDescription: String? { message }
}

public enum PublicRecordMatterHandoffOutcome: Sendable, Equatable {
    case completed(PublicRecordMatterHandoffReceipt)
    case awaitingReadiness(PublicRecordMatterHandoffReceipt)
    case failed(PublicRecordMatterHandoffFailure)
}

/// The only durable Public Records handoff. It materializes a content-addressed
/// provider snapshot, uses the ordinary document import/indexing owners, and
/// reports only the Store's canonical readiness receipt. Repeating the same
/// provider result for the same matter reuses the existing document.
public struct PublicRecordMatterHandoff: Sendable {
    private let store: SupraStore
    private let importService: DocumentImportService
    private let makeIndexingService: @Sendable () -> DocumentIndexingService
    private let stagingRoot: URL

    public init(
        store: SupraStore,
        importService: DocumentImportService,
        indexingService: DocumentIndexingService,
        stagingRoot: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SupraPublicRecordHandoffs", isDirectory: true)
    ) {
        self.store = store
        self.importService = importService
        self.makeIndexingService = { indexingService }
        self.stagingRoot = stagingRoot
    }

    public init(
        store: SupraStore,
        importService: DocumentImportService,
        makeIndexingService: @escaping @Sendable () -> DocumentIndexingService,
        stagingRoot: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SupraPublicRecordHandoffs", isDirectory: true)
    ) {
        self.store = store
        self.importService = importService
        self.makeIndexingService = makeIndexingService
        self.stagingRoot = stagingRoot
    }

    public func addToMatter(
        snapshot: PublicRecordSnapshot,
        matterID: String
    ) async -> PublicRecordMatterHandoffOutcome {
        let data: Data
        do {
            data = try snapshot.retainedData()
        } catch let failure as PublicRecordMatterHandoffFailure {
            return .failed(failure)
        } catch {
            return .failed(.init(
                stage: .snapshotFailed,
                message: "The selected public record could not be retained: \(error.localizedDescription)"
            ))
        }

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let existing = existingDocument(matterID: matterID, digest: digest) {
            return await indexAndReport(
                snapshot: snapshot,
                matterID: matterID,
                documentID: existing.id,
                importBatchID: nil,
                reusedExistingDocument: true
            )
        }

        let sourceURL = stagingRoot.appendingPathComponent(snapshot.fileName)
        do {
            try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            try data.write(to: sourceURL, options: .atomic)
        } catch {
            return .failed(.init(
                stage: .snapshotFailed,
                message: "The selected public record could not be staged for matter import: \(error.localizedDescription)"
            ))
        }
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let importOutcome: DocumentImportService.ImportOutcome
        do {
            importOutcome = try await importService.importSources([sourceURL], matterID: matterID)
        } catch {
            return .failed(.init(
                stage: .importFailed,
                message: "The public record could not be imported into the matter: \(error.localizedDescription)"
            ))
        }
        guard let documentID = importOutcome.report.items.first(where: {
            $0.parentDocumentID == nil && $0.documentID != nil
        })?.documentID else {
            return .failed(.init(
                stage: .importFailed,
                message: importOutcome.report.items.compactMap(\.reason).first
                    ?? "The matter import did not create a document."
            ))
        }
        return await indexAndReport(
            snapshot: snapshot,
            matterID: matterID,
            documentID: documentID,
            importBatchID: importOutcome.batchID,
            reusedExistingDocument: false
        )
    }

    private func existingDocument(matterID: String, digest: String) -> MatterDocumentRecord? {
        guard let blob = try? store.documentLibrary.fetchBlob(sha256: digest) else { return nil }
        return try? store.documentLibrary.fetchDocuments(matterID: matterID)
            .first { $0.blobID == blob.id && $0.parentDocumentID == nil }
    }

    private func indexAndReport(
        snapshot: PublicRecordSnapshot,
        matterID: String,
        documentID: String,
        importBatchID: String?,
        reusedExistingDocument: Bool
    ) async -> PublicRecordMatterHandoffOutcome {
        do {
            _ = try await makeIndexingService().indexDocument(documentID: documentID)
        } catch {
            return .failed(.init(
                stage: .indexingFailed,
                message: "The imported public record could not be indexed: \(error.localizedDescription)"
            ))
        }
        let readiness: DocumentReadinessReceipt
        do {
            readiness = try store.documentReadiness.fetchReceipt(documentID: documentID)
        } catch {
            return .failed(.init(
                stage: .readinessFailed,
                message: "The public record's document readiness could not be confirmed: \(error.localizedDescription)"
            ))
        }
        let receipt = PublicRecordMatterHandoffReceipt(
            snapshotID: snapshot.id,
            matterID: matterID,
            documentID: documentID,
            importBatchID: importBatchID,
            readinessReceipt: readiness,
            reusedExistingDocument: reusedExistingDocument
        )
        _ = try? store.auditEvents.recordEvent(
            matterID: matterID,
            eventType: reusedExistingDocument
                ? "public_record_matter_handoff_reused"
                : "public_record_added_to_matter",
            actor: "user",
            summary: reusedExistingDocument
                ? "Reused public record \(snapshot.id) in matter documents"
                : "Added public record \(snapshot.id) to matter documents",
            relatedTable: "matter_documents",
            relatedID: documentID
        )
        return readiness.isBaseReady ? .completed(receipt) : .awaitingReadiness(receipt)
    }
}
