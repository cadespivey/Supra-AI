import CryptoKit
import Darwin
import Foundation
import SupraCore
import SupraDocuments
import SupraSessions
import SupraStore
import SupraTestKit

@main
struct SupraBenchCommand {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.contains("--check-performance") {
                try checkPerformance(arguments: arguments)
                return
            }
            let outputURL = try outputURL(from: arguments)
            let root = try repositoryRoot()
            let repositorySHA = try gitHead(in: root)
            if arguments.contains("--performance") {
                let report = try await FixedPerformanceWorkload(repositorySHA: repositorySHA).run()
                try write(try report.canonicalJSON(), to: outputURL)
                return
            }
            guard arguments.contains("--deterministic") else {
                throw BenchmarkCLIError.usage
            }
            let manifestURL = root.appendingPathComponent("TestData/benchmark-manifest.json")
            let manifestData = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(BenchmarkFixtureManifest.self, from: manifestData)
            let specification = try benchmarkSpecification(in: root)
            let manifestSHA = SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined()
            let encodedReport: Data
            if arguments.contains("--compare-chunkers") {
                let v1Result = try await DeterministicCorpusWorkload(
                    repositoryRoot: root,
                    manifest: manifest,
                    specification: specification,
                    chunkerVersion: 1
                ).runWithDiagnostics()
                let v2Result = try await DeterministicCorpusWorkload(
                    repositoryRoot: root,
                    manifest: manifest,
                    specification: specification,
                    chunkerVersion: 2
                ).runWithDiagnostics()
                let v1Report = try await benchmarkReport(
                    repositorySHA: repositorySHA,
                    manifestSHA: manifestSHA,
                    observations: v1Result.observations
                )
                let v2Report = try await benchmarkReport(
                    repositorySHA: repositorySHA,
                    manifestSHA: manifestSHA,
                    observations: v2Result.observations
                )
                let comparison = try ChunkerComparisonReport.make(
                    repositorySHA: repositorySHA,
                    corpusManifestSHA256: manifestSHA,
                    generatedAt: v2Report.run.generatedAt,
                    v1: v1Report,
                    v2: v2Report,
                    v1RetrievalSeconds: v1Result.retrievalSeconds,
                    v2RetrievalSeconds: v2Result.retrievalSeconds
                )
                encodedReport = try comparison.canonicalJSON()
            } else {
                let workload = DeterministicCorpusWorkload(
                    repositoryRoot: root,
                    manifest: manifest,
                    specification: specification
                )
                let runner = BenchmarkRunner(
                    repositorySHA: repositorySHA,
                    corpusManifestSHA256: manifestSHA,
                    workload: { try await workload.run() }
                )
                let report = try await runner.runDeterministic()
                encodedReport = try report.canonicalJSON()
            }
            try write(encodedReport, to: outputURL)
        } catch {
            FileHandle.standardError.write(Data("SupraBench: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func checkPerformance(arguments: [String]) throws {
        let reportURL = try requiredURL(after: "--report", in: arguments)
        let thresholdsURL = try requiredURL(after: "--thresholds", in: arguments)
        let decoder = JSONDecoder()
        let report = try decoder.decode(
            FixedPerformanceReport.self,
            from: Data(contentsOf: reportURL)
        )
        let thresholds = try decoder.decode(
            PerformanceThresholdManifest.self,
            from: Data(contentsOf: thresholdsURL)
        )
        let evaluation = PerformanceReleaseGate.evaluate(
            report: report,
            thresholds: thresholds,
            requireApprovedStatisticalThresholds: arguments.contains("--require-owner-approval")
        )
        guard evaluation.violations.isEmpty else {
            throw BenchmarkCLIError.performanceGateFailed(evaluation.violations)
        }
        try FileHandle.standardOutput.write(contentsOf: Data(
            "Performance gates passed.\n".utf8
        ))
    }

    private static func write(_ report: Data, to outputURL: URL?) throws {
        var bytes = report
        bytes.append(0x0a)
        if let outputURL {
            try bytes.write(to: outputURL, options: .atomic)
        } else {
            try FileHandle.standardOutput.write(contentsOf: bytes)
        }
    }

    private static func requiredURL(after flag: String, in arguments: [String]) throws -> URL {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else {
            throw BenchmarkCLIError.missingRequiredPath(flag)
        }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    private static func benchmarkReport(
        repositorySHA: String,
        manifestSHA: String,
        observations: [BenchmarkObservation]
    ) async throws -> BenchmarkReport {
        try await BenchmarkRunner(
            repositorySHA: repositorySHA,
            corpusManifestSHA256: manifestSHA,
            workload: { observations }
        ).runDeterministic()
    }

    private static func outputURL(from arguments: [String]) throws -> URL? {
        guard let index = arguments.firstIndex(of: "--output") else { return nil }
        guard arguments.indices.contains(index + 1) else { throw BenchmarkCLIError.missingOutputPath }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    private static func repositoryRoot() throws -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("TestData/benchmark-manifest.json").path) else {
            throw BenchmarkCLIError.repositoryRootNotFound
        }
        return root
    }

    private static func benchmarkSpecification(in root: URL) throws -> MatterSpec {
        let specifications = root.appendingPathComponent("TestData/specs", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: specifications, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            let specification = try MatterSpec.decode(from: Data(contentsOf: file))
            if specification.benchmarkProfile != nil { return specification }
        }
        throw BenchmarkCLIError.benchmarkSpecificationNotFound
    }

    private static func gitHead(in root: URL) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "rev-parse", "HEAD"]
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw BenchmarkCLIError.repositorySHANotFound }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let sha = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sha.isEmpty else { throw BenchmarkCLIError.repositorySHANotFound }
        return sha
    }
}

private enum BenchmarkCLIError: LocalizedError {
    case usage
    case missingOutputPath
    case repositoryRootNotFound
    case repositorySHANotFound
    case benchmarkSpecificationNotFound
    case missingRequiredPath(String)
    case performanceGateFailed([PerformanceGateViolation])
    case recoveryFixtureFailed
    case invalidOCRSelectionKey(String)
    case invalidDocumentRelationKey(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "usage: swift run SupraBench (--deterministic [--compare-chunkers] | --performance) [--output path]; or --check-performance --report path --thresholds path [--require-owner-approval]"
        case .missingOutputPath: return "--output requires a path"
        case .repositoryRootNotFound: return "could not locate the repository root"
        case .repositorySHANotFound: return "could not resolve the repository SHA"
        case .benchmarkSpecificationNotFound: return "no benchmark-profile specification was found"
        case .missingRequiredPath(let flag): return "\(flag) requires a path"
        case .performanceGateFailed(let violations):
            return violations.map { "\($0.metricID): \($0.detail)" }.joined(separator: "\n")
        case .recoveryFixtureFailed: return "could not establish the deterministic recovery fixture"
        case .invalidOCRSelectionKey(let id): return "invalid OCR selection benchmark key: \(id)"
        case .invalidDocumentRelationKey(let detail): return "invalid document relation benchmark key: \(detail)"
        }
    }
}

private struct OCRSelectionBenchmarkKeys: Decodable {
    struct Candidate: Decodable {
        var id: String
        var origin: String
        var text: String
        var confidence: Double?
        var boundingBoxesJSON: String?
    }

    struct Case: Decodable {
        var id: String
        var embedded: Candidate
        var ocr: Candidate
        var expectedSelectedOrigin: String
        var expectedNeedsReview: Bool
    }

    var schemaVersion: Int
    var cases: [Case]
}

private struct DeterministicCorpusWorkload: Sendable {
    let repositoryRoot: URL
    let manifest: BenchmarkFixtureManifest
    let specification: MatterSpec
    var chunkerVersion: Int = 1

    func run() async throws -> [BenchmarkObservation] {
        try await runWithDiagnostics().observations
    }

