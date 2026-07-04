import Foundation

/// Normalized SEC EDGAR models. Every record preserves its raw source object
/// as `JSONValue` (`raw`) so nothing the normalizer doesn't yet understand is
/// lost; convenience fields are optional wherever the source may omit them.
/// SEC uses empty strings for absent columnar values — those normalize to nil
/// rather than surviving as placeholder text.

/// Company-level metadata from the top of a submissions response.
public struct SecCompanyRecord: Codable, Equatable, Sendable {
    public var source: String
    public var sourceRecordType: String
    public var cik: String
    public var entityName: String?
    public var tickers: [String]
    public var exchanges: [String]
    public var sic: String?
    public var sicDescription: String?
    public var ein: String?
    public var category: String?
    public var fiscalYearEnd: String?
    public var stateOfIncorporation: String?
    public var stateOfIncorporationDescription: String?
    /// Mailing/business addresses exactly as SEC ships them; not flattened
    /// because the shape is stable enough to consume as-is downstream.
    public var addresses: JSONValue?
    public var phone: String?
    public var formerNames: JSONValue?
    public var insiderTransactionForOwnerExists: Bool?
    public var insiderTransactionForIssuerExists: Bool?
    public var sourceUrl: String
    public var retrievedAt: Date
    public var raw: JSONValue

    public init(
        source: String = "sec_edgar",
        sourceRecordType: String = "company",
        cik: String,
        entityName: String? = nil,
        tickers: [String] = [],
        exchanges: [String] = [],
        sic: String? = nil,
        sicDescription: String? = nil,
        ein: String? = nil,
        category: String? = nil,
        fiscalYearEnd: String? = nil,
        stateOfIncorporation: String? = nil,
        stateOfIncorporationDescription: String? = nil,
        addresses: JSONValue? = nil,
        phone: String? = nil,
        formerNames: JSONValue? = nil,
        insiderTransactionForOwnerExists: Bool? = nil,
        insiderTransactionForIssuerExists: Bool? = nil,
        sourceUrl: String,
        retrievedAt: Date,
        raw: JSONValue
    ) {
        self.source = source
        self.sourceRecordType = sourceRecordType
        self.cik = cik
        self.entityName = entityName
        self.tickers = tickers
        self.exchanges = exchanges
        self.sic = sic
        self.sicDescription = sicDescription
        self.ein = ein
        self.category = category
        self.fiscalYearEnd = fiscalYearEnd
        self.stateOfIncorporation = stateOfIncorporation
        self.stateOfIncorporationDescription = stateOfIncorporationDescription
        self.addresses = addresses
        self.phone = phone
        self.formerNames = formerNames
        self.insiderTransactionForOwnerExists = insiderTransactionForOwnerExists
        self.insiderTransactionForIssuerExists = insiderTransactionForIssuerExists
        self.sourceUrl = sourceUrl
        self.retrievedAt = retrievedAt
        self.raw = raw
    }
}

/// One filing, zipped out of SEC's columnar `filings.recent` (or a historical
/// continuation file). Company context (name/tickers/…) is inherited from the
/// submissions envelope because the columnar rows don't repeat it. `raw` is
/// the reconstructed column→value row, values exactly as the source sent them.
public struct SecFilingRecord: Codable, Equatable, Sendable {
    public var source: String
    public var sourceRecordType: String
    public var cik: String
    public var entityName: String?
    public var tickers: [String]
    public var exchanges: [String]
    public var sic: String?
    public var sicDescription: String?
    public var ein: String?
    public var formerNames: JSONValue?
    public var accessionNumber: String
    public var filingDate: String?
    public var reportDate: String?
    public var acceptanceDateTime: String?
    public var act: String?
    public var form: String?
    public var fileNumber: String?
    public var filmNumber: String?
    public var items: String?
    public var size: Int?
    public var isXbrl: Bool?
    public var isInlineXbrl: Bool?
    public var primaryDocument: String?
    public var primaryDocDescription: String?
    /// Browser-facing archive URL (`www.sec.gov` — never fetched by the app).
    public var filingUrl: String
    public var primaryDocumentUrl: String?
    /// The `data.sec.gov` URL this metadata actually came from.
    public var sourceUrl: String
    public var retrievedAt: Date
    public var raw: JSONValue

