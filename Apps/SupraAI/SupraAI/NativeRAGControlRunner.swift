import CryptoKit
import Darwin
import Foundation
import SupraCore
import SupraDocuments
import SupraRuntimeClient
import SupraRuntimeInterface
import SupraSessions
import SupraStore

struct NativeRAGControlInvocation: Sendable {
    let corpusRoot: URL
    let manifestURL: URL
    let outputURL: URL
    let chatRepositoryID: String
    let embeddingRepositoryID: String
    let sourceCommitSHA: String

    static func resolve(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> Self {
        func value(after flag: String) throws -> String {
            let matches = arguments.indices.filter { arguments[$0] == flag }
            guard matches.count == 1,
                  let index = matches.first,
                  arguments.indices.contains(index + 1) else {
                throw NativeRAGControlError.invalidInvocation(flag)
            }
            let value = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { throw NativeRAGControlError.invalidInvocation(flag) }
            return value
        }
        func environmentValue(_ key: String) throws -> String {
            guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { throw NativeRAGControlError.invalidInvocation(key) }
            return value
        }

        let root = URL(fileURLWithPath: try value(after: "-nativeRAGCorpusRoot"), isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let manifest = URL(fileURLWithPath: try value(after: "-nativeRAGManifest"), isDirectory: false)
            .standardizedFileURL.resolvingSymlinksInPath()
        let output = URL(fileURLWithPath: try value(after: "-nativeRAGOutput"), isDirectory: false)
            .standardizedFileURL
        let temporaryRoot = fileManager.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        for candidate in [root, manifest, output.deletingLastPathComponent()] {
            guard candidate.path == temporaryRoot.path
                    || candidate.path.hasPrefix(temporaryRoot.path + "/") else {
                throw NativeRAGControlError.pathOutsideTemporaryContainer(candidate.path)
            }
        }
        let sourceCommit = try environmentValue("SUPRA_RAG_SOURCE_SHA")
        guard sourceCommit.count == 40,
              sourceCommit.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw NativeRAGControlError.invalidInvocation("SUPRA_RAG_SOURCE_SHA")
        }
        return Self(
            corpusRoot: root,
            manifestURL: manifest,
            outputURL: output,
            chatRepositoryID: try environmentValue("SUPRA_RAG_CHAT_REPOSITORY"),
            embeddingRepositoryID: try environmentValue("SUPRA_RAG_EMBEDDING_REPOSITORY"),
            sourceCommitSHA: sourceCommit
        )
    }
}

enum NativeRAGControlError: Error, LocalizedError, Equatable {
    case invalidInvocation(String)
    case pathOutsideTemporaryContainer(String)
    case invalidManifest(String)
    case artifactDigestMismatch(String)
    case chatArtifactMismatch(String)
    case chatModelLoadFailed(String)
    case embeddingProbeFailed(String)
    case importedArtifactMissing(String)
    case runtimeMemoryUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidInvocation(let field): "Native RAG control is missing or duplicates \(field)."
        case .pathOutsideTemporaryContainer(let path):
            "Native RAG control path is outside the app's temporary container: \(path)"
        case .invalidManifest(let reason): "Native RAG control manifest is invalid: \(reason)"
        case .artifactDigestMismatch(let artifact): "Synthetic artifact digest mismatch: \(artifact)"
        case .chatArtifactMismatch(let repository): "Exact chat artifact is unavailable: \(repository)"
        case .chatModelLoadFailed(let detail): "Exact chat artifact failed to load: \(detail)"
        case .embeddingProbeFailed(let detail): "Exact embedding artifact failed its real load probe: \(detail)"
        case .importedArtifactMissing(let artifact): "Imported synthetic artifact is missing: \(artifact)"
        case .runtimeMemoryUnavailable: "App or XPC physical-footprint metrics were unavailable."
        }
    }
}

private struct NativeRAGCorpusManifest: Decodable {
    struct Artifact: Decodable {
        let artifactID: String
        let path: String
        let sha256: String
    }
    struct Query: Decodable {
        let queryID: String
        let prompt: String
        let scopeArtifactIDs: [String]
    }

    let schemaVersion: Int
    let corpusID: String
    let corpusVersion: String
    let containsRealClientData: Bool
    let artifactRoot: String
    let artifacts: [Artifact]
    let queries: [Query]
}

@MainActor
struct NativeRAGControlRunner {
    let store: SupraStore
    let modelLibrary: ModelLibrary
    let runtimeClient: any ModelExecutionGateway