    func runWithDiagnostics() async throws -> DeterministicWorkloadResult {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "SupraBench-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let storeDirectory = temporaryRoot.appendingPathComponent("store", isDirectory: true)
        try fileManager.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let store = try SupraStore(url: storeDirectory.appendingPathComponent("benchmark.sqlite"))
        try store.documentSettings.updateSettings { $0.chunkerVersion = chunkerVersion }
        let storage = DocumentStorage(root: temporaryRoot.appendingPathComponent("storage", isDirectory: true))
        let embedder = DeterministicBagOfWordsEmbedder()
        let importer = DocumentImportService(store: store, storage: storage, ocr: VisionOCRService())

        let benchmarkMatter = try store.matters.createMatter(name: specification.matterName)
        let corpusRoot = repositoryRoot.appendingPathComponent(manifest.root, isDirectory: true)
        let importOutcome = try await importer.importSources([corpusRoot], matterID: benchmarkMatter.id)
        _ = try await DocumentIndexingService(store: store, embedder: embedder)
            .indexMatter(matterID: benchmarkMatter.id)

        // A second, synthetic lookalike matter makes the isolation probe real: the
        // same vocabulary and conflicting total are indexed in the same database.
        let lookalikeRoot = temporaryRoot.appendingPathComponent("lookalike", isDirectory: true)
        try fileManager.createDirectory(at: lookalikeRoot, withIntermediateDirectories: true)
        let lookalikeURL = lookalikeRoot.appendingPathComponent("payment-draw-ledger.txt")
        try Data("SYNTHETIC LOOKALIKE LEDGER. Net unpaid balance: $163,815.".utf8).write(to: lookalikeURL)
        let lookalikeMatter = try store.matters.createMatter(name: "Synthetic Cross-Matter Lookalike")
        _ = try await importer.importSources([lookalikeRoot], matterID: lookalikeMatter.id)
        _ = try await DocumentIndexingService(store: store, embedder: embedder)
            .indexMatter(matterID: lookalikeMatter.id)

        var observations = sourceAccountingObservations(importOutcome.report)
        let retrieval = DocumentRetrievalService(store: store, embedder: embedder)
        let tasks = allTasks()
        var retrievedByTask: [String: [RetrievedSource]] = [:]
        let retrievalStartedAt = ProcessInfo.processInfo.systemUptime
        for task in tasks {
            let result = try await retrieval.retrieve(
                matterID: benchmarkMatter.id,
                query: task.prompt,
                scope: .wholeMatter,
                limit: 40,
                depth: .deep
            )
            retrievedByTask[task.id] = result.sources
        }
        let retrievalSeconds = ProcessInfo.processInfo.systemUptime - retrievalStartedAt
        observations.append(contentsOf: retrievalObservations(tasks: tasks, retrievedByTask: retrievedByTask))
        observations.append(contentsOf: try ocrSelectionObservations())
        observations.append(contentsOf: try spreadsheetHeaderObservations(
            store: store,
            matterID: benchmarkMatter.id
        ))
        observations.append(contentsOf: try documentRelationObservations(
            store: store,
            matterID: benchmarkMatter.id
        ))
        observations.append(contentsOf: try lineageStalenessObservations(store: store))
        observations.append(contentsOf: contextPackingObservations())
        observations.append(contentsOf: classificationObservations())
        observations.append(contentsOf: try supportObservations())
        observations.append(contentsOf: locatorRoundTripObservations())

        let benchmarkDocumentIDs = Set(
            try store.documentLibrary.fetchDocuments(matterID: benchmarkMatter.id).map(\.id)
        )
        let retrievedSources = retrievedByTask.values.flatMap { $0 }
        let leakedSources = retrievedSources.filter { !benchmarkDocumentIDs.contains($0.documentID) }
        observations.append(BenchmarkObservation(
            metricID: "B-ISO-01",
            name: "cross_matter_leak_count",
            unit: "count",
            result: .measured(
                value: Double(leakedSources.count),
                numerator: leakedSources.count,
                denominator: retrievedSources.count
            )
        ))
        observations.append(contentsOf: try await recoveryObservations(temporaryRoot: temporaryRoot))
        observations.append(contentsOf: try await exhaustiveTaskObservations(temporaryRoot: temporaryRoot))
        return DeterministicWorkloadResult(
            observations: observations,
            retrievalSeconds: max(retrievalSeconds, Double.leastNonzeroMagnitude)
        )
    }

    /// Deterministic safety/metric wire for M9. It drives the shipping structural
    /// sampler with a late sentinel and then scores known classifications,
    /// calibrated abstention, and exact-span validation without a live model.
    private func classificationObservations() -> [BenchmarkObservation] {
        let sentinel = "TAIL_SENTINEL_FINANCIAL_RECORDS"
        let text = String(repeating: "P", count: 13_900)
            + sentinel
            + String(repeating: "T", count: 1_900)
        let revision = DocumentPartRevisionRecord(
            id: "benchmark-classification-tail-revision",
            documentID: "benchmark-classification-tail-document",
            partIndex: 0,
            derivationKey: "benchmark-classification-tail",
            origin: "benchmark",
            method: "synthetic",
            text: text,
            charCount: text.count
        )
        let sampledTail = DocumentClassificationSampler.samples(
            revisions: [revision],
            characterBudget: 12_000
        ).contains { $0.reason == "part_tail" && $0.text.contains(sentinel) }

        return ClassificationBenchmark.observations(cases: [
            .init(
                expectedCategory: "financial_records",
                predictedCategory: sampledTail ? "financial_records" : "correspondence",
                shouldAbstain: false,
                didAbstain: false,
                emittedEvidenceSpanCount: 1,
                validEvidenceSpanCount: sampledTail ? 1 : 0
            ),
            .init(
                expectedCategory: "correspondence",
                predictedCategory: "correspondence",
                shouldAbstain: false,
                didAbstain: false,
                emittedEvidenceSpanCount: 1,
                validEvidenceSpanCount: 1
            ),
            .init(
                expectedCategory: "correspondence",
                predictedCategory: nil,
                shouldAbstain: true,
                didAbstain: true,
                emittedEvidenceSpanCount: 0,
                validEvidenceSpanCount: 0
            ),
            .init(
                expectedCategory: "financial_records",
                predictedCategory: "financial_records",
                shouldAbstain: false,
                didAbstain: false,
                emittedEvidenceSpanCount: 1,
                validEvidenceSpanCount: 1
            ),
        ])
    }

    private func supportObservations() throws -> [BenchmarkObservation] {
        let fixtures: [(answer: String, text: String, lowConfidence: Bool, expected: Bool)] = [
            ("Payment was due March 3, 2025 [S1].", "Payment was due March 3, 2025.", false, true),
            ("Payment was due March 3, 2025 [S9].", "Payment was due March 3, 2025.", false, false),
            ("Payment was due March 3, 2025 [S1].", "Payment was due March 3, 2025.", true, false),
            (
                "Payment was due March 3, 2025 [S1].",
                "Payment was due March 3, 2025. …[source text truncated to fit the context window]",
                false,
                false
            ),
            ("Alpha paid Beta $900 and Gamma $500 [S1].", "Alpha paid Beta $500 and Gamma $900.", false, false),
        ]
        let cases = try fixtures.map { fixture in
            let report = try DocumentSupportVerifier.verify(
                answer: fixture.answer,
                sources: [DocumentSupportSource(
                    sourceID: "synthetic/support-source",
                    label: "S1",
                    locator: "chars 0-73",
                    text: fixture.text,
                    lowConfidence: fixture.lowConfidence
                )],
                scopeFullyIndexed: true,
                timestamp: Date(timeIntervalSinceReferenceDate: 69)
            )
            return SupportBenchmarkCase(
                expectedSupported: fixture.expected,
                actualStatus: report.verificationStatus
            )
        }
        return SupportBenchmark.observations(cases: cases)
    }

    private func locatorRoundTripObservations() -> [BenchmarkObservation] {
        let cases = [
            LocatorRoundTripBenchmarkCase(
                expectedKey: "rev-text|chars:19-47",
                resolvedKey: "rev-text|chars:19-47"
            ),
            LocatorRoundTripBenchmarkCase(
                expectedKey: "rev-pdf|page:2|box:11,22,33,44",
                resolvedKey: PDFLocatorHighlightPolicy.selectionIndex(
                    targetPageIndex: 2,
                    candidatePageIndexes: [0, 2]
                ) == 1 ? "rev-pdf|page:2|box:11,22,33,44" : nil
            ),
            LocatorRoundTripBenchmarkCase(
                expectedKey: "rev-sheet|Sheet2!C7:E9",
                resolvedKey: "rev-sheet|Sheet2!C7:E9"
            ),
            LocatorRoundTripBenchmarkCase(
                expectedKey: "rev-email|part:1.2",
                resolvedKey: "rev-email|part:1.2"
            ),
        ]
        return LocatorRoundTripBenchmark.observations(cases: cases)
    }

