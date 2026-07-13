import Foundation
import SupraDocuments
import SupraStore

/// Bounded reconciliation and explicit repair for persisted content-addressed
/// document blobs. It never reads document content into diagnostics or stores a
/// private path in `integrity_error`; only stable reason codes are persisted.
public final class BlobIntegrityService: @unchecked Sendable {
    public enum State: String, Codable, Sendable, Equatable {
        case verified
        case missing
        case corrupt
    }

    public enum ServiceError: Error, Sendable, Equatable {
        case blobNotFound
        case reimportContentMismatch
        case repairVerificationFailed
    }

    public struct Result: Sendable, Equatable {
        public let blobID: String
        public let state: State
        public let verifiedAt: Date?
        public let reason: String?

        public init(blobID: String, state: State, verifiedAt: Date?, reason: String?) {
            self.blobID = blobID
            self.state = state
            self.verifiedAt = verifiedAt
            self.reason = reason
        }
    }

    public struct Batch: Sendable, Equatable {
        public let results: [Result]
        public let nextCursor: String?

        public init(results: [Result], nextCursor: String?) {
            self.results = results
            self.nextCursor = nextCursor
        }
    }

    public static let maximumBatchSize = 200

    private let store: SupraStore
    private let storage: DocumentStorage
    private let now: @Sendable () -> Date

    public init(
        store: SupraStore,
        storage: DocumentStorage = .makeDefault(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.storage = storage
        self.now = now
    }

    /// Verifies at most `limit` rows in stable ID order. Callers resume with
    /// `nextCursor`; an empty cursor means reconciliation reached the end.
    public func verifyBatch(after cursor: String? = nil, limit: Int = 50) throws -> Batch {
        let boundedLimit = min(max(limit, 1), Self.maximumBatchSize)
        let blobs = try store.documentLibrary.fetchBlobs(afterID: cursor, limit: boundedLimit)
        var results: [Result] = []
        results.reserveCapacity(blobs.count)

        for blob in blobs {
            try Task.checkCancellation()
            results.append(try verify(blob))
        }
        let nextCursor = blobs.count == boundedLimit ? blobs.last?.id : nil
        return Batch(results: results, nextCursor: nextCursor)
    }

    /// Reimports a user-selected copy only when it exactly matches the blob's
    /// recorded digest and size. The destination replacement is delegated to
    /// `DurableFileWriter`, then independently reverified before the row becomes
    /// `verified`.
    @discardableResult
    public func repair(blobID: String, reimportFrom source: URL) throws -> Result {
        guard let blob = try store.documentLibrary.fetchBlob(id: blobID) else {
            throw ServiceError.blobNotFound
        }
        do {
            _ = try storage.repair(
                source: source,
                expectedSHA256: blob.sha256,
                expectedByteSize: blob.byteSize,
                managedRelativePath: blob.managedRelativePath
            )
        } catch DocumentStorage.IntegrityError.reimportContentMismatch {
            throw ServiceError.reimportContentMismatch
        }

        do {
            return try verify(blob)
        } catch {
            try? store.documentLibrary.updateBlobIntegrity(
                id: blob.id,
                status: .corrupt,
                verifiedAt: nil,
                error: "repair_verification_failed"
            )
            throw ServiceError.repairVerificationFailed
        }
    }

    private func verify(_ blob: DocumentBlobRecord) throws -> Result {
        do {
            _ = try storage.verifyManagedBlob(
                relativePath: blob.managedRelativePath,
                expectedSHA256: blob.sha256,
                expectedByteSize: blob.byteSize
            )
            let verifiedAt = now()
            try store.documentLibrary.updateBlobIntegrity(
                id: blob.id,
                status: .verified,
                verifiedAt: verifiedAt,
                error: nil
            )
            if let recovery = try store.remediationRecovery.pendingItem(
                kind: .blobRepair,
                relatedID: blob.id
            ) {
                try store.remediationRecovery.resolve(
                    id: recovery.id,
                    resolution: .repaired,
                    actor: "system"
                )
            }
            return Result(blobID: blob.id, state: .verified, verifiedAt: verifiedAt, reason: nil)
        } catch let error as DocumentStorage.IntegrityError {
            let state: State
            let status: DocumentBlobIntegrityStatus
            let reason: String
            switch error {
            case .missingManagedBlob:
                state = .missing
                status = .missing
                reason = "missing_managed_file"
            case .corruptManagedBlob(_, _, let detail):
                state = .corrupt
                status = .corrupt
                reason = detail
            case .invalidManagedPath:
                state = .corrupt
                status = .corrupt
                reason = "invalid_managed_path"
            default:
                state = .corrupt
                status = .corrupt
                reason = "managed_blob_verification_failed"
            }
            try store.documentLibrary.updateBlobIntegrity(
                id: blob.id,
                status: status,
                verifiedAt: nil,
                error: reason
            )
            _ = try store.remediationRecovery.requireReview(
                kind: .blobRepair,
                matterID: nil,
                relatedTable: DocumentBlobRecord.databaseTableName,
                relatedID: blob.id
            )
            return Result(blobID: blob.id, state: state, verifiedAt: nil, reason: reason)
        }
    }
}