    func run(_ invocation: NativeRAGControlInvocation) async throws -> NativeRAGControlRunRecord {
        let startedAt = Date()
        let manifestData = try Data(contentsOf: invocation.manifestURL)
        let manifest = try JSONDecoder().decode(NativeRAGCorpusManifest.self, from: manifestData)
        try validate(manifest: manifest, root: invocation.corpusRoot)

        let artifactURLs = try manifest.artifacts.map { artifact -> URL in
            let url = invocation.corpusRoot.appendingPathComponent(artifact.path, isDirectory: false)
                .standardizedFileURL.resolvingSymlinksInPath()
            guard url.path.hasPrefix(invocation.corpusRoot.path + "/") else {
                throw NativeRAGControlError.invalidManifest("unsafe artifact path \(artifact.path)")
            }
            let digest = Self.sha256(try Data(contentsOf: url))
            guard digest == artifact.sha256 else {
                throw NativeRAGControlError.artifactDigestMismatch(artifact.artifactID)
            }
            return url
        }

        let embeddingBinding = try await prepareEmbeddingModel(
            repositoryID: invocation.embeddingRepositoryID
        )
        guard let selectedEmbedding = try store.documentSettings.fetchSelectedEmbeddingModel(),
              let embedder = RuntimeTextEmbedder(model: selectedEmbedding, runtimeClient: runtimeClient) else {
            throw NativeRAGControlError.embeddingProbeFailed("selected record could not be reconstructed")
        }

        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SupraAI-NativeRAG-Storage-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let storage = DocumentStorage(root: storageRoot)
        let importer = DocumentImportService(store: store, storage: storage, ocr: VisionOCRService())
        let matter = try store.matters.createMatter(name: "Synthetic Native RAG Control")
        let importOutcome = try await importer.importSources(artifactURLs, matterID: matter.id)
        let indexed = try await DocumentIndexingService(
            store: store,
            embedder: embedder,
            deterministicLegacyChunkIDs: true
        ).indexMatter(matterID: matter.id)

        let documents = try store.documentLibrary.fetchDocuments(matterID: matter.id)
        let artifactByFilename = Dictionary(
            uniqueKeysWithValues: manifest.artifacts.map {
                (URL(fileURLWithPath: $0.path).lastPathComponent, $0)
            }
        )
        var artifactIDByDocumentID: [String: String] = [:]
        var documentIDByArtifactID: [String: String] = [:]
        for document in documents {
            guard let artifact = artifactByFilename[document.displayName] else { continue }
            artifactIDByDocumentID[document.id] = artifact.artifactID
            documentIDByArtifactID[artifact.artifactID] = document.id
        }
        for artifact in manifest.artifacts where documentIDByArtifactID[artifact.artifactID] == nil {
            throw NativeRAGControlError.importedArtifactMissing(artifact.artifactID)
        }

        let (chatModelID, chatBinding, route) = try await prepareChatModel(
            repositoryID: invocation.chatRepositoryID
        )
        let timingGateway = NativeRAGTimingGateway(base: runtimeClient)
        var queryRecords: [NativeRAGControlQueryRecord] = []
        var maximumLiveSemanticCacheBytes = 0
        for query in manifest.queries {
            let scopeDocumentIDs = try query.scopeArtifactIDs.map { artifactID -> String in
                guard let documentID = documentIDByArtifactID[artifactID] else {
                    throw NativeRAGControlError.importedArtifactMissing(artifactID)
                }
                return documentID
            }
            let scope = RetrievalScope(documentIDs: scopeDocumentIDs)
            let retrieval = DocumentRetrievalService(store: store, embedder: embedder)
            let coldStarted = ProcessInfo.processInfo.systemUptime
            let cold = try await retrieval.retrieve(
                matterID: matter.id, query: query.prompt, scope: scope, limit: 40, depth: .deep
            )
            maximumLiveSemanticCacheBytes = max(
                maximumLiveSemanticCacheBytes,
                RAGSemanticCandidateCacheMetrics.liveBytes
            )
            let coldMilliseconds = Self.elapsedMilliseconds(since: coldStarted)
            let warmStarted = ProcessInfo.processInfo.systemUptime
            let warm = try await retrieval.retrieve(
                matterID: matter.id, query: query.prompt, scope: scope, limit: 40, depth: .deep
            )
            maximumLiveSemanticCacheBytes = max(
                maximumLiveSemanticCacheBytes,
                RAGSemanticCandidateCacheMetrics.liveBytes
            )
            let warmMilliseconds = Self.elapsedMilliseconds(since: warmStarted)

            timingGateway.beginQuery()
            let qa = DocumentQAController(
                matterID: matter.id,
                store: store,
                runtimeClient: timingGateway,
                embedder: embedder
            )
            let qaStarted = ProcessInfo.processInfo.systemUptime
            let result = await qa.generate(
                question: query.prompt,
                scope: scope,
                mode: .short,
                modelID: chatModelID,
                modelLineage: modelLibrary.generationLineage(for: chatModelID),
                route: route,
                depth: .deep
            )
            maximumLiveSemanticCacheBytes = max(
                maximumLiveSemanticCacheBytes,
                RAGSemanticCandidateCacheMetrics.liveBytes
            )
            let totalMilliseconds = Self.elapsedMilliseconds(since: qaStarted)
            let packedRows = try result.map {
                try store.documentSources.fetchSources(structuredOutputVersionID: $0.versionID)
            } ?? []
            let packedSources = packedRows.map { row in
                NativeRAGControlPackedSource(
                    artifactID: row.documentID.flatMap { artifactIDByDocumentID[$0] },
                    citationLabel: row.citationLabel,
                    locator: Self.locatorDisplay(row.locatorJSON),
                    excerpt: row.excerpt
                )
            }
            queryRecords.append(NativeRAGControlQueryRecord(
                queryID: query.queryID,
                scopeArtifactIDs: query.scopeArtifactIDs,
                coldRetrievalMilliseconds: coldMilliseconds,
                warmRetrievalMilliseconds: warmMilliseconds,
                coldExecutionReceipt: cold.executionReceipt,
                warmExecutionReceipt: warm.executionReceipt,
                coldCandidates: Self.candidates(cold.sources, artifactIDByDocumentID: artifactIDByDocumentID),
                warmCandidates: Self.candidates(warm.sources, artifactIDByDocumentID: artifactIDByDocumentID),
                totalLatencyMilliseconds: result == nil ? nil : totalMilliseconds,
                timeToFirstTokenMilliseconds: timingGateway.firstAnswerTokenMilliseconds,
                answerMarkdown: result?.markdown,
                status: result?.status ?? "failed",
                unsupported: result?.unsupported ?? true,
                failure: result == nil
                    ? (timingGateway.answerFailureDetail ?? qa.message ?? "generation returned no result")
                    : nil,
                warnings: result?.warnings ?? [],
                citationLabels: result?.citationLabels ?? [],
                packedSources: packedSources
            ))
        }

        let memory = try await memoryRecord(
            maximumLiveSemanticCacheBytes: maximumLiveSemanticCacheBytes
        )
        return NativeRAGControlRunRecord(
            controlID: "native-rag-control-v1",
            sourceCommitSHA: invocation.sourceCommitSHA,
            corpusManifestSHA256: Self.sha256(manifestData),
            corpusID: manifest.corpusID,
            corpusVersion: manifest.corpusVersion,
            chatModel: chatBinding,
            embeddingModel: embeddingBinding,
            startedAt: startedAt,
            completedAt: Date(),
            importSummary: NativeRAGControlImportSummary(
                discovered: importOutcome.report.discoveredCount,
                imported: importOutcome.report.importedCount,
                failed: importOutcome.report.failedCount,
                indexedDocuments: indexed
            ),
            queries: queryRecords,
            memory: memory
        )
    }

