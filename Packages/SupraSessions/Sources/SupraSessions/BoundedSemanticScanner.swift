import Foundation
import SupraStore

struct BoundedSemanticScanConfiguration: Sendable, Equatable {
    let pageSize: Int
    let candidateLimit: Int
    let minimumSimilarity: Double

    init(pageSize: Int, candidateLimit: Int, minimumSimilarity: Double) {
        self.pageSize = pageSize
        self.candidateLimit = candidateLimit
        self.minimumSimilarity = minimumSimilarity
    }
}

struct BoundedSemanticScanCandidate: Sendable, Equatable {
    let chunkID: String
    let documentID: String
    let similarity: Double
}

struct BoundedSemanticScanMetrics: Sendable, Equatable {
    let pageSize: Int
    let candidateLimit: Int
    let pageCount: Int
    let scannedRows: Int
    let rejectedRows: Int
    let maximumLivePageRows: Int
    let maximumHeapEntries: Int
    let maximumLiveVectorBytes: Int
}

struct BoundedSemanticScanResult: Sendable, Equatable {
    let candidates: [BoundedSemanticScanCandidate]
    let metrics: BoundedSemanticScanMetrics
}

struct BoundedSemanticScanResourceSnapshot: Sendable, Equatable {
    let currentPageRows: Int
    let currentHeapEntries: Int
    let currentLiveBytes: Int
    let scannedRows: Int
    let rejectedRows: Int
    let maximumLivePageRows: Int
    let maximumHeapEntries: Int
    let maximumLiveVectorBytes: Int
}

/// Testable operational accounting for the bounded in-process scan. It carries
/// counts only—never query text, source text, filenames, or vector values.
final class BoundedSemanticScanInstrumentation: @unchecked Sendable {
    private struct State {
        var currentPageRows = 0
        var currentHeapEntries = 0
        var currentLiveBytes = 0
        var scannedRows = 0
        var rejectedRows = 0
        var maximumLivePageRows = 0
        var maximumHeapEntries = 0
        var maximumLiveVectorBytes = 0
    }

    private let lock = NSLock()
    private var state = State()

    func beginPage(rows: Int, vectorBytes: Int, heapEntries: Int) {
        lock.withLock {
            state.currentPageRows = rows
            state.currentHeapEntries = heapEntries
            state.currentLiveBytes = vectorBytes
            state.maximumLivePageRows = max(state.maximumLivePageRows, rows)
            state.maximumHeapEntries = max(state.maximumHeapEntries, heapEntries)
            state.maximumLiveVectorBytes = max(state.maximumLiveVectorBytes, vectorBytes)
        }
    }

    func recordRow(rejected: Bool, heapEntries: Int) {
        lock.withLock {
            state.scannedRows += 1
            if rejected { state.rejectedRows += 1 }
            state.currentHeapEntries = heapEntries
            state.maximumHeapEntries = max(state.maximumHeapEntries, heapEntries)
        }
    }

    func releaseCurrentState() {
        lock.withLock {
            state.currentPageRows = 0
            state.currentHeapEntries = 0
            state.currentLiveBytes = 0
        }
    }

    func snapshot() -> BoundedSemanticScanResourceSnapshot {
        lock.withLock {
            BoundedSemanticScanResourceSnapshot(
                currentPageRows: state.currentPageRows,
                currentHeapEntries: state.currentHeapEntries,
                currentLiveBytes: state.currentLiveBytes,
                scannedRows: state.scannedRows,
                rejectedRows: state.rejectedRows,
                maximumLivePageRows: state.maximumLivePageRows,
                maximumHeapEntries: state.maximumHeapEntries,
                maximumLiveVectorBytes: state.maximumLiveVectorBytes
            )
        }
    }
}

enum BoundedSemanticScanError: Error, LocalizedError, Equatable, Sendable {
    case invalidPageSize(Int)
    case invalidCandidateLimit(Int)
    case invalidQueryDimension(expected: Int, actual: Int)
    case invalidQueryVector

    var errorDescription: String? {
        switch self {
        case .invalidPageSize(let size):
            "Semantic scan page size \(size) must be positive."
        case .invalidCandidateLimit(let limit):
            "Semantic candidate limit \(limit) must be positive."
        case .invalidQueryDimension(let expected, let actual):
            "Semantic query dimension \(actual) does not match model dimension \(expected)."
        case .invalidQueryVector:
            "Semantic query vector must contain finite values with nonzero magnitude."
        }
    }
}

/// Streams Store-filtered vector pages through a fixed-size worst-at-root heap.
/// Only the winning chunk/document identities survive; source text and
/// structure are hydrated later by `DocumentRetrievalService`.
struct BoundedSemanticScanner: Sendable {
    private let store: SupraStore
    private let instrumentation: BoundedSemanticScanInstrumentation

    init(
        store: SupraStore,
        instrumentation: BoundedSemanticScanInstrumentation = .init()
    ) {
        self.store = store
        self.instrumentation = instrumentation
    }

