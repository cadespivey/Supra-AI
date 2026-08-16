import CryptoKit
import Foundation

public enum RAGExecutionCacheDisposition: String, Codable, Equatable, Sendable {
    case computed
    case hit
    case bypassed
}

public enum RAGExecutionScoreBucket: String, Codable, Equatable, Sendable {
    case high
    case medium
    case low
}

public struct RAGExecutionSemanticFacts: Codable, Equatable, Sendable {
    public let pageSize: Int
    public let candidateLimit: Int
    public let pageCount: Int
    public let scannedRows: Int
    public let rejectedRows: Int
    public let maximumLivePageRows: Int
    public let maximumHeapEntries: Int
    public let maximumLiveVectorBytes: Int
    public let cacheDisposition: RAGExecutionCacheDisposition

    public init(
        pageSize: Int,
        candidateLimit: Int,
        pageCount: Int,
        scannedRows: Int,
        rejectedRows: Int,
        maximumLivePageRows: Int,
        maximumHeapEntries: Int,
        maximumLiveVectorBytes: Int,
        cacheDisposition: RAGExecutionCacheDisposition
    ) {
        self.pageSize = pageSize
        self.candidateLimit = candidateLimit
        self.pageCount = pageCount
        self.scannedRows = scannedRows
        self.rejectedRows = rejectedRows
        self.maximumLivePageRows = maximumLivePageRows
        self.maximumHeapEntries = maximumHeapEntries
        self.maximumLiveVectorBytes = maximumLiveVectorBytes
        self.cacheDisposition = cacheDisposition
    }

