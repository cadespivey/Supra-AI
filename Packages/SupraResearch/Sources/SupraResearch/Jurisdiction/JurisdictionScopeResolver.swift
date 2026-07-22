import Foundation

/// The direction of a state/federal geographic overlap. The two directions are
/// legally distinct and must never collapse into one symmetric value: a federal court
/// sitting in a state routinely applies that state's law, while a state court is not
/// part of its geographically overlapping federal circuit hierarchy at all.
public enum GeographicOverlapDirection: String, Sendable, Equatable {
    /// A federal authority sitting in the expected STATE forum's footprint.
    case federalAuthorityInExpectedState
    /// A state authority inside the expected FEDERAL forum's footprint.
    case stateAuthorityInExpectedFederalFootprint
}

/// The directional relationship of a cited authority to a requested forum — the
/// Phase 3C replacement for the generic `.withinScope` verdict, which collapsed
/// legally distinct concepts (same tribunal, binding superior, same federal family,
/// same state, geographic overlap, subject-limited national jurisdiction, persuasive
/// authority) into one value that hard gates then consumed as a boolean.
///
/// Every consumer must choose explicitly which relationships it accepts; no case here
/// means "fine everywhere". Symmetry exists only where legally appropriate: aliases
/// and exact same-court identity.
public enum AuthorityRelationship: Sendable, Equatable {
    /// The same tribunal, including notation/alias variants of one court.
    case sameCourt
    /// The authority's court bindingly controls the expected forum (SCOTUS over any
    /// resolvable U.S. forum, a circuit over its districts, a state supreme court
    /// over that state's forums).
    case controllingSuperior
    /// Same federal family (a district under the expected circuit, sibling district
    /// courts) — related, not controlling.
    case sameFederalFamily
    /// Same state's court system, without a controlling relationship.
    case sameStateNoncontrolling
    /// State/federal geographic overlap — related but never controlling, and
    /// directional (see `GeographicOverlapDirection`).
    case geographicallyRelated(GeographicOverlapDirection)
    /// Nationwide but subject-limited jurisdiction (the Federal Circuit,
    /// 28 U.S.C. § 1295). Whether it reaches the expected forum depends on subject
    /// matter this resolver cannot see; consumers without established subject matter
    /// MUST fail closed.
    case subjectMatterDependent
    /// Both sides resolved and no recognized relation holds.
    case outsideScope
    /// At least one side is not resolvable against the bundled court list, so the
    /// hierarchy cannot answer the question. Callers must apply their own fail-closed
    /// fallback rather than treating this as a pass.
    case indeterminate
}

/// Decides jurisdictional scope from the court hierarchy in `JurisdictionCatalog`
/// instead of from string containment.
///
/// The check this replaces compared a requested jurisdiction against an authority's
/// court/jurisdiction/courtID with `a.contains(b) || b.contains(a)`, which fails in both
/// directions: it accepts an Arkansas authority for a Kansas matter (one name is a
/// substring of the other) while rejecting "U.S. Court of Appeals for the 11th Circuit"
/// for an "…Eleventh Circuit" matter (no shared substring, not even via the `ca11`
/// courtID). Containment is not a hierarchy relation, so every gap in it had to be
/// patched by hand — the `isNationallyBinding` needle list grew one court at a time.
///
/// Here, both sides resolve to catalog options by *exact* key equality — never by
/// containment — and the verdict comes from catalog fields (`system`, `level`, `state`,
/// `courtListenerIDs`) and the catalog's own federal/state relations. Adding a court to
/// the bundled list extends the check with no code change.
public struct JurisdictionScopeResolver: Sendable {
    /// Shared instance. The key indexes are built once at init (the catalog holds ~2,900
    /// options and the verifier resolves per cited authority), mirroring the catalog's
    /// own precomputed `searchIndex`.
    public static let shared = JurisdictionScopeResolver()

    private let catalog: JurisdictionCatalog
    /// Canonical court-name key → option id. Court and display names both index here.
    private let optionIDByCourtKey: [String: String]
    /// Canonical jurisdiction-name key → option id (the per-state aggregates).
    private let optionIDByJurisdictionKey: [String: String]
    /// CourtListener id → option id.
    private let optionIDByCourtListenerID: [String: String]

    public init(catalog: JurisdictionCatalog = .shared) {
        self.catalog = catalog
        var courtKeys: [String: String] = [:]
        var jurisdictionKeys: [String: String] = [:]
        var courtListenerIDs: [String: String] = [:]
        // First writer wins throughout. Parse order is hierarchy order (SCOTUS, then the
        // circuits, then state sections, each state's aggregate ahead of its courts), so
        // the most authoritative option claims a shared key — "scotus" must resolve to
        // the Supreme Court, and a bare state name to that state's aggregate.
        for option in catalog.options {
            for name in [option.courtName, option.displayName] {
                let key = Self.canonicalKey(name)
                if !key.isEmpty, courtKeys[key] == nil { courtKeys[key] = option.id }
            }
            let jurisdictionKey = Self.canonicalKey(option.jurisdictionName)
            if !jurisdictionKey.isEmpty, jurisdictionKeys[jurisdictionKey] == nil {
                jurisdictionKeys[jurisdictionKey] = option.id
            }
            for id in option.courtListenerIDs {
                let key = id.lowercased()
                if !key.isEmpty, courtListenerIDs[key] == nil { courtListenerIDs[key] = option.id }
            }
        }
        self.optionIDByCourtKey = courtKeys
        self.optionIDByJurisdictionKey = jurisdictionKeys
        self.optionIDByCourtListenerID = courtListenerIDs
    }

