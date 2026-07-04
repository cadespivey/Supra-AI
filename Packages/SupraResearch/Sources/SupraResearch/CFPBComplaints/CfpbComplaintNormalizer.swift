import Foundation

/// CFPB normalization: tolerant of both the Elasticsearch envelope the search
/// API actually returns (`hits.hits[]._source`) and bare complaint objects, so
/// a source-side shape change degrades to a parse error rather than silently
/// mis-normalizing.
enum CfpbComplaintNormalizer {
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// Complaint objects from a search payload: ES envelope, bare array, or a
    /// single object.
    static func complaintObjects(in payload: JSONValue) -> [JSONValue] {
        if let hits = payload["hits"]?["hits"]?.arrayValue {
            return hits.map { $0["_source"] ?? $0 }
        }
        if let array = payload.arrayValue { return array }
        if payload.objectValue != nil { return [payload["_source"] ?? payload] }
        return []
    }

    /// The source-reported total (`hits.total.value` in ES 7+, `hits.total`
    /// in older shapes).
    static func reportedTotal(in payload: JSONValue) -> Int? {
        if let value = payload["hits"]?["total"]?["value"]?.numberValue { return Int(value) }
        if let value = payload["hits"]?["total"]?.numberValue { return Int(value) }
        return nil
    }

    static func record(from object: JSONValue, retrievedAt: Date) -> CfpbComplaintRecord? {
        guard let complaintId = nonEmpty(object["complaint_id"]?.scalarString) else { return nil }
        return CfpbComplaintRecord(
            complaintId: complaintId,
            company: nonEmpty(object["company"]?.stringValue),
            product: nonEmpty(object["product"]?.stringValue),
            subProduct: nonEmpty(object["sub_product"]?.stringValue),
            issue: nonEmpty(object["issue"]?.stringValue),
            subIssue: nonEmpty(object["sub_issue"]?.stringValue),
            state: nonEmpty(object["state"]?.stringValue),
            zipCode: nonEmpty(object["zip_code"]?.scalarString),
            dateReceived: normalizedDay(object["date_received"]?.stringValue),
            dateSentToCompany: normalizedDay(object["date_sent_to_company"]?.stringValue),
            companyResponse: nonEmpty(object["company_response"]?.stringValue),
            companyPublicResponse: nonEmpty(object["company_public_response"]?.stringValue),
            consumerConsentProvided: nonEmpty(object["consumer_consent_provided"]?.stringValue),
            consumerDisputed: nonEmpty(object["consumer_disputed"]?.stringValue),
            narrative: nonEmpty(object["complaint_what_happened"]?.stringValue),
            submittedVia: nonEmpty(object["submitted_via"]?.stringValue),
            tags: tagList(object["tags"]),
            timely: nonEmpty(object["timely"]?.stringValue),
            hasNarrative: object["has_narrative"]?.boolValue
                ?? (nonEmpty(object["complaint_what_happened"]?.stringValue) != nil ? true : nil),
            sourceUrl: CfpbComplaintEndpoint.publicDetailURLString(complaintId: complaintId),
            retrievedAt: retrievedAt,
            raw: object
        )
    }

    /// Client-side residue of filters the API doesn't expose as parameters.
    static func applyClientSideFilters(
        _ records: [CfpbComplaintRecord],
        filters: CfpbComplaintFilters,
        limitations: inout [String]
    ) -> [CfpbComplaintRecord] {
        var result = records
        if !filters.subProduct.isEmpty {
            let wanted = Set(filters.subProduct.map { $0.lowercased() })
            result = result.filter { $0.subProduct.map { wanted.contains($0.lowercased()) } ?? false }
            limitations.append("sub_product was filtered client-side over the fetched pages only.")
        }
        if !filters.subIssue.isEmpty {
            let wanted = Set(filters.subIssue.map { $0.lowercased() })
            result = result.filter { $0.subIssue.map { wanted.contains($0.lowercased()) } ?? false }
            limitations.append("sub_issue was filtered client-side over the fetched pages only.")
        }
        if let disputed = filters.consumerDisputed {
            result = result.filter { $0.consumerDisputed?.caseInsensitiveCompare(disputed) == .orderedSame }
            limitations.append("consumer_disputed was filtered client-side over the fetched pages only.")
        }
        return result
    }