    public init(
        source: String = "sec_edgar",
        sourceRecordType: String = "filing",
        cik: String,
        entityName: String? = nil,
        tickers: [String] = [],
        exchanges: [String] = [],
        sic: String? = nil,
        sicDescription: String? = nil,
        ein: String? = nil,
        formerNames: JSONValue? = nil,
        accessionNumber: String,
        filingDate: String? = nil,
        reportDate: String? = nil,
        acceptanceDateTime: String? = nil,
        act: String? = nil,
        form: String? = nil,
        fileNumber: String? = nil,
        filmNumber: String? = nil,
        items: String? = nil,
        size: Int? = nil,
        isXbrl: Bool? = nil,
        isInlineXbrl: Bool? = nil,
        primaryDocument: String? = nil,
        primaryDocDescription: String? = nil,
        filingUrl: String,
        primaryDocumentUrl: String? = nil,
        sourceUrl: String,
        retrievedAt: Date,
        raw: JSONValue
    ) {
        self.source = source
        self.sourceRecordType = sourceRecordType
        self.cik = cik
        self.entityName = entityName
        self.tickers = tickers
        self.exchanges = exchanges
        self.sic = sic
        self.sicDescription = sicDescription
        self.ein = ein
        self.formerNames = formerNames
        self.accessionNumber = accessionNumber
        self.filingDate = filingDate
        self.reportDate = reportDate
        self.acceptanceDateTime = acceptanceDateTime
        self.act = act
        self.form = form
        self.fileNumber = fileNumber
        self.filmNumber = filmNumber
        self.items = items
        self.size = size
        self.isXbrl = isXbrl
        self.isInlineXbrl = isInlineXbrl
        self.primaryDocument = primaryDocument
        self.primaryDocDescription = primaryDocDescription
        self.filingUrl = filingUrl
        self.primaryDocumentUrl = primaryDocumentUrl
        self.sourceUrl = sourceUrl
        self.retrievedAt = retrievedAt
        self.raw = raw
    }
}

/// One flattened XBRL fact (from company facts, a company concept, or a
/// frame). `sourceRecordType` is `company_fact`, `company_concept`, or
/// `frame`; `raw` is the individual fact object. Flattened summaries are
/// bounded (500 facts per response) — the full raw payload always survives on
/// the enclosing response model.
public struct SecXbrlRecord: Codable, Equatable, Sendable {
    public var source: String
    public var sourceRecordType: String
    public var cik: String?
    public var entityName: String?
    public var taxonomy: String?
    public var concept: String?
    public var label: String?
    public var conceptDescription: String?
    public var unit: String?
    /// `start/end` for durations, the instant date otherwise.
    public var period: String?
    public var fiscalYear: Int?
    public var fiscalPeriod: String?
    public var form: String?
    public var filedDate: String?
    public var accessionNumber: String?
    public var value: JSONValue?
    public var sourceUrl: String
    public var retrievedAt: Date
    public var raw: JSONValue

    public init(
        source: String = "sec_edgar",
        sourceRecordType: String,
        cik: String? = nil,
        entityName: String? = nil,
        taxonomy: String? = nil,
        concept: String? = nil,
        label: String? = nil,
        conceptDescription: String? = nil,
        unit: String? = nil,
        period: String? = nil,
        fiscalYear: Int? = nil,
        fiscalPeriod: String? = nil,
        form: String? = nil,
        filedDate: String? = nil,
        accessionNumber: String? = nil,
        value: JSONValue? = nil,
        sourceUrl: String,
        retrievedAt: Date,
        raw: JSONValue
    ) {
        self.source = source
        self.sourceRecordType = sourceRecordType
        self.cik = cik
        self.entityName = entityName
        self.taxonomy = taxonomy
        self.concept = concept
        self.label = label
        self.conceptDescription = conceptDescription
        self.unit = unit
        self.period = period
        self.fiscalYear = fiscalYear
        self.fiscalPeriod = fiscalPeriod
        self.form = form
        self.filedDate = filedDate
        self.accessionNumber = accessionNumber
        self.value = value
        self.sourceUrl = sourceUrl
        self.retrievedAt = retrievedAt
        self.raw = raw
    }
}

/// Everything one submissions fetch yields: the company record, the zipped
/// recent filings, the names of historical continuation files (loaded lazily
/// by `getFilingByAccession`, never eagerly), and any normalization warnings
/// (e.g. ragged columnar arrays).
public struct SecCompanySubmissions: Codable, Equatable, Sendable {
    public var company: SecCompanyRecord
    public var recentFilings: [SecFilingRecord]
    public var continuationFileNames: [String]
    public var warnings: [String]
    public var sourceUrl: String
    public var retrievedAt: Date
    public var raw: JSONValue

    public init(
        company: SecCompanyRecord,
        recentFilings: [SecFilingRecord],
        continuationFileNames: [String],
        warnings: [String],
        sourceUrl: String,
        retrievedAt: Date,
        raw: JSONValue
    ) {
        self.company = company
        self.recentFilings = recentFilings
        self.continuationFileNames = continuationFileNames
        self.warnings = warnings
        self.sourceUrl = sourceUrl
        self.retrievedAt = retrievedAt
        self.raw = raw
    }
}

