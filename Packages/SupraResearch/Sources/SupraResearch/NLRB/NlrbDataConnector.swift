import Foundation
import SupraNetworking

/// NLRB data connector (plan Phase 4): dataset/export-first. The importable
/// sources are the official recent-filings and recent-election-results CSVs,
/// discovered from the official pages' "Download CSV" links; imported records
/// live in the file-backed local store and every search runs LOCALLY over
/// imported data — there is no NLRB REST API to query.
///
/// Neutrality: filings and allegations are described as filed/alleged, never
/// as findings; party summaries count "matching case records", never
/// "violations". Requests go only to `www.nlrb.gov`. App-side wiring should
/// give this connector its OWN `AuthorizedHTTPClient` with an NLRB-tuned
/// `RateLimitTracker` (30/min, 120/hr — amendment #2).
public final class NlrbDataConnector: @unchecked Sendable {
    public static let connectorName = "nlrb"

    private let configuration: LegalDataConnectorConfiguration
    private let executor: ConnectorHTTPExecutor
    private let localStore: NlrbLocalRecordStore
    private let now: @Sendable () -> Date

    static let discoveryTTL: TimeInterval = 6 * 3_600

    public init(
        httpClient: any AuthorizedHTTPClientProtocol,
        configuration: LegalDataConnectorConfiguration = .fromEnvironment(),
        cache: any LegalDataConnectorCache,
        localStore: NlrbLocalRecordStore,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.localStore = localStore
        self.now = now
        self.executor = ConnectorHTTPExecutor(
            connectorName: Self.connectorName,
            httpClient: httpClient,
            pacer: ConnectorPacer(requestsPerSecond: configuration.nlrbRateLimitPerSecond),
            cache: cache,
            now: now
        )
    }

    public func healthCheck() async -> ConnectorHealth {
        ConnectorHealth(
            connectorName: Self.connectorName,
            checkedAt: now(),
            reachable: true,
            message: "Configuration is valid. NLRB sources are key-less official CSV exports; searches run over locally imported data.",
            sanitizedMetadata: ["importRuns": String(await localStore.importRuns().count)]
        )
    }

    // MARK: - Dataset discovery

    /// Fetches the official recent pages (cached 6h), finds their Download CSV
    /// links, and lists everything else the connector knows about honestly:
    /// CATS/CHIPS as discovery-only, mirrors as unsupported.
    public func refreshAvailableDatasets(options: NlrbRefreshOptions = .init()) async throws -> [NlrbDatasetSource] {
        var sources: [NlrbDatasetSource] = []
        sources.append(await discover(
            name: "Recent unfair-labor-practice and representation filings",
            variant: .officialRecentFilings,
            page: NlrbSources.recentFilingsPage
        ))
        sources.append(await discover(
            name: "Recent election results",
            variant: .officialRecentElectionResults,
            page: NlrbSources.recentElectionResultsPage
        ))
        if options.includeHistoricalSources {
            sources.append(contentsOf: NlrbSources.discoveryOnlySources(now: now()))
        }
        if options.includeThirdPartyMirrors {
            sources.append(NlrbSources.thirdPartyMirrorSource(now: now()))
        }
        return sources
    }

    private func discover(name: String, variant: NlrbSourceVariant, page: URL) async -> NlrbDatasetSource {
        do {
            let response = try await executor.execute(
                operation: "refreshAvailableDatasets",
                request: htmlRequest(page),
                cacheTTL: Self.discoveryTTL
            )
            guard let html = String(data: response.data, encoding: .utf8),
                  let link = NlrbSources.downloadCSVLink(inHTML: html, pageURL: page) else {
                return NlrbDatasetSource(
                    name: name, sourceVariant: variant, status: .unsupported,
                    downloadUrl: nil, pageUrl: page.absoluteString,
                    note: "No Download CSV link could be discovered on the official page; the page layout may have changed or the export may now require an interactive session.",
                    discoveredAt: now()
                )
            }
            return NlrbDatasetSource(
                name: name, sourceVariant: variant, status: .available,
                downloadUrl: link.absoluteString, pageUrl: page.absoluteString,
                note: nil, discoveredAt: now()
            )
        } catch {
            return NlrbDatasetSource(
                name: name, sourceVariant: variant, status: .unsupported,
                downloadUrl: nil, pageUrl: page.absoluteString,
                note: "The official page could not be fetched.",
                discoveredAt: now()
            )
        }
    }

