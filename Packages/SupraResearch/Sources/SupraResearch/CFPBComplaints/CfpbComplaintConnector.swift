import Foundation
import SupraNetworking

/// CFPB consumer-complaint connector (plan Phase 3): documented-parameter
/// search with bounded frm-offset pagination, complaint-by-ID, factual company
/// profiles, interval trends, and neutral ingestion records.
///
/// Complaints are consumer ALLEGATIONS in a public government database —
/// nothing this connector emits may read as a finding. Requests go only to
/// `www.consumerfinance.gov` through the shared executor. App-side wiring
/// should give this connector its OWN `AuthorizedHTTPClient` with a
/// CFPB-tuned `RateLimitTracker` (60/min, 300/hr — amendment #2).
public final class CfpbComplaintConnector: @unchecked Sendable {
    public static let connectorName = "cfpb_complaints"

    private let configuration: LegalDataConnectorConfiguration
    private let executor: ConnectorHTTPExecutor
    private let now: @Sendable () -> Date

    static let searchTTL: TimeInterval = 24 * 3_600

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
            pacer: ConnectorPacer(requestsPerSecond: configuration.cfpbRateLimitPerSecond),
            cache: cache,
            now: now
        )
    }

    /// Test seam with an injectable retry sleeper.
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
            pacer: ConnectorPacer(requestsPerSecond: configuration.cfpbRateLimitPerSecond),
            cache: cache,
            now: now
        )
        executor.retrySleeper = retrySleeper
        self.executor = executor
    }

    public func healthCheck() async -> ConnectorHealth {
        ConnectorHealth(
            connectorName: Self.connectorName,
            checkedAt: now(),
            reachable: true,
            message: "Configuration is valid. The CFPB complaint database requires no key.",
            sanitizedMetadata: [:]
        )
    }

    // MARK: - Search

    public func searchComplaints(_ query: CfpbComplaintQuery) async throws -> CfpbComplaintSearchResult {
        let operation = "searchComplaints"
        let size = min(max(query.options.size, 1), 1_000)
        let pageCap = query.options.allowsLargeExport ? 100 : 20
        let maxPages = min(max(query.options.maxPages, 1), pageCap)

        var limitations: [String] = []
        var complaints: [CfpbComplaintRecord] = []
        var totalCount: Int?
        var pagesFetched = 0

        for page in 0..<maxPages {
            let url = CfpbComplaintEndpoint.search(query: query, frm: page * size, size: size)
            let response = try await executor.execute(
                operation: operation,
                request: jsonRequest(url),
                cacheTTL: Self.searchTTL
            )
            let payload = try parse(response.data, operation: operation, url: url)
            if totalCount == nil { totalCount = CfpbComplaintNormalizer.reportedTotal(in: payload) }
            let pageRecords = CfpbComplaintNormalizer.complaintObjects(in: payload)
                .compactMap { CfpbComplaintNormalizer.record(from: $0, retrievedAt: now()) }
            complaints.append(contentsOf: pageRecords)
            pagesFetched = page + 1
            if pageRecords.count < size { break }
        }
        if let totalCount, complaints.count < totalCount {
            limitations.append("The source reports \(totalCount) matching complaints; \(complaints.count) were retrieved within the page bound.")
        }
        let filtered = CfpbComplaintNormalizer.applyClientSideFilters(
            complaints, filters: query.filters, limitations: &limitations
        )
        return CfpbComplaintSearchResult(
            complaints: filtered,
            totalCount: totalCount,
            pagesFetched: pagesFetched,
            sourceLimitations: limitations
        )
    }

    public func getComplaintById(_ complaintId: String) async throws -> CfpbComplaintRecord {
        let operation = "getComplaintById"
        let trimmed = complaintId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber) else {
            throw LegalDataConnectorError(
                kind: .validation,
                connectorName: Self.connectorName,
                operation: operation,
                message: "A complaint ID must be a positive whole number."
            )
        }
        let url = CfpbComplaintEndpoint.detail(complaintId: trimmed)
        let response = try await executor.execute(
            operation: operation, request: jsonRequest(url), cacheTTL: Self.searchTTL
        )
        let payload = try parse(response.data, operation: operation, url: url)
        guard let object = CfpbComplaintNormalizer.complaintObjects(in: payload).first,
              let record = CfpbComplaintNormalizer.record(from: object, retrievedAt: now()) else {
            throw LegalDataConnectorError(
                kind: .notFound,
                connectorName: Self.connectorName,
                operation: operation,
                sourceURL: url.absoluteString,
                message: "The complaint was not found."
            )
        }
        return record
    }

    // MARK: - Convenience searches

    public func searchByCompany(company: String, options: CfpbComplaintQueryOptions = .init()) async throws -> [CfpbComplaintRecord] {
        try await searchComplaints(
            CfpbComplaintQuery(filters: .init(company: [company]), options: options)
        ).complaints
    }

    public func searchByProduct(product: String, options: CfpbComplaintQueryOptions = .init()) async throws -> [CfpbComplaintRecord] {
        try await searchComplaints(
            CfpbComplaintQuery(filters: .init(product: [product]), options: options)
        ).complaints
    }

    public func searchByIssue(issue: String, options: CfpbComplaintQueryOptions = .init()) async throws -> [CfpbComplaintRecord] {
        try await searchComplaints(
            CfpbComplaintQuery(filters: .init(issue: [issue]), options: options)
        ).complaints
    }

    public func searchByState(state: String, options: CfpbComplaintQueryOptions = .init()) async throws -> [CfpbComplaintRecord] {
        try await searchComplaints(
            CfpbComplaintQuery(filters: .init(state: [state]), options: options)
        ).complaints
    }

    public func searchByDateRange(
        startDate: String,
        endDate: String,
        options: CfpbComplaintQueryOptions = .init()
    ) async throws -> [CfpbComplaintRecord] {
        try validateISODate(startDate, field: "startDate", operation: "searchByDateRange")
        try validateISODate(endDate, field: "endDate", operation: "searchByDateRange")
        return try await searchComplaints(
            CfpbComplaintQuery(
                filters: .init(dateReceivedMin: startDate, dateReceivedMax: endDate),
                options: options
            )
        ).complaints
    }

    // MARK: - Profile + trends

    public func getCompanyComplaintProfile(
        company: String,
        options: CfpbComplaintProfileOptions = .init()
    ) async throws -> CfpbCompanyComplaintProfile {
        var filters = options.filters
        filters.company = [company]
        let result = try await searchComplaints(
            CfpbComplaintQuery(filters: filters, options: options.queryOptions)
        )
        let records = result.complaints
        var limitations = result.sourceLimitations
        limitations.append("Counts describe complaint records in the CFPB database; the database does not adjudicate complaints.")

        let narratives = records.compactMap(\.narrative)
        return CfpbCompanyComplaintProfile(
            company: company,
            totalMatchingComplaints: records.count,
            sourceReportedTotal: result.totalCount,
            countsByProduct: CfpbComplaintAggregations.countsBy(records, \.product),
            countsByIssue: CfpbComplaintAggregations.countsBy(records, \.issue),
            countsByState: CfpbComplaintAggregations.countsBy(records, \.state),
            countsBySubmittedVia: CfpbComplaintAggregations.countsBy(records, \.submittedVia),
            countsByCompanyResponse: CfpbComplaintAggregations.countsBy(records, \.companyResponse),
            timelyResponseRate: CfpbComplaintAggregations.timelyRate(records),
            narrativeCount: narratives.count,
            sampleNarratives: Array(narratives.prefix(max(0, options.sampleNarrativeLimit))),
            trend: CfpbComplaintAggregations.trendBuckets(records, interval: options.trendInterval, includeCompanies: false),
            limitations: limitations,
            retrievedAt: now()
        )
    }

    /// Trends computed from BOUNDED search pages: the documented `/trends`
    /// endpoint returns counts without per-bucket product/issue/company
    /// breakdowns, so it cannot satisfy the bucket contract (limitation
    /// recorded in the connector doc).
    public func getComplaintTrends(
        filters: CfpbComplaintFilters,
        interval: CfpbTrendInterval,
        options: CfpbComplaintQueryOptions = .init()
    ) async throws -> [CfpbComplaintTrendBucket] {
        let result = try await searchComplaints(CfpbComplaintQuery(filters: filters, options: options))
        return CfpbComplaintAggregations.trendBuckets(
            result.complaints,
            interval: interval,
            includeCompanies: filters.company.isEmpty
        )
    }

    // MARK: - Ingestion

    public func toIngestionRecords(_ records: [CfpbComplaintRecord]) throws -> [LegalDataIngestionRecord] {
        try records.map { record in
            guard let normalized = try? encodeToJSONValue(record) else {
                throw LegalDataConnectorError(
                    kind: .importFailed,
                    connectorName: Self.connectorName,
                    operation: "toIngestionRecords",
                    message: "A normalized complaint record could not be encoded for ingestion."
                )
            }
            return LegalDataIngestionRecord(
                source: Self.connectorName,
                sourceRecordType: record.sourceRecordType,
                sourceRecordId: "cfpb_complaints:consumer_complaint:\(record.complaintId)",
                sourceUrl: record.sourceUrl,
                retrievedAt: record.retrievedAt,
                rawPayload: record.raw,
                normalizedPayload: normalized,
                ragText: CfpbComplaintNormalizer.ragText(for: record)
            )
        }
    }

    // MARK: - Shared

    private func jsonRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func parse(_ data: Data, operation: String, url: URL) throws -> JSONValue {
        do {
            return try JSONValue.fromData(data)
        } catch {
            throw LegalDataConnectorError(
                kind: .parse,
                connectorName: Self.connectorName,
                operation: operation,
                sourceURL: url.absoluteString,
                message: "The CFPB response could not be parsed as JSON."
            )
        }
    }

    private func validateISODate(_ value: String, field: String, operation: String) throws {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            throw LegalDataConnectorError(
                kind: .validation,
                connectorName: Self.connectorName,
                operation: operation,
                message: "The \(field) value must be an ISO date (yyyy-MM-dd)."
            )
        }
    }

    private func encodeToJSONValue<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }
}
