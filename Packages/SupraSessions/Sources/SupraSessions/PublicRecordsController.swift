import Foundation
import SupraNetworking
import SupraResearch
import SupraStore

/// App-side orchestration for the key-less government-data connectors
/// (SEC EDGAR, CFPB complaints, NLRB exports). Lives in SupraSessions per the
/// connector plan: `SupraResearch` stays a pure data layer, and nothing here
/// feeds model prompts — results are shown to the user as sourced public
/// records, never injected into chat context.
///
/// Each connector gets its OWN `AuthorizedHTTPClient` with a source-tuned
/// `RateLimitTracker` (the default tracker is CourtListener-tuned at 5/min).
/// All requests ride `sendUnauthenticated`; the stored CourtListener token is
/// never read on these paths.
@MainActor
public final class PublicRecordsController: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    public enum SecFormScope: String, CaseIterable, Identifiable, Sendable {
        case all = "All recent"
        case annual = "Annual (10-K)"
        case quarterly = "Quarterly (10-Q)"
        case current = "Current (8-K)"
        public var id: String { rawValue }
    }

    // MARK: - SEC state

    @Published public private(set) var secCompany: SecCompanyRecord?
    @Published public private(set) var secFilings: [SecFilingRecord] = []
    @Published public private(set) var secPhase: Phase = .idle

    // MARK: - CFPB state

    @Published public private(set) var cfpbResult: CfpbComplaintSearchResult?
    @Published public private(set) var cfpbPhase: Phase = .idle

    // MARK: - NLRB state

    @Published public private(set) var nlrbDatasets: [NlrbDatasetSource] = []
    @Published public private(set) var nlrbDatasetsPhase: Phase = .idle
    @Published public private(set) var nlrbImportStatus: String?
    @Published public private(set) var nlrbSummary: NlrbPartyHistorySummary?
    @Published public private(set) var nlrbCaseMatches: [NlrbCaseRecord] = []
    @Published public private(set) var nlrbPhase: Phase = .idle

    private let secConnector: SecEdgarConnector
    private let cfpbConnector: CfpbComplaintConnector
    private let nlrbConnector: NlrbDataConnector

    /// Production wiring: three policy-checked, logged, per-source-limited
    /// clients over one shared connector configuration.
    public convenience init(store: SupraStore, keyStore: any APIKeyStoreProtocol) {
        let configuration = Self.makeConfiguration()
        func client(perMinute: Int, perHour: Int, perDay: Int) -> AuthorizedHTTPClient {
            AuthorizedHTTPClient(
                keyStore: keyStore,
                policy: NetworkPolicyService(),
                logger: NetworkRequestLogger(repository: store.networkRequests),
                rateLimitTracker: RateLimitTracker(
                    limits: .init(perMinute: perMinute, perHour: perHour, perDay: perDay)
                )
            )
        }
        self.init(
            secConnector: SecEdgarConnector(
                httpClient: client(perMinute: 120, perHour: 600, perDay: 2_000),
                configuration: configuration,
                cache: FileLegalDataConnectorCache.forConnector(named: SecEdgarConnector.connectorName, configuration: configuration)
            ),
            cfpbConnector: CfpbComplaintConnector(
                httpClient: client(perMinute: 60, perHour: 300, perDay: 1_000),
                configuration: configuration,
                cache: FileLegalDataConnectorCache.forConnector(named: CfpbComplaintConnector.connectorName, configuration: configuration)
            ),
            nlrbConnector: NlrbDataConnector(
                httpClient: client(perMinute: 30, perHour: 120, perDay: 300),
                configuration: configuration,
                cache: FileLegalDataConnectorCache.forConnector(named: NlrbDataConnector.connectorName, configuration: configuration),
                localStore: NlrbLocalRecordStore(directory: configuration.nlrbLocalDataDirectory)
            )
        )
    }

    /// Test seam: inject fully-constructed connectors.
    public init(
        secConnector: SecEdgarConnector,
        cfpbConnector: CfpbComplaintConnector,
        nlrbConnector: NlrbDataConnector
    ) {
        self.secConnector = secConnector
        self.cfpbConnector = cfpbConnector
        self.nlrbConnector = nlrbConnector
    }

    /// Cache under Caches (evictable), NLRB records under Application Support
    /// (imported datasets must survive cache eviction). The SEC User-Agent is
    /// the app identifying itself per SEC fair-access guidance — it is not a
    /// credential and never contains user data.
    static func makeConfiguration() -> LegalDataConnectorConfiguration {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        return LegalDataConnectorConfiguration(
            cacheDirectory: caches.appendingPathComponent("LegalDataConnectors", isDirectory: true),
            nlrbLocalDataDirectory: support.appendingPathComponent("NLRBData", isDirectory: true),
            secEdgarUserAgent: "SupraAI/\(version) (https://supralegal.ai)"
        )
    }

    // MARK: - SEC

    public func searchSecFilings(cik: String, scope: SecFormScope) async {
        let trimmed = cik.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        secPhase = .loading
        secCompany = nil
        secFilings = []
        do {
            // Fetch the submissions ONCE and derive every scope from it — the
            // per-scope connector methods would each re-fetch the same CIK's
            // submissions JSON (a redundant parse, and a redundant SEC hit if
            // the cache is cold or disabled).
            let submissions = try await secConnector.getCompanySubmissions(trimmed)
            secCompany = submissions.company
            let filters = SecFilingFilters(limit: 40)
            let operation = "searchSecFilings"
            switch scope {
            case .all:
                secFilings = try SecEdgarConnector.apply(filters, to: submissions.recentFilings, operation: operation)
            case .annual:
                secFilings = try SecEdgarConnector.filings(in: submissions, formFamily: SecEdgarConnector.annualReportForms, filters: filters, operation: operation)
            case .quarterly:
                secFilings = try SecEdgarConnector.filings(in: submissions, formFamily: SecEdgarConnector.quarterlyReportForms, filters: filters, operation: operation)
            case .current:
                secFilings = try SecEdgarConnector.filings(in: submissions, formFamily: SecEdgarConnector.currentReportForms, filters: filters, operation: operation)
            }
            secPhase = .loaded
        } catch {
            secPhase = .failed(Self.userMessage(for: error))
        }
    }

    // MARK: - CFPB

    public func searchCfpbComplaints(
        company: String,
        state: String,
        product: String
    ) async {
        let companyTrimmed = company.trimmingCharacters(in: .whitespacesAndNewlines)
        let stateTrimmed = state.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let productTrimmed = product.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !companyTrimmed.isEmpty || !stateTrimmed.isEmpty || !productTrimmed.isEmpty else { return }
        cfpbPhase = .loading
        cfpbResult = nil
        do {
            // The database's company filter is exact-match against canonical
            // names — resolve free-text input through the official suggest
            // endpoint first, and say what it matched.
            var companies: [String] = []
            var resolutionNote: String?
            if !companyTrimmed.isEmpty {
                let suggested = try await cfpbConnector.suggestCompanies(companyTrimmed)
                if suggested.isEmpty {
                    companies = [companyTrimmed]
                    resolutionNote = "No company in the database matched “\(companyTrimmed)”; searched the name as typed."
                } else {
                    companies = suggested
                    resolutionNote = "Company matched as: \(suggested.joined(separator: "; "))."
                }
            }
            let query = CfpbComplaintQuery(
                filters: .init(
                    company: companies,
                    product: productTrimmed.isEmpty ? [] : [productTrimmed],
                    state: stateTrimmed.isEmpty ? [] : [stateTrimmed]
                ),
                options: .init(size: 25, maxPages: 1)
            )
            var result = try await cfpbConnector.searchComplaints(query)
            if let resolutionNote {
                result.sourceLimitations.insert(resolutionNote, at: 0)
            }
            cfpbResult = result
            cfpbPhase = .loaded
        } catch {
            cfpbPhase = .failed(Self.userMessage(for: error))
        }
    }

    // MARK: - NLRB

    public func refreshNlrbDatasets() async {
        nlrbDatasetsPhase = .loading
        do {
            nlrbDatasets = try await nlrbConnector.refreshAvailableDatasets()
            nlrbDatasetsPhase = .loaded
        } catch {
            nlrbDatasetsPhase = .failed(Self.userMessage(for: error))
        }
    }

    public func importNlrbDataset(_ source: NlrbDatasetSource) async {
        nlrbImportStatus = "Importing \(source.name)…"
        do {
            let run = try await nlrbConnector.importDataset(source)
            var pieces = ["Imported \(run.importedRecordCount) new record(s)"]
            if run.duplicateRecordCount > 0 { pieces.append("\(run.duplicateRecordCount) already present") }
            if !run.warnings.isEmpty { pieces.append("\(run.warnings.count) warning(s)") }
            nlrbImportStatus = pieces.joined(separator: ", ") + "."
        } catch {
            nlrbImportStatus = Self.userMessage(for: error)
        }
    }

    /// Imports an export the user downloaded manually in their browser —
    /// the supported path while the official pages keep their CSVs behind a
    /// cookie-token download tray.
    public func importNlrbLocalFile(_ fileURL: URL) async {
        nlrbImportStatus = "Importing \(fileURL.lastPathComponent)…"
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        do {
            let run = try await nlrbConnector.importLocalCSV(fileURL: fileURL)
            var pieces = ["Imported \(run.importedRecordCount) new record(s) from \(fileURL.lastPathComponent)"]
            if run.duplicateRecordCount > 0 { pieces.append("\(run.duplicateRecordCount) already present") }
            if !run.warnings.isEmpty { pieces.append("\(run.warnings.count) warning(s)") }
            nlrbImportStatus = pieces.joined(separator: ", ") + "."
        } catch {
            nlrbImportStatus = Self.userMessage(for: error)
        }
    }

    /// Party search over LOCALLY imported records: neutral history summary +
    /// its matching case records.
    public func searchNlrbParty(_ partyName: String) async {
        let trimmed = partyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        nlrbPhase = .loading
        nlrbSummary = nil
        nlrbCaseMatches = []
        do {
            let summary = try await nlrbConnector.summarizePartyNlrbHistory(partyName: trimmed)
            nlrbSummary = summary
            nlrbCaseMatches = summary.recentCases
            nlrbPhase = .loaded
        } catch {
            nlrbPhase = .failed(Self.userMessage(for: error))
        }
    }

    public func lookupNlrbCase(_ caseNumber: String) async {
        let trimmed = caseNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        nlrbPhase = .loading
        nlrbSummary = nil
        nlrbCaseMatches = []
        do {
            if let record = try await nlrbConnector.getCaseByNumber(trimmed) {
                nlrbCaseMatches = [record]
            }
            nlrbPhase = .loaded
        } catch {
            nlrbPhase = .failed(Self.userMessage(for: error))
        }
    }

    public var nlrbHasImportedData: Bool {
        nlrbImportStatus?.hasPrefix("Imported") == true || !nlrbCaseMatches.isEmpty
    }

    // MARK: - Errors

    /// Connector errors carry sanitized, user-safe messages by contract;
    /// anything else gets a generic line rather than a raw error dump.
    static func userMessage(for error: Error) -> String {
        if let connectorError = error as? LegalDataConnectorError {
            return connectorError.message
        }
        return "The request could not be completed. Check the network log in Diagnostics."
    }
}
