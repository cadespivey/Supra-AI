import Foundation

/// Where an NLRB record came from. NLRB has no stable public REST API, so
/// provenance is tracked per EXPORT SOURCE rather than per endpoint. The raw
/// values are a fixed contract (they appear in dedup keys, file names, and
/// ingestion records) — never rename them.
///
/// Only the two `official_recent_*` variants are importable this milestone.
/// CATS/CHIPS are discovery-only (no stable confirmed download URL), the
/// advanced-search export requires an interactive session, and
/// `labordata_mirror` is defined for provenance completeness but is NEVER
/// fetched: no third-party mirror host is on the network allow-list.
public enum NlrbSourceVariant: String, Codable, Equatable, Sendable, CaseIterable {
    case officialRecentFilings = "official_recent_filings"
    case officialRecentElectionResults = "official_recent_election_results"
    case officialAdvancedSearchExport = "official_advanced_search_export"
    case officialCatsData = "official_cats_data"
    case officialChipsData = "official_chips_data"
    case labordataMirror = "labordata_mirror"
}

/// One NLRB case row normalized from an official export. Optional fields stay
/// nil when the source leaves them blank — the RAG renderer omits them rather
/// than writing placeholders. `raw` preserves the original header→value row.
public struct NlrbCaseRecord: Codable, Equatable, Sendable {
    public var source: String
    public var sourceRecordType: String
    public var sourceVariant: NlrbSourceVariant
    public var caseNumber: String
    public var caseName: String?
    /// Raw case-type code as the source gave it (e.g. "CA"); unknown codes are
    /// preserved verbatim so no source information is lost.
    public var caseType: String?
    public var caseTypeCategory: NlrbCaseTypeCategory
    public var region: String?
    public var status: String?
    /// Source date string (NLRB exports use MM/dd/yyyy); parsing happens only
    /// where sorting/filtering needs it.
    public var dateFiled: String?
    public var employer: String?
    public var union: String?
    public var city: String?
    public var state: String?
    public var allegations: String?
    public var reasonClosed: String?
    /// Stable public case page (built for the user's browser, never fetched).
    public var sourceUrl: String
    /// The export URL this row was downloaded from, for exact provenance.
    public var datasetUrl: String?
    public var retrievedAt: Date
    public var raw: JSONValue

    public init(
        sourceVariant: NlrbSourceVariant,
        caseNumber: String,
        caseName: String? = nil,
        caseType: String? = nil,
        caseTypeCategory: NlrbCaseTypeCategory = .unknown,
        region: String? = nil,
        status: String? = nil,
        dateFiled: String? = nil,
        employer: String? = nil,
        union: String? = nil,
        city: String? = nil,
        state: String? = nil,
        allegations: String? = nil,
        reasonClosed: String? = nil,
        sourceUrl: String,
        datasetUrl: String? = nil,
        retrievedAt: Date,
        raw: JSONValue
    ) {
        self.source = "nlrb"
        self.sourceRecordType = "case"
        self.sourceVariant = sourceVariant
        self.caseNumber = caseNumber
        self.caseName = caseName
        self.caseType = caseType
        self.caseTypeCategory = caseTypeCategory
        self.region = region
        self.status = status
        self.dateFiled = dateFiled
        self.employer = employer
        self.union = union
        self.city = city
        self.state = state
        self.allegations = allegations
        self.reasonClosed = reasonClosed
        self.sourceUrl = sourceUrl
        self.datasetUrl = datasetUrl
        self.retrievedAt = retrievedAt
        self.raw = raw
    }
}

/// One tally row from the official recent-election-results export. Vote
/// counts are normalized to Int where the source cell parses cleanly;
/// otherwise they stay nil and the original text survives in `raw`.
public struct NlrbElectionResultRecord: Codable, Equatable, Sendable {
    public var source: String
    public var sourceRecordType: String
    public var sourceVariant: NlrbSourceVariant
    public var caseNumber: String
    public var caseName: String?
    public var caseType: String?
    public var caseTypeCategory: NlrbCaseTypeCategory
    public var region: String?
    public var city: String?
    public var state: String?
    public var unitId: String?
    public var tallyDate: String?
    public var electionType: String?
    public var union: String?
    public var votesFor: Int?
    public var votesAgainst: Int?
    public var totalBallotsCounted: Int?
    public var unitSize: Int?
    public var eligibleVoters: Int?
    /// Only set when the source explicitly names a certified representative —
    /// the connector never infers an election outcome from vote counts.
    public var certifiedRepresentative: String?
    public var sourceUrl: String
    public var datasetUrl: String?
    public var retrievedAt: Date
    public var raw: JSONValue

