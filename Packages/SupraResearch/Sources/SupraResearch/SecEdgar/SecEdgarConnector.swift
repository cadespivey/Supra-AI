import Foundation
import SupraNetworking

/// SEC EDGAR connector (plan Phase 2): company submissions, filing history
/// (including lazy historical continuation files), XBRL facts/concept/frame,
/// browser-facing filing URLs, and neutral ingestion records.
///
/// Requests go ONLY to `data.sec.gov` through the shared executor
/// (`sendUnauthenticated`; the CourtListener-token path is never used) and
/// always carry the user's declared `SUPRA_SEC_EDGAR_USER_AGENT` — checked
/// BEFORE any network work per SEC's fair-access policy. App-side wiring
/// should give this connector its OWN `AuthorizedHTTPClient` with a
/// SEC-appropriate `RateLimitTracker` (120/min, 600/hr — amendment #2); the
/// default 5/min tracker is CourtListener-tuned and would starve pagination.
public final class SecEdgarConnector: @unchecked Sendable {
    public static let connectorName = "sec_edgar"

    private let configuration: LegalDataConnectorConfiguration
    private let executor: ConnectorHTTPExecutor
    private let now: @Sendable () -> Date

    static let submissionsTTL: TimeInterval = 6 * 3_600
    static let xbrlTTL: TimeInterval = 24 * 3_600

    public init(
        httpClient: any AuthorizedHTTPClientProtocol,
        configuration: LegalDataConnectorConfiguration = .fromEnvironment(),
        cache: any LegalDataConnectorCache,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.now = now
        self.executor = ConnectorHTTPExecutor(
            connectorName: Self.connectorName,
            httpClient: httpClient,
            pacer: ConnectorPacer(requestsPerSecond: configuration.secEdgarRateLimitPerSecond),
            cache: cache,
            now: now
        )
    }

    /// Test seam: identical wiring but with an injectable retry sleeper so
    /// retry tests don't actually wait.
    init(
        httpClient: any AuthorizedHTTPClientProtocol,
        configuration: LegalDataConnectorConfiguration,
        cache: any LegalDataConnectorCache,
        now: @escaping @Sendable () -> Date,
        retrySleeper: @escaping @Sendable (TimeInterval) async -> Void
    ) {
        self.configuration = configuration
        self.now = now
        var executor = ConnectorHTTPExecutor(
            connectorName: Self.connectorName,
            httpClient: httpClient,
            pacer: ConnectorPacer(requestsPerSecond: configuration.secEdgarRateLimitPerSecond),
            cache: cache,
            now: now
        )
        executor.retrySleeper = retrySleeper
        self.executor = executor
    }

    // MARK: - Health

    /// Config-only: a health check must never surprise the app with public-
    /// service traffic. Live reachability is an opt-in test concern.
    public func healthCheck() async -> ConnectorHealth {
        let hasUserAgent = configuration.secEdgarUserAgent?.isEmpty == false
        return ConnectorHealth(
            connectorName: Self.connectorName,
            checkedAt: now(),
            reachable: hasUserAgent,
            message: hasUserAgent
                ? "Configuration is valid. SEC EDGAR requests are enabled."
                : "Set SUPRA_SEC_EDGAR_USER_AGENT to enable SEC EDGAR requests (SEC fair-access policy requires a contact User-Agent).",
            sanitizedMetadata: ["userAgentConfigured": hasUserAgent ? "true" : "false"]
        )
    }

    // MARK: - CIK normalization