    func scan(
        matterID: String,
        documentIDs: [String],
        queryVector: [Float],
        activeModel: DocumentReadinessEmbeddingModelIdentity,
        configuration: BoundedSemanticScanConfiguration,
        cancellationCheck: @Sendable () throws -> Void = { try Task.checkCancellation() }
    ) throws -> BoundedSemanticScanResult {
        guard configuration.pageSize > 0 else {
            throw BoundedSemanticScanError.invalidPageSize(configuration.pageSize)
        }
        guard configuration.candidateLimit > 0 else {
            throw BoundedSemanticScanError.invalidCandidateLimit(configuration.candidateLimit)
        }
        guard queryVector.count == activeModel.dimension else {
            throw BoundedSemanticScanError.invalidQueryDimension(
                expected: activeModel.dimension,
                actual: queryVector.count
            )
        }
        let queryNormSquared = queryVector.reduce(Float(0)) { partial, value in
            partial + value * value
        }
        guard queryNormSquared.isFinite,
              queryNormSquared > 0,
              queryVector.allSatisfy(\.isFinite) else {
            throw BoundedSemanticScanError.invalidQueryVector
        }
        let inverseNorm = 1 / sqrt(queryNormSquared)
        let normalizedQuery = queryVector.map { $0 * inverseNorm }

        var heap = FixedSemanticCandidateHeap(capacity: configuration.candidateLimit)
        var cursor: DocumentEmbeddingScanCursor?
        var pageCount = 0
        defer { instrumentation.releaseCurrentState() }

        repeat {
            try cancellationCheck()
            let page = try store.documentIndex.fetchEmbeddingScanPage(
                matterID: matterID,
                documentIDs: documentIDs,
                activeModel: activeModel,
                pageSize: configuration.pageSize,
                after: cursor
            )
            pageCount += 1
            let pageBytes = page.entries.reduce(0) { $0 + $1.vector.count }
            instrumentation.beginPage(
                rows: page.entries.count,
                vectorBytes: pageBytes,
                heapEntries: heap.count
            )
            for entry in page.entries {
                try cancellationCheck()
                guard let similarity = Self.validatedSimilarity(
                    query: normalizedQuery,
                    entry: entry,
                    expectedDimension: activeModel.dimension
                ), similarity >= configuration.minimumSimilarity else {
                    instrumentation.recordRow(rejected: true, heapEntries: heap.count)
                    continue
                }
                heap.insert(
                    BoundedSemanticScanCandidate(
                        chunkID: entry.chunkID,
                        documentID: entry.documentID,
                        similarity: similarity
                    )
                )
                instrumentation.recordRow(rejected: false, heapEntries: heap.count)
            }
            cursor = page.nextCursor
            instrumentation.releaseCurrentState()
        } while cursor != nil

        try cancellationCheck()
        let snapshot = instrumentation.snapshot()
        return BoundedSemanticScanResult(
            candidates: heap.sortedBestFirst(),
            metrics: BoundedSemanticScanMetrics(
                pageSize: configuration.pageSize,
                candidateLimit: configuration.candidateLimit,
                pageCount: pageCount,
                scannedRows: snapshot.scannedRows,
                rejectedRows: snapshot.rejectedRows,
                maximumLivePageRows: snapshot.maximumLivePageRows,
                maximumHeapEntries: snapshot.maximumHeapEntries,
                maximumLiveVectorBytes: snapshot.maximumLiveVectorBytes
            )
        )
    }

    private static func validatedSimilarity(
        query: [Float],
        entry: DocumentEmbeddingScanEntry,
        expectedDimension: Int
    ) -> Double? {
        guard entry.dimension == expectedDimension else { return nil }
        let expectedBytes = expectedDimension.multipliedReportingOverflow(
            by: MemoryLayout<UInt32>.size
        )
        guard !expectedBytes.overflow,
              entry.vector.count == expectedBytes.partialValue else { return nil }
        return entry.vector.withUnsafeBytes { bytes -> Double? in
            var dot = 0.0
            var normSquared = 0.0
            for index in 0..<expectedDimension {
                let stored = bytes.loadUnaligned(
                    fromByteOffset: index * MemoryLayout<UInt32>.size,
                    as: UInt32.self
                )
                let value = Float(bitPattern: UInt32(littleEndian: stored))
                guard value.isFinite else { return nil }
                dot += Double(query[index]) * Double(value)
                normSquared += Double(value) * Double(value)
            }
            guard dot.isFinite,
                  normSquared.isFinite,
                  abs(normSquared - 1) <= 0.001 else { return nil }
            return dot
        }
    }
}

private struct FixedSemanticCandidateHeap {
    private let capacity: Int
    private var storage: [BoundedSemanticScanCandidate] = []

    init(capacity: Int) {
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    var count: Int { storage.count }

    mutating func insert(_ candidate: BoundedSemanticScanCandidate) {
        guard capacity > 0 else { return }
        if storage.count < capacity {
            storage.append(candidate)
            siftUp(from: storage.count - 1)
            return
        }
        guard let worst = storage.first,
              Self.isBetter(candidate, than: worst) else { return }
        storage[0] = candidate
        siftDown(from: 0)
    }

    func sortedBestFirst() -> [BoundedSemanticScanCandidate] {
        storage.sorted(by: Self.isBetter)
    }

    private mutating func siftUp(from start: Int) {
        var child = start
        while child > 0 {
            let parent = (child - 1) / 2
            guard Self.isWorse(storage[child], than: storage[parent]) else { break }
            storage.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(from start: Int) {
        var parent = start
        while true {
            let left = parent * 2 + 1
            guard left < storage.count else { return }
            let right = left + 1
            var worseChild = left
            if right < storage.count,
               Self.isWorse(storage[right], than: storage[left]) {
                worseChild = right
            }
            guard Self.isWorse(storage[worseChild], than: storage[parent]) else { return }
            storage.swapAt(parent, worseChild)
            parent = worseChild
        }
    }

    private static func isBetter(
        _ lhs: BoundedSemanticScanCandidate,
        than rhs: BoundedSemanticScanCandidate
    ) -> Bool {
        if lhs.similarity != rhs.similarity { return lhs.similarity > rhs.similarity }
        return lhs.chunkID < rhs.chunkID
    }

    private static func isWorse(
        _ lhs: BoundedSemanticScanCandidate,
        than rhs: BoundedSemanticScanCandidate
    ) -> Bool {
        if lhs.similarity != rhs.similarity { return lhs.similarity < rhs.similarity }
        return lhs.chunkID > rhs.chunkID
    }
}
