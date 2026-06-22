import Foundation

// Milestone 4 Phase 7 (folds in the remaining Phase-6 deliverable) — the pre-export
// validator. LEDES 1998B is a strict, machine-ingested format: a missing client id,
// firm matter id, timekeeper rate, or required UTBMS code produces an invoice a
// billing system will silently reject or mis-post. This pure validator surfaces
// those gaps with clear, attorney-readable messages BEFORE export, so nothing
// half-formed leaves the app. See Docs/ScratchPad-SPEC.md §8.

/// One blocking problem found while validating a draft for LEDES export.
public struct BillingExportIssue: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case noLines
        case timekeeperRate
        case timekeeperID
        case firmID
        case clientID
        case firmMatterID
        case zeroHours
        case lineRate
        case activityCode
        case taskCode
    }

    public var kind: Kind
    /// Attorney-facing explanation of what to fix.
    public var message: String
    /// The narrative of the offending line, or nil for an invoice-level problem.
    public var lineNarrative: String?

    public var id: String { "\(kind.rawValue)\u{1}\(lineNarrative ?? "")" }

    public init(kind: Kind, message: String, lineNarrative: String? = nil) {
        self.kind = kind
        self.message = message
        self.lineNarrative = lineNarrative
    }
}

public enum BillingExportValidator {
    /// Returns every blocking issue that must be resolved before the lines can be
    /// exported as LEDES 1998B. An empty result means the draft is export-ready.
    /// CSV/clipboard exports are review aids and are intentionally NOT gated here.
    public static func validateForLEDES(lines: [BillingLine], timekeeper: BillingTimekeeper) -> [BillingExportIssue] {
        var issues: [BillingExportIssue] = []

        guard !lines.isEmpty else {
            return [BillingExportIssue(kind: .noLines, message: "There are no billable lines to export.")]
        }

        // Invoice-level (firm/timekeeper) requirements — configured in Settings.
        if timekeeper.defaultRate <= 0 {
            issues.append(BillingExportIssue(
                kind: .timekeeperRate,
                message: "Set the timekeeper's default rate in Settings → ScratchPad & Billing before exporting."
            ))
        }
        if timekeeper.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(BillingExportIssue(
                kind: .timekeeperID,
                message: "Set the timekeeper ID in Settings → ScratchPad & Billing (LEDES requires TIMEKEEPER_ID)."
            ))
        }
        if timekeeper.lawFirmID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(BillingExportIssue(
                kind: .firmID,
                message: "Set the firm's LAW_FIRM_ID in Settings → ScratchPad & Billing."
            ))
        }

        // Per-line requirements. De-duplicated by kind so a many-line draft surfaces
        // each distinct fix once, attributed to the first offending line.
        var seenClientID = false, seenFirmMatterID = false
        for line in lines {
            if isBlank(line.clientID), !seenClientID {
                seenClientID = true
                issues.append(BillingExportIssue(
                    kind: .clientID,
                    message: "Add the client's CLIENT_ID on the matter (Matter → Billing) — required for LEDES.",
                    lineNarrative: line.narrative
                ))
            }
            if isBlank(line.lawFirmMatterID), !seenFirmMatterID {
                seenFirmMatterID = true
                issues.append(BillingExportIssue(
                    kind: .firmMatterID,
                    message: "Add the firm's internal matter ID (LAW_FIRM_MATTER_ID) on the matter — required for LEDES.",
                    lineNarrative: line.narrative
                ))
            }
            if line.hours <= 0 {
                issues.append(BillingExportIssue(
                    kind: .zeroHours,
                    message: "This line has no billable time. Set its hours or remove it.",
                    lineNarrative: line.narrative
                ))
            }
            // A blank line rate falls back to the timekeeper default (guarded above);
            // an explicit per-line override of 0 would export a $0 fee line, so block it.
            if let lineRate = line.rate, lineRate <= 0 {
                issues.append(BillingExportIssue(
                    kind: .lineRate,
                    message: "This line has a $0 rate. Set a positive rate or remove the line before export.",
                    lineNarrative: line.narrative
                ))
            }
            if isBlank(line.activityCode) {
                issues.append(BillingExportIssue(
                    kind: .activityCode,
                    message: "Assign a UTBMS activity code (A1xx) to this line.",
                    lineNarrative: line.narrative
                ))
            }
            if line.codeSet.requiresTaskCode, isBlank(line.taskCode) {
                issues.append(BillingExportIssue(
                    kind: .taskCode,
                    message: "Set the firm's \(line.codeSet.displayLabel) task code on this line before export.",
                    lineNarrative: line.narrative
                ))
            }
        }

        return issues
    }

    private static func isBlank(_ value: String?) -> Bool {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
