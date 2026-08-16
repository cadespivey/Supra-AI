import CryptoKit
import Foundation
import GRDB
import SupraCore

/// Derives canonical base readiness from persisted document, revision, index,
/// and active-model evidence. No readiness result is cached or persisted.
public final class DocumentReadinessRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Derives one receipt inside one database read snapshot.
    public func fetchReceipt(documentID: String) throws -> DocumentReadinessReceipt {
        try writer.read { database in
            guard let document = try MatterDocumentRecord.fetchOne(database, key: documentID) else {
                throw DocumentReadinessRepositoryError.documentNotFound(documentID)
            }
            return try Self.deriveReceipt(for: document, in: database)
        }
    }

    /// Derives an exact matter-scoped batch inside one database read snapshot.
    /// Missing, foreign, and duplicate identities fail the whole request; the
    /// denominator is never silently reduced.
    public func fetchReceipts(
        matterID: String,
        documentIDs: [String]
    ) throws -> [DocumentReadinessReceipt] {
        try writer.read { database in
            guard !documentIDs.isEmpty else { return [] }

            let duplicateIDs = Self.duplicates(in: documentIDs)
            guard duplicateIDs.isEmpty else {
                throw DocumentReadinessRepositoryError.duplicateDocumentIDs(duplicateIDs)
            }

            let documents = try MatterDocumentRecord.fetchAll(
                database,
                sql: """
                    SELECT *
                    FROM matter_documents
                    WHERE id IN (\(databaseQuestionMarks(count: documentIDs.count)))
                    """,
                arguments: StatementArguments(documentIDs)
            )
            let documentsByID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
            let missingIDs = documentIDs.filter { documentsByID[$0] == nil }.sorted()
            let foreignIDs = documentIDs.filter {
                guard let document = documentsByID[$0] else { return false }
                return document.matterID != matterID
            }.sorted()
            guard missingIDs.isEmpty, foreignIDs.isEmpty else {
                throw DocumentReadinessRepositoryError.batchScopeMismatch(
                    matterID: matterID,
                    missingDocumentIDs: missingIDs,
                    foreignDocumentIDs: foreignIDs
                )
            }

            return try documentIDs.map { documentID in
                guard let document = documentsByID[documentID] else {
                    throw DocumentReadinessRepositoryError.documentNotFound(documentID)
                }
                return try Self.deriveReceipt(for: document, in: database)
            }
        }
    }

    /// Internal snapshot seam for Store repositories that must return their
    /// domain rows and the canonical readiness proof from one database read.
    /// Callers outside SupraStore continue to use `fetchReceipt(s)`.
    static func deriveReceipt(
        for document: MatterDocumentRecord,
        in database: Database
    ) throws -> DocumentReadinessReceipt {
        let snapshot = try DocumentReadinessSnapshotRow(document: document, database: database)
        return snapshot.makeReceipt()
    }

    private static func duplicates(in values: [String]) -> [String] {
        var seen: Set<String> = []
        var duplicates: Set<String> = []
        for value in values where !seen.insert(value).inserted {
            duplicates.insert(value)
        }
        return duplicates.sorted()
    }
}

/// Internal, ephemeral projection built entirely inside the repository's one
/// read snapshot. Raw text and display content never enter the receipt; a
/// cryptographic fingerprint binds mutable chunk bytes without disclosing them.
private struct DocumentReadinessSnapshotRow {
    let document: MatterDocumentRecord
    let parts: [DocumentPagePartRecord]
    let partBindings: [DocumentReadinessPartBinding]
    let selectedRevisionIDs: [String]
    let selectionIDs: [String]
    let selectedRevisionToolchains: [String]
    let selectedRevisionCoherent: Bool
    let chunks: [DocumentChunkRecord]
    let indexedRevisionIDs: [String]
    let chunkRevisionBindingsCurrent: [Bool]
    let chunkerVersion: Int
    let textIndexMatches: [Bool]
    let hasExtraTextIndexRows: Bool
    let activeModel: DocumentEmbeddingModelRecord?
    let selectedModelFlagIDs: [String]
    let activeModelMissing: Bool
    let modelSelectionInconsistent: Bool
    let modelUnverified: Bool
    let semanticIndexMatches: [Bool]
    let hasExtraActiveModelEmbeddings: Bool
    let embeddingIdentities: [EmbeddingIdentity]
    let availableEmbeddingModelIDs: [String]