    // MARK: - Import

    public func importDataset(
        _ datasetSource: NlrbDatasetSource,
        options: NlrbImportOptions = .init()
    ) async throws -> NlrbImportRun {
        let operation = "importDataset"
        guard datasetSource.status == .available, let downloadUrl = datasetSource.downloadUrl,
              let url = URL(string: downloadUrl) else {
            throw LegalDataConnectorError(
                kind: .validation,
                connectorName: Self.connectorName,
                operation: operation,
                sourceVariant: datasetSource.sourceVariant.rawValue,
                message: "Only datasets with a confirmed official download URL can be imported; this one is discovery-only or unsupported."
            )
        }
        // Re-assert the pin downloadCSVLink enforces at discovery: dataset
        // sources are plain Codable values, so a tampered or hand-built one
        // must not be able to point the importer at any other allow-listed
        // host and launder its payload as an official NLRB export.
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "www.nlrb.gov" else {
            throw LegalDataConnectorError(
                kind: .validation,
                connectorName: Self.connectorName,
                operation: operation,
                sourceVariant: datasetSource.sourceVariant.rawValue,
                message: "Only https://www.nlrb.gov download URLs can be imported."
            )
        }
        guard datasetSource.sourceVariant == .officialRecentFilings
                || datasetSource.sourceVariant == .officialRecentElectionResults else {
            throw LegalDataConnectorError(
                kind: .validation,
                connectorName: Self.connectorName,
                operation: operation,
                sourceVariant: datasetSource.sourceVariant.rawValue,
                message: "This source variant is not importable in this milestone."
            )
        }

        let response = try await executor.execute(
            operation: operation,
            request: htmlRequest(url),
            cacheTTL: options.forceRefresh ? nil : Self.discoveryTTL
        )
        guard let text = String(data: response.data, encoding: .utf8), !text.isEmpty else {
            throw LegalDataConnectorError(
                kind: .download,
                connectorName: Self.connectorName,
                operation: operation,
                sourceVariant: datasetSource.sourceVariant.rawValue,
                sourceURL: url.absoluteString,
                message: "The dataset download was empty or not decodable as text."
            )
        }
        return try await ingest(
            text: text, data: response.data, variant: datasetSource.sourceVariant,
            datasetName: datasetSource.name, datasetUrl: url.absoluteString,
            operation: operation, options: options
        )
    }