    // MARK: - Relationship

    /// The directional relationship of a cited authority to the requested forum.
    ///
    /// - Parameters:
    ///   - expected: the requested jurisdiction — a bare jurisdiction name
    ///     ("California") or a full court name, since it originates from query
    ///     classification and takes both shapes.
    ///   - authorityCourt: the authority's court name, if recorded.
    ///   - authorityJurisdiction: the authority's jurisdiction name, if recorded.
    ///   - authorityCourtID: the authority's CourtListener court id, if recorded.
    public func relationship(
        expected: String,
        authorityCourt: String?,
        authorityJurisdiction: String?,
        authorityCourtID: String?
    ) -> AuthorityRelationship {
        guard
            let authority = resolveAuthority(
                court: authorityCourt,
                jurisdiction: authorityJurisdiction,
                courtID: authorityCourtID
            )
        else {
            return .indeterminate
        }
        guard let expectedOption = resolveExpected(expected) else { return .indeterminate }

        // Identity — the ONE deliberately symmetric relation. A state AGGREGATE
        // (level `.jurisdiction`) is a jurisdiction, not a tribunal: two sides that
        // both resolve to it share a state, never a court.
        if authority.id == expectedOption.id {
            if expectedOption.level == .jurisdiction {
                return expectedOption.system == .state ? .sameStateNoncontrolling : .sameFederalFamily
            }
            return .sameCourt
        }
        // The same tribunal under differing names, by CourtListener identity —
        // restricted to precisely identified tribunals: aggregates and county trial
        // rollups carry a whole jurisdiction's ids as authority SCOPE, not identity.
        if isPreciselyIdentifiedTribunal(authority), isPreciselyIdentifiedTribunal(expectedOption),
           !Set(authority.courtListenerIDs.map { $0.lowercased() })
               .isDisjoint(with: expectedOption.courtListenerIDs.map { $0.lowercased() }) {
            return .sameCourt
        }

        // The Federal Circuit is nationwide but subject-limited (28 U.S.C. § 1295):
        // never an unconditional match for another forum. This resolver cannot see
        // subject matter, so the answer is `.subjectMatterDependent` and consumers
        // without established subject matter fail closed.
        if authority.courtListenerIDs.contains(where: { $0.lowercased() == "cafc" }) {
            return .subjectMatterDependent
        }

        // SCOTUS bindingly controls every resolvable U.S. forum.
        if authority.system == .federal, authority.level == .supreme {
            return .controllingSuperior
        }

        // The same state's courts, directional: the state supreme court controls the
        // state's forums; anything else same-state is noncontrolling.
        if authority.system == .state, expectedOption.system == .state,
           let authorityState = authority.state, authorityState == expectedOption.state {
            return authority.level == .supreme ? .controllingSuperior : .sameStateNoncontrolling
        }

        // The federal hierarchy, directional: the circuit above the expected district
        // controls it; a district under the expected circuit (or a sibling district in
        // the same state family) is family, not controlling.
        if authority.system == .federal, expectedOption.system == .federal {
            if let state = expectedOption.state, isInFederalFamily(authority, ofState: state) {
                return authority.level == .federalAppellate ? .controllingSuperior : .sameFederalFamily
            }
            if let state = authority.state, isInFederalFamily(expectedOption, ofState: state) {
                return .sameFederalFamily
            }
            return .outsideScope
        }

        // State/federal geographic overlap — related, never controlling, directional.
        // A state court is NOT part of its overlapping federal circuit hierarchy; each
        // consumer decides what either direction is worth.
        if expectedOption.system == .state, authority.system == .federal,
           let state = expectedOption.state, isInFederalFamily(authority, ofState: state) {
            return .geographicallyRelated(.federalAuthorityInExpectedState)
        }
        if expectedOption.system == .federal, authority.system == .state,
           let state = authority.state, isInFederalFamily(expectedOption, ofState: state) {
            return .geographicallyRelated(.stateAuthorityInExpectedFederalFootprint)
        }

        // Both sides resolved and no relation holds.
        return .outsideScope
    }

    /// The catalog option id a court name resolves to, or `nil` when the bundled court
    /// list does not carry that court. Exposed so callers can prove that two notations
    /// of one court resolve to the same option.
    public func resolvedOptionID(forCourtName name: String) -> String? {
        optionIDByCourtKey[Self.canonicalKey(name)]
    }

    // MARK: - Resolution

