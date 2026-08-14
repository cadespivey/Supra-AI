import Foundation
import SupraStore

/// Every input that can change semantic candidate identities or ordering.
/// Only digests, opaque identities, and numeric configuration are retained.
struct RAGDerivedCacheKey: Codable, Hashable, Sendable {
    let querySHA256: String
    let matterID: String
    let documentIDs: [String]
    let readinessReceiptIDs: [String]
    let embeddingModel: DocumentReadinessEmbeddingModelIdentity
    let artifactIdentitySHA256: String
    let pageSize: Int
    let candidateLimit: Int
    let minimumSimilarity: Double
    let retrievalDepth: String
    let algorithmVersion: Int

    init(
        querySHA256: String,
        matterID: String,
        documentIDs: [String],
        readinessReceiptIDs: [String],
        embeddingModel: DocumentReadinessEmbeddingModelIdentity,
        artifactIdentitySHA256: String,
        pageSize: Int,
        candidateLimit: Int,
        minimumSimilarity: Double,
        retrievalDepth: String,
        algorithmVersion: Int
    ) {
        self.querySHA256 = querySHA256
        self.matterID = matterID
        self.documentIDs = Array(Set(documentIDs)).sorted()
        self.readinessReceiptIDs = Array(Set(readinessReceiptIDs)).sorted()
        self.embeddingModel = embeddingModel
        self.artifactIdentitySHA256 = artifactIdentitySHA256
        self.pageSize = pageSize
        self.candidateLimit = candidateLimit
        self.minimumSimilarity = minimumSimilarity
        self.retrievalDepth = retrievalDepth
        self.algorithmVersion = algorithmVersion
    }
}

/// Authority is deliberately supplied at each use. A cached result never
/// establishes readiness or policy eligibility merely because its key exists.
struct RAGDerivedCacheAccess: Equatable, Sendable {
    let readinessReceiptIDs: [String]
    let allDocumentsBaseReady: Bool
    let policyAllowsUse: Bool

    init(
        readinessReceiptIDs: [String],
        allDocumentsBaseReady: Bool,
        policyAllowsUse: Bool
    ) {
        self.readinessReceiptIDs = Array(Set(readinessReceiptIDs)).sorted()
        self.allDocumentsBaseReady = allDocumentsBaseReady
        self.policyAllowsUse = policyAllowsUse
    }

    func authorizes(_ key: RAGDerivedCacheKey) -> Bool {
        allDocumentsBaseReady
            && policyAllowsUse
            && readinessReceiptIDs == key.readinessReceiptIDs
            && Self.isLowercaseSHA256(key.artifactIdentitySHA256)
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= Character("0").asciiValue! && byte <= Character("9").asciiValue!)
                || (byte >= Character("a").asciiValue!
                    && byte <= Character("f").asciiValue!)
        }
    }
}

struct RAGCachedSemanticCandidate: Codable, Equatable, Sendable {
    let chunkID: String
    let documentID: String
    let similarity: Double
}

/// The sole cached RAG payload. It cannot represent a prompt, source excerpt,
/// generated answer, credential, filename, readiness receipt, or legal result.
struct RAGSemanticCandidateCacheValue: Codable, Equatable, Sendable {
    let candidates: [RAGCachedSemanticCandidate]
}

struct RAGCacheSnapshot: Equatable, Sendable {
    let entryCount: Int
    let totalBytes: Int
    let maximumBytes: Int
}

enum RAGCacheMemoryPressure: Sendable {
    case warning
    case critical
}