    init(document: MatterDocumentRecord, database: Database) throws {
        self.document = document
        parts = try DocumentPagePartRecord.fetchAll(
            database,
            sql: """
                SELECT * FROM document_pages_parts
                WHERE document_id = ?
                ORDER BY part_index, id
                """,
            arguments: [document.id]
        )
        partBindings = parts.map {
            DocumentReadinessPartBinding(
                partIndex: $0.partIndex,
                partID: $0.id,
                currentRevisionID: $0.currentRevisionID,
                currentSelectionID: $0.currentSelectionID
            )
        }

        var revisionIDs: [String] = []
        var selectionIDs: [String] = []
        var revisionToolchains: [String] = []
        var revisionByPartID: [String: String] = [:]
        var coherent = !parts.isEmpty
        for part in parts {
            if let revisionID = part.currentRevisionID {
                revisionIDs.append(revisionID)
                revisionByPartID[part.id] = revisionID
            }
            if let selectionID = part.currentSelectionID {
                selectionIDs.append(selectionID)
            }

            guard let revisionID = part.currentRevisionID,
                  let selectionID = part.currentSelectionID,
                  let revision = try DocumentPartRevisionRecord.fetchOne(database, key: revisionID),
                  let selection = try DocumentPartSelectionRecord.fetchOne(database, key: selectionID),
                  revision.documentID == document.id,
                  revision.partIndex == part.partIndex,
                  selection.documentID == document.id,
                  selection.partIndex == part.partIndex,
                  selection.selectedRevisionID == revisionID,
                  part.normalizedText == revision.text,
                  part.charCount == revision.charCount,
                  part.ocrConfidence == revision.ocrConfidence,
                  part.boundingBoxesJSON == revision.boundingBoxesJSON
            else {
                coherent = false
                continue
            }
            revisionToolchains.append(revision.toolchainVersion ?? "")
        }
        selectedRevisionIDs = revisionIDs
        self.selectionIDs = selectionIDs
        selectedRevisionToolchains = revisionToolchains
        selectedRevisionCoherent = coherent

        chunks = try DocumentChunkRecord.fetchAll(
            database,
            sql: """
                SELECT * FROM document_chunks
                WHERE document_id = ?
                ORDER BY chunk_index, id
                """,
            arguments: [document.id]
        )
        indexedRevisionIDs = Self.orderedUnique(chunks.compactMap(\.revisionID))
        chunkRevisionBindingsCurrent = chunks.map { chunk in
            guard let partID = chunk.pagePartID,
                  let revisionID = chunk.revisionID else { return false }
            return revisionByPartID[partID] == revisionID
        }

        let settings = try DocumentIntelligenceSettingsRecord.fetchOne(
            database,
            key: DocumentIntelligenceSettingsRecord.singletonID
        )
        chunkerVersion = settings?.chunkerVersion ?? 0

        let textRows = try Self.fetchTextIndexRows(
            documentID: document.id,
            chunkIDs: chunks.map(\.id),
            database: database
        )
        let textRowsByChunkID = Dictionary(grouping: textRows, by: \.chunkID)
        textIndexMatches = chunks.map { chunk in
            guard let rows = textRowsByChunkID[chunk.id], rows.count == 1 else { return false }
            let row = rows[0]
            return row.documentID == document.id && row.text == chunk.normalizedText
        }
        let currentChunkIDs = Set(chunks.map(\.id))
        hasExtraTextIndexRows = textRows.contains { row in
            guard row.documentID == document.id else { return false }
            guard let chunkID = row.chunkID else { return true }
            return !currentChunkIDs.contains(chunkID)
        }
        selectedModelFlagIDs = try String.fetchAll(
            database,
            sql: """
                SELECT id FROM document_embedding_models
                WHERE is_selected = 1
                ORDER BY id
                """
        )
        if let selectedModelID = settings?.selectedEmbeddingModelID {
            activeModel = try DocumentEmbeddingModelRecord.fetchOne(database, key: selectedModelID)
        } else {
            activeModel = nil
        }
        activeModelMissing = settings?.selectedEmbeddingModelID == nil || activeModel == nil
        let expectedSelectedModelFlagIDs = activeModel.map { [$0.id] } ?? []
        modelSelectionInconsistent = selectedModelFlagIDs != expectedSelectedModelFlagIDs
        modelUnverified = activeModel.map { model in
            model.dimension <= 0
                || model.lastTestLoadAt == nil
                || model.lastTestLoadResult != "passed"
                || settings?.embeddingModelLastTestedAt == nil
        } ?? false

        let embeddings = try Self.fetchEmbeddings(
            documentID: document.id,
            chunkIDs: chunks.map(\.id),
            database: database
        )
        availableEmbeddingModelIDs = Array(Set(embeddings.map(\.embeddingModelID))).sorted()
        if let activeModel {
            let activeEmbeddings = embeddings.filter { $0.embeddingModelID == activeModel.id }
            embeddingIdentities = activeEmbeddings.map(EmbeddingIdentity.init)
            let activeByChunkID = Dictionary(grouping: activeEmbeddings, by: \.chunkID)
            semanticIndexMatches = chunks.map { chunk in
                guard let candidates = activeByChunkID[chunk.id], candidates.count == 1 else {
                    return false
                }
                return Self.isValid(candidates[0], for: chunk, document: document, model: activeModel)
            }
            hasExtraActiveModelEmbeddings = activeEmbeddings.contains { embedding in
                !currentChunkIDs.contains(embedding.chunkID)
            }
        } else {
            embeddingIdentities = []
            semanticIndexMatches = Array(repeating: false, count: chunks.count)
            hasExtraActiveModelEmbeddings = false
        }

    }