    private func resolveAuthority(
        court: String?,
        jurisdiction: String?,
        courtID: String?
    ) -> JurisdictionOption? {
        if let courtID, let id = optionIDByCourtListenerID[courtID.lowercased()],
           let option = catalog.option(id: id) {
            return option
        }
        if let court, let option = option(forCourtKey: court) { return option }
        if let jurisdiction {
            if let option = option(forCourtKey: jurisdiction) { return option }
            if let option = option(forJurisdictionKey: jurisdiction) { return option }
        }
        // A court name the list does not carry can still name its jurisdiction — fall
        // back to the state the court name ends in ("Supreme Court of Arkansas").
        if let court, let option = optionForTrailingJurisdiction(in: court) { return option }
        return nil
    }

    private func resolveExpected(_ expected: String) -> JurisdictionOption? {
        option(forCourtKey: expected)
            ?? option(forJurisdictionKey: expected)
            ?? optionForTrailingJurisdiction(in: expected)
    }

    private func option(forCourtKey name: String) -> JurisdictionOption? {
        guard let id = optionIDByCourtKey[Self.canonicalKey(name)] else { return nil }
        return catalog.option(id: id)
    }

    private func option(forJurisdictionKey name: String) -> JurisdictionOption? {
        guard let id = optionIDByJurisdictionKey[Self.canonicalKey(name)] else { return nil }
        return catalog.option(id: id)
    }

    /// Resolves a jurisdiction named as the tail of a court name — "Supreme Court of
    /// Arkansas" → Arkansas. Matches whole trailing words against the jurisdiction index,
    /// longest first, so "West Virginia" wins over "Virginia"; a plain suffix test would
    /// reintroduce exactly the containment bug this type exists to remove.
    private func optionForTrailingJurisdiction(in name: String) -> JurisdictionOption? {
        let words = name
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        // Longest trailing phrase first: "of West Virginia" → "West Virginia" → "Virginia".
        for start in 0..<words.count {
            let phrase = words[start...].joined(separator: " ")
            if let option = option(forJurisdictionKey: phrase) { return option }
        }
        return nil
    }

    // MARK: - Relations

    /// Whether an option identifies one specific tribunal. State aggregates
    /// (`.jurisdiction`) and county trial rollups (`.trial`) carry a whole
    /// jurisdiction's CourtListener ids as authority scope, so a shared id there is
    /// not court identity.
    private func isPreciselyIdentifiedTribunal(_ option: JurisdictionOption) -> Bool {
        option.level != .jurisdiction && option.level != .trial
    }

    /// Whether `option` belongs to the federal court family of `state` — that state's
    /// circuit plus the federal district and bankruptcy courts sitting in it.
    private func isInFederalFamily(_ option: JurisdictionOption, ofState state: String) -> Bool {
        guard !option.courtListenerIDs.isEmpty else { return false }
        let family = Set(catalog.relatedFederalCourtIDs(forState: state).map { $0.lowercased() })
        return option.courtListenerIDs.contains { family.contains($0.lowercased()) }
    }

    // MARK: - Canonical key

    /// A comparison key that absorbs notation variance without ever comparing by
    /// containment: ordinal numerals become words ("11th" → "eleventh"), punctuation and
    /// spacing are dropped, and a leading sovereign prefix is removed so
    /// "U.S. Court of Appeals for the 11th Circuit" and "United States Court of Appeals
    /// for the Eleventh Circuit" produce the *same* key, while "Kansas" and "Arkansas"
    /// stay distinct.
    static func canonicalKey(_ value: String) -> String {
        var text = value.lowercased()
        text = spellOutOrdinals(in: text)
        text = String(text.filter { $0.isLetter || $0.isNumber })
        for prefix in ["unitedstates", "us"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            break
        }
        return text
    }

    /// Rewrites "11th" → "eleventh" on whole-token boundaries. Bounded rather than
    /// arithmetic because court names only ever carry small ordinals (circuits, judicial
    /// circuits, appellate districts); an unmapped ordinal is left as written, which
    /// simply means the two spellings do not unify.
    private static func spellOutOrdinals(in text: String) -> String {
        guard let regex = ordinalRegex else { return text }
        let nsText = text as NSString
        var result = text
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        // Replace back-to-front so earlier ranges stay valid.
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }
            let numeral = nsText.substring(with: match.range(at: 1))
            guard let word = ordinalWords[numeral] else { continue }
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: word)
        }
        return result
    }

    private static let ordinalRegex = try? NSRegularExpression(
        pattern: #"\b(\d{1,2})(?:st|nd|rd|th)\b"#
    )

    private static let ordinalWords: [String: String] = [
        "1": "first", "2": "second", "3": "third", "4": "fourth", "5": "fifth",
        "6": "sixth", "7": "seventh", "8": "eighth", "9": "ninth", "10": "tenth",
        "11": "eleventh", "12": "twelfth", "13": "thirteenth", "14": "fourteenth",
        "15": "fifteenth", "16": "sixteenth", "17": "seventeenth", "18": "eighteenth",
        "19": "nineteenth", "20": "twentieth", "21": "twentyfirst", "22": "twentysecond",
        "23": "twentythird", "24": "twentyfourth", "25": "twentyfifth",
        "26": "twentysixth", "27": "twentyseventh", "28": "twentyeighth",
        "29": "twentyninth", "30": "thirtieth"
    ]
}