/// A deterministic, byte-costed in-memory LRU. Costs are supplied by the owner
/// because generic Swift values do not expose their retained heap allocation.
final class ByteCostedRAGCache<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    private struct Entry {
        let value: Value
        let byteCost: Int
        var lastAccess: UInt64
    }

    private let lock = NSLock()
    private let maximumBytes: Int
    private var entries: [Key: Entry] = [:]
    private var totalBytes = 0
    private var accessClock: UInt64 = 0

    init(maximumBytes: Int) {
        self.maximumBytes = max(0, maximumBytes)
    }

    @discardableResult
    func insert(_ value: Value, for key: Key, byteCost: Int) -> Bool {
        guard byteCost >= 0, byteCost <= maximumBytes else { return false }
        return lock.withLock {
            if let existing = entries.removeValue(forKey: key) {
                totalBytes -= existing.byteCost
            }
            while totalBytes + byteCost > maximumBytes,
                  let victim = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess }) {
                entries.removeValue(forKey: victim.key)
                totalBytes -= victim.value.byteCost
            }
            guard totalBytes + byteCost <= maximumBytes else { return false }
            entries[key] = Entry(
                value: value,
                byteCost: byteCost,
                lastAccess: nextAccessLocked()
            )
            totalBytes += byteCost
            return true
        }
    }

    func value(
        for key: Key,
        validation: (Value) -> Bool = { _ in true }
    ) -> Value? {
        lock.withLock {
            guard var entry = entries[key] else { return nil }
            guard validation(entry.value) else {
                entries.removeValue(forKey: key)
                totalBytes -= entry.byteCost
                return nil
            }
            entry.lastAccess = nextAccessLocked()
            entries[key] = entry
            return entry.value
        }
    }

    func removeAll() {
        lock.withLock {
            entries.removeAll(keepingCapacity: false)
            totalBytes = 0
        }
    }

    func handleMemoryPressure(_ pressure: RAGCacheMemoryPressure) {
        switch pressure {
        case .warning, .critical:
            removeAll()
        }
    }

    func snapshot() -> RAGCacheSnapshot {
        lock.withLock {
            RAGCacheSnapshot(
                entryCount: entries.count,
                totalBytes: totalBytes,
                maximumBytes: maximumBytes
            )
        }
    }

    private func nextAccessLocked() -> UInt64 {
        if accessClock == .max {
            let ordered = entries.sorted { lhs, rhs in
                lhs.value.lastAccess < rhs.value.lastAccess
            }
            for (offset, item) in ordered.enumerated() {
                entries[item.key]?.lastAccess = UInt64(offset)
            }
            accessClock = UInt64(ordered.count)
        } else {
            accessClock += 1
        }
        return accessClock
    }
}

protocol RAGSemanticCandidateCacheBackend: Sendable {
    func load(
        for key: RAGDerivedCacheKey,
        access: RAGDerivedCacheAccess
    ) throws -> RAGSemanticCandidateCacheValue?

    func store(
        _ value: RAGSemanticCandidateCacheValue,
        for key: RAGDerivedCacheKey,
        access: RAGDerivedCacheAccess
    ) throws
}

final class RAGSemanticCandidateCache: RAGSemanticCandidateCacheBackend, @unchecked Sendable {
    static let defaultMaximumBytes = 1_048_576

    private let storage: ByteCostedRAGCache<RAGDerivedCacheKey, RAGSemanticCandidateCacheValue>

    init(maximumBytes: Int = defaultMaximumBytes) {
        storage = ByteCostedRAGCache(maximumBytes: maximumBytes)
    }

    func load(
        for key: RAGDerivedCacheKey,
        access: RAGDerivedCacheAccess
    ) throws -> RAGSemanticCandidateCacheValue? {
        guard access.authorizes(key) else { return nil }
        return storage.value(for: key) { Self.valid($0, for: key) }
    }

    func store(
        _ value: RAGSemanticCandidateCacheValue,
        for key: RAGDerivedCacheKey,
        access: RAGDerivedCacheAccess
    ) throws {
        guard access.authorizes(key), Self.valid(value, for: key) else { return }
        _ = storage.insert(value, for: key, byteCost: Self.byteCost(of: value, for: key))
    }

    func handleMemoryPressure(_ pressure: RAGCacheMemoryPressure) {
        storage.handleMemoryPressure(pressure)
    }

    func snapshot() -> RAGCacheSnapshot {
        storage.snapshot()
    }

