import Combine
import Foundation
import SupraCore
import SupraDocuments
import SupraRuntimeClient
import SupraRuntimeInterface
import SupraStore

/// App-run Milestone 3 document-intelligence validation (plan §15.4). Builds the
/// fixture matter, runs the full pipeline against the loaded chat + embedding
/// models, and persists per-scenario results to `model_validation_runs` /
/// `model_validation_tests` under suite id `milestone3-document-intelligence-suite`.
@MainActor
public final class DocumentValidationRunController: ObservableObject {
    public static let suiteID = "milestone3-document-intelligence-suite"
    public static let suiteVersion = 1

    public enum State: Equatable, Sendable {
        case idle
        case running(scenario: String)
        case finished(runID: String, passed: Int, total: Int)
        case failed(message: String)
    }

    @Published public private(set) var state: State = .idle

    private let store: SupraStore
    private let runtimeClient: any RuntimeClientProtocol
    private var task: Task<Void, Never>?

    public init(store: SupraStore, runtimeClient: any RuntimeClientProtocol) {
        self.store = store
        self.runtimeClient = runtimeClient
    }

    public var isRunning: Bool { if case .running = state { return true }; return false }

    /// Requires a loaded chat model and a selected embedding model.
    public func run(chatModelID: ModelID, chatModelName: String) {
        guard !isRunning else { return }
        task = Task { await self.execute(chatModelID: chatModelID, chatModelName: chatModelName) }
    }