    // MARK: - RAG text

    /// Neutral complaint rendering. The narrative and public response sections
    /// are OMITTED when absent — no placeholders — and the framing always
    /// says "complaint submitted to the CFPB", never that anything occurred.
    static func ragText(for record: CfpbComplaintRecord) -> String {
        var lines: [String] = ["CFPB consumer complaint record (complaint ID \(record.complaintId))."]
        if let company = record.company {
            lines.append("Company the complaint was submitted about: \(company).")
        }
        var productLine: [String] = []
        if let product = record.product { productLine.append(product) }
        if let subProduct = record.subProduct { productLine.append(subProduct) }
        if !productLine.isEmpty { lines.append("Product: \(productLine.joined(separator: " — ")).") }
        var issueLine: [String] = []
        if let issue = record.issue { issueLine.append(issue) }
        if let subIssue = record.subIssue { issueLine.append(subIssue) }
        if !issueLine.isEmpty { lines.append("Issue as categorized by the consumer: \(issueLine.joined(separator: " — ")).") }
        if let received = record.dateReceived { lines.append("Received by the CFPB: \(received).") }
        if let state = record.state {
            var location = "Consumer location: \(state)"
            if let zip = record.zipCode { location += " \(zip)" }
            lines.append(location + ".")
        }
        if let via = record.submittedVia { lines.append("Submitted via: \(via).") }
        if let narrative = record.narrative {
            lines.append("Consumer narrative (as submitted, an allegation): \(narrative)")
        }
        if let response = record.companyPublicResponse {
            lines.append("Company public response: \(response)")
        }
        if let response = record.companyResponse { lines.append("Company response category: \(response).") }
        if let timely = record.timely { lines.append("Timely response per database: \(timely).") }
        lines.append("Source: \(record.sourceUrl) (retrieved \(dayFormatter.string(from: record.retrievedAt))).")
        return lines.joined(separator: "\n")
    }

    /// Factual profile summary. Wording is deliberately database-descriptive
    /// ("the database contains…") and never evaluative.
    static func summaryText(for profile: CfpbCompanyComplaintProfile) -> String {
        var lines: [String] = [
            "The CFPB consumer-complaint database contains \(profile.sourceReportedTotal ?? profile.totalMatchingComplaints) complaints matching \(profile.company); \(profile.totalMatchingComplaints) were retrieved for this profile."
        ]
        if let top = topEntries(profile.countsByProduct) { lines.append("Most common products: \(top).") }
        if let top = topEntries(profile.countsByIssue) { lines.append("Most common issues: \(top).") }
        if let top = topEntries(profile.countsByState) { lines.append("Most common consumer states: \(top).") }
        if let rate = profile.timelyResponseRate {
            lines.append("Share of retrieved complaints marked as receiving a timely response: \(Int((rate * 100).rounded()))%.")
        }
        lines.append("\(profile.narrativeCount) of the retrieved complaints include a consumer narrative.")
        if !profile.limitations.isEmpty {
            lines.append("Limitations: " + profile.limitations.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    private static func topEntries(_ counts: [String: Int], limit: Int = 3) -> String? {
        guard !counts.isEmpty else { return nil }
        return counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit)
            .map { "\($0.key) (\($0.value))" }
            .joined(separator: ", ")
    }

    // MARK: - Coercions

    static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The API returns `date_received` as `yyyy-MM-dd'T'HH:mm:ss` or a bare
    /// day; comparisons and bucketing need the day part only.
    static func normalizedDay(_ value: String?) -> String? {
        guard let value = nonEmpty(value) else { return nil }
        return String(value.prefix(10))
    }

    private static func tagList(_ value: JSONValue?) -> [String] {
        if let array = value?.arrayValue {
            return array.compactMap { $0.stringValue }.filter { !$0.isEmpty }
        }
        if let single = value?.stringValue, !single.isEmpty { return [single] }
        return []
    }
}