    public init(
        sourceVariant: NlrbSourceVariant,
        caseNumber: String,
        caseName: String? = nil,
        caseType: String? = nil,
        caseTypeCategory: NlrbCaseTypeCategory = .unknown,
        region: String? = nil,
        city: String? = nil,
        state: String? = nil,
        unitId: String? = nil,
        tallyDate: String? = nil,
        electionType: String? = nil,
        union: String? = nil,
        votesFor: Int? = nil,
        votesAgainst: Int? = nil,
        totalBallotsCounted: Int? = nil,
        unitSize: Int? = nil,
        eligibleVoters: Int? = nil,
        certifiedRepresentative: String? = nil,
        sourceUrl: String,
        datasetUrl: String? = nil,
        retrievedAt: Date,
        raw: JSONValue
    ) {
        self.source = "nlrb"
        self.sourceRecordType = "election_result"
        self.sourceVariant = sourceVariant
        self.caseNumber = caseNumber
        self.caseName = caseName
        self.caseType = caseType
        self.caseTypeCategory = caseTypeCategory
        self.region = region
        self.city = city
        self.state = state
        self.unitId = unitId
        self.tallyDate = tallyDate
        self.electionType = electionType
        self.union = union
        self.votesFor = votesFor
        self.votesAgainst = votesAgainst
        self.totalBallotsCounted = totalBallotsCounted
        self.unitSize = unitSize
        self.eligibleVoters = eligibleVoters
        self.certifiedRepresentative = certifiedRepresentative
        self.sourceUrl = sourceUrl
        self.datasetUrl = datasetUrl
        self.retrievedAt = retrievedAt
        self.raw = raw
    }
}

/// Case row from a historical system export (CATS/CHIPS). The model exists so
/// the store, dedup, and ingestion seams are ready, but no importer produces
/// these this milestone — CATS/CHIPS stays discovery-only until a stable
/// official download URL is confirmed.
public struct NlrbHistoricalCaseRecord: Codable, Equatable, Sendable {
    public var source: String
    public var sourceRecordType: String
    public var sourceVariant: NlrbSourceVariant
    /// E.g. "CATS" or "CHIPS"; part of the dedup key because the same case can
    /// appear in both systems.
    public var historicalSystem: String?
    public var caseNumber: String
    public var caseName: String?
    public var caseType: String?
    public var caseTypeCategory: NlrbCaseTypeCategory
    public var region: String?
    public var status: String?
    public var dateFiled: String?
    public var dateClosed: String?
    public var reasonClosed: String?
    public var parties: [String]
    public var sourceUrl: String?
    public var datasetUrl: String?
    public var retrievedAt: Date
    public var raw: JSONValue

    public init(
        sourceVariant: NlrbSourceVariant,
        historicalSystem: String? = nil,
        caseNumber: String,
        caseName: String? = nil,
        caseType: String? = nil,
        caseTypeCategory: NlrbCaseTypeCategory = .unknown,
        region: String? = nil,
        status: String? = nil,
        dateFiled: String? = nil,
        dateClosed: String? = nil,
        reasonClosed: String? = nil,
        parties: [String] = [],
        sourceUrl: String? = nil,
        datasetUrl: String? = nil,
        retrievedAt: Date,
        raw: JSONValue
    ) {
        self.source = "nlrb"
        self.sourceRecordType = "historical_case"
        self.sourceVariant = sourceVariant
        self.historicalSystem = historicalSystem
        self.caseNumber = caseNumber
        self.caseName = caseName
        self.caseType = caseType
        self.caseTypeCategory = caseTypeCategory
        self.region = region
        self.status = status
        self.dateFiled = dateFiled
        self.dateClosed = dateClosed
        self.reasonClosed = reasonClosed
        self.parties = parties
        self.sourceUrl = sourceUrl
        self.datasetUrl = datasetUrl
        self.retrievedAt = retrievedAt
        self.raw = raw
    }
}

/// Union type over everything the local store holds and `toIngestionRecords`
/// accepts, so imports and ingestion share one seam.
public enum NlrbIngestibleRecord: Codable, Equatable, Sendable {
    case `case`(NlrbCaseRecord)
    case electionResult(NlrbElectionResultRecord)
    case historicalCase(NlrbHistoricalCaseRecord)
}

