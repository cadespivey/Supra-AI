import Foundation
import SupraDiagnostics

/// Exact installed artifact identity bound to a native RAG control run.
public struct NativeRAGControlArtifactBinding: Codable, Equatable, Sendable {
    public var repositoryID: String
    public var revision: String
    public var artifactIdentitySHA256: String

    public init(repositoryID: String, revision: String, artifactIdentitySHA256: String) {
        self.repositoryID = repositoryID
        self.revision = revision
        self.artifactIdentitySHA256 = artifactIdentitySHA256
    }
}

public struct NativeRAGControlImportSummary: Codable, Equatable, Sendable {
    public var discovered: Int
    public var imported: Int
    public var failed: Int
    public var indexedDocuments: Int

    public init(discovered: Int, imported: Int, failed: Int, indexedDocuments: Int) {
        self.discovered = discovered
        self.imported = imported
        self.failed = failed
        self.indexedDocuments = indexedDocuments
    }
}

/// One raw retrieved passage. Synthetic excerpts and filenames are intentionally
/// retained so the deterministic evaluator can be re-run without trusting a
/// precomputed score.
public struct NativeRAGControlCandidate: Codable, Equatable, Sendable {
    public var artifactID: String?
    public var documentName: String
    public var locator: String
    public var excerpt: String
    public var rank: Int
    public var score: Double
    public var ftsMatched: Bool
    public var semanticBucket: String?

    public init(
        artifactID: String?,
        documentName: String,
        locator: String,
        excerpt: String,
        rank: Int,
        score: Double,
        ftsMatched: Bool,
        semanticBucket: String?
    ) {
        self.artifactID = artifactID
        self.documentName = documentName
        self.locator = locator
        self.excerpt = excerpt
        self.rank = rank
        self.score = score
        self.ftsMatched = ftsMatched
        self.semanticBucket = semanticBucket
    }
}

/// One source actually persisted with the generated answer after reranking and
/// token packing. This is distinct from the retrieval candidate list.
public struct NativeRAGControlPackedSource: Codable, Equatable, Sendable {
    public var artifactID: String?
    public var citationLabel: String
    public var locator: String
    public var excerpt: String

    public init(
        artifactID: String?,
        citationLabel: String,
        locator: String,
        excerpt: String
    ) {
        self.artifactID = artifactID
        self.citationLabel = citationLabel
        self.locator = locator
        self.excerpt = excerpt
    }
}

public struct NativeRAGControlQueryRecord: Codable, Equatable, Sendable {
    public var queryID: String
    public var scopeArtifactIDs: [String]
    public var coldRetrievalMilliseconds: Int
    public var warmRetrievalMilliseconds: Int
    public var coldExecutionReceipt: RAGExecutionReceipt?
    public var warmExecutionReceipt: RAGExecutionReceipt?
    public var coldCandidates: [NativeRAGControlCandidate]
    public var warmCandidates: [NativeRAGControlCandidate]
    public var totalLatencyMilliseconds: Int?
    public var timeToFirstTokenMilliseconds: Int?
    public var answerMarkdown: String?
    public var status: String
    public var unsupported: Bool
    public var failure: String?
    public var warnings: [String]
    public var citationLabels: [String]
    public var packedSources: [NativeRAGControlPackedSource]

    public init(
        queryID: String,
        scopeArtifactIDs: [String],
        coldRetrievalMilliseconds: Int,
        warmRetrievalMilliseconds: Int,
        coldExecutionReceipt: RAGExecutionReceipt?,
        warmExecutionReceipt: RAGExecutionReceipt?,
        coldCandidates: [NativeRAGControlCandidate],
        warmCandidates: [NativeRAGControlCandidate],
        totalLatencyMilliseconds: Int?,
        timeToFirstTokenMilliseconds: Int?,
        answerMarkdown: String?,
        status: String,
        unsupported: Bool,
        failure: String?,
        warnings: [String],
        citationLabels: [String],
        packedSources: [NativeRAGControlPackedSource]
    ) {
        self.queryID = queryID
        self.scopeArtifactIDs = scopeArtifactIDs
        self.coldRetrievalMilliseconds = coldRetrievalMilliseconds
        self.warmRetrievalMilliseconds = warmRetrievalMilliseconds
        self.coldExecutionReceipt = coldExecutionReceipt
        self.warmExecutionReceipt = warmExecutionReceipt
        self.coldCandidates = coldCandidates
        self.warmCandidates = warmCandidates
        self.totalLatencyMilliseconds = totalLatencyMilliseconds
        self.timeToFirstTokenMilliseconds = timeToFirstTokenMilliseconds
        self.answerMarkdown = answerMarkdown
        self.status = status
        self.unsupported = unsupported
        self.failure = failure
        self.warnings = warnings
        self.citationLabels = citationLabels
        self.packedSources = packedSources
    }
}