    func makeReceipt() -> DocumentReadinessReceipt {
        var reasons: Set<DocumentReadinessExclusionReason> = []
        let status = MatterDocumentStatus(rawValue: document.status)
        let extractionStatus = DocumentExtractionStatus(rawValue: document.extractionStatus)
        let indexStatus = DocumentIndexStatus(rawValue: document.indexStatus)
        var reviewConditions: [DocumentReadinessReviewCondition] = []

        if document.deletedAt != nil || status == .deleted {
            reasons.insert(.deleted)
        }
        if extractionStatus == .failed {
            reasons.insert(.extractionFailed)
        }
        if status == .failed || status == nil {
            reasons.insert(.processingFailed)
        }
        if status == .needsReview {
            reasons.insert(.reviewRequired)
            reviewConditions.append(.statusNeedsReview)
        }
        if document.extractionMethod?.hasPrefix("converted_lossy@toolchain:") == true {
            reasons.insert(.reviewRequired)
            reviewConditions.append(.convertedLossyExtraction)
        }

        let extractionIsTerminal = extractionStatus.map {
            [DocumentExtractionStatus.extracted, .ocrComplete, .edited].contains($0)
        } ?? false
        if !extractionIsTerminal
            || parts.isEmpty
            || document.pagePartCount != parts.count
            || document.extractionMethod?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            || document.extractedTextChecksum?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            || (status.map {
                [MatterDocumentStatus.importing, .extracting, .needsOCR, .ocrPending].contains($0)
            } ?? false) {
            reasons.insert(.extractionIncomplete)
        }
        if !selectedRevisionCoherent {
            reasons.insert(.selectedRevisionIncoherent)
        }
        if indexStatus == .failed {
            reasons.insert(.textIndexFailed)
        }

        let selectedRevisionSet = Set(selectedRevisionIDs)
        let indexedRevisionSet = Set(indexedRevisionIDs)
        let chunksWithWrongCurrentRevision = zip(chunks, chunkRevisionBindingsCurrent).contains {
            chunk, bindingIsCurrent in
            chunk.pagePartID != nil && chunk.revisionID != nil && !bindingIsCurrent
        }
        let selectedRevisionCoverageIsStale = !chunks.isEmpty
            && !selectedRevisionSet.isEmpty
            && selectedRevisionSet != indexedRevisionSet
        let activeChunkerBindingIsStale = chunks.contains { $0.chunkerVersion != chunkerVersion }
        if indexStatus == .stale
            || chunksWithWrongCurrentRevision
            || selectedRevisionCoverageIsStale
            || activeChunkerBindingIsStale {
            reasons.insert(.staleRevision)
        }

        let chunksHaveCompleteBindings = !chunks.isEmpty
            && chunkRevisionBindingsCurrent.allSatisfy { $0 }
        let textIndexIsComplete = chunksHaveCompleteBindings
            && chunkerVersion > 0
            && chunks.allSatisfy { $0.chunkerVersion == chunkerVersion }
            && textIndexMatches.allSatisfy { $0 }
            && !hasExtraTextIndexRows
            && indexStatus != .notIndexed
            && indexStatus != nil
        if !textIndexIsComplete || status == .indexing {
            reasons.insert(.textIndexIncomplete)
        }
        if activeModelMissing {
            reasons.insert(.activeEmbeddingModelMissing)
        }
        if modelSelectionInconsistent {
            reasons.insert(.selectionInconsistent)
        }
        if modelUnverified {
            reasons.insert(.unverified)
        }

        let semanticIndexIsComplete = !chunks.isEmpty
            && semanticIndexMatches.allSatisfy { $0 }
            && !hasExtraActiveModelEmbeddings
            && indexStatus == .ready
            && status != .embedding
        if !semanticIndexIsComplete {
            reasons.insert(.semanticIndexIncomplete)
        }

        let exclusions = DocumentReadinessExclusionReason.allCases.filter(reasons.contains)
        var digest = ReceiptDigest()
        digest.append("document-readiness-v1")
        digest.append(document.id)
        digest.append(document.matterID)
        digest.append(document.status)
        digest.append(document.extractionStatus)
        digest.append(document.indexStatus)
        digest.append(document.deletedAt == nil ? "live" : "deleted")
        digest.append(document.extractedTextChecksum ?? "")
        digest.append(reviewConditions.map(\.rawValue))
        for binding in partBindings {
            digest.append(binding.partIndex)
            digest.append(binding.partID)
            digest.append(binding.currentRevisionID ?? "")
            digest.append(binding.currentSelectionID ?? "")
        }
        digest.append(selectedRevisionIDs)
        digest.append(selectionIDs)
        digest.append(selectedRevisionToolchains)
        digest.append(selectedRevisionCoherent)
        digest.append(indexedRevisionIDs)
        digest.append(chunks.map(\.id))
        digest.append(chunks.map { $0.pagePartID ?? "" })
        digest.append(chunks.map { $0.revisionID ?? "" })
        digest.append(chunks.map {
            ReadinessFingerprint.sha256Hex(Data($0.normalizedText.utf8))
        })
        digest.append(chunkRevisionBindingsCurrent)
        digest.append(chunks.map(\.chunkerVersion))
        digest.append(chunkerVersion)
        digest.append(textIndexMatches)
        digest.append(hasExtraTextIndexRows)
        digest.append(activeModel?.id ?? "")
        digest.append(activeModel?.repoID ?? "")
        digest.append(activeModel?.revision ?? "")
        digest.append(activeModel?.dimension ?? 0)
        digest.append(selectedModelFlagIDs)
        digest.append(availableEmbeddingModelIDs)
        digest.append(activeModelMissing)
        digest.append(modelSelectionInconsistent)
        digest.append(modelUnverified)
        digest.append(semanticIndexMatches)
        digest.append(hasExtraActiveModelEmbeddings)
        for identity in embeddingIdentities.sorted() {
            digest.append(identity.fields)
        }
        digest.append(exclusions.map(\.rawValue))

        return DocumentReadinessReceipt(
            receiptID: digest.finalize(),
            documentID: document.id,
            matterID: document.matterID,
            exclusions: exclusions,
            extractionStatus: extractionStatus,
            extractionMethod: document.extractionMethod,
            reviewConditions: reviewConditions,
            partBindings: partBindings,
            selectedRevisionIDs: selectedRevisionIDs,
            selectionIDs: selectionIDs,
            indexedRevisionIDs: indexedRevisionIDs,
            chunkIDs: chunks.map(\.id),
            chunkerVersion: chunkerVersion,
            activeEmbeddingModelID: activeModel?.id,
            activeEmbeddingModelRevision: activeModel?.revision,
            activeEmbeddingDimension: activeModel?.dimension,
            activeEmbeddingModel: activeModel.map {
                DocumentReadinessEmbeddingModelIdentity(
                    id: $0.id,
                    repoID: $0.repoID,
                    revision: $0.revision,
                    dimension: $0.dimension
                )
            },
            selectedEmbeddingModelFlagIDs: selectedModelFlagIDs,
            availableEmbeddingModelIDs: availableEmbeddingModelIDs,
            chunkCount: chunks.count,
            textIndexedChunkCount: hasExtraTextIndexRows
                ? 0
                : zip(chunks, textIndexMatches).filter { $0.1 }.count,
            semanticIndexedChunkCount: hasExtraActiveModelEmbeddings
                ? 0
                : zip(chunks, semanticIndexMatches).filter { $0.1 }.count
        )
    }