/// A dataset the connector knows how to talk about. `available` means a
/// confirmed official download URL exists; `discoveredButNotImported` means
/// the dataset is real but must be fetched manually (CATS/CHIPS);
/// `unsupported` means automation was deliberately declined (session-bound
/// exports, unlisted mirror hosts, or a page whose CSV link could not be
/// discovered).
public struct NlrbDatasetSource: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Equatable, Sendable {
        case available
        case discoveredButNotImported
        case unsupported
    }

    public var name: String
    public var sourceVariant: NlrbSourceVariant
    public var status: Status
    /// Resolved CSV export URL — only for `available` sources.
    public var downloadUrl: String?
    /// The official page a user can visit (also where the CSV link was found).
    public var pageUrl: String?
    public var note: String?
    public var discoveredAt: Date

    public init(
        name: String,
        sourceVariant: NlrbSourceVariant,
        status: Status,
        downloadUrl: String? = nil,
        pageUrl: String? = nil,
        note: String? = nil,
        discoveredAt: Date
    ) {
        self.name = name
        self.sourceVariant = sourceVariant
        self.status = status
        self.downloadUrl = downloadUrl
        self.pageUrl = pageUrl
        self.note = note
        self.discoveredAt = discoveredAt
    }
}

/// Audit metadata for one import. `rawFileRelativePath` is relative to the
/// store root deliberately — absolute local paths must not leak into anything
/// that could surface to users or logs.
public struct NlrbImportRun: Codable, Equatable, Sendable {
    public var id: String
    public var connectorName: String
    public var sourceVariant: NlrbSourceVariant
    public var datasetName: String
    public var sourceUrl: String?
    public var retrievedAt: Date
    /// Data rows parsed from the CSV (excluding the header row).
    public var recordCount: Int
    public var rawPayloadHash: String
    public var rawFileRelativePath: String?
    /// Rows that normalized into records (rows without a case number don't).
    public var normalizedRecordCount: Int
    /// Records actually added; re-importing the same export adds zero.
    public var importedRecordCount: Int
    public var duplicateRecordCount: Int
    public var errors: [String]
    public var warnings: [String]

    public init(
        id: String,
        sourceVariant: NlrbSourceVariant,
        datasetName: String,
        sourceUrl: String?,
        retrievedAt: Date,
        recordCount: Int,
        rawPayloadHash: String,
        rawFileRelativePath: String?,
        normalizedRecordCount: Int,
        importedRecordCount: Int,
        duplicateRecordCount: Int,
        errors: [String],
        warnings: [String]
    ) {
        self.id = id
        self.connectorName = "nlrb"
        self.sourceVariant = sourceVariant
        self.datasetName = datasetName
        self.sourceUrl = sourceUrl
        self.retrievedAt = retrievedAt
        self.recordCount = recordCount
        self.rawPayloadHash = rawPayloadHash
        self.rawFileRelativePath = rawFileRelativePath
        self.normalizedRecordCount = normalizedRecordCount
        self.importedRecordCount = importedRecordCount
        self.duplicateRecordCount = duplicateRecordCount
        self.errors = errors
        self.warnings = warnings
    }
}

/// Neutral, count-based view of a party's imported NLRB records. The summary
/// reports MATCHING CASE RECORDS only — nothing here characterizes merits,
/// outcomes, or compliance, because the source exports don't either.
public struct NlrbPartyHistorySummary: Codable, Equatable, Sendable {
    public var partyName: String
    public var totalMatchingCaseRecords: Int
    public var countsByCaseType: [String: Int]
    public var countsByCaseTypeCategory: [String: Int]
    public var countsByRegion: [String: Int]
    public var countsByStatus: [String: Int]
    public var reasonClosedDistribution: [String: Int]
    public var recentCases: [NlrbCaseRecord]
    public var electionResults: [NlrbElectionResultRecord]
    public var sourceVariantsUsed: [String]
    public var limitations: [String]
    public var summaryText: String
    public var generatedAt: Date

    public init(
        partyName: String,
        totalMatchingCaseRecords: Int,
        countsByCaseType: [String: Int],
        countsByCaseTypeCategory: [String: Int],
        countsByRegion: [String: Int],
        countsByStatus: [String: Int],
        reasonClosedDistribution: [String: Int],
        recentCases: [NlrbCaseRecord],
        electionResults: [NlrbElectionResultRecord],
        sourceVariantsUsed: [String],
        limitations: [String],
        summaryText: String,
        generatedAt: Date
    ) {
        self.partyName = partyName
        self.totalMatchingCaseRecords = totalMatchingCaseRecords
        self.countsByCaseType = countsByCaseType
        self.countsByCaseTypeCategory = countsByCaseTypeCategory
        self.countsByRegion = countsByRegion
        self.countsByStatus = countsByStatus
        self.reasonClosedDistribution = reasonClosedDistribution
        self.recentCases = recentCases
        self.electionResults = electionResults
        self.sourceVariantsUsed = sourceVariantsUsed
        self.limitations = limitations
        self.summaryText = summaryText
        self.generatedAt = generatedAt
    }
}