    private static func valid(
        _ value: RAGSemanticCandidateCacheValue,
        for key: RAGDerivedCacheKey
    ) -> Bool {
        guard key.candidateLimit > 0,
              value.candidates.count <= key.candidateLimit else { return false }
        let allowedDocuments = Set(key.documentIDs)
        var seenChunkIDs: Set<String> = []
        var previous: RAGCachedSemanticCandidate?
        for candidate in value.candidates {
            guard !candidate.chunkID.isEmpty,
                  allowedDocuments.contains(candidate.documentID),
                  seenChunkIDs.insert(candidate.chunkID).inserted,
                  candidate.similarity.isFinite,
                  candidate.similarity >= key.minimumSimilarity,
                  candidate.similarity <= 1.001 else { return false }
            if let previous {
                guard previous.similarity > candidate.similarity
                    || (previous.similarity == candidate.similarity
                        && previous.chunkID < candidate.chunkID) else { return false }
            }
            previous = candidate
        }
        return true
    }

    private static func byteCost(
        of value: RAGSemanticCandidateCacheValue,
        for key: RAGDerivedCacheKey
    ) -> Int {
        var total = 0
        let strings = [
            key.querySHA256,
            key.matterID,
            key.embeddingModel.id,
            key.embeddingModel.repoID,
            key.embeddingModel.revision ?? "",
            key.artifactIdentitySHA256,
            key.retrievalDepth,
        ] + key.documentIDs + key.readinessReceiptIDs
        for string in strings {
            let addition = string.utf8.count.addingReportingOverflow(8)
            guard !addition.overflow else { return .max }
            let next = total.addingReportingOverflow(addition.partialValue)
            guard !next.overflow else { return .max }
            total = next.partialValue
        }
        for candidate in value.candidates {
            let addition = candidate.chunkID.utf8.count
                + candidate.documentID.utf8.count
                + MemoryLayout<Double>.size
                + 16
            let next = total.addingReportingOverflow(addition)
            guard !next.overflow else { return .max }
            total = next.partialValue
        }
        let numericBytes = 6 * MemoryLayout<Int>.size + MemoryLayout<Double>.size
        let final = total.addingReportingOverflow(numericBytes)
        return final.overflow ? .max : final.partialValue
    }
}

enum RAGCacheResolutionSource: Equatable, Sendable {
    case cache
    case computed
}

struct RAGSemanticCandidateCacheResolution: Equatable, Sendable {
    let value: RAGSemanticCandidateCacheValue
    let source: RAGCacheResolutionSource
}

/// Cache failure is deliberately non-authoritative. Store/runtime computation
/// remains the source of truth, and successful computation survives a cache
/// read or write failure.
struct RAGSemanticCandidateCacheResolver: Sendable {
    private let cache: any RAGSemanticCandidateCacheBackend

    init(cache: any RAGSemanticCandidateCacheBackend) {
        self.cache = cache
    }

    func resolve(
        key: RAGDerivedCacheKey,
        access: RAGDerivedCacheAccess,
        compute: () async throws -> RAGSemanticCandidateCacheValue
    ) async throws -> RAGSemanticCandidateCacheResolution {
        guard let resolution = try await resolveIfAvailable(
            key: key,
            access: access,
            compute: { try await compute() }
        ) else {
            preconditionFailure("A nonoptional cache computation returned no value.")
        }
        return resolution
    }

    func resolveIfAvailable(
        key: RAGDerivedCacheKey,
        access: RAGDerivedCacheAccess,
        compute: () async throws -> RAGSemanticCandidateCacheValue?
    ) async throws -> RAGSemanticCandidateCacheResolution? {
        if let cached = try? cache.load(for: key, access: access) {
            return RAGSemanticCandidateCacheResolution(value: cached, source: .cache)
        }
        guard let computed = try await compute() else { return nil }
        try? cache.store(computed, for: key, access: access)
        return RAGSemanticCandidateCacheResolution(value: computed, source: .computed)
    }
}