/// XBRL company-facts response: full raw payload plus a bounded, flattened
/// fact summary (cap 500 — see `SecEdgarNormalizer.factSummaryCap`).
public struct SecCompanyFacts: Codable, Equatable, Sendable {
    public var cik: String
    public var entityName: String?
    public var factSummaries: [SecXbrlRecord]
    public var isFactSummaryTruncated: Bool
    public var sourceUrl: String
    public var retrievedAt: Date
    public var raw: JSONValue

    public init(
        cik: String,
        entityName: String? = nil,
        factSummaries: [SecXbrlRecord],
        isFactSummaryTruncated: Bool,
        sourceUrl: String,
        retrievedAt: Date,
        raw: JSONValue
    ) {
        self.cik = cik
        self.entityName = entityName
        self.factSummaries = factSummaries
        self.isFactSummaryTruncated = isFactSummaryTruncated
        self.sourceUrl = sourceUrl
        self.retrievedAt = retrievedAt
        self.raw = raw
    }
}

/// XBRL company-concept response (`units` → fact arrays), same bounding rules
/// as company facts.
public struct SecCompanyConcept: Codable, Equatable, Sendable {
    public var cik: String
    public var entityName: String?
    public var taxonomy: String
    public var concept: String
    public var label: String?
    public var conceptDescription: String?
    public var factSummaries: [SecXbrlRecord]
    public var isFactSummaryTruncated: Bool
    public var sourceUrl: String
    public var retrievedAt: Date
    public var raw: JSONValue

    public init(
        cik: String,
        entityName: String? = nil,
        taxonomy: String,
        concept: String,
        label: String? = nil,
        conceptDescription: String? = nil,
        factSummaries: [SecXbrlRecord],
        isFactSummaryTruncated: Bool,
        sourceUrl: String,
        retrievedAt: Date,
        raw: JSONValue
    ) {
        self.cik = cik
        self.entityName = entityName
        self.taxonomy = taxonomy
        self.concept = concept
        self.label = label
        self.conceptDescription = conceptDescription
        self.factSummaries = factSummaries
        self.isFactSummaryTruncated = isFactSummaryTruncated
        self.sourceUrl = sourceUrl
        self.retrievedAt = retrievedAt
        self.raw = raw
    }
}

/// XBRL frame response: one concept/unit/period across many entities.
public struct SecFrame: Codable, Equatable, Sendable {
    public var taxonomy: String
    public var concept: String
    public var unit: String
    public var frame: String
    public var label: String?
    public var conceptDescription: String?
    public var factSummaries: [SecXbrlRecord]
    public var isFactSummaryTruncated: Bool
    public var sourceUrl: String
    public var retrievedAt: Date
    public var raw: JSONValue

    public init(
        taxonomy: String,
        concept: String,
        unit: String,
        frame: String,
        label: String? = nil,
        conceptDescription: String? = nil,
        factSummaries: [SecXbrlRecord],
        isFactSummaryTruncated: Bool,
        sourceUrl: String,
        retrievedAt: Date,
        raw: JSONValue
    ) {
        self.taxonomy = taxonomy
        self.concept = concept
        self.unit = unit
        self.frame = frame
        self.label = label
        self.conceptDescription = conceptDescription
        self.factSummaries = factSummaries
        self.isFactSummaryTruncated = isFactSummaryTruncated
        self.sourceUrl = sourceUrl
        self.retrievedAt = retrievedAt
        self.raw = raw
    }
}

/// Client-side filters over already-retrieved filing metadata. Filtering is
/// local because the submissions API has no server-side filter parameters.
public struct SecFilingFilters: Codable, Equatable, Sendable {
    /// Matched case-insensitively after trimming. Empty means all forms.
    public var formTypes: [String]
    /// ISO `yyyy-MM-dd`; anything else is a validation error.
    public var startDate: String?
    public var endDate: String?
    /// Accepts dashed or undashed accession numbers.
    public var accessionNumber: String?
    /// When false, forms ending in `/A` are excluded UNLESS the caller
    /// explicitly listed that amended form in `formTypes`.
    public var includeAmendments: Bool
    /// Clamped to 1...1000 when provided; nil means no cap.
    public var limit: Int?

    public init(
        formTypes: [String] = [],
        startDate: String? = nil,
        endDate: String? = nil,
        accessionNumber: String? = nil,
        includeAmendments: Bool = true,
        limit: Int? = nil
    ) {
        self.formTypes = formTypes
        self.startDate = startDate
        self.endDate = endDate
        self.accessionNumber = accessionNumber
        self.includeAmendments = includeAmendments
        self.limit = limit
    }
}

/// Browser-facing archive URLs for one filing. `primaryDocumentUrl` exists
/// only when the source provided a primary document name.
public struct SecFilingURLs: Codable, Equatable, Sendable {
    public var filingUrl: String
    public var primaryDocumentUrl: String?

    public init(filingUrl: String, primaryDocumentUrl: String? = nil) {
        self.filingUrl = filingUrl
        self.primaryDocumentUrl = primaryDocumentUrl
    }
}