    private func validate(manifest: NativeRAGCorpusManifest, root: URL) throws {
        guard manifest.schemaVersion == 1,
              !manifest.containsRealClientData,
              manifest.artifacts.count == 8,
              manifest.queries.count == 5,
              !manifest.corpusID.isEmpty,
              !manifest.corpusVersion.isEmpty,
              manifest.artifactRoot == "TestData/Synthetic Document Intelligence Benchmark",
              FileManager.default.fileExists(atPath: root.path) else {
            throw NativeRAGControlError.invalidManifest("expected fixed 8-artifact, 5-query synthetic corpus")
        }
        guard Set(manifest.artifacts.map(\.artifactID)).count == manifest.artifacts.count,
              Set(manifest.queries.map(\.queryID)).count == manifest.queries.count else {
            throw NativeRAGControlError.invalidManifest("duplicate artifact or query identity")
        }
    }

    private func prepareEmbeddingModel(
        repositoryID: String
    ) async throws -> NativeRAGControlArtifactBinding {
        let record = try DiskEmbeddingModelRegistrar.registerVerifiedModel(
            into: store,
            root: ManagedModelStorage.embeddingModelsDirectory(),
            repositoryID: repositoryID
        )
        guard let embedder = RuntimeTextEmbedder(model: record, runtimeClient: runtimeClient) else {
            throw NativeRAGControlError.embeddingProbeFailed("verified record could not create an embedder")
        }
        do {
            let vectors = try await embedder.embed(["Synthetic native RAG binding probe."])
            guard vectors.count == 1,
                  vectors[0].count == record.dimension,
                  vectors[0].allSatisfy(\.isFinite) else {
                throw NativeRAGControlError.embeddingProbeFailed("runtime returned an invalid vector")
            }
        } catch {
            throw NativeRAGControlError.embeddingProbeFailed(error.localizedDescription)
        }
        let verifiedAt = Date()
        var verified = record
        verified.lastTestLoadAt = verifiedAt
        verified.lastTestLoadResult = "passed"
        verified.updatedAt = verifiedAt
        try store.documentSettings.upsertEmbeddingModel(verified)
        try store.documentSettings.selectEmbeddingModel(id: verified.id)
        try store.documentSettings.updateSettings {
            $0.embeddingModelLastTestedAt = verifiedAt
            $0.chunkerVersion = 2
        }
        let manifest = try ManagedModelStorage.loadVerifiedManifest(
            at: URL(fileURLWithPath: try Self.require(verified.localPath), isDirectory: true)
        )
        return try Self.binding(manifest)
    }

