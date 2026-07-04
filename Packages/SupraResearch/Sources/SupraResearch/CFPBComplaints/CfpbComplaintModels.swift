import Foundation

/// Normalized CFPB consumer-complaint models. Complaints are ALLEGATIONS
/// consumers submitted to a government database — nothing here may imply a
/// complaint is true, proven, adjudicated, or legally meritorious, and the
/// models preserve every raw source object as `JSONValue`.

public struct CfpbComplaintFilters: Codable, Equatable, Sendable {
    public var company: [String]
    public var product: [String]
    /// Not a confirmed first-class API filter — applied CLIENT-SIDE over the
    /// bounded page set (limitation surfaced in `sourceLimitations`).
    public var subProduct: [String]
    public var issue: [String]
    /// Client-side only, like `subProduct`.
    public var subIssue: [String]
    public var state: [String]
    public var zipCode: [String]
    public var dateReceivedMin: String?
    public var dateReceivedMax: String?
    public var companyResponse: [String]
    public var timely: String?
    /// Client-side only, like `subProduct`.
    public var consumerDisputed: String?
    public var hasNarrative: Bool?
    public var submittedVia: [String]
    public var tags: [String]

    public init(
        company: [String] = [],
        product: [String] = [],
        subProduct: [String] = [],
        issue: [String] = [],
        subIssue: [String] = [],
        state: [String] = [],
        zipCode: [String] = [],
        dateReceivedMin: String? = nil,
        dateReceivedMax: String? = nil,
        companyResponse: [String] = [],
        timely: String? = nil,
        consumerDisputed: String? = nil,
        hasNarrative: Bool? = nil,
        submittedVia: [String] = [],
        tags: [String] = []
    ) {
        self.company = company
        self.product = product
        self.subProduct = subProduct
        self.issue = issue
        self.subIssue = subIssue
        self.state = state
        self.zipCode = zipCode
        self.dateReceivedMin = dateReceivedMin
        self.dateReceivedMax = dateReceivedMax
        self.companyResponse = companyResponse
        self.timely = timely
        self.consumerDisputed = consumerDisputed
        self.hasNarrative = hasNarrative
        self.submittedVia = submittedVia
        self.tags = tags
    }
}

public enum CfpbSearchField: String, Codable, Equatable, Sendable {
    case complaintWhatHappened = "complaint_what_happened"
    case companyPublicResponse = "company_public_response"
    case all
}

public struct CfpbComplaintQueryOptions: Codable, Equatable, Sendable {
    /// Page size; clamped to 1...1000 (default 100).
    public var size: Int
    /// Pages fetched per call; clamped to 1...20, or 1...100 when
    /// `allowsLargeExport` (never unbounded).
    public var maxPages: Int
    public var sort: String
    public var noAggregations: Bool
    public var noHighlight: Bool
    public var allowsLargeExport: Bool

    public init(
        size: Int = 100,
        maxPages: Int = 5,
        sort: String = "created_date_desc",
        noAggregations: Bool = false,
        noHighlight: Bool = true,
        allowsLargeExport: Bool = false
    ) {
        self.size = size
        self.maxPages = maxPages
        self.sort = sort
        self.noAggregations = noAggregations
        self.noHighlight = noHighlight
        self.allowsLargeExport = allowsLargeExport
    }
}

public struct CfpbComplaintQuery: Codable, Equatable, Sendable {
    public var searchTerm: String?
    public var field: CfpbSearchField
    public var filters: CfpbComplaintFilters
    public var options: CfpbComplaintQueryOptions

    public init(
        searchTerm: String? = nil,
        field: CfpbSearchField = .complaintWhatHappened,
        filters: CfpbComplaintFilters = .init(),
        options: CfpbComplaintQueryOptions = .init()
    ) {
        self.searchTerm = searchTerm
        self.field = field
        self.filters = filters
        self.options = options
    }
}

public enum CfpbTrendInterval: String, Codable, Equatable, Sendable {
    case month
    case quarter
    case year
}

public struct CfpbComplaintProfileOptions: Codable, Equatable, Sendable {
    public var filters: CfpbComplaintFilters
    public var sampleNarrativeLimit: Int
    public var trendInterval: CfpbTrendInterval
    public var queryOptions: CfpbComplaintQueryOptions

    public init(
        filters: CfpbComplaintFilters = .init(),
        sampleNarrativeLimit: Int = 5,
        trendInterval: CfpbTrendInterval = .month,
        queryOptions: CfpbComplaintQueryOptions = .init()
    ) {
        self.filters = filters
        self.sampleNarrativeLimit = sampleNarrativeLimit
        self.trendInterval = trendInterval
        self.queryOptions = queryOptions
    }
}

public struct CfpbComplaintRecord: Codable, Equatable, Sendable {
    public var source: String
    public var sourceRecordType: String
    public var complaintId: String
    public var company: String?
    public var product: String?
    public var subProduct: String?
    public var issue: String?
    public var subIssue: String?
    public var state: String?
    public var zipCode: String?
    public var dateReceived: String?
    public var dateSentToCompany: String?
    public var companyResponse: String?
    public var companyPublicResponse: String?
    public var consumerConsentProvided: String?
    public var consumerDisputed: String?
    /// The consumer's own narrative, present only when published.
    public var narrative: String?
    public var submittedVia: String?
    public var tags: [String]
    public var timely: String?
    public var hasNarrative: Bool?
    public var sourceUrl: String
    public var retrievedAt: Date
    public var raw: JSONValue