/// Absolute physical-footprint observations. Combined peak is the conservative
/// sum of the independent app and XPC peaks, not a claim that both peaked in the
/// same sampling instant.
public struct NativeRAGControlMemoryRecord: Codable, Equatable, Sendable {
    public var appCurrentPhysFootprintBytes: UInt64
    public var appPeakPhysFootprintBytes: UInt64
    public var xpcCurrentPhysFootprintBytes: UInt64
    public var xpcPeakPhysFootprintBytes: UInt64
    public var combinedCurrentPhysFootprintBytes: UInt64
    public var combinedPeakPhysFootprintBytes: UInt64
    public var maximumLiveSemanticCacheBytes: UInt64

    public init(
        appCurrentPhysFootprintBytes: UInt64,
        appPeakPhysFootprintBytes: UInt64,
        xpcCurrentPhysFootprintBytes: UInt64,
        xpcPeakPhysFootprintBytes: UInt64,
        combinedCurrentPhysFootprintBytes: UInt64,
        combinedPeakPhysFootprintBytes: UInt64,
        maximumLiveSemanticCacheBytes: UInt64
    ) {
        self.appCurrentPhysFootprintBytes = appCurrentPhysFootprintBytes
        self.appPeakPhysFootprintBytes = appPeakPhysFootprintBytes
        self.xpcCurrentPhysFootprintBytes = xpcCurrentPhysFootprintBytes
        self.xpcPeakPhysFootprintBytes = xpcPeakPhysFootprintBytes
        self.combinedCurrentPhysFootprintBytes = combinedCurrentPhysFootprintBytes
        self.combinedPeakPhysFootprintBytes = combinedPeakPhysFootprintBytes
        self.maximumLiveSemanticCacheBytes = maximumLiveSemanticCacheBytes
    }
}

/// Content-complete raw output from the signed app/XPC control. It deliberately
/// carries no pass/fail decision: deterministic scoring and owner-approved
/// thresholds remain separate authority boundaries.
public struct NativeRAGControlRunRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var controlID: String
    public var sourceCommitSHA: String
    public var corpusManifestSHA256: String
    public var corpusID: String
    public var corpusVersion: String
    public var chatModel: NativeRAGControlArtifactBinding
    public var embeddingModel: NativeRAGControlArtifactBinding
    public var startedAt: Date
    public var completedAt: Date
    public var importSummary: NativeRAGControlImportSummary
    public var queries: [NativeRAGControlQueryRecord]
    public var memory: NativeRAGControlMemoryRecord

    public init(
        controlID: String,
        sourceCommitSHA: String,
        corpusManifestSHA256: String,
        corpusID: String,
        corpusVersion: String,
        chatModel: NativeRAGControlArtifactBinding,
        embeddingModel: NativeRAGControlArtifactBinding,
        startedAt: Date,
        completedAt: Date,
        importSummary: NativeRAGControlImportSummary,
        queries: [NativeRAGControlQueryRecord],
        memory: NativeRAGControlMemoryRecord
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.controlID = controlID
        self.sourceCommitSHA = sourceCommitSHA
        self.corpusManifestSHA256 = corpusManifestSHA256
        self.corpusID = corpusID
        self.corpusVersion = corpusVersion
        self.chatModel = chatModel
        self.embeddingModel = embeddingModel
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.importSummary = importSummary
        self.queries = queries
        self.memory = memory
    }
}
