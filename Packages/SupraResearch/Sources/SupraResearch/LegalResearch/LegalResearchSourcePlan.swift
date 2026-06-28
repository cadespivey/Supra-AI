import Foundation

public enum LegalSourceTargetKind: String, Codable, Hashable, Sendable {
    case global
    case matter
}

/// The caller's source universe. Global and matter chats should differ here, not
/// by forking the legal-research workflow itself.
public struct LegalSourceTarget: Codable, Hashable, Sendable {
    public var kind: LegalSourceTargetKind
    public var matterID: String?
    public var jurisdiction: String?
    public var courtIDs: [String]
    public var hasMatterDocuments: Bool
    public var hasSavedMatterAuthorities: Bool

    public init(
        kind: LegalSourceTargetKind,
        matterID: String? = nil,
        jurisdiction: String? = nil,
        courtIDs: [String] = [],
        hasMatterDocuments: Bool = false,
        hasSavedMatterAuthorities: Bool = false
    ) {
        self.kind = kind
        self.matterID = matterID
        self.jurisdiction = jurisdiction
        self.courtIDs = courtIDs
        self.hasMatterDocuments = hasMatterDocuments
        self.hasSavedMatterAuthorities = hasSavedMatterAuthorities
    }
}

public struct LegalResearchSourcePlan: Codable, Hashable, Sendable {
    public var target: LegalSourceTarget
    public var effectiveClassification: LegalQueryClassification
    public var requiresPrimaryLaw: Bool
    public var shouldRetrievePrimaryLaw: Bool
    public var shouldRetrieveCaseLaw: Bool
    public var shouldRetrieveDevelopments: Bool
    public var satisfiesJurisdictionRequirement: Bool
    public var authorityPriority: [LegalAuthorityPriorityStep]
    public var primaryLawQueryTerms: String
    public var primaryLawCitationQuery: String?
    public var notes: [String]

    public init(
        target: LegalSourceTarget,
        effectiveClassification: LegalQueryClassification,
        requiresPrimaryLaw: Bool,
        shouldRetrievePrimaryLaw: Bool,
        shouldRetrieveCaseLaw: Bool,
        shouldRetrieveDevelopments: Bool,
        satisfiesJurisdictionRequirement: Bool,
        authorityPriority: [LegalAuthorityPriorityStep] = [],
        primaryLawQueryTerms: String,
        primaryLawCitationQuery: String? = nil,
        notes: [String] = []
    ) {
        self.target = target
        self.effectiveClassification = effectiveClassification
        self.requiresPrimaryLaw = requiresPrimaryLaw
        self.shouldRetrievePrimaryLaw = shouldRetrievePrimaryLaw
        self.shouldRetrieveCaseLaw = shouldRetrieveCaseLaw
        self.shouldRetrieveDevelopments = shouldRetrieveDevelopments
        self.satisfiesJurisdictionRequirement = satisfiesJurisdictionRequirement
        self.authorityPriority = authorityPriority
        self.primaryLawQueryTerms = primaryLawQueryTerms
        self.primaryLawCitationQuery = primaryLawCitationQuery
        self.notes = notes
    }
}

public struct LegalAuthorityPriorityStep: Codable, Hashable, Sendable {
    public var rank: Int
    public var label: String
    public var guidance: String

    public init(rank: Int, label: String, guidance: String) {
        self.rank = rank
        self.label = label
        self.guidance = guidance
    }
}

public enum LegalResearchSourcePlanner {
    public static func plan(
        classification: LegalQueryClassification,
        target: LegalSourceTarget
    ) -> LegalResearchSourcePlan {
        let scheme = federalSchemeHint(for: classification.legalIssue)
        var effective = classification
        if effective.jurisdiction?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            if let targetJurisdiction = target.jurisdiction?.trimmingCharacters(in: .whitespacesAndNewlines),
               !targetJurisdiction.isEmpty {
                effective.jurisdiction = targetJurisdiction
            } else if scheme != nil {
                effective.jurisdiction = "Federal"
            }
        }
        if effective.courtIDs.isEmpty, !target.courtIDs.isEmpty {
            effective.courtIDs = target.courtIDs
        }

