import Foundation

/// Factual aggregation over retrieved complaint records: counts, timely rate,
/// narrative samples, and interval trend buckets. Trends are computed from the
/// BOUNDED page set the caller fetched — the documented `/trends` endpoint
/// returns counts without the per-bucket product/issue/company breakdowns the
/// bucket contract requires, so it is parsed only as a counts cross-check
/// (`parseTrendCounts`) and the limitation is recorded on results.
enum CfpbComplaintAggregations {
    static func countsBy(_ records: [CfpbComplaintRecord], _ key: (CfpbComplaintRecord) -> String?) -> [String: Int] {
        var counts: [String: Int] = [:]
        for record in records {
            guard let value = key(record) else { continue }
            counts[value, default: 0] += 1
        }
        return counts
    }

    /// Share of records with timely == "Yes" among records carrying the field.
    static func timelyRate(_ records: [CfpbComplaintRecord]) -> Double? {
        let flagged = records.compactMap(\.timely)
        guard !flagged.isEmpty else { return nil }
        let yes = flagged.filter { $0.caseInsensitiveCompare("Yes") == .orderedSame }.count
        return Double(yes) / Double(flagged.count)
    }

    static func trendBuckets(
        _ records: [CfpbComplaintRecord],
        interval: CfpbTrendInterval,
        includeCompanies: Bool
    ) -> [CfpbComplaintTrendBucket] {
        var grouped: [String: [CfpbComplaintRecord]] = [:]
        for record in records {
            guard let day = record.dateReceived, let start = bucketStart(day: day, interval: interval) else { continue }
            grouped[start, default: []].append(record)
        }
        return grouped.keys.sorted().map { start in
            let bucket = grouped[start] ?? []
            return CfpbComplaintTrendBucket(
                intervalStart: start,
                intervalEnd: bucketEnd(start: start, interval: interval),
                count: bucket.count,
                topProducts: topValues(bucket, \.product),
                topIssues: topValues(bucket, \.issue),
                topCompanies: includeCompanies ? topValues(bucket, \.company) : []
            )
        }
    }

    /// `yyyy-MM-dd` → bucket start for the interval; nil for unparseable days
    /// (records without a parseable date are excluded from trends).
    static func bucketStart(day: String, interval: CfpbTrendInterval) -> String? {
        guard day.count >= 7,
              let year = Int(day.prefix(4)),
              let month = Int(day.dropFirst(5).prefix(2)),
              (1...12).contains(month) else { return nil }
        switch interval {
        case .month:
            return String(format: "%04d-%02d-01", year, month)
        case .quarter:
            let quarterMonth = ((month - 1) / 3) * 3 + 1
            return String(format: "%04d-%02d-01", year, quarterMonth)
        case .year:
            return String(format: "%04d-01-01", year)
        }
    }

    /// Last day of the bucket that starts at `start`.
    static func bucketEnd(start: String, interval: CfpbTrendInterval) -> String {
        guard let year = Int(start.prefix(4)), let month = Int(start.dropFirst(5).prefix(2)) else { return start }
        let endMonth: Int
        let endYear: Int
        switch interval {
        case .month: (endYear, endMonth) = (year, month)
        case .quarter: (endYear, endMonth) = (year, month + 2)
        case .year: (endYear, endMonth) = (year, 12)
        }
        return String(format: "%04d-%02d-%02d", endYear, endMonth, lastDay(ofMonth: endMonth, year: endYear))
    }

    private static func lastDay(ofMonth month: Int, year: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        default:
            let isLeap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return isLeap ? 29 : 28
        }
    }

    private static func topValues(
        _ records: [CfpbComplaintRecord],
        _ key: (CfpbComplaintRecord) -> String?,
        limit: Int = 3
    ) -> [String] {
        countsBy(records, key)
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }

    /// Counts-only parse of the documented `/trends` response shape
    /// (`aggregations.dateRangeArea.dateRangeArea.buckets[]`), used as a
    /// cross-check; not sufficient for the full bucket contract.
    static func parseTrendCounts(_ payload: JSONValue) -> [(day: String, count: Int)] {
        let buckets = payload["aggregations"]?["dateRangeArea"]?["dateRangeArea"]?["buckets"]?.arrayValue ?? []
        return buckets.compactMap { bucket in
            guard let count = bucket["doc_count"]?.numberValue else { return nil }
            // Prefer the ISO `key_as_string`; only if absent fall back to the
            // numeric `key`, which is epoch-MILLISECONDS. String-slicing that
            // raw integer would yield a truncated-epoch string, not a day, so
            // convert it properly (UTC).
            let day: String
            if let iso = bucket["key_as_string"]?.stringValue {
                day = String(iso.prefix(10))
            } else if let epochMillis = bucket["key"]?.numberValue {
                day = utcDayFormatter.string(from: Date(timeIntervalSince1970: epochMillis / 1000))
            } else {
                return nil
            }
            return (day: day, count: Int(count))
        }
    }

    private static let utcDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
