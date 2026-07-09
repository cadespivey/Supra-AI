import Foundation

/// The starter folder set a new matter's Documents tab is seeded with, chosen
/// by keyword match against the matter's practice area. Free-text practice
/// areas ("Commercial Litigation", "Real Estate — Leasing") map onto a
/// template by containing any of its keywords as whole words/phrases (so
/// "Intellectual Property" does NOT match real estate's "property");
/// unmatched or empty practice areas get the general set.
public enum PracticeAreaFolderTemplates {
    /// The fallback set for matters with no or an unrecognized practice area.
    public static let generalFolders = [
        "Key Documents", "Correspondence", "Research", "Drafts"
    ]

    /// Ordered: the first template whose keyword appears in the practice area
    /// wins, so more specific entries (appellate, construction) precede the
    /// broad litigation match.
    static let templates: [(keywords: [String], folders: [String])] = [
        (
            ["appellate", "appeal", "appeals"],
            ["Record on Appeal", "Briefs", "Orders & Opinions", "Correspondence", "Research", "Drafts"]
        ),
        (
            ["construction"],
            ["Contracts", "Change Orders", "Claims", "Pleadings", "Correspondence", "Research", "Drafts"]
        ),
        (
            ["bankruptcy", "restructuring", "creditors", "insolvency"],
            ["Petitions & Schedules", "Claims", "Pleadings", "Correspondence", "Research", "Drafts"]
        ),
        (
            ["employment", "labor"],
            ["Pleadings", "Discovery", "Personnel Records", "Agreements", "Correspondence", "Research", "Drafts"]
        ),
        (
            ["real estate", "lease", "leases", "leasing", "landlord", "land use", "zoning", "foreclosure"],
            ["Contracts", "Title & Survey", "Closing", "Leases", "Correspondence", "Research", "Drafts"]
        ),
        (
            ["corporate", "transactional", "m&a", "merger", "mergers", "acquisitions", "securities"],
            ["Agreements", "Due Diligence", "Corporate Records", "Correspondence", "Research", "Drafts"]
        ),
        (
            ["litigation", "dispute", "disputes", "trial", "arbitration"],
            ["Pleadings", "Discovery", "Motions", "Exhibits", "Correspondence", "Research", "Drafts"]
        )
    ]

    private static let litigationKeywords = ["litigation", "dispute", "disputes", "trial", "arbitration"]

    /// The folder names to preload for a matter with this practice area.
    public static func folders(forPracticeArea practiceArea: String) -> [String] {
        guard !practiceArea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return generalFolders
        }
        let normalized = normalize(practiceArea)
        guard let matched = templates.first(where: { template in
            template.keywords.contains { normalized.contains(normalize($0)) }
        }) else { return generalFolders }

        // "Real Estate Litigation" gets the real-estate set for its subject
        // matter — but it's still litigation, so make sure the adversarial
        // basics are present too.
        let mentionsLitigation = litigationKeywords.contains { normalized.contains(normalize($0)) }
        if mentionsLitigation {
            let missing = ["Pleadings", "Discovery"].filter { !matched.folders.contains($0) }
            return missing + matched.folders
        }
        return matched.folders
    }

    /// Case/diacritic-folds and reduces to space-separated word tokens padded
    /// with spaces, so keyword containment means whole-word/phrase match:
    /// " intellectual property " contains " property " but not " real estate ".
    private static func normalize(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let words = folded
            .map { $0.isLetter || $0.isNumber || $0 == "&" ? $0 : " " }
        return " " + String(words).split(separator: " ").joined(separator: " ") + " "
    }
}