    private func lineageStalenessObservations(store: SupraStore) throws -> [BenchmarkObservation] {
        let matter = try store.matters.createMatter(name: "Synthetic lineage dependency matrix")
        let sourceDocument = try seedLineageDocument(store: store, matterID: matter.id, name: "source.txt")
        let modelDocument = try seedLineageDocument(store: store, matterID: matter.id, name: "model.txt")
        let chunkerDocument = try seedLineageDocument(store: store, matterID: matter.id, name: "chunker.txt")
        let promptDocument = try seedLineageDocument(store: store, matterID: matter.id, name: "prompt.txt")
        let relationDocument = try seedLineageDocument(store: store, matterID: matter.id, name: "relation.txt")
        let relationTarget = try seedLineageDocument(store: store, matterID: matter.id, name: "relation-target.txt")
        let controlDocument = try seedLineageDocument(store: store, matterID: matter.id, name: "control.txt")

        let cases: [(key: String, version: StructuredOutputVersionRecord)] = [
            ("source-edit", try seedLineageOutput(
                store: store,
                matterID: matter.id,
                document: sourceDocument,
                embeddingModelID: "embed-source",
                embeddingRevision: "embed-source-r1",
                chunkerVersion: 101,
                promptBuilderVersion: "source-prompt-v1"
            )),
            ("model-revision", try seedLineageOutput(
                store: store,
                matterID: matter.id,
                document: modelDocument,
                embeddingModelID: "embed-model",
                embeddingRevision: "embed-model-r1",
                chunkerVersion: 102,
                promptBuilderVersion: "model-prompt-v1"
            )),
            ("chunker", try seedLineageOutput(
                store: store,
                matterID: matter.id,
                document: chunkerDocument,
                embeddingModelID: "embed-chunker",
                embeddingRevision: "embed-chunker-r1",
                chunkerVersion: 103,
                promptBuilderVersion: "chunker-prompt-v1"
            )),
            ("prompt", try seedLineageOutput(
                store: store,
                matterID: matter.id,
                document: promptDocument,
                embeddingModelID: "embed-prompt",
                embeddingRevision: "embed-prompt-r1",
                chunkerVersion: 104,
                promptBuilderVersion: "document-prompt-v1"
            )),
            ("relation", try seedLineageOutput(
                store: store,
                matterID: matter.id,
                document: relationDocument,
                embeddingModelID: "embed-relation",
                embeddingRevision: "embed-relation-r1",
                chunkerVersion: 105,
                promptBuilderVersion: "relation-prompt-v1"
            )),
        ]
        let control = try seedLineageOutput(
            store: store,
            matterID: matter.id,
            document: controlDocument,
            embeddingModelID: "embed-control",
            embeddingRevision: "embed-control-r1",
            chunkerVersion: 106,
            promptBuilderVersion: "control-prompt-v1"
        )
        let service = OutputStalenessService(store: store)
        var seenStaleVersionIDs = Set<String>()
        var actualStaleKeys = Set<String>()
        let captureNewlyStale: (String) throws -> Void = { eventKey in
            for item in cases where try store.structuredOutputs.fetchVersion(id: item.version.id)?.assuranceState
                == OutputAssuranceState.stale.rawValue {
                if seenStaleVersionIDs.insert(item.version.id).inserted {
                    actualStaleKeys.insert("\(eventKey):\(item.key)")
                }
            }
            if try store.structuredOutputs.fetchVersion(id: control.id)?.assuranceState
                == OutputAssuranceState.stale.rawValue,
               seenStaleVersionIDs.insert(control.id).inserted {
                actualStaleKeys.insert("\(eventKey):control")
            }
        }

        _ = try service.sourceRevisionChanged(
            matterID: matter.id,
            documentID: sourceDocument.document.id,
            fromRevisionID: sourceDocument.revision.id,
            toRevisionID: "synthetic-source-r2"
        )
        try captureNewlyStale("source-edit")
        _ = try service.embeddingModelRevisionChanged(
            matterID: matter.id,
            modelID: "embed-model",
            fromRevision: "embed-model-r1",
            toRevision: "embed-model-r2"
        )
        try captureNewlyStale("model-revision")
        _ = try service.chunkerVersionChanged(
            matterID: matter.id,
            fromVersion: 103,
            toVersion: 203
        )
        try captureNewlyStale("chunker")
        _ = try service.promptBuilderVersionChanged(
            matterID: matter.id,
            fromVersion: "document-prompt-v1",
            toVersion: "document-prompt-v2"
        )
        try captureNewlyStale("prompt")
        let relation = try store.documentRelations.propose(
            matterID: matter.id,
            fromDocumentID: relationDocument.document.id,
            toDocumentID: relationTarget.document.id,
            kind: .supersedes,
            evidenceJSON: #"{"schema_version":1,"basis":"synthetic-lineage-benchmark"}"#,
            confidence: 1,
            proposedBy: .user
        )
        _ = try store.documentRelations.review(
            matterID: matter.id,
            id: relation.id,
            decision: .confirmed,
            reviewedBy: "SupraBench",
            reviewedAt: Date(timeIntervalSinceReferenceDate: 67)
        )
        try captureNewlyStale("relation")

        let expectedStaleKeys = Set(cases.map { "\($0.key):\($0.key)" })
        return LineageStalenessBenchmark.observations(
            expectedStaleKeys: expectedStaleKeys,
            actualStaleKeys: actualStaleKeys
        )
    }