    private func prepareChatModel(
        repositoryID: String
    ) async throws -> (ModelID, NativeRAGControlArtifactBinding, ModelRoute) {
        let modelDirectory = ManagedModelStorage.modelsDirectory().appendingPathComponent(
            ManagedModelStorage.folderName(forRepoID: repositoryID), isDirectory: true
        )
        let manifest = try ManagedModelStorage.loadVerifiedManifest(at: modelDirectory)
        guard manifest.repositoryID == repositoryID else {
            throw NativeRAGControlError.chatArtifactMismatch(repositoryID)
        }
        if !modelLibrary.models.contains(where: { $0.path == modelDirectory.path }) {
            _ = try modelLibrary.addModel(
                displayName: repositoryID,
                path: modelDirectory.path,
                bookmarkData: nil
            )
        }
        let configuration = LegalModelConfiguration(
            legalReasoningModel: repositoryID,
            legalReasoningHighQualityModel: repositoryID,
            draftingModel: repositoryID,
            critiqueModel: repositoryID
        )
        let resolution = await modelLibrary.ensureLoadedRoutedModelID(
            for: .legalReasoning,
            configuration: configuration
        )
        let modelID: ModelID
        switch resolution {
        case .success(let loaded): modelID = loaded
        case .failure(let issue):
            throw NativeRAGControlError.chatModelLoadFailed(String(describing: issue))
        }
        guard modelLibrary.loadedModel?.displayName == repositoryID,
              let route = ModelRouter(configuration: configuration)
                .route(forStructuredOutput: .documentQA) else {
            throw NativeRAGControlError.chatArtifactMismatch(repositoryID)
        }
        return (modelID, try Self.binding(manifest), route)
    }

    private func memoryRecord(
        maximumLiveSemanticCacheBytes: Int
    ) async throws -> NativeRAGControlMemoryRecord {
        guard let app = Self.appMemory(),
              let runtimeMetrics = try await runtimeClient.runtimeStatus().metrics,
              let xpcCurrentMiB = runtimeMetrics.currentMemoryMb,
              let xpcPeakMiB = runtimeMetrics.peakMemoryMb,
              xpcCurrentMiB > 0, xpcPeakMiB > 0 else {
            throw NativeRAGControlError.runtimeMemoryUnavailable
        }
        let xpcCurrent = UInt64(xpcCurrentMiB) * 1_024 * 1_024
        let xpcPeak = UInt64(xpcPeakMiB) * 1_024 * 1_024
        return NativeRAGControlMemoryRecord(
            appCurrentPhysFootprintBytes: app.current,
            appPeakPhysFootprintBytes: app.peak,
            xpcCurrentPhysFootprintBytes: xpcCurrent,
            xpcPeakPhysFootprintBytes: xpcPeak,
            combinedCurrentPhysFootprintBytes: app.current + xpcCurrent,
            combinedPeakPhysFootprintBytes: app.peak + xpcPeak,
            maximumLiveSemanticCacheBytes: UInt64(max(0, maximumLiveSemanticCacheBytes))
        )
    }

    private static func candidates(
        _ sources: [RetrievedSource],
        artifactIDByDocumentID: [String: String]
    ) -> [NativeRAGControlCandidate] {
        sources.map {
            NativeRAGControlCandidate(
                artifactID: artifactIDByDocumentID[$0.documentID],
                documentName: $0.documentName,
                locator: $0.locator.displayString,
                excerpt: $0.excerpt,
                rank: $0.rank + 1,
                score: $0.score,
                ftsMatched: $0.ftsMatched,
                semanticBucket: $0.semanticBucket
            )
        }
    }