    /// Accepts common CIK spellings — whitespace, internal spaces, and hyphens
    /// only — then requires pure digits, 1–10 of them, left-padded to 10.
    /// Letters and URL punctuation are validation errors, never stripped: a
    /// value like "CIK320193" or "320193?x=1" signals caller confusion that
    /// silent cleanup would hide.
    public static func normalizeCik(_ cik: String) throws -> String {
        let despaced = cik
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
        // Hyphens are harmless FORMATTING only between digits — a leading or
        // trailing hyphen reads as a sign or a typo, not formatting.
        guard !despaced.hasPrefix("-"), !despaced.hasSuffix("-") else {
            throw SecEdgarErrorMapping.validationError(
                operation: "normalizeCik",
                message: "A CIK must be 1–10 digits (whitespace and internal hyphens are tolerated; letters and punctuation are not)."
            )
        }
        let cleaned = despaced.replacingOccurrences(of: "-", with: "")
        // ASCII digits only: Character.isNumber accepts Unicode digits that
        // Int() rejects and SEC URLs cannot carry.
        guard !cleaned.isEmpty, cleaned.count <= 10, cleaned.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw SecEdgarErrorMapping.validationError(
                operation: "normalizeCik",
                message: "A CIK must be 1–10 digits (whitespace and internal hyphens are tolerated; letters and punctuation are not)."
            )
        }
        return String(repeating: "0", count: 10 - cleaned.count) + cleaned
    }

    public static func normalizeCik(_ cik: Int) throws -> String {
        guard cik > 0 else {
            throw SecEdgarErrorMapping.validationError(
                operation: "normalizeCik",
                message: "A CIK must be a positive integer."
            )
        }
        return try normalizeCik(String(cik))
    }

    // MARK: - Submissions + filings

    public func getCompanySubmissions(_ cik: String) async throws -> SecCompanySubmissions {
        let operation = "getCompanySubmissions"
        let normalized = try Self.normalizeCik(cik)
        let url = SecEdgarEndpoint.submissions(normalizedCik: normalized)
        let payload = try await fetchJSON(operation: operation, url: url, ttl: Self.submissionsTTL)
        return try SecEdgarNormalizer.submissions(
            from: payload,
            cik: normalized,
            sourceUrl: url.absoluteString,
            retrievedAt: now(),
            operation: operation
        )
    }

    /// Top-level recent filings only — historical continuation files are
    /// loaded lazily by `getFilingByAccession`, never here.
    public func getRecentFilings(cik: String, filters: SecFilingFilters = .init()) async throws -> [SecFilingRecord] {
        let submissions = try await getCompanySubmissions(cik)
        return try Self.apply(filters, to: submissions.recentFilings, operation: "getRecentFilings")
    }

    /// Recent filings first; on a miss, walks the historical continuation
    /// files listed in `submissions.files` (each cached independently) until
    /// the accession is found or the list is exhausted.
    public func getFilingByAccession(cik: String, accessionNumber: String) async throws -> SecFilingRecord? {
        let operation = "getFilingByAccession"
        let target = try Self.undashedAccession(accessionNumber, operation: operation)
        let submissions = try await getCompanySubmissions(cik)
        if let match = submissions.recentFilings.first(where: {
            (try? Self.undashedAccession($0.accessionNumber, operation: operation)) == target
        }) {
            return match
        }
        for fileName in submissions.continuationFileNames {
            let url = try SecEdgarEndpoint.submissionsContinuation(fileName: fileName, operation: operation)
            let payload = try await fetchJSON(operation: operation, url: url, ttl: Self.submissionsTTL)
            var warnings: [String] = []
            let filings = SecEdgarNormalizer.zipColumnarFilings(
                payload,
                company: submissions.company,
                sourceUrl: url.absoluteString,
                retrievedAt: now(),
                warnings: &warnings
            )
            if let match = filings.first(where: {
                (try? Self.undashedAccession($0.accessionNumber, operation: operation)) == target
            }) {
                return match
            }
        }
        return nil
    }

    // MARK: - Form-family helpers

    /// Form families, the single source of truth shared by the fetch helpers
    /// and by `filings(in:formFamily:...)` so callers that already hold a
    /// submissions payload don't re-fetch it.
    public static let annualReportForms = ["10-K", "10-K/A", "20-F", "20-F/A", "40-F", "40-F/A"]
    public static let quarterlyReportForms = ["10-Q", "10-Q/A"]
    public static let currentReportForms = ["8-K", "8-K/A", "6-K", "6-K/A"]

    public func getAnnualReports(cik: String, filters: SecFilingFilters = .init()) async throws -> [SecFilingRecord] {
        try await filingsForForms(cik: cik, forms: Self.annualReportForms, filters: filters)
    }

    public func getQuarterlyReports(cik: String, filters: SecFilingFilters = .init()) async throws -> [SecFilingRecord] {
        try await filingsForForms(cik: cik, forms: Self.quarterlyReportForms, filters: filters)
    }

    public func getCurrentReports(cik: String, filters: SecFilingFilters = .init()) async throws -> [SecFilingRecord] {
        try await filingsForForms(cik: cik, forms: Self.currentReportForms, filters: filters)
    }

    /// 8-K family with an optional item filter (e.g. "1.01"); matching is a
    /// substring test over the source's comma-separated `items` field.
    public func getMaterialEventFilings(cik: String, item: String? = nil, filters: SecFilingFilters = .init()) async throws -> [SecFilingRecord] {
        let reports = try await filingsForForms(cik: cik, forms: ["8-K", "8-K/A"], filters: filters)
        guard let item = SecEdgarNormalizer.nonEmpty(item) else { return reports }
        return reports.filter { $0.items?.contains(item) == true }
    }

    /// Metadata-first exhibit screen: form families that commonly attach
    /// exhibits, or descriptions/items suggesting one. Document bodies are
    /// never downloaded.
    public func getRecentExhibitBearingFilings(cik: String, filters: SecFilingFilters = .init()) async throws -> [SecFilingRecord] {
        let filings = try await getRecentFilings(cik: cik, filters: filters)
        return filings.filter { filing in
            let form = filing.form?.uppercased() ?? ""
            if form.hasPrefix("8-K") || form.hasPrefix("S-") || form.hasPrefix("10-K") || form.hasPrefix("10-Q") {
                return true
            }
            let description = filing.primaryDocDescription?.lowercased() ?? ""
            return description.contains("exhibit") || (filing.items?.contains("9.01") == true)
        }
    }

    public func getCompanyProfile(_ cik: String) async throws -> SecCompanyRecord {
        try await getCompanySubmissions(cik).company
    }

    private func filingsForForms(cik: String, forms: [String], filters: SecFilingFilters) async throws -> [SecFilingRecord] {
        let submissions = try await getCompanySubmissions(cik)
        return try Self.filings(in: submissions, formFamily: forms, filters: filters, operation: "getRecentFilings")
    }

    /// Filters an ALREADY-FETCHED submissions payload by form family — no
    /// network. Callers that already hold submissions (e.g. a company view
    /// that fetched the header) use this to avoid re-fetching the same JSON.
    /// Semantics match `getRecentFilings` + the form-family merge exactly.
    public static func filings(
        in submissions: SecCompanySubmissions,
        formFamily: [String],
        filters: SecFilingFilters = .init(),
        operation: String
    ) throws -> [SecFilingRecord] {
        var merged = filters
        if merged.formTypes.isEmpty {
            // The family list is connector-injected, not caller-explicit, so
            // includeAmendments=false strips its /A members.
            merged.formTypes = filters.includeAmendments ? formFamily : formFamily.filter { !$0.hasSuffix("/A") }
        } else {
            let allowed = Set(formFamily.map { $0.uppercased() })
            merged.formTypes = merged.formTypes.filter { allowed.contains($0.trimmingCharacters(in: .whitespaces).uppercased()) }
            if merged.formTypes.isEmpty { return [] }
        }
        return try apply(merged, to: submissions.recentFilings, operation: operation)
    }

    // MARK: - XBRL

    public func getCompanyFacts(_ cik: String) async throws -> SecCompanyFacts {
        let operation = "getCompanyFacts"
        let normalized = try Self.normalizeCik(cik)
        let url = SecEdgarEndpoint.companyFacts(normalizedCik: normalized)
        let payload = try await fetchJSON(operation: operation, url: url, ttl: Self.xbrlTTL)
        return try SecEdgarNormalizer.companyFacts(
            from: payload, cik: normalized, sourceUrl: url.absoluteString, retrievedAt: now(), operation: operation
        )
    }

    public func getCompanyConcept(cik: String, taxonomy: String, concept: String) async throws -> SecCompanyConcept {
        let operation = "getCompanyConcept"
        let normalized = try Self.normalizeCik(cik)
        let safeTaxonomy = try SecEdgarEndpoint.validatedPathComponent(taxonomy, field: "taxonomy", operation: operation)
        let safeConcept = try SecEdgarEndpoint.validatedPathComponent(concept, field: "concept", operation: operation)
        let url = SecEdgarEndpoint.companyConcept(normalizedCik: normalized, taxonomy: safeTaxonomy, concept: safeConcept)
        let payload = try await fetchJSON(operation: operation, url: url, ttl: Self.xbrlTTL)
        return try SecEdgarNormalizer.companyConcept(
            from: payload, cik: normalized, taxonomy: safeTaxonomy, concept: safeConcept,
            sourceUrl: url.absoluteString, retrievedAt: now(), operation: operation
        )
    }

    public func getFrame(taxonomy: String, concept: String, unit: String, frame: String) async throws -> SecFrame {
        let operation = "getFrame"
        let safeTaxonomy = try SecEdgarEndpoint.validatedPathComponent(taxonomy, field: "taxonomy", operation: operation)
        let safeConcept = try SecEdgarEndpoint.validatedPathComponent(concept, field: "concept", operation: operation)
        let safeUnit = try SecEdgarEndpoint.validatedPathComponent(unit, field: "unit", operation: operation)
        let safeFrame = try SecEdgarEndpoint.validatedPathComponent(frame, field: "frame", operation: operation)
        let url = SecEdgarEndpoint.frames(taxonomy: safeTaxonomy, concept: safeConcept, unit: safeUnit, frame: safeFrame)
        let payload = try await fetchJSON(operation: operation, url: url, ttl: Self.xbrlTTL)
        return try SecEdgarNormalizer.frame(
            from: payload, taxonomy: safeTaxonomy, concept: safeConcept, unit: safeUnit, frame: safeFrame,
            sourceUrl: url.absoluteString, retrievedAt: now(), operation: operation
        )
    }

    // MARK: - Filing URLs

    /// Browser-facing archive URLs. Accepts dashed (`0000320193-23-000106`) or
    /// undashed accession numbers; the archive path uses the undashed form and
    /// the CIK without leading zeros.
    public static func buildFilingUrl(
        cik: String,
        accessionNumber: String,
        primaryDocument: String?
    ) throws -> SecFilingURLs {
        let operation = "buildFilingUrl"
        let normalized = try normalizeCik(cik)
        let undashed = try undashedAccession(accessionNumber, operation: operation)
        let stripped = normalized.drop { $0 == "0" }
        let cikWithoutZeros = stripped.isEmpty ? "0" : String(stripped)
        let filingUrl = SecEdgarEndpoint.filingArchiveURLString(
            cikWithoutLeadingZeros: cikWithoutZeros,
            undashedAccession: undashed
        )
        guard let primaryDocument = SecEdgarNormalizer.nonEmpty(primaryDocument) else {
            return SecFilingURLs(filingUrl: filingUrl)
        }
        let encoded = try SecEdgarEndpoint.encodedPrimaryDocumentPath(primaryDocument, operation: operation)
        return SecFilingURLs(filingUrl: filingUrl, primaryDocumentUrl: filingUrl + encoded)
    }

    static func undashedAccession(_ accession: String, operation: String) throws -> String {
        let undashed = accession
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
        guard undashed.count == 18, undashed.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw SecEdgarErrorMapping.validationError(
                operation: operation,
                message: "An accession number must be 18 digits (dashes are tolerated)."
            )
        }
        return undashed
    }

    // MARK: - Filters

    public static func apply(_ filters: SecFilingFilters, to filings: [SecFilingRecord], operation: String) throws -> [SecFilingRecord] {
        try validateISODate(filters.startDate, field: "startDate", operation: operation)
        try validateISODate(filters.endDate, field: "endDate", operation: operation)
        let forms = Set(filters.formTypes.map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty })
        let accessionTarget = try filters.accessionNumber.map { try undashedAccession($0, operation: operation) }

        var result = filings.filter { filing in
            let form = filing.form?.uppercased() ?? ""
            if !forms.isEmpty {
                // An explicitly requested amended form wins over
                // includeAmendments=false (plan filter semantics).
                guard forms.contains(form) else { return false }
            } else if !filters.includeAmendments, form.hasSuffix("/A") {
                return false
            }
            if let start = filters.startDate {
                guard let date = filing.filingDate, date >= start else { return false }
            }
            if let end = filters.endDate {
                guard let date = filing.filingDate, date <= end else { return false }
            }
            if let accessionTarget {
                guard (try? undashedAccession(filing.accessionNumber, operation: operation)) == accessionTarget else {
                    return false
                }
            }
            return true
        }
        if let limit = filters.limit {
            result = Array(result.prefix(min(max(limit, 1), 1_000)))
        }
        return result
    }

    private static func validateISODate(_ value: String?, field: String, operation: String) throws {
        guard let value else { return }
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            throw SecEdgarErrorMapping.validationError(
                operation: operation,
                message: "The \(field) filter must be an ISO date (yyyy-MM-dd)."
            )
        }
    }

    // MARK: - Ingestion records

    public func toIngestionRecords(_ records: [SecFilingRecord]) throws -> [LegalDataIngestionRecord] {
        try records.map { filing in
            guard let normalized = try? encodeToJSONValue(filing) else {
                throw SecEdgarErrorMapping.encodingError(operation: "toIngestionRecords")
            }
            return LegalDataIngestionRecord(
                source: Self.connectorName,
                sourceRecordType: filing.sourceRecordType,
                sourceRecordId: "sec_edgar:filing:\(filing.cik):\(filing.accessionNumber)",
                sourceUrl: filing.filingUrl.isEmpty ? filing.sourceUrl : filing.filingUrl,
                retrievedAt: filing.retrievedAt,
                rawPayload: filing.raw,
                normalizedPayload: normalized,
                ragText: SecEdgarNormalizer.ragText(for: filing)
            )
        }
    }

    public func toIngestionRecords(_ records: [SecXbrlRecord]) throws -> [LegalDataIngestionRecord] {
        try records.map { record in
            guard let normalized = try? encodeToJSONValue(record) else {
                throw SecEdgarErrorMapping.encodingError(operation: "toIngestionRecords")
            }
            let id = [
                "sec_edgar", "xbrl", record.sourceRecordType,
                record.cik ?? "", record.taxonomy ?? "", record.concept ?? "",
                record.unit ?? "", record.period ?? "", record.accessionNumber ?? ""
            ].joined(separator: ":")
            return LegalDataIngestionRecord(
                source: Self.connectorName,
                sourceRecordType: record.sourceRecordType,
                sourceRecordId: id,
                sourceUrl: record.sourceUrl,
                retrievedAt: record.retrievedAt,
                rawPayload: record.raw,
                normalizedPayload: normalized,
                ragText: SecEdgarNormalizer.ragText(for: record)
            )
        }
    }

    private func encodeToJSONValue<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }

    // MARK: - Shared request path

    private func fetchJSON(operation: String, url: URL, ttl: TimeInterval) async throws -> JSONValue {
        // Fail fast on missing UA BEFORE the cache/pacer/network do any work.
        let userAgent = try configuration.requireSecEdgarUserAgent(
            connectorName: Self.connectorName, operation: operation
        )
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await executor.execute(operation: operation, request: request, cacheTTL: ttl)
        do {
            return try JSONValue.fromData(response.data)
        } catch {
            throw SecEdgarErrorMapping.parseError(operation: operation, sourceURL: url.absoluteString)
        }
    }
}