        let requiresPrimary = requiresPrimaryLaw(for: effective)
        let shouldRetrievePrimary = requiresPrimary || isStatutoryOrRegulatory(effective)
        let citationQuery = primaryLawCitationQuery(classification: effective, scheme: scheme)
        let terms = primaryLawQueryTerms(classification: effective, scheme: scheme)
        let hasJurisdiction = !(effective.jurisdiction?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let satisfiesJurisdiction = hasJurisdiction || scheme != nil

        var notes: [String] = []
        if let scheme {
            notes.append("federal_scheme:\(scheme.id)")
        }
        if requiresPrimary {
            notes.append("primary_law_required")
        }

        return LegalResearchSourcePlan(
            target: target,
            effectiveClassification: effective,
            requiresPrimaryLaw: requiresPrimary,
            shouldRetrievePrimaryLaw: shouldRetrievePrimary,
            shouldRetrieveCaseLaw: true,
            shouldRetrieveDevelopments: shouldRetrieveDevelopments(for: effective),
            satisfiesJurisdictionRequirement: satisfiesJurisdiction,
            authorityPriority: authorityPriority(for: effective, target: target, requiresPrimaryLaw: requiresPrimary),
            primaryLawQueryTerms: terms,
            primaryLawCitationQuery: citationQuery,
            notes: notes
        )
    }

    public static func statutoryQuery(
        for plan: LegalResearchSourcePlan,
        limit: Int
    ) -> StatutoryQuery {
        StatutoryQuery(
            terms: plan.primaryLawQueryTerms,
            jurisdiction: plan.effectiveClassification.jurisdiction,
            citation: plan.primaryLawCitationQuery ?? plan.effectiveClassification.citationLookup,
            limit: limit
        )
    }

    public static func requiresPrimaryLaw(for classification: LegalQueryClassification) -> Bool {
        if isStatutoryOrRegulatory(classification) { return true }
        let lower = classification.legalIssue.lowercased()
        let markers = [
            "statute of limitations", "limitations period", "deadline", "time limit",
            "limitations run", "claim filing", "file a claim",
            "statutory scheme", "agency administer",
            "agency-administered", "department oversees", "administrative claim",
            "benefits claim", "exhaustion", "notice requirement"
        ]
        return markers.contains { lower.contains($0) } || federalSchemeHint(for: lower) != nil
    }

    public static func isStatutoryOrRegulatory(_ classification: LegalQueryClassification) -> Bool {
        if classification.desiredAuthorityType == .statute { return true }
        let haystack = [classification.legalIssue, classification.citationLookup ?? ""]
            .joined(separator: " ")
            .lowercased()
        return haystack.contains("u.s.c")
            || haystack.contains("c.f.r")
            || haystack.contains("§")
            || haystack.contains("statute")
            || haystack.contains("regulation")
            || haystack.contains("code section")
    }

    public static func shouldRetrieveDevelopments(for classification: LegalQueryClassification) -> Bool {
        if classification.dateSensitivity == "current_or_recent" { return true }
        let lower = classification.legalIssue.lowercased()
        let markers = [
            "latest", "recent", "current", "pending", "proposed", "rulemaking",
            "new rule", "amendment", "amended", "bill", "legislation", "regulatory change"
        ]
        return markers.contains { lower.contains($0) }
    }

    public static func authorityPriority(
        for classification: LegalQueryClassification,
        target: LegalSourceTarget,
        requiresPrimaryLaw: Bool
    ) -> [LegalAuthorityPriorityStep] {
        let federal = isFederal(classification: classification, target: target)
        let primaryLabel = federal
            ? "Governing federal text"
            : "Governing state text"
        let primaryGuidance = federal
            ? "Start with applicable constitutional text, statutes, regulations, rules, or incorporated federal schemes. Do not infer their contents from cases."
            : "Start with applicable state constitutional provisions, statutes, regulations, and procedural rules. Do not infer their contents from cases."

        var steps: [LegalAuthorityPriorityStep] = [
            LegalAuthorityPriorityStep(rank: 1, label: primaryLabel, guidance: primaryGuidance)
        ]

        if federal {
            steps += [
                LegalAuthorityPriorityStep(rank: 2, label: "U.S. Supreme Court", guidance: "Controls federal issues and may set constitutional or statutory limits."),
                LegalAuthorityPriorityStep(rank: 3, label: "Governing federal circuit", guidance: "Use published opinions from the controlling circuit when a circuit is specified or inferable."),
                LegalAuthorityPriorityStep(rank: 4, label: "Other federal circuits", guidance: "Persuasive only unless no controlling circuit authority is in the packet."),
                LegalAuthorityPriorityStep(rank: 5, label: "Federal district and agency decisions", guidance: "Persuasive or scheme-specific only; never let them override higher authority.")
            ]
        } else {
            steps += [
                LegalAuthorityPriorityStep(rank: 2, label: "U.S. Supreme Court federal limits", guidance: "Controls federal constitutional or federal-law constraints on state law."),
                LegalAuthorityPriorityStep(rank: 3, label: "State court of last resort", guidance: "Controls state-law interpretation when on point."),
                LegalAuthorityPriorityStep(rank: 4, label: "State intermediate appellate courts", guidance: "Use as controlling/predictive according to local rules when the high court has not spoken."),
                LegalAuthorityPriorityStep(rank: 5, label: "Trial orders and federal Erie predictions", guidance: "Persuasive only; do not present as controlling law.")
            ]
        }

        if !requiresPrimaryLaw {
            steps[0].guidance += " If primary law is irrelevant to the question, say so rather than forcing a statutory analysis."
        }
        return steps
    }