    private static func locatorDisplay(_ json: String) -> String {
        (try? JSONDecoder().decode(DocumentSourceLocator.self, from: Data(json.utf8)))?.displayString
            ?? "unavailable locator"
    }

    private static func binding(
        _ manifest: ModelArtifactManifest
    ) throws -> NativeRAGControlArtifactBinding {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return NativeRAGControlArtifactBinding(
            repositoryID: manifest.repositoryID,
            revision: manifest.revision,
            artifactIdentitySHA256: sha256(try encoder.encode(manifest))
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func elapsedMilliseconds(since started: TimeInterval) -> Int {
        max(0, Int(((ProcessInfo.processInfo.systemUptime - started) * 1_000).rounded()))
    }

    private static func require(_ value: String?) throws -> String {
        guard let value, !value.isEmpty else {
            throw NativeRAGControlError.embeddingProbeFailed("managed path is missing")
        }
        return value
    }

    private static func appMemory() -> (current: UInt64, peak: UInt64)? {
        var information = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &information) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS,
              information.phys_footprint > 0,
              information.ledger_phys_footprint_peak > 0 else { return nil }
        return (
            UInt64(information.phys_footprint),
            UInt64(information.ledger_phys_footprint_peak)
        )
    }
}

/// Observes the real generation stream without changing it. Only the first
/// non-reranker token latency is exposed to the control record.
private final class NativeRAGTimingGateway: ModelExecutionGateway, @unchecked Sendable {
    private let base: any ModelExecutionGateway
    private let lock = NSLock()
    private var answerFirstTokenMilliseconds: Int?
    private var retainedAnswerFailureDetail: String?

    init(base: any ModelExecutionGateway) { self.base = base }

    var firstAnswerTokenMilliseconds: Int? {
        lock.withLock { answerFirstTokenMilliseconds }
    }

    var answerFailureDetail: String? {
        lock.withLock { retainedAnswerFailureDetail }
    }

    func beginQuery() {
        lock.withLock {
            answerFirstTokenMilliseconds = nil
            retainedAnswerFailureDetail = nil
        }
    }

    func connect() async throws { try await base.connect() }
    func loadModel(_ request: LoadModelRequest) async throws -> LoadModelResponse {
        try await base.loadModel(request)
    }
    func generate(_ request: GenerateRequest) throws -> AsyncThrowingStream<GenerationEvent, Error> {
        let upstream = try base.generate(request)
        let started = ProcessInfo.processInfo.systemUptime
        let isReranker = request.systemPrompt == "You are a retrieval reranker. Output only the source labels."
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await event in upstream {
                        if !isReranker,
                           event.type == .token,
                           event.tokenText?.isEmpty == false {
                            let elapsed = max(0, Int(
                                ((ProcessInfo.processInfo.systemUptime - started) * 1_000).rounded()
                            ))
                            self.lock.withLock {
                                if self.answerFirstTokenMilliseconds == nil {
                                    self.answerFirstTokenMilliseconds = elapsed
                                }
                            }
                        }
                        if !isReranker, event.type == .generationFailed {
                            self.lock.withLock {
                                self.retainedAnswerFailureDetail =
                                    event.error?.technicalDetails ?? event.error?.message
                            }
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    func countTokens(_ request: CountTokensRequest) async throws -> CountTokensResponse {
        try await base.countTokens(request)
    }
    func cancelGeneration(_ generationID: GenerationID) async throws -> CancelGenerationResponse {
        try await base.cancelGeneration(generationID)
    }
    func recentEvents(
        for generationID: GenerationID,
        after sequenceNumber: Int
    ) async throws -> [GenerationEvent] {
        try await base.recentEvents(for: generationID, after: sequenceNumber)
    }
    func unloadModel() async throws -> UnloadModelResponse { try await base.unloadModel() }
    func reloadCurrentModel() async throws -> LoadModelResponse { try await base.reloadCurrentModel() }
    func runtimeStatus() async throws -> RuntimeStatus { try await base.runtimeStatus() }
    func loadEmbeddingModel(_ request: LoadEmbeddingModelRequest) async throws -> LoadEmbeddingModelResponse {
        try await base.loadEmbeddingModel(request)
    }
    func embedTexts(_ request: EmbedTextRequest) async throws -> EmbedTextResponse {
        try await base.embedTexts(request)
    }
    func embeddingStatus() async throws -> EmbeddingModelStatus { try await base.embeddingStatus() }
}