    private func execute(chatModelID: ModelID, chatModelName: String) async {
        do {
            let run = try store.validation.createValidationRun(
                modelID: chatModelID.rawValue.uuidString, suiteID: Self.suiteID, suiteVersion: Self.suiteVersion
            )
            var results: [(id: String, name: String, status: ValidationTestStatus, excerpt: String, errors: [String])] = []

            // Build + import the fixture matter into a dedicated validation matter.
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("M3Val-\(UUID().uuidString)", isDirectory: true)
            let root = try Milestone3ValidationFixtures.write(into: base)
            defer { try? FileManager.default.removeItem(at: base) }
            let matter = try store.matters.createMatter(name: "M3 Validation \(Self.shortStamp())")

            let embedder = (try? store.documentSettings.fetchSelectedEmbeddingModel())
                .flatMap { RuntimeTextEmbedder(model: $0, runtimeClient: runtimeClient) }

            state = .running(scenario: "Import")
            let importer = DocumentImportService(store: store)
            let outcome = try await importer.importSources([root], matterID: matter.id)
            results.append(check("import_report", "Import report accounts for every file",
                                 pass: outcome.report.discoveredCount >= 14 && outcome.report.items.contains { $0.disposition == DocumentImportDisposition.unsupported.rawValue },
                                 excerpt: "discovered \(outcome.report.discoveredCount), imported \(outcome.report.importedCount), failed \(outcome.report.failedCount)"))

            let docs = try store.documentLibrary.fetchDocuments(matterID: matter.id)
            let pdfInstances = docs.filter { $0.displayName.hasPrefix("service-agreement") }
            results.append(check("dedup", "Duplicate content shares one blob",
                                 pass: pdfInstances.count == 2 && Set(pdfInstances.map(\.blobID)).count == 1,
                                 excerpt: "\(pdfInstances.count) instances"))
            let email = docs.first { $0.displayName == "notice-thread.eml" }
            results.append(check("attachments", "Email attachment becomes a child document",
                                 pass: email.map { e in docs.contains { $0.parentDocumentID == e.id } } ?? false,
                                 excerpt: "child docs: \(docs.filter { $0.parentDocumentID == email?.id }.count)"))
            let image = docs.first { $0.displayName == "scanned-notice.png" }
            results.append(check("ocr", "Image OCR persisted with confidence",
                                 pass: image?.ocrConfidenceSummary != nil,
                                 excerpt: image?.ocrConfidenceSummary ?? "no OCR summary"))

            state = .running(scenario: "Indexing")
            _ = try await DocumentIndexingService(store: store, embedder: embedder).indexMatter(matterID: matter.id)
            let ftsHits = try store.documentIndex.searchChunks(matterID: matter.id, query: "indemnification")
            results.append(check("fts_search", "Full-text search finds indexed terms", pass: !ftsHits.isEmpty, excerpt: "\(ftsHits.count) hits"))

            // Q&A + chronology against the real model.
            let qa = DocumentQAController(matterID: matter.id, store: store, runtimeClient: runtimeClient, embedder: embedder)
            state = .running(scenario: "Q&A")
            let qaResult = await qa.generate(question: "Does indemnification survive termination?", modelID: chatModelID)
            let qaSources = qaResult.map { (try? store.documentSources.fetchSources(structuredOutputVersionID: $0.versionID)) ?? [] } ?? []
            let qaPass = qaResult.map { r in r.citationLabels.allSatisfy { label in qaSources.contains { $0.citationLabel == label } } && !qaSources.isEmpty } ?? false
            results.append(check("qa_auto_source", "Auto-source Q&A cites resolvable sources", pass: qaPass, excerpt: qaResult?.markdown.prefix(160).description ?? (qa.message ?? "no result")))

            state = .running(scenario: "Unsupported Q&A")
            let unsupported = await qa.generate(question: "What is the unrelated merger consideration per share?", modelID: chatModelID)
            results.append(check("qa_unsupported", "Unanswerable question is not fabricated",
                                 status: (unsupported?.unsupported ?? false) ? .passed : .warning,
                                 excerpt: unsupported?.markdown.prefix(160).description ?? "no result"))

            state = .running(scenario: "Chronology")
            let chronology = DocumentChronologyController(matterID: matter.id, store: store, runtimeClient: runtimeClient)
            let chronoResult = await chronology.generate(scope: .wholeMatter, format: .table, modelID: chatModelID)
            results.append(check("chronology", "Chronology generated with sources",
                                 pass: chronoResult.map { !((try? store.documentSources.fetchSources(structuredOutputVersionID: $0.versionID))?.isEmpty ?? true) } ?? false,
                                 excerpt: chronoResult?.markdown.prefix(160).description ?? (chronology.message ?? "no result")))

            if let qaResult {
                state = .running(scenario: "Export")
                let exporter = DocumentExportService(store: store)
                var exported = 0
                for format in DocumentExportFormat.allCases {
                    if let url = try? exporter.export(matterID: matter.id, structuredOutputID: qaResult.outputID, format: format),
                       FileManager.default.fileExists(atPath: url.path) { exported += 1 }
                }
                results.append(check("export", "Exports created in all formats", pass: exported == DocumentExportFormat.allCases.count, excerpt: "\(exported)/\(DocumentExportFormat.allCases.count) formats"))
            }

            let noStuckActiveJob: Bool
            do {
                noStuckActiveJob = try store.documentJobs.fetchActiveJob() == nil
            } catch {
                // A DB error means the invariant could not be verified — not a pass.
                noStuckActiveJob = false
            }
            results.append(check("queue_resume", "No stuck active job", pass: noStuckActiveJob, excerpt: noStuckActiveJob ? "active job reconciled" : "could not verify active-job state"))

            for result in results {
                _ = try? store.validation.appendValidationTest(
                    runID: run.id, testID: result.id, name: result.name, status: result.status,
                    outputExcerpt: result.excerpt, errors: result.errors
                )
            }
            let passed = results.filter { $0.status == .passed }.count
            // Match ValidationRunner: any failure → failed, otherwise any warning →
            // partial, else passed (previously warnings were silently reported as passed).
            let runStatus: ValidationRunStatus
            if results.contains(where: { $0.status == .failed }) {
                runStatus = .failed
            } else if results.contains(where: { $0.status == .warning }) {
                runStatus = .partial
            } else {
                runStatus = .passed
            }
            try? store.validation.completeValidationRun(runID: run.id, status: runStatus, summary: "M3 document validation: \(passed)/\(results.count) passed")
            _ = try? store.auditEvents.recordEvent(matterID: matter.id, eventType: "m3_validation_completed", actor: "user", summary: "Ran M3 document validation", relatedTable: "model_validation_runs", relatedID: run.id)
            state = .finished(runID: run.id, passed: passed, total: results.count)
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    private func check(_ id: String, _ name: String, pass: Bool, excerpt: String) -> (id: String, name: String, status: ValidationTestStatus, excerpt: String, errors: [String]) {
        (id, name, pass ? .passed : .failed, excerpt, pass ? [] : ["\(name) did not hold"])
    }

    private func check(_ id: String, _ name: String, status: ValidationTestStatus, excerpt: String) -> (id: String, name: String, status: ValidationTestStatus, excerpt: String, errors: [String]) {
        (id, name, status, excerpt, status == .failed ? ["\(name) failed"] : [])
    }

    private static func shortStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date())
    }
}
