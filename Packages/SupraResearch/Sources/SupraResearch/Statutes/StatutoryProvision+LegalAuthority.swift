import Foundation

public extension StatutoryProvision {
    /// Bridges a normalized statutory provision into a `LegalAuthority` so it flows through the
    /// existing source-packet / prompt / `[A#]` citation-verification machinery alongside case law.
    ///
    /// - `jurisdictionLabel` is the classifier's jurisdiction (e.g. "Florida") so the citation
    ///   verifier's jurisdiction check matches; the provider's own name (e.g. "Florida Statutes")
    ///   is folded into the citation. The currency caveat rides in `text` so the model — and the
    ///   reader — always see that convenience-tier statutory text is unverified.
    func asLegalAuthority(jurisdictionLabel: String?) -> LegalAuthority {
        let citationLabel = [jurisdictionName, citation].filter { !$0.isEmpty }.joined(separator: " ")
        let groundingText: String = {
            var parts: [String] = []
            if !text.isEmpty { parts.append(text) }
            if let currencyCaveat { parts.append("[Currency note] \(currencyCaveat)") }
            return parts.joined(separator: "\n\n")
        }()
        return LegalAuthority(
            id: "\(sourceID):\(jurisdictionID ?? jurisdictionName):\(locatorPath ?? citation)",
            source: Self.legalAuthoritySource(forSourceID: sourceID),
            authorityType: .statute,
            caseName: heading ?? citationLabel,
            citation: citationLabel,
            citations: Array(Set([citation, citationLabel].filter { !$0.isEmpty })),
            court: nil,
            courtID: nil,
            jurisdiction: jurisdictionLabel ?? jurisdictionName,
            dateFiled: effectiveDate,
            precedentialStatus: "statutory · \(sourceName)\(weightTier == .convenience ? " (unverified currency)" : "")",
            url: url,
            snippet: snippet,
            text: groundingText.isEmpty ? nil : groundingText
        )
    }

    /// Maps a source id to a `LegalAuthoritySource`. Extend when adding a provider whose results
    /// should carry a distinct source tag (e.g. add a `.govinfo` case to `LegalAuthoritySource`).
    private static func legalAuthoritySource(forSourceID sourceID: String) -> LegalAuthoritySource {
        switch sourceID {
        case "open-legal-codes": return .openlegalcodes
        case "ecfr": return .ecfr
        case "govinfo": return .govinfo
        default: return .openlegalcodes
        }
    }
}
