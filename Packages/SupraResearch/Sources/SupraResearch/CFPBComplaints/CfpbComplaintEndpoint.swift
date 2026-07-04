import Foundation

/// URL construction for the CFPB consumer-complaint API
/// (https://cfpb.github.io/api/ccdb/api.html). Parameter names map exactly to
/// the documented Swagger; array filters use REPEATED query items (Swagger
/// `explode: true`). `sub_product`, `sub_issue`, and `consumer_disputed` are
/// NOT sent — they are not confirmed first-class parameters and are applied
/// client-side instead.
enum CfpbComplaintEndpoint {
    static let base = URL(string: "https://www.consumerfinance.gov/data-research/consumer-complaints/search/api/v1/")!

    /// Public complaint-detail page shown to users as the record's source URL.
    static func publicDetailURLString(complaintId: String) -> String {
        // IDs are numeric; filtering (matching NlrbSources.casePageURLString)
        // keeps payload-supplied IDs from smuggling URL metacharacters into
        // the citation surface.
        let safe = complaintId.filter { $0.isASCII && $0.isNumber }
        return "https://www.consumerfinance.gov/data-research/consumer-complaints/search/detail/\(safe)"
    }

    static func search(query: CfpbComplaintQuery, frm: Int, size: Int) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = []
        if let term = query.searchTerm?.trimmingCharacters(in: .whitespacesAndNewlines), !term.isEmpty {
            items.append(URLQueryItem(name: "search_term", value: term))
            if query.field != .all {
                items.append(URLQueryItem(name: "field", value: query.field.rawValue))
            }
        }
        items.append(URLQueryItem(name: "frm", value: String(frm)))
        items.append(URLQueryItem(name: "size", value: String(size)))
        if !query.options.sort.isEmpty {
            items.append(URLQueryItem(name: "sort", value: query.options.sort))
        }
        if query.options.noAggregations {
            items.append(URLQueryItem(name: "no_aggs", value: "true"))
        }
        if query.options.noHighlight {
            items.append(URLQueryItem(name: "no_highlight", value: "true"))
        }
        items.append(contentsOf: filterItems(query.filters))
        components.queryItems = items
        return components.url!
    }

    static func detail(complaintId: String) -> URL {
        base.appendingPathComponent(complaintId)
    }

    static func filterItems(_ filters: CfpbComplaintFilters) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        func repeated(_ name: String, _ values: [String]) {
            for value in values {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { items.append(URLQueryItem(name: name, value: trimmed)) }
            }
        }
        repeated("company", filters.company)
        repeated("product", filters.product)
        repeated("issue", filters.issue)
        repeated("state", filters.state)
        repeated("zip_code", filters.zipCode)
        repeated("company_response", filters.companyResponse)
        repeated("submitted_via", filters.submittedVia)
        repeated("tags", filters.tags)
        if let min = filters.dateReceivedMin { items.append(URLQueryItem(name: "date_received_min", value: min)) }
        if let max = filters.dateReceivedMax { items.append(URLQueryItem(name: "date_received_max", value: max)) }
        if let timely = filters.timely { items.append(URLQueryItem(name: "timely", value: timely)) }
        if let hasNarrative = filters.hasNarrative {
            items.append(URLQueryItem(name: "has_narrative", value: hasNarrative ? "true" : "false"))
        }
        return items
    }
}