    private static func primaryLawQueryTerms(
        classification: LegalQueryClassification,
        scheme: FederalSchemeHint?
    ) -> String {
        var parts = [classification.legalIssue]
        if let scheme {
            parts.append(scheme.searchTerms)
            parts.append(contentsOf: scheme.citations)
        }
        return uniqueTerms(parts).joined(separator: " ")
    }

    private static func primaryLawCitationQuery(
        classification: LegalQueryClassification,
        scheme: FederalSchemeHint?
    ) -> String? {
        var citations: [String] = []
        if let citation = classification.citationLookup, !citation.isEmpty {
            citations.append(citation)
        }
        if let scheme {
            citations.append(contentsOf: scheme.citations)
        }
        let unique = uniqueTerms(citations)
        return unique.isEmpty ? nil : unique.joined(separator: "; ")
    }

    private static func uniqueTerms(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    private static func isFederal(classification: LegalQueryClassification, target: LegalSourceTarget) -> Bool {
        let values = [
            classification.jurisdiction,
            target.jurisdiction,
            classification.jurisdictionContext
        ].compactMap { $0?.lowercased() }
        if values.contains(where: { $0.contains("federal") || $0.contains("circuit") }) {
            return true
        }
        let federalCourtIDs: Set<String> = [
            "scotus", "ca1", "ca2", "ca3", "ca4", "ca5", "ca6", "ca7", "ca8", "ca9",
            "ca10", "ca11", "cadc", "cafc", "cand", "dcd", "nysd", "nyed", "txsd",
            "txnd", "flsd", "flmd", "flnd"
        ]
        if classification.courtIDs.contains(where: federalCourtIDs.contains) {
            return true
        }
        return federalSchemeHint(for: classification.legalIssue) != nil
    }

    private struct FederalSchemeHint {
        var id: String
        var searchTerms: String
        var citations: [String]
    }

    private static func federalSchemeHint(for issue: String) -> FederalSchemeHint? {
        let lower = issue.lowercased()
        if lower.contains("defense base act") || lower.contains("dba claim") {
            let limitations = lower.contains("limitations")
                || lower.contains("deadline")
                || lower.contains("time limit")
                || lower.contains("when does")
                || lower.contains("claim filing")
            return FederalSchemeHint(
                id: "defense-base-act",
                searchTerms: limitations
                    ? "Defense Base Act Longshore claim filing limitations"
                    : "Defense Base Act Longshore workers compensation",
                citations: limitations
                    ? ["42 U.S.C. § 1651", "33 U.S.C. § 913"]
                    : ["42 U.S.C. § 1651"]
            )
        }
        if lower.contains("longshore") || lower.contains("lhwca") {
            return FederalSchemeHint(
                id: "longshore",
                searchTerms: "Longshore and Harbor Workers' Compensation Act",
                citations: ["33 U.S.C. § 901"]
            )
        }
        if lower.contains("flsa") || lower.contains("fair labor standards") {
            return FederalSchemeHint(id: "flsa", searchTerms: "Fair Labor Standards Act", citations: ["29 U.S.C. § 201"])
        }
        if lower.contains("erisa") {
            return FederalSchemeHint(id: "erisa", searchTerms: "Employee Retirement Income Security Act", citations: ["29 U.S.C. § 1001"])
        }
        if lower.contains("ftca") || lower.contains("federal tort claims") {
            return FederalSchemeHint(id: "ftca", searchTerms: "Federal Tort Claims Act", citations: ["28 U.S.C. § 1346"])
        }
        return nil
    }
}