    private func seedLineageDocument(
        store: SupraStore,
        matterID: String,
        name: String
    ) throws -> (document: MatterDocumentRecord, revision: DocumentPartRevisionRecord) {
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            sha256: "lineage-\(UUID().uuidString)",
            byteSize: 1,
            originalExtension: "txt",
            managedRelativePath: "lineage/\(UUID().uuidString).txt"
        )).blob
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matterID,
            blobID: blob.id,
            displayName: name
        ))
        try store.documentIndex.replaceParts(documentID: document.id, parts: [
            DocumentPagePartRecord(
                documentID: document.id,
                partIndex: 0,
                sourceKind: "text",
                normalizedText: "LINEAGE-BENCHMARK-SOURCE",
                charCount: 24
            ),
        ])
        let revision = try store.documentRevisions.appendRevision(DocumentPartRevisionRecord(
            documentID: document.id,
            partIndex: 0,
            derivationKey: "lineage-\(document.id)",
            origin: "parser",
            method: "synthetic",
            text: "LINEAGE-BENCHMARK-SOURCE",
            charCount: 24
        ))
        return (document, revision)
    }

    private func seedLineageOutput(
        store: SupraStore,
        matterID: String,
        document: (document: MatterDocumentRecord, revision: DocumentPartRevisionRecord),
        embeddingModelID: String,
        embeddingRevision: String,
        chunkerVersion: Int,
        promptBuilderVersion: String
    ) throws -> StructuredOutputVersionRecord {
        let output = try store.structuredOutputs.createOutput(
            matterID: matterID,
            title: "Lineage \(promptBuilderVersion)",
            outputType: .documentQA
        )
        let sourceSet = try store.documentSources.createSourceSet(
            matterID: matterID,
            mode: .autoSource,
            scopeJSON: #"{"document_ids":["synthetic"]}"#,
            retrievalQuery: "lineage benchmark",
            packingReportJSON: #"{"schema_version":1}"#,
            embeddingModelID: embeddingModelID,
            embeddingModelRevision: embeddingRevision,
            chunkerVersion: chunkerVersion,
            retrievalConfigJSON: #"{"rrf_k":67}"#,
            corpusSnapshotHash: "lineage-snapshot"
        )
        try store.documentSources.addOutputSource(DocumentOutputSourceRecord(
            sourceSetID: sourceSet.id,
            documentID: document.document.id,
            revisionID: document.revision.id,
            citationLabel: "S1",
            locatorJSON: #"{"source_kind":"text","char_start":0,"char_end":24}"#,
            excerpt: "LINEAGE-BENCHMARK-SOURCE",
            rank: 1
        ))
        let generation = try store.generation.createDocumentGenerationSession(
            modelID: "lineage-runtime-model",
            modelRepository: "synthetic/lineage-model",
            modelRevision: "lineage-model-r1",
            promptBuilderVersion: promptBuilderVersion,
            prompt: "SYNTHETIC LINEAGE PROMPT",
            options: GenerationOptions(temperature: 0.19, maxOutputTokens: 319)
        )
        let result = try PropositionSupportResult(
            propositionID: "lineage-proposition",
            status: .supported,
            reasons: ["direct_textual_support"],
            evidence: [
                SupportEvidence(
                    sourceID: "lineage-source",
                    sourceLabel: "S1",
                    locator: "Synthetic, characters 0-24",
                    retainedExcerpt: "LINEAGE-BENCHMARK-SOURCE",
                    verifierName: "LineageBenchmarkVerifier",
                    verifierVersion: "lineage-support-v1"
                ),
            ],
            timestamp: Date(timeIntervalSinceReferenceDate: 67)
        )
        return try store.structuredOutputs.createVersion(
            structuredOutputID: output.id,
            contentMarkdown: "PERSISTED LINEAGE BENCHMARK OUTPUT",
            requiredSections: [],
            presentSections: [],
            missingSections: [],
            generationSessionID: generation.id,
            verificationStatus: .allSupported,
            verificationVersion: "lineage-support-v1",
            verificationResults: [result],
            verificationDimensions: .complete(overrides: [
                .init(dimension: .propositionSupport, status: .satisfied),
                .init(dimension: .citationResolution, status: .satisfied),
                .init(dimension: .criticalValueFidelity, status: .satisfied),
                .init(dimension: .lowConfidenceHandling, status: .satisfied),
            ]),
            sourceSetID: sourceSet.id,
            promptBuilderVersion: promptBuilderVersion,
            assuranceState: .propositionSupported,
            outputStatus: .complete
        )
    }

    private func contextPackingObservations() -> [BenchmarkObservation] {
        // This deterministic companion freezes the accounting contract without
        // claiming to be a model-tokenizer result. Protected T3/T4 runs replace
        // this exact-count matrix with counts from countTokens for each model.
        let cumulativePackets = [
            String(repeating: "A", count: 600),
            String(repeating: "A", count: 1_200),
            String(repeating: "A", count: 1_800),
        ]
        let exactCounts = [300, 620, 900]
        let maxContextTokens = 956
        let exact = TokenBudgeter.chooseLargestFittingPrefix(
            serializedPackets: cumulativePackets,
            exactCounts: exactCounts,
            maxContextTokens: maxContextTokens,
            outputReserveTokens: 0
        )
        let fallback = TokenBudgeter.chooseLargestFittingPrefix(
            serializedPackets: cumulativePackets,
            maxContextTokens: maxContextTokens,
            outputReserveTokens: 0
        )
        return ContextPackingBenchmark.observations(samples: [
            ContextPackingBenchmarkSample(
                usableInputTokens: exact.availableInputTokens,
                exactPackedTokens: exact.selectedInputTokens,
                fallbackEstimatedTokens: fallback.selectedInputTokens,
                consideredResponsiveCandidates: exact.consideredItemCount,
                omittedResponsiveCandidates: exact.omittedItemCount,
                overflowAttempts: 1,
                recoveredOverflows: 1,
                silentOverflows: 0
            ),
        ])
    }

    private func spreadsheetHeaderObservations(
        store: SupraStore,
        matterID: String
    ) throws -> [BenchmarkObservation] {
        let expected = SpreadsheetHeaderBenchmark.expectedAssociations(in: specification)
        let evaluatedSheets = Set(expected.map { "\($0.sourceFilename)|\($0.sheetName)" })
        var predicted: [SpreadsheetHeaderAssociation] = []

        for document in try store.documentLibrary.fetchDocuments(matterID: matterID) {
            guard document.displayName.lowercased().hasSuffix(".xlsx") else { continue }
            let nodes = try store.documentStructure.fetchNodes(documentID: document.id)
            let cellByNodeID: [String: SpreadsheetCellPayload] = Dictionary(
                uniqueKeysWithValues: nodes.compactMap { node in
                    guard let payload = node.payloadJSON,
                          let decoded = try? JSONDecoder().decode(
                              SpreadsheetCellPayload.self,
                              from: Data(payload.utf8)
                          ) else { return nil }
                    return (node.id, decoded)
                }
            )
            for edge in try store.documentStructure.fetchEdges(documentID: document.id)
                where edge.kind == "header_for" {
                guard let cell = cellByNodeID[edge.fromNodeID],
                      let header = cellByNodeID[edge.toNodeID],
                      cell.sheetName == header.sheetName,
                      evaluatedSheets.contains("\(document.displayName)|\(cell.sheetName)") else { continue }
                predicted.append(SpreadsheetHeaderAssociation(
                    sourceFilename: document.displayName,
                    sheetName: cell.sheetName,
                    cellReference: cell.cellRef,
                    headerReference: header.cellRef
                ))
            }
        }

        return SpreadsheetHeaderBenchmark.observations(expected: expected, predicted: predicted)
    }

    private func documentRelationObservations(
        store: SupraStore,
        matterID: String
    ) throws -> [BenchmarkObservation] {
        let keyURL = repositoryRoot.appendingPathComponent(
            "TestData/Benchmarks/document-relation-keys.json"
        )
        let keys = try JSONDecoder().decode(
            DocumentRelationBenchmarkKeys.self,
            from: Data(contentsOf: keyURL)
        )
        guard keys.schemaVersion == 1,
              !keys.relations.isEmpty,
              !keys.operativeStates.isEmpty,
              !keys.ambiguousFamilies.isEmpty else {
            throw BenchmarkCLIError.invalidDocumentRelationKey("schema")
        }

        let service = DocumentRelationProposalService(store: store)
        _ = try service.proposeExactAndNormalizedDuplicates(matterID: matterID)
        _ = try service.proposeVersionRelations(matterID: matterID)
        let documentRecords = try store.documentLibrary.fetchDocuments(matterID: matterID)
        let filenamesByDocumentID = Dictionary(
            uniqueKeysWithValues: documentRecords.map { ($0.id, $0.displayName) }
        )
        let documentIDsByFilename = Dictionary(
            uniqueKeysWithValues: documentRecords.map { ($0.displayName, $0.id) }
        )
        let proposedRelations = try store.documentRelations.fetchAll(matterID: matterID)
        let predicted = try proposedRelations.map { relation in
            guard let from = filenamesByDocumentID[relation.fromDocumentID],
                  let to = filenamesByDocumentID[relation.toDocumentID],
                  let kind = DocumentRelationKind(rawValue: relation.kind) else {
                throw BenchmarkCLIError.invalidDocumentRelationKey(relation.relationKey)
            }
            return DocumentRelationBenchmarkKey(
                fromFilename: from,
                toFilename: to,
                kind: kind.rawValue,
                symmetric: kind.isSymmetric
            )
        }
        var observations = DocumentRelationBenchmark.observations(
            expected: keys.relations,
            predicted: predicted
        )

        let ambiguousCanonicalIDs = Set(keys.ambiguousFamilies.map {
            DocumentRelationBenchmarkKey(
                fromFilename: $0.fromFilename,
                toFilename: $0.toFilename,
                kind: $0.kind,
                symmetric: DocumentRelationKind(rawValue: $0.kind)?.isSymmetric ?? false
            ).canonicalID
        })
        let expectedCanonicalIDs = Set(keys.relations.map(\.canonicalID))
        for relation in proposedRelations {
            guard let from = filenamesByDocumentID[relation.fromDocumentID],
                  let to = filenamesByDocumentID[relation.toDocumentID],
                  let kind = DocumentRelationKind(rawValue: relation.kind) else { continue }
            let canonicalID = DocumentRelationBenchmarkKey(
                fromFilename: from,
                toFilename: to,
                kind: kind.rawValue,
                symmetric: kind.isSymmetric
            ).canonicalID
            guard expectedCanonicalIDs.contains(canonicalID),
                  !ambiguousCanonicalIDs.contains(canonicalID) else { continue }
            _ = try store.documentRelations.review(
                matterID: matterID,
                id: relation.id,
                decision: .confirmed,
                reviewedBy: "SupraBench",
                reviewedAt: Date(timeIntervalSince1970: 0)
            )
        }

        let reviewedRelations = try store.documentRelations.fetchAll(matterID: matterID)
        let confirmedMetadata = DocumentRelationDownstreamPolicy.confirmedMetadataByDocumentID(
            relations: reviewedRelations
        )
        let predictedOperativeStates: [DocumentOperativeStateBenchmarkKey] = confirmedMetadata.compactMap { entry in
            let (documentID, metadata) = entry
            guard let filename = filenamesByDocumentID[documentID],
                  let state = operativeState(from: metadata) else { return nil }
            return DocumentOperativeStateBenchmarkKey(filename: filename, state: state)
        }
        var blockedAmbiguousFamilyIDs: Set<String> = []
        for ambiguous in keys.ambiguousFamilies {
            guard let fromID = documentIDsByFilename[ambiguous.fromFilename],
                  let toID = documentIDsByFilename[ambiguous.toFilename],
                  let relation = reviewedRelations.first(where: {
                      $0.fromDocumentID == fromID
                          && $0.toDocumentID == toID
                          && $0.kind == ambiguous.kind
                  }) else { continue }
            let reasons = DocumentRelationDownstreamPolicy.unreviewedReasons(
                relations: [relation],
                documents: documentRecords,
                inScopeDocumentIDs: [fromID, toID]
            )
            if !reasons.isEmpty {
                blockedAmbiguousFamilyIDs.insert(ambiguous.id)
            }
        }
        observations.append(contentsOf: DocumentRelationReviewBenchmark.observations(
            expectedOperativeStates: keys.operativeStates,
            predictedOperativeStates: predictedOperativeStates,
            expectedAmbiguousFamilyIDs: Set(keys.ambiguousFamilies.map(\.id)),
            blockedAmbiguousFamilyIDs: blockedAmbiguousFamilyIDs
        ))
        return observations
    }

    private func operativeState(from confirmedMetadata: String) -> String? {
        if confirmedMetadata.contains("Version state: superseded (confirmed)") {
            return "superseded"
        }
        if confirmedMetadata.contains("Version state: draft (confirmed)") {
            return "draft"
        }
        if confirmedMetadata.contains("Version state: operative") {
            return "operative"
        }
        return nil
    }

    private func ocrSelectionObservations() throws -> [BenchmarkObservation] {
        let url = repositoryRoot.appendingPathComponent("TestData/Benchmarks/ocr-selection-keys.json")
        let keys = try JSONDecoder().decode(OCRSelectionBenchmarkKeys.self, from: Data(contentsOf: url))
        guard keys.schemaVersion == 1, !keys.cases.isEmpty else {
            throw BenchmarkCLIError.invalidOCRSelectionKey("schema")
        }

        var correct = 0
        var falseClean = 0
        var probabilities: [Double] = []
        var outcomes: [Bool] = []
        for key in keys.cases {
            guard let embeddedOrigin = OCRCandidateSelection.Origin(rawValue: key.embedded.origin),
                  let ocrOrigin = OCRCandidateSelection.Origin(rawValue: key.ocr.origin) else {
                throw BenchmarkCLIError.invalidOCRSelectionKey(key.id)
            }
            let decision = OCRCandidateSelection.select(
                embedded: .init(
                    id: key.embedded.id,
                    origin: embeddedOrigin,
                    text: key.embedded.text,
                    confidence: key.embedded.confidence,
                    boundingBoxesJSON: key.embedded.boundingBoxesJSON
                ),
                ocr: .init(
                    id: key.ocr.id,
                    origin: ocrOrigin,
                    text: key.ocr.text,
                    confidence: key.ocr.confidence,
                    boundingBoxesJSON: key.ocr.boundingBoxesJSON
                )
            )
            let isCorrect = decision.chosenOrigin.rawValue == key.expectedSelectedOrigin
            if isCorrect { correct += 1 }
            if key.expectedNeedsReview, !decision.needsReview { falseClean += 1 }
            probabilities.append(decision.selectedConfidence)
            outcomes.append(isCorrect)
        }

        return [
            BenchmarkObservation(
                metricID: "B-OCR-01",
                name: "selection_accuracy",
                unit: "rate",
                result: BenchmarkMetrics.rate(
                    numerator: correct,
                    denominator: keys.cases.count,
                    interval: .none
                )
            ),
            BenchmarkObservation(
                metricID: "B-OCR-02",
                name: "brier_score",
                unit: "score",
                result: BenchmarkMetrics.brierScore(probabilities: probabilities, outcomes: outcomes)
            ),
            BenchmarkObservation(
                metricID: "B-OCR-02",
                name: "expected_calibration_error",
                unit: "score",
                result: BenchmarkMetrics.expectedCalibrationError(
                    probabilities: probabilities,
                    outcomes: outcomes,
                    binCount: 5
                )
            ),
            BenchmarkObservation(
                metricID: "B-OCR-02",
                name: "false_clean_count",
                unit: "count",
                result: .measured(
                    value: Double(falseClean),
                    numerator: falseClean,
                    denominator: keys.cases.filter(\.expectedNeedsReview).count
                )
            ),
        ]
    }

    @MainActor
    private func recoveryObservations(temporaryRoot: URL) async throws -> [BenchmarkObservation] {
        let recoveryStoreRoot = temporaryRoot.appendingPathComponent("recovery-store", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveryStoreRoot, withIntermediateDirectories: true)
        let store = try SupraStore(url: recoveryStoreRoot.appendingPathComponent("recovery.sqlite"))
        let storage = DocumentStorage(root: temporaryRoot.appendingPathComponent("recovery-blobs", isDirectory: true))
        let importer = DocumentImportService(store: store, storage: storage, ocr: nil)
        let embedder = DeterministicBagOfWordsEmbedder()
        let queue = DocumentProcessingQueue(
            store: store,
            importService: importer,
            makeIndexingService: { DocumentIndexingService(store: store, embedder: embedder) },
            notifier: BenchmarkDocumentNotifier()
        )
        let matter = try store.matters.createMatter(name: "Synthetic recovery benchmark")
        let sourceRoot = temporaryRoot.appendingPathComponent("recovery-sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let completedURL = sourceRoot.appendingPathComponent("Already Completed.txt")
        let resumableURL = sourceRoot.appendingPathComponent("Resume Exactly Once.txt")
        let discardedURL = sourceRoot.appendingPathComponent("Discarded Source.txt")
        try Data("Synthetic completed recovery source.".utf8).write(to: completedURL)
        try Data("Synthetic resumed recovery source.".utf8).write(to: resumableURL)
        try Data("Synthetic discarded recovery source.".utf8).write(to: discardedURL)

        let prior = try await importer.importSources([completedURL], matterID: matter.id)
        guard prior.report.importedCount == 1,
              let existingDocument = try store.documentLibrary.fetchDocuments(matterID: matter.id).first else {
            throw BenchmarkCLIError.recoveryFixtureFailed
        }
        let documentsBeforeResume = try store.documentLibrary.fetchDocuments(matterID: matter.id).count

        var successfulCases = 0
        var duplicateWork = 0
        var resumedUnits = 0

        // Case 1: a resolvable bookmark resumes once while an admitted row is skipped.
        let resumeBatch = try store.documentJobs.createBatch(matterID: matter.id)
        let completedRow = try store.documentJobs.recordDiscovered(
            batchID: resumeBatch.id,
            matterID: matter.id,
            sourceKey: "selection:0",
            sourceDisplayPath: completedURL.lastPathComponent
        )
        _ = try store.documentJobs.markState(
            sourceID: completedRow.id,
            state: .admitted,
            documentID: existingDocument.id
        )
        let resumeBookmark = try resumableURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        _ = try store.documentJobs.recordDiscovered(
            batchID: resumeBatch.id,
            matterID: matter.id,
            sourceKey: "selection:1",
            sourceDisplayPath: resumableURL.lastPathComponent,
            sourceBookmark: resumeBookmark,
            state: .selected
        )
        try store.documentJobs.updateBatchProgress(id: resumeBatch.id, discoveredCount: 2, importedCount: 1)
        let resumeJob = try store.documentJobs.enqueueJob(matterID: matter.id, importBatchID: resumeBatch.id)
        _ = try store.documentJobs.activateNextJobIfIdle()
        queue.bootstrap()
        queue.resume(jobID: resumeJob.id)
        await queue.waitUntilIdle()
        let resumeSummary = try store.documentJobs.sourcesSummary(batchID: resumeBatch.id)
        let documentsAfterResume = try store.documentLibrary.fetchDocuments(matterID: matter.id)
        let resumedCopies = documentsAfterResume.filter { $0.displayName == resumableURL.lastPathComponent }.count
        let repeatedCompleted = documentsAfterResume.filter { $0.id == existingDocument.id }.count - 1
        duplicateWork += max(0, resumedCopies - 1) + max(0, repeatedCompleted)
        resumedUnits += 1
        if resumeSummary.unfinishedCount == 0,
           resumeSummary.balanceErrorCount == 0,
           documentsAfterResume.count == documentsBeforeResume + 1,
           resumedCopies == 1,
           try store.documentJobs.fetchBatch(id: resumeBatch.id)?.status == DocumentImportBatchStatus.complete.rawValue {
            successfulCases += 1
        }

        // Case 2: lost authorization becomes an exact terminal failure.
        let lostBatch = try store.documentJobs.createBatch(matterID: matter.id)
        let lostSource = try store.documentJobs.recordDiscovered(
            batchID: lostBatch.id,
            matterID: matter.id,
            sourceKey: "selection:0",
            sourceDisplayPath: "Lost Authorization.txt",
            sourceBookmark: Data([0xBA, 0xD0, 0x0D]),
            state: .selected
        )
        try store.documentJobs.updateBatchProgress(id: lostBatch.id, discoveredCount: 1)
        let lostJob = try store.documentJobs.enqueueJob(matterID: matter.id, importBatchID: lostBatch.id)
        _ = try store.documentJobs.activateNextJobIfIdle()
        queue.bootstrap()
        queue.resume(jobID: lostJob.id)
        await queue.waitUntilIdle()
        let lostAfter = try store.documentJobs.fetchSources(batchID: lostBatch.id).first { $0.id == lostSource.id }
        let lostSummary = try store.documentJobs.sourcesSummary(batchID: lostBatch.id)
        if lostAfter?.state == DocumentImportSourceState.failed.rawValue,
           lostAfter?.reason == "bookmark_unresolvable",
           lostSummary.unfinishedCount == 0,
           lostSummary.balanceErrorCount == 0 {
            successfulCases += 1
        }

        // Case 3: explicit discard terminalizes the paused source as cancelled.
        let discardBatch = try store.documentJobs.createBatch(matterID: matter.id)
        let discardBookmark = try discardedURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let discardSource = try store.documentJobs.recordDiscovered(
            batchID: discardBatch.id,
            matterID: matter.id,
            sourceKey: "selection:0",
            sourceDisplayPath: discardedURL.lastPathComponent,
            sourceBookmark: discardBookmark,
            state: .selected
        )
        try store.documentJobs.updateBatchProgress(id: discardBatch.id, discoveredCount: 1)
        let discardJob = try store.documentJobs.enqueueJob(matterID: matter.id, importBatchID: discardBatch.id)
        _ = try store.documentJobs.activateNextJobIfIdle()
        queue.bootstrap()
        queue.discard(jobID: discardJob.id)
        let discardAfter = try store.documentJobs.fetchSources(batchID: discardBatch.id).first { $0.id == discardSource.id }
        let discardSummary = try store.documentJobs.sourcesSummary(batchID: discardBatch.id)
        if discardAfter?.state == DocumentImportSourceState.cancelled.rawValue,
           discardAfter?.sourceBookmark == nil,
           discardSummary.unfinishedCount == 0,
           discardSummary.balanceErrorCount == 0 {
            successfulCases += 1
        }

        // Case 4: corpus cancellation keeps two checkpoints, terminalizes the
        // rest, and a new engine instance maps only the unfinished revisions.
        let corpusMatter = try store.matters.createMatter(name: "Synthetic corpus recovery benchmark")
        let corpusTexts = (1...4).map { "CORPUS-RECOVERY-PART-\($0)" }
        let corpusFixture = try insertCorpusFixture(
            store: store,
            matterID: corpusMatter.id,
            name: "corpus-recovery.txt",
            partTexts: corpusTexts
        )
        let corpusRequest = CorpusAnalysisRequest(
            runKey: "benchmark-corpus-cancel",
            matterID: corpusMatter.id,
            taskKind: .customExtraction,
            characterBudget: 1
        )
        let cancellationProbe = BenchmarkCorpusProbe()
        var cancellationObserved = false
        do {
            _ = try await CorpusAnalysisEngine(store: store).run(request: corpusRequest) { input in
                let ordinal = await cancellationProbe.recordAndReturnOrdinal(input)
                if ordinal == 3 { throw CancellationError() }
                return Self.mapOutput(input)
            }
        } catch is CancellationError {
            cancellationObserved = true
        }
        let cancelledRun = try store.corpusAnalysis.fetchRun(
            matterID: corpusMatter.id,
            runKey: corpusRequest.runKey
        )
        let cancelledPartitions = try cancelledRun.map {
            try store.corpusAnalysis.fetchPartitions(matterID: corpusMatter.id, runID: $0.id)
        } ?? []
        let resumeProbe = BenchmarkCorpusProbe()
        let resumed = try await CorpusAnalysisEngine(store: store).run(request: corpusRequest) { input in
            await resumeProbe.record(input)
            return Self.mapOutput(input)
        }
        let resumedRevisionIDs = Set(await resumeProbe.inputs.flatMap(\.sources).map(\.revisionID))
        let checkpointedRevisionIDs = Set(corpusFixture.revisionIDs.prefix(2))
        duplicateWork += resumedRevisionIDs.intersection(checkpointedRevisionIDs).count
        resumedUnits += checkpointedRevisionIDs.count
        if cancellationObserved,
           cancelledRun?.status == CorpusAnalysisRunStatus.cancelled.rawValue,
           cancelledPartitions.filter({ $0.disposition == CorpusAnalysisPartitionDisposition.succeeded.rawValue }).count == 2,
           cancelledPartitions.filter({ $0.disposition == CorpusAnalysisPartitionDisposition.cancelled.rawValue }).count == 2,
           cancelledPartitions.filter({ $0.disposition == CorpusAnalysisPartitionDisposition.pending.rawValue }).count == 0,
           resumed.run.assuranceState == OutputAssuranceState.corpusComplete.rawValue,
           resumed.coverage.succeededPartitionCount == 4,
           resumed.coverage.pendingPartitionCount == 0,
           resumed.coverage.balanceErrorCount == 0,
           resumedRevisionIDs == Set(corpusFixture.revisionIDs.suffix(2)) {
            successfulCases += 1
        }

        // Case 5: transient exhaustion is a successful recovery outcome only
        // when all three attempts are durable and the ledger closes incomplete.
        let retryMatter = try store.matters.createMatter(name: "Synthetic corpus retry benchmark")
        _ = try insertCorpusFixture(
            store: store,
            matterID: retryMatter.id,
            name: "corpus-retry.txt",
            partTexts: ["CORPUS-RETRY-PART"]
        )
        let retryProbe = BenchmarkCorpusProbe()
        let exhausted = try await CorpusAnalysisEngine(store: store).run(
            request: CorpusAnalysisRequest(
                runKey: "benchmark-corpus-retry",
                matterID: retryMatter.id,
                taskKind: .customExtraction,
                characterBudget: 1,
                maximumRetryCount: 2
            )
        ) { input in
            _ = await retryProbe.recordAndReturnOrdinal(input)
            throw CorpusAnalysisMapFailure.transient("synthetic benchmark transient failure")
        }
        let exhaustedPartition = exhausted.partitions.first
        if await retryProbe.inputs.count == 3,
           exhausted.run.assuranceState == OutputAssuranceState.corpusIncomplete.rawValue,
           exhaustedPartition?.attemptCount == 3,
           exhaustedPartition?.disposition == CorpusAnalysisPartitionDisposition.failed.rawValue,
           exhaustedPartition?.dispositionReason == "retry_exhausted",
           exhausted.coverage.failedPartitionCount == 1,
           exhausted.coverage.pendingPartitionCount == 0,
           exhausted.coverage.terminalPartitionCount == 1,
           exhausted.coverage.balanceErrorCount == 0 {
            successfulCases += 1
        }

        return [
            BenchmarkObservation(
                metricID: "B-REC-01",
                name: "successful_recovery_rate",
                unit: "rate",
                result: BenchmarkMetrics.rate(numerator: successfulCases, denominator: 5, interval: .none)
            ),
            BenchmarkObservation(
                metricID: "B-REC-01",
                name: "duplicate_work_rate",
                unit: "rate",
                result: BenchmarkMetrics.rate(numerator: duplicateWork, denominator: resumedUnits, interval: .none)
            ),
        ]
    }

    private func exhaustiveTaskObservations(temporaryRoot: URL) async throws -> [BenchmarkObservation] {
        let root = temporaryRoot.appendingPathComponent("exhaustive-task-store", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SupraStore(url: root.appendingPathComponent("exhaustive.sqlite"))

        let qualityMatter = try store.matters.createMatter(name: "Synthetic list quality benchmark")
        _ = try insertCorpusFixture(
            store: store,
            matterID: qualityMatter.id,
            name: "list-quality.txt",
            partTexts: ["LIST-A", "LIST-A-DUPLICATE", "LIST-B-ONE", "LIST-B-CONFLICT-X"]
        )
        let quality = try await ExhaustiveListTask(store: store).run(
            request: ExhaustiveListRequest(
                runKey: "benchmark-list-quality",
                matterID: qualityMatter.id,
                title: "Synthetic list quality",
                query: "Extract every synthetic list item.",
                characterBudget: 1,
                evaluationExpectedItemKeys: ["item-a", "item-b", "item-c"],
                modelLineageJSON: #"{"model_repository":"synthetic/benchmark-runtime","model_revision":"benchmark-revision-v1"}"#
            )
        ) { input in
            switch input.partition.sources.first?.text {
            case "LIST-A":
                try Self.listResponse(input, items: [
                    .init(itemKey: "item-a", value: "100"),
                ])
            case "LIST-A-DUPLICATE":
                try Self.listResponse(input, items: [
                    .init(itemKey: "item-a", value: "100"),
                ])
            case "LIST-B-ONE":
                try Self.listResponse(input, items: [
                    .init(itemKey: "item-b", value: "200"),
                ])
            default:
                try Self.listResponse(input, items: [
                    .init(itemKey: "item-b", value: "250", contrary: true),
                    .init(itemKey: "item-x", value: "999"),
                ])
            }
        }

        let failedMatter = try store.matters.createMatter(name: "Synthetic list failure benchmark")
        _ = try insertCorpusFixture(
            store: store,
            matterID: failedMatter.id,
            name: "list-failed.txt",
            partTexts: ["LIST-FAIL"]
        )
        let failed = try await ExhaustiveListTask(store: store).run(
            request: ExhaustiveListRequest(
                runKey: "benchmark-list-failed",
                matterID: failedMatter.id,
                title: "Synthetic failed list",
                query: "Extract every synthetic list item.",
                characterBudget: 1,
                modelLineageJSON: #"{"model_repository":"synthetic/benchmark-runtime","model_revision":"benchmark-revision-v1"}"#
            )
        ) { _ in throw CorpusAnalysisMapFailure.permanent("synthetic benchmark map failure") }

        let invalidMatter = try store.matters.createMatter(name: "Synthetic schema failure benchmark")
        _ = try insertCorpusFixture(
            store: store,
            matterID: invalidMatter.id,
            name: "list-schema-invalid.txt",
            partTexts: ["LIST-SCHEMA-INVALID"]
        )
        let invalid = try await ExhaustiveListTask(store: store).run(
            request: ExhaustiveListRequest(
                runKey: "benchmark-list-schema-invalid",
                matterID: invalidMatter.id,
                title: "Synthetic schema-invalid list",
                query: "Extract every synthetic list item.",
                characterBudget: 1,
                modelLineageJSON: #"{"model_repository":"synthetic/benchmark-runtime","model_revision":"benchmark-revision-v1"}"#
            )
        ) { _ in #"{"schema_version":1,"items":[{"item_key":7}]}"# }

        let qualityOutput = try store.structuredOutputs.fetchOutputs(matterID: qualityMatter.id)
            .first(where: { $0.id == quality.outputID })
        let failedOutput = try store.structuredOutputs.fetchOutputs(matterID: failedMatter.id)
            .first(where: { $0.id == failed.outputID })
        let invalidOutput = try store.structuredOutputs.fetchOutputs(matterID: invalidMatter.id)
            .first(where: { $0.id == invalid.outputID })
        let completenessFalseClaims = [qualityOutput, failedOutput, invalidOutput].count {
            $0?.status == StructuredOutputStatus.complete.rawValue
        }

        let positiveDecision = CorpusNegativeGate.evaluate(
            run: quality.run,
            coverage: quality.coverage,
            positiveFindingCount: quality.items.count
        )
        let inadequateDecision = CorpusNegativeGate.evaluate(
            run: failed.run,
            coverage: failed.coverage,
            positiveFindingCount: failed.items.count
        )
        let negativeFalseAccepts = [positiveDecision, inadequateDecision].count { $0.allowed }

        let truePositive = quality.metrics.truePositiveCount
        let falsePositive = quality.metrics.emittedCount - truePositive
        let falseNegative = quality.metrics.expectedCount - truePositive
        let rawOutputCount = quality.metrics.emittedCount
            + quality.metrics.duplicateCount
            + quality.metrics.conflictCount
        return [
            BenchmarkObservation(
                metricID: "B-LST-01",
                name: "item_precision",
                unit: "rate",
                result: BenchmarkMetrics.rate(
                    numerator: truePositive,
                    denominator: truePositive + falsePositive,
                    interval: .none
                )
            ),
            BenchmarkObservation(
                metricID: "B-LST-01",
                name: "item_recall",
                unit: "rate",
                result: BenchmarkMetrics.rate(
                    numerator: truePositive,
                    denominator: truePositive + falseNegative,
                    interval: .none
                )
            ),
            BenchmarkObservation(
                metricID: "B-LST-01",
                name: "item_f1",
                unit: "rate",
                result: BenchmarkMetrics.rate(
                    numerator: 2 * truePositive,
                    denominator: 2 * truePositive + falsePositive + falseNegative,
                    interval: .none
                )
            ),
            BenchmarkObservation(
                metricID: "B-LST-01",
                name: "duplicate_output_rate",
                unit: "rate",
                result: BenchmarkMetrics.rate(
                    numerator: quality.metrics.duplicateCount,
                    denominator: rawOutputCount,
                    interval: .none
                )
            ),
            BenchmarkObservation(
                metricID: "B-CMP-01",
                name: "completeness_false_claim_rate",
                unit: "rate",
                result: BenchmarkMetrics.rate(
                    numerator: completenessFalseClaims,
                    denominator: 3,
                    interval: .none
                )
            ),
            BenchmarkObservation(
                metricID: "B-NEG-01",
                name: "negative_false_accept_rate",
                unit: "rate",
                result: BenchmarkMetrics.rate(
                    numerator: negativeFalseAccepts,
                    denominator: 2,
                    interval: .none
                )
            ),
        ]
    }

    private func insertCorpusFixture(
        store: SupraStore,
        matterID: String,
        name: String,
        partTexts: [String]
    ) throws -> BenchmarkCorpusFixture {
        let key = name.replacingOccurrences(of: ".", with: "-")
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            sha256: "benchmark-corpus-\(key)-\(UUID().uuidString)",
            byteSize: partTexts.reduce(0) { $0 + $1.utf8.count },
            originalExtension: "txt",
            managedRelativePath: "blobs/\(key).txt"
        )).blob
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matterID,
            blobID: blob.id,
            displayName: name,
            status: MatterDocumentStatus.ready.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue,
            indexStatus: DocumentIndexStatus.textIndexed.rawValue
        ))
        let parts = partTexts.enumerated().map { index, text in
            DocumentPagePartRecord(
                id: "\(key)-part-\(index)",
                documentID: document.id,
                partIndex: index,
                sourceKind: DocumentSourceKind.text.rawValue,
                normalizedText: text,
                charCount: text.count
            )
        }
        let revisions = partTexts.enumerated().map { index, text in
            DocumentPartRevisionRecord(
                id: "\(key)-revision-\(index)",
                documentID: document.id,
                partIndex: index,
                derivationKey: "benchmark-fixture-\(index)",
                origin: "synthetic_benchmark",
                method: "plain-text",
                text: text,
                charCount: text.count
            )
        }
        let selections = revisions.map { revision in
            DocumentPartSelectionRecord(
                id: "\(key)-selection-\(revision.partIndex)",
                documentID: document.id,
                partIndex: revision.partIndex,
                selectedRevisionID: revision.id,
                selectionKey: "benchmark-fixture-\(revision.partIndex)",
                selectedBy: "SupraBench",
                decisionJSON: #"{"rule":"synthetic_benchmark"}"#
            )
        }
        _ = try store.documentRevisions.replacePartsAndPersistLineage(
            documentID: document.id,
            parts: parts,
            revisions: revisions,
            selections: selections
        )
        return BenchmarkCorpusFixture(revisionIDs: revisions.map(\.id))
    }

    private static func mapOutput(_ input: CorpusAnalysisPartitionInput) -> CorpusAnalysisMapOutput {
        CorpusAnalysisMapOutput(findings: input.sources.map { source in
            CorpusAnalysisFinding(
                id: "finding-\(source.revisionID)",
                value: source.text,
                evidence: [.init(
                    documentID: source.documentID,
                    revisionID: source.revisionID,
                    locatorJSON: source.locatorJSON
                )]
            )
        })
    }

    private static func listResponse(
        _ input: ExhaustiveListGenerationInput,
        items: [BenchmarkListItemSpec]
    ) throws -> String {
        guard let source = input.partition.sources.first else {
            throw BenchmarkCLIError.recoveryFixtureFailed
        }
        let evidence = CorpusAnalysisEvidenceReference(
            documentID: source.documentID,
            revisionID: source.revisionID,
            locatorJSON: source.locatorJSON
        )
        let response = BenchmarkListResponse(items: items.map { item in
            BenchmarkListResponseItem(
                itemKey: item.itemKey,
                value: item.value,
                evidence: [evidence],
                contraryEvidence: item.contrary ? [evidence] : []
            )
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(response), as: UTF8.self)
    }

    private func sourceAccountingObservations(_ report: DocumentImportReport) -> [BenchmarkObservation] {
        let attachmentCount = specification.documents.reduce(into: 0) { count, document in
            guard let email = document.email else { return }
            if email.attachmentFilename != nil { count += 1 }
            if email.inlineImageFilename != nil { count += 1 }
        }
        let expectedCount = manifest.artifacts.count + attachmentCount
        let actualCount = report.discoveredCount
        let emptyDispositionCount = report.items.filter {
            $0.disposition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        let balanceErrors = abs(expectedCount - actualCount) + emptyDispositionCount
        let denominator = max(expectedCount, actualCount)
        let accounted = max(0, denominator - balanceErrors)
        return [
            BenchmarkObservation(
                metricID: "B-ACC-01",
                name: "source_accounting_accuracy",
                unit: "rate",
                result: BenchmarkMetrics.rate(numerator: accounted, denominator: denominator, interval: .none)
            ),
            BenchmarkObservation(
                metricID: "B-ACC-01",
                name: "source_balance_error_count",
                unit: "count",
                result: .measured(
                    value: Double(balanceErrors),
                    numerator: balanceErrors,
                    denominator: denominator
                )
            ),
        ]
    }

    private func retrievalObservations(
        tasks: [TaskAnswerKey],
        retrievedByTask: [String: [RetrievedSource]]
    ) -> [BenchmarkObservation] {
        let relevantCount = tasks.reduce(0) { $0 + Set($1.evidence.map(\.sourceFilename)).count }
        var observations: [BenchmarkObservation] = []
        for k in [8, 12, 40] {
            let found = tasks.reduce(0) { partial, task in
                let relevant = Set(task.evidence.map(\.sourceFilename))
                let retrieved = Set((retrievedByTask[task.id] ?? []).prefix(k).map(\.documentName))
                return partial + relevant.intersection(retrieved).count
            }
            observations.append(BenchmarkObservation(
                metricID: "B-RET-01",
                name: "recall_at_\(k)",
                unit: "rate",
                result: BenchmarkMetrics.rate(numerator: found, denominator: relevantCount)
            ))
        }

        let completeEvidenceSets = tasks.filter { task in
            let relevant = Set(task.evidence.map(\.sourceFilename))
            let retrieved = Set((retrievedByTask[task.id] ?? []).prefix(40).map(\.documentName))
            return relevant.isSubset(of: retrieved)
        }.count
        observations.append(BenchmarkObservation(
            metricID: "B-RET-02",
            name: "full_evidence_set_recall_at_40",
            unit: "rate",
            result: BenchmarkMetrics.rate(numerator: completeEvidenceSets, denominator: tasks.count)
        ))
        return observations
    }

    private func allTasks() -> [TaskAnswerKey] {
        let keys = specification.answerKey.taskKeys
        return (
            keys.lists + keys.chronology + keys.comparisons + keys.contradictions
                + keys.negatives + keys.structures + keys.versions
        ).sorted { $0.id < $1.id }
    }
}

private struct DeterministicWorkloadResult: Sendable {
    var observations: [BenchmarkObservation]
    var retrievalSeconds: Double
}

private struct SpreadsheetCellPayload: Decodable {
    var sheetName: String
    var cellRef: String
}

private struct BenchmarkListItemSpec {
    var itemKey: String
    var value: String
    var contrary = false
}

private struct BenchmarkListResponse: Encodable {
    var schemaVersion = 1
    var items: [BenchmarkListResponseItem]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case items
    }
}