    private static func fetchTextIndexRows(
        documentID: String,
        chunkIDs: [String],
        database: Database
    ) throws -> [TextIndexRow] {
        var arguments: [DatabaseValueConvertible] = [documentID]
        var predicate = "document_id = ?"
        if !chunkIDs.isEmpty {
            predicate += " OR chunk_id IN (\(databaseQuestionMarks(count: chunkIDs.count)))"
            arguments.append(contentsOf: chunkIDs)
        }
        return try Row.fetchAll(
            database,
            sql: """
                SELECT rowid, text, chunk_id, document_id
                FROM document_chunk_fts
                WHERE \(predicate)
                ORDER BY rowid
                """,
            arguments: StatementArguments(arguments)
        ).map { row in
            TextIndexRow(
                text: row["text"],
                chunkID: row["chunk_id"],
                documentID: row["document_id"]
            )
        }
    }

    private static func fetchEmbeddings(
        documentID: String,
        chunkIDs: [String],
        database: Database
    ) throws -> [DocumentChunkEmbeddingRecord] {
        var arguments: [DatabaseValueConvertible] = [documentID]
        var predicate = "document_id = ?"
        if !chunkIDs.isEmpty {
            predicate += " OR chunk_id IN (\(databaseQuestionMarks(count: chunkIDs.count)))"
            arguments.append(contentsOf: chunkIDs)
        }
        return try DocumentChunkEmbeddingRecord.fetchAll(
            database,
            sql: """
                SELECT * FROM document_chunk_embeddings
                WHERE \(predicate)
                ORDER BY chunk_id, embedding_model_id, id
                """,
            arguments: StatementArguments(arguments)
        )
    }