// MARK: - Options and filters

public struct NlrbRefreshOptions: Codable, Equatable, Sendable {
    public var includeHistoricalSources: Bool
    /// Third-party mirrors are listed (as unsupported) but NEVER fetched — no
    /// mirror host is on the network allow-list.
    public var includeThirdPartyMirrors: Bool

    public init(includeHistoricalSources: Bool = true, includeThirdPartyMirrors: Bool = false) {
        self.includeHistoricalSources = includeHistoricalSources
        self.includeThirdPartyMirrors = includeThirdPartyMirrors
    }
}

public struct NlrbImportOptions: Codable, Equatable, Sendable {
    /// Bypasses the short response cache so an explicit refresh re-downloads.
    public var forceRefresh: Bool
    public var maxRecords: Int?

    public init(forceRefresh: Bool = false, maxRecords: Int? = nil) {
        self.forceRefresh = forceRefresh
        self.maxRecords = maxRecords
    }
}

public struct NlrbSearchOptions: Codable, Equatable, Sendable {
    /// Clamped to 1...1_000 at query time.
    public var limit: Int
    public var includeHistorical: Bool
    public var includeElectionResults: Bool
    /// Date-range searches drop records whose filed date is blank or
    /// unparseable unless this is set.
    public var includeUndated: Bool

    public init(
        limit: Int = 100,
        includeHistorical: Bool = true,
        includeElectionResults: Bool = true,
        includeUndated: Bool = false
    ) {
        self.limit = limit
        self.includeHistorical = includeHistorical
        self.includeElectionResults = includeElectionResults
        self.includeUndated = includeUndated
    }
}

public struct NlrbCaseFilters: Codable, Equatable, Sendable {
    public var query: String?
    public var caseNumber: String?
    public var employer: String?
    public var union: String?
    public var partyName: String?
    public var caseType: String?
    public var caseTypeCategory: String?
    public var region: String?
    public var status: String?
    public var startDate: String?
    public var endDate: String?

    public init(
        query: String? = nil,
        caseNumber: String? = nil,
        employer: String? = nil,
        union: String? = nil,
        partyName: String? = nil,
        caseType: String? = nil,
        caseTypeCategory: String? = nil,
        region: String? = nil,
        status: String? = nil,
        startDate: String? = nil,
        endDate: String? = nil
    ) {
        self.query = query
        self.caseNumber = caseNumber
        self.employer = employer
        self.union = union
        self.partyName = partyName
        self.caseType = caseType
        self.caseTypeCategory = caseTypeCategory
        self.region = region
        self.status = status
        self.startDate = startDate
        self.endDate = endDate
    }
}

public struct NlrbElectionFilters: Codable, Equatable, Sendable {
    public var caseNumber: String?
    /// Matched against the election row's case name — the official tally
    /// export names the employer through the case caption.
    public var employer: String?
    public var union: String?
    public var region: String?
    public var state: String?
    public var tallyStartDate: String?
    public var tallyEndDate: String?
    public var limit: Int

    public init(
        caseNumber: String? = nil,
        employer: String? = nil,
        union: String? = nil,
        region: String? = nil,
        state: String? = nil,
        tallyStartDate: String? = nil,
        tallyEndDate: String? = nil,
        limit: Int = 100
    ) {
        self.caseNumber = caseNumber
        self.employer = employer
        self.union = union
        self.region = region
        self.state = state
        self.tallyStartDate = tallyStartDate
        self.tallyEndDate = tallyEndDate
        self.limit = limit
    }
}

public struct NlrbHistoryOptions: Codable, Equatable, Sendable {
    public var dateRangeStart: String?
    public var dateRangeEnd: String?
    public var includeElectionResults: Bool
    public var limit: Int

    public init(
        dateRangeStart: String? = nil,
        dateRangeEnd: String? = nil,
        includeElectionResults: Bool = true,
        limit: Int = 100
    ) {
        self.dateRangeStart = dateRangeStart
        self.dateRangeEnd = dateRangeEnd
        self.includeElectionResults = includeElectionResults
        self.limit = limit
    }
}