    public init(
        source: String = "cfpb_complaints",
        sourceRecordType: String = "consumer_complaint",
        complaintId: String,
        company: String? = nil,
        product: String? = nil,
        subProduct: String? = nil,
        issue: String? = nil,
        subIssue: String? = nil,
        state: String? = nil,
        zipCode: String? = nil,
        dateReceived: String? = nil,
        dateSentToCompany: String? = nil,
        companyResponse: String? = nil,
        companyPublicResponse: String? = nil,
        consumerConsentProvided: String? = nil,
        consumerDisputed: String? = nil,
        narrative: String? = nil,
        submittedVia: String? = nil,
        tags: [String] = [],
        timely: String? = nil,
        hasNarrative: Bool? = nil,
        sourceUrl: String,
        retrievedAt: Date,
        raw: JSONValue
    ) {
        self.source = source
        self.sourceRecordType = sourceRecordType
        self.complaintId = complaintId
        self.company = company
        self.product = product
        self.subProduct = subProduct
        self.issue = issue
        self.subIssue = subIssue
        self.state = state
        self.zipCode = zipCode
        self.dateReceived = dateReceived
        self.dateSentToCompany = dateSentToCompany
        self.companyResponse = companyResponse
        self.companyPublicResponse = companyPublicResponse
        self.consumerConsentProvided = consumerConsentProvided
        self.consumerDisputed = consumerDisputed
        self.narrative = narrative
        self.submittedVia = submittedVia
        self.tags = tags
        self.timely = timely
        self.hasNarrative = hasNarrative
        self.sourceUrl = sourceUrl
        self.retrievedAt = retrievedAt
        self.raw = raw
    }
}

public struct CfpbComplaintSearchResult: Codable, Equatable, Sendable {
    public var complaints: [CfpbComplaintRecord]
    /// The source's reported total when available (can exceed what was fetched).
    public var totalCount: Int?
    public var pagesFetched: Int
    /// Client-side-filter and bounding caveats accrued while fetching.
    public var sourceLimitations: [String]

    public init(
        complaints: [CfpbComplaintRecord],
        totalCount: Int?,
        pagesFetched: Int,
        sourceLimitations: [String]
    ) {
        self.complaints = complaints
        self.totalCount = totalCount
        self.pagesFetched = pagesFetched
        self.sourceLimitations = sourceLimitations
    }
}

public struct CfpbComplaintTrendBucket: Codable, Equatable, Sendable {
    /// First day of the bucket (`yyyy-MM-dd`).
    public var intervalStart: String
    /// Last day of the bucket (`yyyy-MM-dd`).
    public var intervalEnd: String
    public var count: Int
    public var topProducts: [String]
    public var topIssues: [String]
    /// Empty when a company filter narrows the query to one company.
    public var topCompanies: [String]

    public init(
        intervalStart: String,
        intervalEnd: String,
        count: Int,
        topProducts: [String] = [],
        topIssues: [String] = [],
        topCompanies: [String] = []
    ) {
        self.intervalStart = intervalStart
        self.intervalEnd = intervalEnd
        self.count = count
        self.topProducts = topProducts
        self.topIssues = topIssues
        self.topCompanies = topCompanies
    }
}

/// Factual aggregation of a company's complaint records — counts and samples,
/// never conclusions.
public struct CfpbCompanyComplaintProfile: Codable, Equatable, Sendable {
    public var company: String
    public var totalMatchingComplaints: Int
    /// The source-reported total, which can exceed the bounded fetch.
    public var sourceReportedTotal: Int?
    public var countsByProduct: [String: Int]
    public var countsByIssue: [String: Int]
    public var countsByState: [String: Int]
    public var countsBySubmittedVia: [String: Int]
    public var countsByCompanyResponse: [String: Int]
    /// Share of fetched complaints marked timely = "Yes" (0–1); nil when the
    /// field is absent from every record.
    public var timelyResponseRate: Double?
    public var narrativeCount: Int
    public var sampleNarratives: [String]
    public var trend: [CfpbComplaintTrendBucket]
    public var limitations: [String]
    public var retrievedAt: Date

    public init(
        company: String,
        totalMatchingComplaints: Int,
        sourceReportedTotal: Int?,
        countsByProduct: [String: Int],
        countsByIssue: [String: Int],
        countsByState: [String: Int],
        countsBySubmittedVia: [String: Int],
        countsByCompanyResponse: [String: Int],
        timelyResponseRate: Double?,
        narrativeCount: Int,
        sampleNarratives: [String],
        trend: [CfpbComplaintTrendBucket],
        limitations: [String],
        retrievedAt: Date
    ) {
        self.company = company
        self.totalMatchingComplaints = totalMatchingComplaints
        self.sourceReportedTotal = sourceReportedTotal
        self.countsByProduct = countsByProduct
        self.countsByIssue = countsByIssue
        self.countsByState = countsByState
        self.countsBySubmittedVia = countsBySubmittedVia
        self.countsByCompanyResponse = countsByCompanyResponse
        self.timelyResponseRate = timelyResponseRate
        self.narrativeCount = narrativeCount
        self.sampleNarratives = sampleNarratives
        self.trend = trend
        self.limitations = limitations
        self.retrievedAt = retrievedAt
    }
}
