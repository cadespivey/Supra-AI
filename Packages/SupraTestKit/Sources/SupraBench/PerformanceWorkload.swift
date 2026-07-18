import Darwin
import Foundation
import GRDB
import SupraCore
import SupraDocuments
import SupraSessions
import SupraStore
import SupraTestKit

struct FixedPerformanceWorkload {
    static let protocolVersion = "document-performance-v1"
    static let scaleDocumentCounts = [10, 50, 200]
    static let retrievalSampleCount = 10

    let repositorySHA: String

    func run() async throws -> FixedPerformanceReport {
        var scales: [PerformanceScaleMeasurement] = []
        var incremental: IncrementalPerformanceMeasurement?
        for documentCount in Self.scaleDocumentCounts {
            let result = try await runScale(documentCount: documentCount)
            scales.append(result.scale)
            if let measured = result.incremental { incremental = measured }
        }
        guard let incremental else { throw FixedPerformanceWorkloadError.incrementalMissing }
        return FixedPerformanceReport(
            schemaVersion: 1,
            run: PerformanceRunMetadata(
                repositorySHA: repositorySHA,
                generatedAt: Self.timestamp(Date()),
                hardwareIdentifier: Self.hardwareIdentifier(),
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                xcodeVersion: Self.commandVersion("/usr/bin/xcodebuild", arguments: ["-version"]),
                swiftVersion: Self.commandVersion("/usr/bin/swift", arguments: ["--version"]),
                thermalState: Self.thermalState,
                protocolVersion: Self.protocolVersion
            ),
            scales: scales,
            incremental: incremental
        )
    }

    private func runScale(documentCount: Int) async throws -> (
        scale: PerformanceScaleMeasurement,
        incremental: IncrementalPerformanceMeasurement?
    ) {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "SupraPerformance-\(documentCount)-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("Sources", isDirectory: true)
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)

        var inputBytes = 0
        for index in 0..<documentCount {
            let text = Self.documentText(index: index)
            let data = Data(text.utf8)
            inputBytes += data.count
            try data.write(
                to: sourceRoot.appendingPathComponent(String(format: "document-%03d.txt", index)),
                options: .atomic
            )
        }

        let store = try SupraStore(url: root.appendingPathComponent("performance.sqlite"))
        try store.documentSettings.updateSettings { $0.chunkerVersion = 2 }
        let matter = try store.matters.createMatter(name: "Synthetic performance scale \(documentCount)")
        let storage = DocumentStorage(root: root.appendingPathComponent("Managed", isDirectory: true))
        let embedder = PerformanceBagOfWordsEmbedder()
        let importStarted = ProcessInfo.processInfo.systemUptime
        _ = try await DocumentImportService(store: store, storage: storage)
            .importSources([sourceRoot], matterID: matter.id)
        _ = try await DocumentIndexingService(store: store, embedder: embedder)
            .indexMatter(matterID: matter.id)
        let importIndexSeconds = max(
            ProcessInfo.processInfo.systemUptime - importStarted,
            Double.leastNonzeroMagnitude
        )

        let documents = try store.documentLibrary.fetchDocuments(matterID: matter.id)
            .sorted { $0.displayName < $1.displayName }
        guard documents.count == documentCount else {
            throw FixedPerformanceWorkloadError.documentCount(
                expected: documentCount,
                actual: documents.count
            )
        }
        let revisions = try documents.map { document -> (MatterDocumentRecord, DocumentPagePartRecord, String) in
            guard let part = try store.documentIndex.fetchParts(documentID: document.id).first,
                  let revisionID = part.currentRevisionID else {
                throw FixedPerformanceWorkloadError.revisionMissing(document.id)
            }
            return (document, part, revisionID)
        }

        let structureSamples = try persistStructures(store: store, revisions: revisions)
        let ledger = try persistLedger(
            store: store,
            matterID: matter.id,
            revisions: revisions
        )
        let retrieval = DocumentRetrievalService(store: store, embedder: embedder)
        _ = try await retrieval.retrieve(
            matterID: matter.id,
            query: "PERF_CANARY_0 indemnification notice",
            scope: .wholeMatter,
            limit: 12,
            depth: .fast
        )
        _ = try await retrieval.retrieve(
            matterID: matter.id,
            query: "PERF_CANARY_0 indemnification notice",
            scope: .wholeMatter,
            limit: 12,
            depth: .deep
        )
        var fastRetrievalSamples: [Double] = []
        var retrievalSamples: [Double] = []
        for sample in 0..<Self.retrievalSampleCount {
            let target = (sample * 17) % documentCount
            var started = ProcessInfo.processInfo.systemUptime
            _ = try await retrieval.retrieve(
                matterID: matter.id,
                query: "PERF_CANARY_\(target) indemnification notice",
                scope: .wholeMatter,
                limit: 12,
                depth: .fast
            )
            fastRetrievalSamples.append(
                (ProcessInfo.processInfo.systemUptime - started) * 1_000
            )
            started = ProcessInfo.processInfo.systemUptime
            _ = try await retrieval.retrieve(
                matterID: matter.id,
                query: "PERF_CANARY_\(target) indemnification notice",
                scope: .wholeMatter,
                limit: 12,
                depth: .deep
            )
            retrievalSamples.append(
                (ProcessInfo.processInfo.systemUptime - started) * 1_000
            )
        }