    /// Imports an official export the USER downloaded in their browser — the
    /// supported path when the official pages hide the CSV behind their
    /// cookie-token download tray. The variant is detected from the header
    /// row. Only the file NAME enters stored metadata, never the local path.
    public func importLocalCSV(fileURL: URL, options: NlrbImportOptions = .init()) async throws -> NlrbImportRun {
        let operation = "importLocalCSV"
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw LegalDataConnectorError(
                kind: .validation,
                connectorName: Self.connectorName,
                operation: operation,
                message: "The selected file could not be read."
            )
        }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw LegalDataConnectorError(
                kind: .validation,
                connectorName: Self.connectorName,
                operation: operation,
                message: "The selected file is empty or not text."
            )
        }
        let variant = try Self.detectVariant(inCSV: text, operation: operation)
        return try await ingest(
            text: text, data: data, variant: variant,
            datasetName: "Manually downloaded export (\(fileURL.lastPathComponent))",
            datasetUrl: nil, operation: operation, options: options
        )
    }

    /// Header fields that appear ONLY in the election-results export, spelled
    /// every way `NlrbNormalizer.electionRecord` accepts. The discriminator
    /// must recognize exactly the headers the normalizer can parse — a subset
    /// silently misclassifies a valid alternate-spelling export and drops its
    /// vote data.
    static let electionOnlyHeaderKeys: Set<String> = Set([
        "Tally Date", "tally_date", "Date Tally Issued",
        "Election Type", "Ballot Type",
        "Votes For", "Votes for Labor Org", "Union Yes Votes",
        "Votes Against", "Against Votes", "No Votes",
        "Total Ballots Counted", "Valid Votes Counted",
        "Unit ID", "unit_id", "Unit Size",
        "Eligible Voters", "Number of Eligible Voters",
        "Certified Representative", "Certified Rep",
    ].map(NlrbCSVImporter.normalizedHeaderKey))

    /// Case-number header spellings `NlrbNormalizer.caseRecord` accepts,
    /// including the bare `Case` column.
    static let caseNumberHeaderKeys: Set<String> = Set([
        "Case Number", "case_number", "CaseNumber", "Case",
    ].map(NlrbCSVImporter.normalizedHeaderKey))

    /// Header-based variant detection for manually downloaded exports.
    /// Election is checked FIRST because the election export also carries a
    /// case-number column; the election-only fields never appear in the
    /// filings export, so this cannot misclassify filings as elections.
    static func detectVariant(inCSV text: String, operation: String) throws -> NlrbSourceVariant {
        let headerKeys = Set((NlrbCSVImporter.parse(text).first ?? []).map(NlrbCSVImporter.normalizedHeaderKey))
        if !headerKeys.isDisjoint(with: electionOnlyHeaderKeys) { return .officialRecentElectionResults }
        if !headerKeys.isDisjoint(with: caseNumberHeaderKeys) { return .officialRecentFilings }
        throw LegalDataConnectorError(
            kind: .validation,
            connectorName: Self.connectorName,
            operation: operation,
            message: "The file does not look like an NLRB recent-filings or election-results export (no recognizable header row)."
        )
    }

    private func ingest(
        text: String,
        data: Data,
        variant: NlrbSourceVariant,
        datasetName: String,
        datasetUrl: String?,
        operation: String,
        options: NlrbImportOptions
    ) async throws -> NlrbImportRun {
        var warnings: [String] = []
        var errors: [String] = []
        var rows = NlrbCSVImporter.headerMappedRows(text)
        if rows.isEmpty { errors.append("The CSV contained no data rows.") }
        if let cap = options.maxRecords, cap > 0, rows.count > cap {
            warnings.append("Import capped at \(cap) of \(rows.count) rows by maxRecords.")
            rows = Array(rows.prefix(cap))
        }

        let payloadHash = ConnectorHashing.sha256Hex(data)
        let rawPath = try await localStore.saveRawPayload(
            data, variant: variant, hash: payloadHash
        )

        var normalizedCount = 0
        var imported = 0
        var duplicates = 0
        switch variant {
        case .officialRecentFilings:
            let records = rows.compactMap {
                NlrbNormalizer.caseRecord(
                    from: $0, variant: variant,
                    datasetUrl: datasetUrl, retrievedAt: now()
                )
            }
            normalizedCount = records.count
            if records.count < rows.count {
                warnings.append("Skipped \(rows.count - records.count) row(s) with no case number.")
            }
            let outcome = try await localStore.appendCases(records)
            imported = outcome.imported
            duplicates = outcome.duplicates
        case .officialRecentElectionResults:
            let records = rows.compactMap {
                NlrbNormalizer.electionRecord(
                    from: $0, variant: variant,
                    datasetUrl: datasetUrl, retrievedAt: now()
                )
            }
            normalizedCount = records.count
            if records.count < rows.count {
                warnings.append("Skipped \(rows.count - records.count) row(s) with no case number.")
            }
            let outcome = try await localStore.appendElections(records)
            imported = outcome.imported
            duplicates = outcome.duplicates
        default:
            break
        }

        let run = NlrbImportRun(
            id: String(payloadHash.prefix(16)) + "-" + String(Int(now().timeIntervalSince1970)) + "-" + String(UUID().uuidString.prefix(8)),
            sourceVariant: variant,
            datasetName: datasetName,
            sourceUrl: datasetUrl,
            retrievedAt: now(),
            recordCount: rows.count,
            rawPayloadHash: payloadHash,
            rawFileRelativePath: rawPath,
            normalizedRecordCount: normalizedCount,
            importedRecordCount: imported,
            duplicateRecordCount: duplicates,
            errors: errors,
            warnings: warnings
        )
        try await localStore.saveImportRun(run)
        return run
    }

    // MARK: - Local search

    public func searchCases(query: String, options: NlrbSearchOptions = .init()) async throws -> [NlrbCaseRecord] {
        let needle = NlrbLocalRecordStore.normalizedPartyKey(query)
        guard !needle.isEmpty else { return [] }
        return bounded(await localStore.allCases().filter { record in
            [record.caseName, record.employer, record.union, record.allegations, record.caseNumber]
                .compactMap { $0 }
                .contains { NlrbLocalRecordStore.normalizedPartyKey($0).contains(needle) }
        }, options: options)
    }

    public func getCaseByNumber(_ caseNumber: String) async throws -> NlrbCaseRecord? {
        await localStore.casesByNumber(caseNumber).first
    }

    public func searchByEmployer(_ employer: String, options: NlrbSearchOptions = .init()) async throws -> [NlrbCaseRecord] {
        let needle = NlrbLocalRecordStore.normalizedPartyKey(employer)
        return bounded(await localStore.allCases().filter { record in
            record.employer.map { NlrbLocalRecordStore.normalizedPartyKey($0).contains(needle) } ?? false
        }, options: options)
    }

    public func searchByUnion(_ union: String, options: NlrbSearchOptions = .init()) async throws -> [NlrbCaseRecord] {
        let needle = NlrbLocalRecordStore.normalizedPartyKey(union)
        return bounded(await localStore.allCases().filter { record in
            record.union.map { NlrbLocalRecordStore.normalizedPartyKey($0).contains(needle) } ?? false
        }, options: options)
    }

    public func searchByPartyName(_ partyName: String, options: NlrbSearchOptions = .init()) async throws -> [NlrbCaseRecord] {
        let needle = NlrbLocalRecordStore.normalizedPartyKey(partyName)
        return bounded(await localStore.allCases().filter { record in
            [record.employer, record.union, record.caseName]
                .compactMap { $0 }
                .contains { NlrbLocalRecordStore.normalizedPartyKey($0).contains(needle) }
        }, options: options)
    }

    public func searchByRegion(_ region: String, options: NlrbSearchOptions = .init()) async throws -> [NlrbCaseRecord] {
        let needle = region.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return bounded(await localStore.allCases().filter { record in
            record.region?.lowercased().contains(needle) == true
        }, options: options)
    }

    public func searchByDateRange(
        startDate: String,
        endDate: String,
        options: NlrbSearchOptions = .init()
    ) async throws -> [NlrbCaseRecord] {
        guard let start = NlrbNormalizer.parseDay(startDate), let end = NlrbNormalizer.parseDay(endDate) else {
            throw LegalDataConnectorError(
                kind: .validation,
                connectorName: Self.connectorName,
                operation: "searchByDateRange",
                message: "Start and end dates must be ISO (yyyy-MM-dd) or NLRB display dates (MM/dd/yyyy)."
            )
        }
        return bounded(await localStore.allCases().filter { record in
            guard let filed = NlrbNormalizer.parseDay(record.dateFiled) else { return options.includeUndated }
            return filed >= start && filed <= end
        }, options: options)
    }

    public func searchUnfairLaborPracticeCases(filters: NlrbCaseFilters) async throws -> [NlrbCaseRecord] {
        try await filteredCases(filters, category: .unfairLaborPractice)
    }

    public func searchRepresentationCases(filters: NlrbCaseFilters) async throws -> [NlrbCaseRecord] {
        try await filteredCases(filters, category: .representation)
    }

    public func getElectionResults(filters: NlrbElectionFilters = .init()) async throws -> [NlrbElectionResultRecord] {
        let limit = min(max(filters.limit, 1), 1_000)
        var results = await localStore.allElections()
        if let caseNumber = filters.caseNumber {
            let key = NlrbLocalRecordStore.normalizedCaseNumber(caseNumber)
            results = results.filter { NlrbLocalRecordStore.normalizedCaseNumber($0.caseNumber) == key }
        }
        if let union = filters.union {
            let needle = NlrbLocalRecordStore.normalizedPartyKey(union)
            results = results.filter { $0.union.map { NlrbLocalRecordStore.normalizedPartyKey($0).contains(needle) } ?? false }
        }
        if let employer = filters.employer {
            let needle = NlrbLocalRecordStore.normalizedPartyKey(employer)
            results = results.filter { $0.caseName.map { NlrbLocalRecordStore.normalizedPartyKey($0).contains(needle) } ?? false }
        }
        if let region = filters.region {
            let needle = region.lowercased()
            results = results.filter { $0.region?.lowercased().contains(needle) == true }
        }
        if let state = filters.state {
            results = results.filter { $0.state?.caseInsensitiveCompare(state) == .orderedSame }
        }
        if let start = try Self.dayFilter(filters.tallyStartDate, field: "tallyStartDate", operation: "getElectionResults") {
            results = results.filter { NlrbNormalizer.parseDay($0.tallyDate).map { $0 >= start } ?? false }
        }
        if let end = try Self.dayFilter(filters.tallyEndDate, field: "tallyEndDate", operation: "getElectionResults") {
            results = results.filter { NlrbNormalizer.parseDay($0.tallyDate).map { $0 <= end } ?? false }
        }
        return Array(results.prefix(limit))
    }

    // MARK: - Party history

    public func summarizePartyNlrbHistory(
        partyName: String,
        options: NlrbHistoryOptions = .init()
    ) async throws -> NlrbPartyHistorySummary {
        var cases = try await searchByPartyName(partyName, options: .init(limit: 1_000))
        if let start = try Self.dayFilter(options.dateRangeStart, field: "dateRangeStart", operation: "summarizePartyNlrbHistory") {
            cases = cases.filter { NlrbNormalizer.parseDay($0.dateFiled).map { $0 >= start } ?? false }
        }
        if let end = try Self.dayFilter(options.dateRangeEnd, field: "dateRangeEnd", operation: "summarizePartyNlrbHistory") {
            cases = cases.filter { NlrbNormalizer.parseDay($0.dateFiled).map { $0 <= end } ?? false }
        }
        let limit = min(max(options.limit, 1), 1_000)

        var elections: [NlrbElectionResultRecord] = []
        if options.includeElectionResults {
            elections = try await getElectionResults(filters: .init(employer: partyName, limit: limit))
            if elections.isEmpty {
                elections = try await getElectionResults(filters: .init(union: partyName, limit: limit))
            }
        }

        func counts(_ key: (NlrbCaseRecord) -> String?) -> [String: Int] {
            var result: [String: Int] = [:]
            for record in cases {
                guard let value = key(record) else { continue }
                result[value, default: 0] += 1
            }
            return result
        }

        let recent = cases
            .sorted { (NlrbNormalizer.parseDay($0.dateFiled) ?? .distantPast) > (NlrbNormalizer.parseDay($1.dateFiled) ?? .distantPast) }
            .prefix(limit)
        let variants = Set(cases.map { $0.sourceVariant.rawValue } + elections.map { $0.sourceVariant.rawValue })
        var limitations = [
            "Counts describe matching case records in locally imported official NLRB exports; they are not findings, adjudications, or violations.",
            "Coverage is limited to the datasets imported so far."
        ]
        if cases.count >= 1_000 {
            limitations.append("Counts reflect the first 1,000 matching case records; the true total may be higher.")
        }
        let summary = NlrbPartyHistorySummary(
            partyName: partyName,
            totalMatchingCaseRecords: cases.count,
            countsByCaseType: counts { $0.caseType },
            countsByCaseTypeCategory: counts { $0.caseTypeCategory.rawValue },
            countsByRegion: counts { $0.region },
            countsByStatus: counts { $0.status },
            reasonClosedDistribution: counts { $0.reasonClosed },
            recentCases: Array(recent),
            electionResults: elections,
            sourceVariantsUsed: variants.sorted(),
            limitations: limitations,
            summaryText: Self.historySummaryText(
                partyName: partyName, caseCount: cases.count,
                categories: counts { $0.caseTypeCategory.rawValue },
                electionCount: elections.count
            ),
            generatedAt: now()
        )
        return summary
    }

    /// Neutral wording only: "matching case records", never "violations".
    static func historySummaryText(
        partyName: String,
        caseCount: Int,
        categories: [String: Int],
        electionCount: Int
    ) -> String {
        var lines = [
            "The locally imported NLRB exports contain \(caseCount) matching case records for \(partyName)."
        ]
        // Omit the "unknown" bucket from the human-readable breakdown — an
        // "unknown: N" category is noise, not information (the cases still
        // count toward the total above; the structured field keeps the count).
        let namedCategories = categories.filter { $0.key != NlrbCaseTypeCategory.unknown.rawValue }
        if !namedCategories.isEmpty {
            let breakdown = namedCategories
                .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .map { "\($0.key.replacingOccurrences(of: "_", with: " ")): \($0.value)" }
                .joined(separator: ", ")
            lines.append("By case category — \(breakdown).")
        }
        if electionCount > 0 {
            lines.append("\(electionCount) election result record(s) reference this party.")
        }
        lines.append("These are case records from official NLRB exports, not findings or adjudications.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Ingestion

    public func toIngestionRecords(_ records: [NlrbIngestibleRecord]) throws -> [LegalDataIngestionRecord] {
        try records.map { record in
            switch record {
            case .case(let caseRecord):
                return LegalDataIngestionRecord(
                    source: Self.connectorName,
                    sourceVariant: caseRecord.sourceVariant.rawValue,
                    sourceRecordType: caseRecord.sourceRecordType,
                    sourceRecordId: "nlrb:case:\(NlrbLocalRecordStore.normalizedCaseNumber(caseRecord.caseNumber))",
                    sourceUrl: caseRecord.sourceUrl,
                    retrievedAt: caseRecord.retrievedAt,
                    rawPayload: caseRecord.raw,
                    normalizedPayload: try encodeToJSONValue(caseRecord),
                    ragText: NlrbNormalizer.ragText(for: caseRecord)
                )
            case .electionResult(let election):
                let idParts = [
                    "nlrb", "election",
                    NlrbLocalRecordStore.normalizedCaseNumber(election.caseNumber),
                    election.unitId ?? "", election.tallyDate ?? ""
                ]
                return LegalDataIngestionRecord(
                    source: Self.connectorName,
                    sourceVariant: election.sourceVariant.rawValue,
                    sourceRecordType: election.sourceRecordType,
                    sourceRecordId: idParts.joined(separator: ":"),
                    sourceUrl: election.sourceUrl,
                    retrievedAt: election.retrievedAt,
                    rawPayload: election.raw,
                    normalizedPayload: try encodeToJSONValue(election),
                    ragText: NlrbNormalizer.ragText(for: election)
                )
            case .historicalCase(let historical):
                return LegalDataIngestionRecord(
                    source: Self.connectorName,
                    sourceVariant: historical.sourceVariant.rawValue,
                    sourceRecordType: historical.sourceRecordType,
                    sourceRecordId: "nlrb:historical:\(historical.historicalSystem ?? "unknown"):\(NlrbLocalRecordStore.normalizedCaseNumber(historical.caseNumber))",
                    sourceUrl: historical.sourceUrl,
                    retrievedAt: historical.retrievedAt,
                    rawPayload: historical.raw,
                    normalizedPayload: try encodeToJSONValue(historical),
                    ragText: "NLRB historical case record (case number \(historical.caseNumber)). Source: historical NLRB dataset."
                )
            }
        }
    }

    // MARK: - Shared

    private func filteredCases(_ filters: NlrbCaseFilters, category: NlrbCaseTypeCategory) async throws -> [NlrbCaseRecord] {
        var cases = await localStore.allCases().filter { $0.caseTypeCategory == category }
        if let query = filters.query {
            let needle = NlrbLocalRecordStore.normalizedPartyKey(query)
            cases = cases.filter { record in
                [record.caseName, record.employer, record.union, record.allegations]
                    .compactMap { $0 }
                    .contains { NlrbLocalRecordStore.normalizedPartyKey($0).contains(needle) }
            }
        }
        if let caseNumber = filters.caseNumber {
            let key = NlrbLocalRecordStore.normalizedCaseNumber(caseNumber)
            cases = cases.filter { NlrbLocalRecordStore.normalizedCaseNumber($0.caseNumber) == key }
        }
        if let employer = filters.employer {
            let needle = NlrbLocalRecordStore.normalizedPartyKey(employer)
            cases = cases.filter { $0.employer.map { NlrbLocalRecordStore.normalizedPartyKey($0).contains(needle) } ?? false }
        }
        if let union = filters.union {
            let needle = NlrbLocalRecordStore.normalizedPartyKey(union)
            cases = cases.filter { $0.union.map { NlrbLocalRecordStore.normalizedPartyKey($0).contains(needle) } ?? false }
        }
        if let partyName = filters.partyName {
            let needle = NlrbLocalRecordStore.normalizedPartyKey(partyName)
            cases = cases.filter { record in
                [record.employer, record.union, record.caseName]
                    .compactMap { $0 }
                    .contains { NlrbLocalRecordStore.normalizedPartyKey($0).contains(needle) }
            }
        }
        if let caseType = filters.caseType?.trimmingCharacters(in: .whitespacesAndNewlines), !caseType.isEmpty {
            cases = cases.filter { $0.caseType?.caseInsensitiveCompare(caseType) == .orderedSame }
        }
        if let categoryFilter = filters.caseTypeCategory?.trimmingCharacters(in: .whitespacesAndNewlines), !categoryFilter.isEmpty {
            cases = cases.filter { $0.caseTypeCategory.rawValue.caseInsensitiveCompare(categoryFilter) == .orderedSame }
        }
        if let region = filters.region {
            let needle = region.lowercased()
            cases = cases.filter { $0.region?.lowercased().contains(needle) == true }
        }
        if let status = filters.status {
            cases = cases.filter { $0.status?.caseInsensitiveCompare(status) == .orderedSame }
        }
        if let start = try Self.dayFilter(filters.startDate, field: "startDate", operation: "searchCases") {
            cases = cases.filter { NlrbNormalizer.parseDay($0.dateFiled).map { $0 >= start } ?? false }
        }
        if let end = try Self.dayFilter(filters.endDate, field: "endDate", operation: "searchCases") {
            cases = cases.filter { NlrbNormalizer.parseDay($0.dateFiled).map { $0 <= end } ?? false }
        }
        return cases
    }

    /// A nil/blank filter is "no filter"; a non-blank unparseable one throws —
    /// silently dropping it would silently WIDEN the search.
    private static func dayFilter(_ value: String?, field: String, operation: String) throws -> Date? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let parsed = NlrbNormalizer.parseDay(value) else {
            throw LegalDataConnectorError(
                kind: .validation,
                connectorName: Self.connectorName,
                operation: operation,
                message: "The \(field) filter must be an ISO date (yyyy-MM-dd) or an NLRB display date (MM/dd/yyyy)."
            )
        }
        return parsed
    }

    private func bounded(_ records: [NlrbCaseRecord], options: NlrbSearchOptions) -> [NlrbCaseRecord] {
        Array(records.prefix(min(max(options.limit, 1), 1_000)))
    }

    private func htmlRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return request
    }

    private func encodeToJSONValue<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }
}
