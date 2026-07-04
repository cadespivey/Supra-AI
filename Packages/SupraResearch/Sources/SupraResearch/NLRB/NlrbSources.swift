import Foundation

/// Official-page export adapter: NLRB has no stable REST API, so the two
/// importable sources are the "Download CSV" links on the official recent
/// pages. This file isolates the (fixture-tested) HTML link discovery; if a
/// page ever moves to an interactive download queue or form token, discovery
/// returns nil and the dataset is reported unsupported — session state is
/// never automated.
enum NlrbSources {
    static let recentFilingsPage = URL(string: "https://www.nlrb.gov/reports/graphs-data/recent-filings")!
    static let recentElectionResultsPage = URL(string: "https://www.nlrb.gov/reports/graphs-data/recent-election-results")!

    /// Public case page for a case number — built for the user's browser.
    static func casePageURLString(caseNumber: String) -> String {
        let safe = caseNumber.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return "https://www.nlrb.gov/case/\(safe)"
    }

    /// The `Download CSV` link on an official page. Anchor text must contain
    /// "download csv" (case-insensitive); relative hrefs resolve against the
    /// page URL; anything that resolves off `www.nlrb.gov` is rejected —
    /// page markup must not be able to redirect the importer.
    static func downloadCSVLink(inHTML html: String, pageURL: URL) -> URL? {
        guard let regex = try? NSRegularExpression(
            pattern: #"<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var found: URL?
        regex.enumerateMatches(in: html, range: range) { match, _, stop in
            guard let match, match.numberOfRanges >= 3,
                  let hrefRange = Range(match.range(at: 1), in: html),
                  let textRange = Range(match.range(at: 2), in: html) else { return }
            let text = html[textRange]
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .lowercased()
            guard text.contains("download csv") else { return }
            // href attribute values are HTML-entity-encoded (`&amp;` between
            // query parameters on Drupal pages) — decode before URL-building.
            let href = decodeBasicEntities(String(html[hrefRange]))
            guard let resolved = URL(string: href, relativeTo: pageURL)?.absoluteURL,
                  resolved.scheme == "https",
                  resolved.host?.lowercased() == "www.nlrb.gov" else { return }
            // The live pages use a JS "download tray" whose anchor href is the
            // page itself (the real download runs behind a cookie token —
            // session state this connector never automates). Only accept
            // targets that actually LOOK like a file export.
            let path = resolved.path.lowercased()
            let queryString = resolved.query?.lowercased() ?? ""
            let looksLikeExport = path.hasSuffix(".csv")
                || queryString.contains("csv")
                || path.contains("export")
                || path.contains("/files/")
            guard looksLikeExport, resolved.path != pageURL.path || !queryString.isEmpty else { return }
            found = resolved
            stop.pointee = true
        }
        return found
    }

    /// The handful of entities that appear in attribute values on the official
    /// pages. `&amp;` must decode LAST so it can't create new entities.
    static func decodeBasicEntities(_ value: String) -> String {
        var decoded = value
        for (entity, replacement) in [
            ("&quot;", "\""), ("&#34;", "\""), ("&#039;", "'"), ("&#39;", "'"),
            ("&lt;", "<"), ("&gt;", ">"), ("&#038;", "&"), ("&#38;", "&"), ("&amp;", "&")
        ] {
            decoded = decoded.replacingOccurrences(of: entity, with: replacement)
        }
        return decoded
    }

    /// Discovery-only sources: no stable confirmed download URL, so they are
    /// listed with manual links rather than imported (plan amendment #1).
    static func discoveryOnlySources(now: Date) -> [NlrbDatasetSource] {
        [
            NlrbDatasetSource(
                name: "CATS unfair-labor-practice case data (historical)",
                sourceVariant: .officialCatsData,
                status: .discoveredButNotImported,
                downloadUrl: nil,
                pageUrl: "https://www.nlrb.gov/data-on-datagov",
                note: "No stable confirmed download URL. Locate the dataset manually via NLRB's Data.gov listing or the National Archives catalog.",
                discoveredAt: now
            ),
            NlrbDatasetSource(
                name: "CHIPS representation case data (historical)",
                sourceVariant: .officialChipsData,
                status: .discoveredButNotImported,
                downloadUrl: nil,
                pageUrl: "https://www.nlrb.gov/data-on-datagov",
                note: "No stable confirmed download URL. Locate the dataset manually via NLRB's Data.gov listing or the National Archives catalog.",
                discoveredAt: now
            )
        ]
    }

    /// The third-party mirror is provenance-defined but NEVER fetched: its
    /// host is not on the network allow-list, and this milestone does not add
    /// it. Listed only when the caller explicitly asks for mirrors.
    static func thirdPartyMirrorSource(now: Date) -> NlrbDatasetSource {
        NlrbDatasetSource(
            name: "labordata.info NLRB mirror (third-party)",
            sourceVariant: .labordataMirror,
            status: .unsupported,
            downloadUrl: nil,
            pageUrl: nil,
            note: "Third-party mirrors are not fetched: no mirror host is network-allow-listed. Defined for provenance completeness only.",
            discoveredAt: now
        )
    }
}