        let scale = try PerformanceScaleMeasurement(
            documentCount: documentCount,
            inputBytes: inputBytes,
            importIndexSeconds: importIndexSeconds,
            fastRetrievalMilliseconds: fastRetrievalSamples,
            retrievalMilliseconds: retrievalSamples,
            ledgerWriteMilliseconds: ledger.samples,
            structureWriteMilliseconds: structureSamples,
            peakRSSMiB: Self.peakRSSMiB,
            importedDocumentCount: documents.count,
            persistedLedgerRowCount: ledger.rowCount,
            persistedStructureNodeCount: try documents.reduce(into: 0) { count, document in
                count += try store.documentStructure.fetchNodes(documentID: document.id).count
            }
        )
        let incremental = documentCount == 200
            ? try measureIncrementalChange(
                store: store,
                matterID: matter.id,
                revisions: revisions
            )
            : nil
        return (scale, incremental)
    }

    private func persistStructures(
        store: SupraStore,
        revisions: [(MatterDocumentRecord, DocumentPagePartRecord, String)]
    ) throws -> [Double] {
        try revisions.map { document, part, revisionID in
            let root = DocumentStructureNodeRecord(
                id: "perf-root-\(document.id)",
                documentID: document.id,
                revisionID: revisionID,
                nodeKey: "document",
                ordinal: 0,
                kind: DocumentStructureNodeKind.document.rawValue
            )
            let paragraph = DocumentStructureNodeRecord(
                id: "perf-paragraph-\(document.id)",
                documentID: document.id,
                revisionID: revisionID,
                nodeKey: "paragraph",
                parentNodeID: root.id,
                ordinal: 0,
                kind: DocumentStructureNodeKind.paragraph.rawValue,
                charStart: 0,
                charEnd: part.normalizedText.count
            )
            let started = ProcessInfo.processInfo.systemUptime
            try store.documentStructure.replaceStructure(
                documentID: document.id,
                revisionID: revisionID,
                nodes: [root, paragraph],
                edges: []
            )
            return (ProcessInfo.processInfo.systemUptime - started) * 1_000
        }
    }

    private func persistLedger(
        store: SupraStore,
        matterID: String,
        revisions: [(MatterDocumentRecord, DocumentPagePartRecord, String)]
    ) throws -> (samples: [Double], rowCount: Int) {
        let members = revisions.map { document, _, revisionID in
            CorpusAnalysisSnapshotMember(
                memberKey: document.id,
                documentID: document.id,
                displayName: document.displayName,
                revisionIDs: [revisionID],
                indexState: document.indexStatus,
                disposition: .eligible
            )
        }
        let snapshotData = try JSONEncoder().encode(CorpusAnalysisSnapshot(members: members))
        let run = try store.corpusAnalysis.createOrFetchRun(CorpusAnalysisRunRecord(
            runKey: "performance-ledger-\(revisions.count)",
            matterID: matterID,
            taskKind: CorpusAnalysisTaskKind.exhaustiveList.rawValue,
            scopeJSON: "{}",
            corpusSnapshotJSON: String(decoding: snapshotData, as: UTF8.self),
            partitionStrategy: "one_document",
            partitionStrategyVersion: 1,
            status: CorpusAnalysisRunStatus.planning.rawValue
        ))
        var samples: [Double] = []
        let batchSize = max(1, Int(ceil(Double(revisions.count) / 10.0)))
        for batchStart in stride(from: 0, to: revisions.count, by: batchSize) {
            let batchEnd = min(revisions.count, batchStart + batchSize)
            let partitions = try revisions[batchStart..<batchEnd].map { document, _, revisionID in
                CorpusAnalysisPartitionRecord(
                    runID: run.id,
                    partitionKey: document.id,
                    inputRevisionIDsJSON: String(
                        decoding: try JSONEncoder().encode([revisionID]),
                        as: UTF8.self
                    )
                )
            }
            let started = ProcessInfo.processInfo.systemUptime
            try store.corpusAnalysis.createPartitions(
                matterID: matterID,
                runID: run.id,
                partitions: partitions
            )
            samples.append((ProcessInfo.processInfo.systemUptime - started) * 1_000)
        }
        return (
            samples,
            try store.corpusAnalysis.fetchPartitions(matterID: matterID, runID: run.id).count
        )
    }

    private func measureIncrementalChange(
        store: SupraStore,
        matterID: String,
        revisions: [(MatterDocumentRecord, DocumentPagePartRecord, String)]
    ) throws -> IncrementalPerformanceMeasurement {
        var dependentVersions: [(documentID: String, versionID: String)] = []
        for (document, _, revisionID) in revisions {
            let output = try store.structuredOutputs.createOutput(
                matterID: matterID,
                title: "Performance dependency \(document.displayName)",
                outputType: .documentQA
            )
            let sourceSet = try store.documentSources.createSourceSet(
                matterID: matterID,
                mode: .autoSource
            )
            try store.documentSources.addOutputSource(DocumentOutputSourceRecord(
                sourceSetID: sourceSet.id,
                documentID: document.id,
                revisionID: revisionID,
                citationLabel: "S1",
                locatorJSON: DocumentSourceLocator(sourceKind: .text).encodedJSON(),
                excerpt: "Synthetic performance dependency",
                rank: 0
            ))
            let version = try store.structuredOutputs.createVersion(
                structuredOutputID: output.id,
                contentMarkdown: "Synthetic performance dependency [S1].",
                requiredSections: [],
                presentSections: [],
                missingSections: [],
                sourceSetID: sourceSet.id,
                assuranceState: .propositionSupported,
                outputStatus: .draft
            )
            dependentVersions.append((document.id, version.id))
        }

        guard let target = revisions.first else {
            throw FixedPerformanceWorkloadError.incrementalMissing
        }
        let changesBefore = try store.database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT total_changes()") ?? 0
        }
        let editedText = target.1.normalizedText + "\nINCREMENTAL_CHANGE_CANARY"
        let started = ProcessInfo.processInfo.systemUptime
        let newRevision = try store.documentRevisions.appendUserEdit(
            documentID: target.0.id,
            partID: target.1.id,
            text: editedText,
            author: "performance-harness",
            reason: "B-PERF-03 one-document change"
        )
        _ = try OutputStalenessService(store: store).sourceRevisionChanged(
            matterID: matterID,
            documentID: target.0.id,
            fromRevisionID: target.2,
            toRevisionID: newRevision.id
        )
        let wallMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000
        let changesAfter = try store.database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT total_changes()") ?? changesBefore
        }
        var changedDocumentCount = 0
        var unaffectedTouched = 0
        for dependency in dependentVersions {
            guard let version = try store.structuredOutputs.fetchVersion(id: dependency.versionID) else {
                continue
            }
            let changed = version.assuranceState == OutputAssuranceState.stale.rawValue
                && version.staleReason != nil
            if dependency.documentID == target.0.id {
                if changed { changedDocumentCount += 1 }
            } else if changed {
                unaffectedTouched += 1
            }
        }
        return IncrementalPerformanceMeasurement(
            documentCount: revisions.count,
            changedDocumentCount: changedDocumentCount,
            unaffectedDocumentsTouched: unaffectedTouched,
            rowsTouched: max(0, changesAfter - changesBefore),
            bytesTouched: editedText.utf8.count,
            wallClockMilliseconds: wallMilliseconds
        )
    }

    private static func documentText(index: Int) -> String {
        let paragraph = "Synthetic local document PERF_CANARY_\(index). The indemnification notice deadline is May \((index % 27) + 1), 2025. Account \(10_000 + index) records $\(500 + index). "
        return String(repeating: paragraph, count: 24)
    }

    private static var peakRSSMiB: Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_maxrss) / (1_024 * 1_024)
    }

    private static var thermalState: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    private static func hardwareIdentifier() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return "unknown"
        }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &value, &size, nil, 0) == 0 else { return "unknown" }
        if value.last == 0 { value.removeLast() }
        return String(decoding: value.map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    private static func commandVersion(_ executable: String, arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            return String(
                decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "unavailable"
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

private enum FixedPerformanceWorkloadError: Error {
    case documentCount(expected: Int, actual: Int)
    case revisionMissing(String)
    case incrementalMissing
}

private struct PerformanceBagOfWordsEmbedder: TextEmbedder {
    let modelID = "supra-performance-bow-v1"
    let modelRepoID = "supra-performance-bow-v1"
    let modelDisplayName = "SupraBench performance bag of words"
    let modelRevision: String? = "1"
    let dimension = 128

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { text in
            var vector = [Float](repeating: 0, count: dimension)
            for token in text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
                where token.count >= 2 {
                vector[Self.bucket(token, dimension: dimension)] += 1
            }
            return vector
        }
    }

    private static func bucket(_ token: String, dimension: Int) -> Int {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in token.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return Int(hash % UInt64(dimension))
    }
}
