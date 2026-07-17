import CryptoKit
import Darwin
import Foundation
import SupraDocuments
import SupraSessions
import SupraStore
import SupraTestKit

@main
struct SupraBenchCommand {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.contains("--deterministic") else {
                throw BenchmarkCLIError.usage
            }
            let outputURL = try outputURL(from: arguments)
            let root = try repositoryRoot()
            let manifestURL = root.appendingPathComponent("TestData/benchmark-manifest.json")
            let manifestData = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(BenchmarkFixtureManifest.self, from: manifestData)
            let specification = try benchmarkSpecification(in: root)
            let repositorySHA = try gitHead(in: root)
            let manifestSHA = SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined()
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
            var bytes = try report.canonicalJSON()
            bytes.append(0x0a)
            if let outputURL {
                try bytes.write(to: outputURL, options: .atomic)
            } else {
                try FileHandle.standardOutput.write(contentsOf: bytes)
            }
        } catch {
            FileHandle.standardError.write(Data("SupraBench: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
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

    var errorDescription: String? {
        switch self {
        case .usage: return "usage: swift run SupraBench --deterministic [--output path]"
        case .missingOutputPath: return "--output requires a path"
        case .repositoryRootNotFound: return "could not locate the repository root"
        case .repositorySHANotFound: return "could not resolve the repository SHA"
        case .benchmarkSpecificationNotFound: return "no benchmark-profile specification was found"
        }
    }
}

private struct DeterministicCorpusWorkload: Sendable {
    let repositoryRoot: URL
    let manifest: BenchmarkFixtureManifest
    let specification: MatterSpec

    func run() async throws -> [BenchmarkObservation] {
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
        observations.append(contentsOf: retrievalObservations(tasks: tasks, retrievedByTask: retrievedByTask))

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
        return observations
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
