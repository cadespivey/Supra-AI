import Foundation

// Milestone 4 — the UTBMS (Uniform Task-Based Management System) code tables the
// billing engine validates against and the review UI picks from. The ABA litigation
// task set (L1xx–L5xx) and the universal activity set (A1xx) are fixed standards.
// Transactional / counseling task codes are firm-specific (supplied via the matter's
// guideline docs), so those task codes are accepted as-entered rather than validated
// against a built-in list. See Docs/ScratchPad-SPEC.md §5.4, §7.

/// One UTBMS code with its human title (for pickers and tooltips).
public struct UTBMSCode: Sendable, Equatable, Identifiable, Hashable {
    public let code: String
    public let title: String
    public var id: String { code }

    public init(_ code: String, _ title: String) {
        self.code = code
        self.title = title
    }
}

public enum UTBMSCodes {
    /// Universal activity codes (A1xx) — what kind of work, on every fee line.
    public static let activity: [UTBMSCode] = [
        UTBMSCode("A101", "Plan and prepare for"),
        UTBMSCode("A102", "Research"),
        UTBMSCode("A103", "Draft/revise"),
        UTBMSCode("A104", "Review/analyze"),
        UTBMSCode("A105", "Communicate (in firm)"),
        UTBMSCode("A106", "Communicate (with client)"),
        UTBMSCode("A107", "Communicate (other outside counsel)"),
        UTBMSCode("A108", "Communicate (other external)"),
        UTBMSCode("A109", "Appear for/attend"),
        UTBMSCode("A110", "Manage data/files"),
        UTBMSCode("A111", "Other"),
    ]

    /// Litigation task codes (L1xx–L5xx) — the ABA litigation code set.
    public static let litigationTask: [UTBMSCode] = [
        UTBMSCode("L100", "Case Assessment, Development and Administration"),
        UTBMSCode("L110", "Fact Investigation/Development"),
        UTBMSCode("L120", "Analysis/Strategy"),
        UTBMSCode("L130", "Experts/Consultants"),
        UTBMSCode("L140", "Document/File Management"),
        UTBMSCode("L150", "Budgeting"),
        UTBMSCode("L160", "Settlement/Non-Binding ADR"),
        UTBMSCode("L190", "Other Case Assessment/Development/Administration"),
        UTBMSCode("L200", "Pre-Trial Pleadings and Motions"),
        UTBMSCode("L210", "Pleadings"),
        UTBMSCode("L220", "Preliminary Injunctions/Provisional Remedies"),
        UTBMSCode("L230", "Court Mandated Conferences"),
        UTBMSCode("L240", "Dispositive Motions"),
        UTBMSCode("L250", "Other Written Motions and Submissions"),
        UTBMSCode("L300", "Discovery"),
        UTBMSCode("L310", "Written Discovery"),
        UTBMSCode("L320", "Document Production"),
        UTBMSCode("L330", "Depositions"),
        UTBMSCode("L340", "Expert Discovery"),
        UTBMSCode("L350", "Discovery Motions"),
        UTBMSCode("L390", "Other Discovery"),
        UTBMSCode("L400", "Trial Preparation and Trial"),
        UTBMSCode("L410", "Fact Witnesses"),
        UTBMSCode("L420", "Expert Witnesses"),
        UTBMSCode("L430", "Written Motions and Submissions"),
        UTBMSCode("L440", "Other Trial Preparation and Support"),
        UTBMSCode("L450", "Trial and Hearing Attendance"),
        UTBMSCode("L460", "Post-Trial Motions and Submissions"),
        UTBMSCode("L470", "Enforcement"),
        UTBMSCode("L500", "Appeal"),
        UTBMSCode("L510", "Appellate Motions and Submissions"),
        UTBMSCode("L520", "Appellate Briefs"),
        UTBMSCode("L530", "Oral Argument"),
    ]

    private static let activityCodeSet: Set<String> = Set(activity.map(\.code))
    private static let litigationTaskCodeSet: Set<String> = Set(litigationTask.map(\.code))

    /// The task codes offered in the picker for a matter on the given code set.
    /// Litigation has a built-in list; the firm-specific sets do not.
    public static func taskCodes(for codeSet: BillingCodeSet) -> [UTBMSCode] {
        codeSet == .litigation ? litigationTask : []
    }

    /// Normalizes + validates a model- or user-supplied activity code: uppercased,
    /// returned only if it's a real A1xx code, else nil.
    public static func normalizedActivityCode(_ raw: String?) -> String? {
        guard let code = clean(raw), activityCodeSet.contains(code) else { return nil }
        return code
    }

    /// Normalizes + validates a task code against the matter's code set. Litigation
    /// codes are checked against the L-set; firm-specific (transactional/advisory)
    /// task codes are accepted as-entered; `.none` carries no task code.
    public static func normalizedTaskCode(_ raw: String?, codeSet: BillingCodeSet) -> String? {
        guard let code = clean(raw) else { return nil }
        switch codeSet {
        case .litigation:
            return litigationTaskCodeSet.contains(code) ? code : nil
        case .transactional, .advisory:
            return code
        case .none:
            return nil
        }
    }

    public static func isValidActivityCode(_ raw: String?) -> Bool { normalizedActivityCode(raw) != nil }

    private static func clean(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed.uppercased()
    }
}
