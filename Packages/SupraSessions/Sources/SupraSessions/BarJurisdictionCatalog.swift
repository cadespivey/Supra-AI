import Foundation

/// A U.S. bar-admission jurisdiction (the 50 states + D.C.), used to label a bar
/// number on a court filing's signature block. Distinct from SupraResearch's
/// `JurisdictionCatalog` (which models court systems for legal-research filtering).
/// Mirrors `CitationStyleCatalog`:
/// a small catalog with a stable id (the USPS abbreviation) plus a display name and
/// the prefix that prints before the number (e.g. "Florida Bar No.").
public struct BarJurisdiction: Identifiable, Hashable, Sendable {
    /// USPS abbreviation, lowercased (e.g. "fl", "dc") — the value persisted on a
    /// `AssistantProfile.BarLicense`.
    public let id: String
    public let displayName: String
    /// The signature-block prefix, e.g. "Florida Bar No." or "D.C. Bar No.".
    public let barLabel: String
    /// USPS abbreviation, uppercase (e.g. "FL"), used for free-text matching.
    public var abbreviation: String { id.uppercased() }

    public init(id: String, displayName: String, barLabel: String) {
        self.id = id
        self.displayName = displayName
        self.barLabel = barLabel
    }
}

public enum BarJurisdictionCatalog {
    /// 50 states + the District of Columbia. Bar labels follow the common
    /// "{Jurisdiction} Bar No." signature-block convention (D.C. abbreviated).
    public static let all: [BarJurisdiction] = [
        entry("al", "Alabama"), entry("ak", "Alaska"), entry("az", "Arizona"),
        entry("ar", "Arkansas"), entry("ca", "California"), entry("co", "Colorado"),
        entry("ct", "Connecticut"), entry("de", "Delaware"),
        BarJurisdiction(id: "dc", displayName: "District of Columbia", barLabel: "D.C. Bar No."),
        entry("fl", "Florida"), entry("ga", "Georgia"), entry("hi", "Hawaii"),
        entry("id", "Idaho"), entry("il", "Illinois"), entry("in", "Indiana"),
        entry("ia", "Iowa"), entry("ks", "Kansas"), entry("ky", "Kentucky"),
        entry("la", "Louisiana"), entry("me", "Maine"), entry("md", "Maryland"),
        entry("ma", "Massachusetts"), entry("mi", "Michigan"), entry("mn", "Minnesota"),
        entry("ms", "Mississippi"), entry("mo", "Missouri"), entry("mt", "Montana"),
        entry("ne", "Nebraska"), entry("nv", "Nevada"), entry("nh", "New Hampshire"),
        entry("nj", "New Jersey"), entry("nm", "New Mexico"), entry("ny", "New York"),
        entry("nc", "North Carolina"), entry("nd", "North Dakota"), entry("oh", "Ohio"),
        entry("ok", "Oklahoma"), entry("or", "Oregon"), entry("pa", "Pennsylvania"),
        entry("ri", "Rhode Island"), entry("sc", "South Carolina"), entry("sd", "South Dakota"),
        entry("tn", "Tennessee"), entry("tx", "Texas"), entry("ut", "Utah"),
        entry("vt", "Vermont"), entry("va", "Virginia"), entry("wa", "Washington"),
        entry("wv", "West Virginia"), entry("wi", "Wisconsin"), entry("wy", "Wyoming")
    ]

    /// Looks up a jurisdiction by its stored id (USPS abbreviation, case-insensitive).
    public static func jurisdiction(id: String?) -> BarJurisdiction? {
        guard let id, !id.isEmpty else { return nil }
        let lower = id.lowercased()
        return all.first { $0.id == lower }
    }

    /// Resolves a free-text jurisdiction string (e.g. a matter's `jurisdiction` or a
    /// profile's `officeState`) to a catalog entry. Prefers a full display-name match
    /// (so "California state and the Ninth Circuit" → California), then falls back to
    /// a USPS-abbreviation token. Lowercase two-letter values match when the whole
    /// field is just the abbreviation ("fl"), while longer prose only treats
    /// uppercase tokens as abbreviations so words like "in" and "or" don't become
    /// Indiana/Oregon. Returns nil when nothing matches.
    public static func match(_ text: String) -> BarJurisdiction? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if let byName = all.first(where: { lower.contains($0.displayName.lowercased()) }) {
            return byName
        }
        if isDistrictOfColumbiaAbbreviation(trimmed) {
            return jurisdiction(id: "dc")
        }
        let rawTokens = trimmed.split { !$0.isLetter }.map(String.init)
        if rawTokens.count == 1, let token = rawTokens.first, token.count == 2 {
            return all.first { $0.abbreviation == token.uppercased() }
        }
        let upperTokens = Set(rawTokens.filter { $0 == $0.uppercased() }.map { $0.uppercased() })
        return all.first { upperTokens.contains($0.abbreviation) }
    }

    private static func isDistrictOfColumbiaAbbreviation(_ text: String) -> Bool {
        let upper = text.uppercased()
        if upper == "DC" || upper == "D.C." || upper.contains("D.C.") { return true }
        let tokens = upper.split { !$0.isLetter }.map(String.init)
        if tokens == ["D", "C"] || tokens.contains("DC") { return true }
        return zip(tokens, tokens.dropFirst()).contains { lhs, rhs in lhs == "D" && rhs == "C" }
    }

    private static func entry(_ id: String, _ name: String) -> BarJurisdiction {
        BarJurisdiction(id: id, displayName: name, barLabel: "\(name) Bar No.")
    }
}