    private static func isValid(
        _ embedding: DocumentChunkEmbeddingRecord,
        for chunk: DocumentChunkRecord,
        document: MatterDocumentRecord,
        model: DocumentEmbeddingModelRecord
    ) -> Bool {
        guard embedding.dimension > 0 else { return false }
        let expectedByteCount = embedding.dimension.multipliedReportingOverflow(
            by: MemoryLayout<Float>.size
        )
        guard !expectedByteCount.overflow,
              embedding.chunkID == chunk.id,
              embedding.documentID == document.id,
              embedding.embeddingModelID == model.id,
              embedding.modelDisplayName == model.displayName,
              embedding.modelRevision == model.revision,
              embedding.dimension == model.dimension,
              embedding.normalized,
              embedding.vector.count == expectedByteCount.partialValue,
              let normSquared = vectorNormSquared(embedding.vector),
              abs(normSquared - 1) <= 0.001 else {
            return false
        }
        return true
    }

    private static func vectorNormSquared(_ data: Data) -> Double? {
        guard data.count.isMultiple(of: MemoryLayout<UInt32>.size) else { return nil }
        return data.withUnsafeBytes { bytes -> Double? in
            var normSquared = 0.0
            for offset in stride(from: 0, to: data.count, by: MemoryLayout<UInt32>.size) {
                let stored = bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                let value = Float(bitPattern: UInt32(littleEndian: stored))
                guard value.isFinite else { return nil }
                normSquared += Double(value) * Double(value)
            }
            return normSquared.isFinite ? normSquared : nil
        }
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}

private struct TextIndexRow {
    let text: String?
    let chunkID: String?
    let documentID: String?
}

private struct EmbeddingIdentity: Comparable {
    let fields: [String]

    init(_ embedding: DocumentChunkEmbeddingRecord) {
        fields = [
            embedding.id,
            embedding.chunkID,
            embedding.documentID,
            embedding.embeddingModelID,
            embedding.modelRevision ?? "",
            String(embedding.dimension),
            embedding.normalized ? "normalized" : "not-normalized",
            ReadinessFingerprint.sha256Hex(embedding.vector),
        ]
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.fields.lexicographicallyPrecedes(rhs.fields)
    }
}

private enum ReadinessFingerprint {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct ReceiptDigest {
    private var bytes = Data()

    mutating func append(_ value: String) {
        let valueBytes = Data(value.utf8)
        var count = UInt64(valueBytes.count).bigEndian
        withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }
        bytes.append(valueBytes)
    }

    mutating func append(_ value: Int) {
        append(String(value))
    }

    mutating func append(_ value: Bool) {
        append(value ? "true" : "false")
    }

    mutating func append(_ values: [String]) {
        append(values.count)
        values.forEach { append($0) }
    }

    mutating func append(_ values: [Int]) {
        append(values.map(String.init))
    }

    mutating func append(_ values: [Bool]) {
        append(values.map { $0 ? "true" : "false" })
    }

    func finalize() -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