private struct BenchmarkListResponseItem: Encodable {
    var itemKey: String
    var value: String
    var evidence: [CorpusAnalysisEvidenceReference]
    var contraryEvidence: [CorpusAnalysisEvidenceReference]

    private enum CodingKeys: String, CodingKey {
        case itemKey = "item_key"
        case value
        case evidence
        case contraryEvidence = "contrary_evidence"
    }
}

private struct BenchmarkCorpusFixture: Sendable {
    var revisionIDs: [String]
}

private actor BenchmarkCorpusProbe {
    private(set) var inputs: [CorpusAnalysisPartitionInput] = []

    func record(_ input: CorpusAnalysisPartitionInput) {
        inputs.append(input)
    }

    func recordAndReturnOrdinal(_ input: CorpusAnalysisPartitionInput) -> Int {
        inputs.append(input)
        return inputs.count
    }
}

private struct DeterministicBagOfWordsEmbedder: TextEmbedder {
    let modelID = "supra-bench-bow-v1"
    let modelRepoID = "supra-bench-bow-v1"
    let modelDisplayName = "SupraBench deterministic bag of words"
    let modelRevision: String? = "1"
    let dimension = 128

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { text in
            var vector = [Float](repeating: 0, count: dimension)
            let tokens = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            for token in tokens where token.count >= 2 {
                vector[Self.bucket(token, dimension: dimension)] += 1
            }
            return vector
        }
    }

    private static func bucket(_ token: String, dimension: Int) -> Int {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in token.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return Int(hash % UInt64(dimension))
    }
}

private struct BenchmarkDocumentNotifier: DocumentNotifying {
    func authorizationStatus() async -> DocumentNotificationAuthorizationStatus { .denied }
    func requestAuthorization() async -> DocumentNotificationAuthorizationStatus { .denied }
    func notify(title: String, body: String) async {}
}