    fileprivate func validate() throws {
        let values = [
            pageSize,
            candidateLimit,
            pageCount,
            scannedRows,
            rejectedRows,
            maximumLivePageRows,
            maximumHeapEntries,
            maximumLiveVectorBytes,
        ]
        guard values.allSatisfy({ $0 >= 0 }),
              rejectedRows <= scannedRows else {
            throw RAGExecutionReceiptError.invalidResourceFacts
        }
        switch cacheDisposition {
        case .computed:
            guard pageSize > 0,
                  candidateLimit > 0,
                  maximumLivePageRows <= pageSize,
                  maximumHeapEntries <= candidateLimit else {
                throw RAGExecutionReceiptError.invalidResourceFacts
            }
        case .hit, .bypassed:
            guard pageCount == 0,
                  scannedRows == 0,
                  rejectedRows == 0,
                  maximumLivePageRows == 0,
                  maximumHeapEntries == 0,
                  maximumLiveVectorBytes == 0 else {
                throw RAGExecutionReceiptError.invalidResourceFacts
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case pageSize = "page_size"
        case candidateLimit = "candidate_limit"
        case pageCount = "page_count"
        case scannedRows = "scanned_rows"
        case rejectedRows = "rejected_rows"
        case maximumLivePageRows = "maximum_live_page_rows"
        case maximumHeapEntries = "maximum_heap_entries"
        case maximumLiveVectorBytes = "maximum_live_vector_bytes"
        case cacheDisposition = "cache_disposition"
    }
}

public struct RAGExecutionRankFact: Codable, Equatable, Sendable {
    public let candidateIdentitySHA256: String
    public let rank: Int
    public let scoreBucket: RAGExecutionScoreBucket
    public let selected: Bool

    public init(
        candidateIdentitySHA256: String,
        rank: Int,
        scoreBucket: RAGExecutionScoreBucket,
        selected: Bool
    ) {
        self.candidateIdentitySHA256 = candidateIdentitySHA256
        self.rank = rank
        self.scoreBucket = scoreBucket
        self.selected = selected
    }

    private enum CodingKeys: String, CodingKey {
        case candidateIdentitySHA256 = "candidate_identity_sha256"
        case rank
        case scoreBucket = "score_bucket"
        case selected
    }
}

/// A whitelist-only operational receipt. It is intentionally insufficient to
/// establish readiness, provenance, legal authority, egress approval, or the
/// completion of any legal aggregate.
public struct RAGExecutionReceipt: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let receiptID: String
    public let schemaVersion: Int
    public let executionID: String
    public let retrievalAlgorithmVersion: Int
    public let querySHA256: String
    public let scopeSHA256: String
    public let readinessReceiptSetSHA256: String
    public let embeddingArtifactIdentitySHA256: String?
    public let chunkerVersion: Int
    public let retrievalDepth: String
    public let startedAtUnixMilliseconds: Int64
    public let elapsedMilliseconds: Int
    public let lexicalCandidateCount: Int
    public let semantic: RAGExecutionSemanticFacts
    public let ranks: [RAGExecutionRankFact]

    public init(
        executionID: String,
        retrievalAlgorithmVersion: Int,
        querySHA256: String,
        scopeSHA256: String,
        readinessReceiptSetSHA256: String,
        embeddingArtifactIdentitySHA256: String?,
        chunkerVersion: Int,
        retrievalDepth: String,
        startedAtUnixMilliseconds: Int64,
        elapsedMilliseconds: Int,
        lexicalCandidateCount: Int,
        semantic: RAGExecutionSemanticFacts,
        ranks: [RAGExecutionRankFact]
    ) throws {
        guard Self.isOpaqueIdentifier(executionID) else {
            throw RAGExecutionReceiptError.invalidExecutionID
        }
        guard retrievalAlgorithmVersion > 0,
              chunkerVersion > 0,
              startedAtUnixMilliseconds >= 0,
              elapsedMilliseconds >= 0,
              lexicalCandidateCount >= 0,
              retrievalDepth == "fast" || retrievalDepth == "deep" else {
            throw RAGExecutionReceiptError.invalidVersionOrTiming
        }
        guard Self.isSHA256(querySHA256),
              Self.isSHA256(scopeSHA256),
              Self.isSHA256(readinessReceiptSetSHA256),
              embeddingArtifactIdentitySHA256.map(Self.isSHA256) ?? true else {
            throw RAGExecutionReceiptError.invalidDigest
        }
        try semantic.validate()
        guard ranks.enumerated().allSatisfy({ offset, fact in
            fact.rank == offset + 1 && Self.isSHA256(fact.candidateIdentitySHA256)
        }) else {
            throw RAGExecutionReceiptError.invalidRankFacts
        }

        let payload = Payload(
            schemaVersion: Self.currentSchemaVersion,
            executionID: executionID,
            retrievalAlgorithmVersion: retrievalAlgorithmVersion,
            querySHA256: querySHA256,
            scopeSHA256: scopeSHA256,
            readinessReceiptSetSHA256: readinessReceiptSetSHA256,
            embeddingArtifactIdentitySHA256: embeddingArtifactIdentitySHA256,
            chunkerVersion: chunkerVersion,
            retrievalDepth: retrievalDepth,
            startedAtUnixMilliseconds: startedAtUnixMilliseconds,
            elapsedMilliseconds: elapsedMilliseconds,
            lexicalCandidateCount: lexicalCandidateCount,
            semantic: semantic,
            ranks: ranks
        )
        self.receiptID = try Self.digest(payload)
        self.schemaVersion = Self.currentSchemaVersion
        self.executionID = executionID
        self.retrievalAlgorithmVersion = retrievalAlgorithmVersion
        self.querySHA256 = querySHA256
        self.scopeSHA256 = scopeSHA256
        self.readinessReceiptSetSHA256 = readinessReceiptSetSHA256
        self.embeddingArtifactIdentitySHA256 = embeddingArtifactIdentitySHA256
        self.chunkerVersion = chunkerVersion
        self.retrievalDepth = retrievalDepth
        self.startedAtUnixMilliseconds = startedAtUnixMilliseconds
        self.elapsedMilliseconds = elapsedMilliseconds
        self.lexicalCandidateCount = lexicalCandidateCount
        self.semantic = semantic
        self.ranks = ranks
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encodedReceiptID = try container.decode(String.self, forKey: .receiptID)
        let encodedSchemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard encodedSchemaVersion == Self.currentSchemaVersion else {
            throw RAGExecutionReceiptError.invalidVersionOrTiming
        }
        try self.init(
            executionID: container.decode(String.self, forKey: .executionID),
            retrievalAlgorithmVersion: container.decode(
                Int.self,
                forKey: .retrievalAlgorithmVersion
            ),
            querySHA256: container.decode(String.self, forKey: .querySHA256),
            scopeSHA256: container.decode(String.self, forKey: .scopeSHA256),
            readinessReceiptSetSHA256: container.decode(
                String.self,
                forKey: .readinessReceiptSetSHA256
            ),
            embeddingArtifactIdentitySHA256: container.decodeIfPresent(
                String.self,
                forKey: .embeddingArtifactIdentitySHA256
            ),
            chunkerVersion: container.decode(Int.self, forKey: .chunkerVersion),
            retrievalDepth: container.decode(String.self, forKey: .retrievalDepth),
            startedAtUnixMilliseconds: container.decode(
                Int64.self,
                forKey: .startedAtUnixMilliseconds
            ),
            elapsedMilliseconds: container.decode(Int.self, forKey: .elapsedMilliseconds),
            lexicalCandidateCount: container.decode(Int.self, forKey: .lexicalCandidateCount),
            semantic: container.decode(RAGExecutionSemanticFacts.self, forKey: .semantic),
            ranks: container.decode([RAGExecutionRankFact].self, forKey: .ranks)
        )
        guard Self.constantTimeEqual(receiptID, encodedReceiptID) else {
            throw RAGExecutionReceiptError.receiptDigestMismatch
        }
    }

    private struct Payload: Codable {
        let schemaVersion: Int
        let executionID: String
        let retrievalAlgorithmVersion: Int
        let querySHA256: String
        let scopeSHA256: String
        let readinessReceiptSetSHA256: String
        let embeddingArtifactIdentitySHA256: String?
        let chunkerVersion: Int
        let retrievalDepth: String
        let startedAtUnixMilliseconds: Int64
        let elapsedMilliseconds: Int
        let lexicalCandidateCount: Int
        let semantic: RAGExecutionSemanticFacts
        let ranks: [RAGExecutionRankFact]
    }

    private static func digest(_ payload: Payload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(payload))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isOpaqueIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy { byte in
            (byte >= Character("a").asciiValue! && byte <= Character("z").asciiValue!)
                || (byte >= Character("A").asciiValue!
                    && byte <= Character("Z").asciiValue!)
                || (byte >= Character("0").asciiValue!
                    && byte <= Character("9").asciiValue!)
                || byte == Character("-").asciiValue!
                || byte == Character("_").asciiValue!
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= Character("0").asciiValue! && byte <= Character("9").asciiValue!)
                || (byte >= Character("a").asciiValue!
                    && byte <= Character("f").asciiValue!)
        }
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }

    private enum CodingKeys: String, CodingKey {
        case receiptID = "receipt_id"
        case schemaVersion = "schema_version"
        case executionID = "execution_id"
        case retrievalAlgorithmVersion = "retrieval_algorithm_version"
        case querySHA256 = "query_sha256"
        case scopeSHA256 = "scope_sha256"
        case readinessReceiptSetSHA256 = "readiness_receipt_set_sha256"
        case embeddingArtifactIdentitySHA256 = "embedding_artifact_identity_sha256"
        case chunkerVersion = "chunker_version"
        case retrievalDepth = "retrieval_depth"
        case startedAtUnixMilliseconds = "started_at_unix_milliseconds"
        case elapsedMilliseconds = "elapsed_milliseconds"
        case lexicalCandidateCount = "lexical_candidate_count"
        case semantic
        case ranks
    }
}

public enum RAGExecutionReceiptError: Error, Equatable, Sendable {
    case invalidExecutionID
    case invalidVersionOrTiming
    case invalidDigest
    case invalidResourceFacts
    case invalidRankFacts
    case receiptDigestMismatch
}

public struct RAGExecutionReceiptAdvancedExporter: Sendable {
    public init() {}

    public func render(_ receipts: [RAGExecutionReceipt]) throws -> Data {
        let envelope = ExportEnvelope(
            exportSchemaVersion: 1,
            redaction: "content_free_v1",
            receipts: receipts
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(envelope)
    }

    private struct ExportEnvelope: Codable {
        let exportSchemaVersion: Int
        let redaction: String
        let receipts: [RAGExecutionReceipt]

        private enum CodingKeys: String, CodingKey {
            case exportSchemaVersion = "export_schema_version"
            case redaction
            case receipts
        }
    }
}
