import Foundation
import SupraCore
import SupraStore

/// Builds the system + user prompts for billing-draft generation (Milestone 4
/// Phase 4b). The schema and rules are the contract the local model must follow;
/// the app validates and repairs the result and does all arithmetic.
enum BillingDraftPrompt {

    struct Context {
        var dayDate: String
        var entries: [ScratchPadEntryRecord]
        var attachments: [ScratchPadAttachmentRecord]
        var matters: [MatterRecord]
        var profiles: [String: MatterBillingProfileRecord]
        var sensitivity: Double
        var increment: Double
        var globalInstructions: String
    }

    static func system() -> String {
        """
        You convert a lawyer's contemporaneous daily notes (and attachment evidence) into billing line items.

        Output STRICT JSON only — no prose, no markdown fences — of exactly this shape:
        {"lineItems":[{"matterID":string|null,"narrative":string,"hours":number,"workDate":"YYYY-MM-DD","taskCode":string|null,"activityCode":string|null,"confidence":"high|medium|low","evidence":string,"codeNote":string|null,"sourceEntryIDs":[string]}]}

        Rules:
        - One billable task per line item (no block billing). Past tense. Describe the work product AND its purpose; avoid vague entries ("attention to file"). Spell out a term on first use, then abbreviate ("TC" = telephone conference).
        - matterID MUST be copied verbatim from the provided matter ids, or null if you cannot tell.
        - hours: your best decimal estimate; the app rounds to the increment. NEVER invent time with no basis — if you genuinely cannot tell, use 0 and confidence "low".
        - evidence: state exactly what justifies the duration (a timestamp gap, a file's page/word count, a written "~0.4h" cue, or the implied workflow you inferred).
        - UTBMS coding: for LITIGATION matters assign a task code (L1xx/L2xx/L3xx/L4xx/L5xx) AND an activity code (A1xx). For TRANSACTIONAL/ADVISORY matters (codeSet not "litigation") set taskCode to null, add a codeNote naming the firm's code set, and still assign an A1xx activity code.
        - Exclude apparent non-billable time (lunch, personal, routine admin).
        """
    }

    static func user(_ context: Context) -> String {
        let bucket = BillingSensitivity(value: context.sensitivity)
        var sections: [String] = []

        sections.append("""
        Today: \(context.dayDate). Time sensitivity: \(bucket.rawValue) (\(String(format: "%.2f", context.sensitivity))). Round to \(BillingExporter.hoursString(context.increment))h.
        At low sensitivity bill only explicit/strong-evidence time; at high sensitivity you MAY infer implied workflow (e.g. research preceding substantive drafting, review before a conference) and estimate from timestamp gaps + attachment evidence.
        """)

        let instructions = context.globalInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        sections.append("Global billing instructions:\n\(instructions.isEmpty ? "(none)" : instructions)")

        sections.append("Matters (copy the exact id into matterID, or null):\n" + mattersBlock(context))

        sections.append("Day notes (chronological; [HH:mm] is when each line was written):\n" + entriesBlock(context))

        if !context.attachments.isEmpty {
            sections.append("Attachments (evidence):\n" + attachmentsBlock(context))
        }

        sections.append("Return only the JSON object.")
        return sections.joined(separator: "\n\n")
    }

    // MARK: - Blocks

    private static func mattersBlock(_ context: Context) -> String {
        guard !context.matters.isEmpty else { return "(no matters on file — use null and infer the client/matter in the narrative)" }
        return context.matters.map { matter in
            let codeSet = context.profiles[matter.id]?.billingCodeSet ?? BillingCodeSet.none.rawValue
            var line = "- id=\(matter.id) | \(matter.name)"
            if let client = matter.clientNames, !client.isEmpty { line += " | client=\(client)" }
            line += " | codeSet=\(codeSet)"
            if let override = context.profiles[matter.id]?.overrideInstructions, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                line += " | override: \(override)"
            }
            return line
        }.joined(separator: "\n")
    }

    private static func entriesBlock(_ context: Context) -> String {
        let nameByID = Dictionary(uniqueKeysWithValues: context.matters.map { ($0.id, $0.name) })
        return context.entries.map { entry in
            var line = "[\(timeFormatter.string(from: entry.createdAt))] \(entry.text)"
            let mentionNames = entry.mentions.compactMap { nameByID[$0] }
            if !mentionNames.isEmpty { line += "  (matter: \(mentionNames.joined(separator: ", ")))" }
            return line
        }.joined(separator: "\n")
    }

    private static func attachmentsBlock(_ context: Context) -> String {
        let nameByID = Dictionary(uniqueKeysWithValues: context.matters.map { ($0.id, $0.name) })
        return context.attachments.map { attachment in
            let evidence = AttachmentEvidence.decode(attachment.evidenceSignalsJSON)
            let fileName = evidence?.fileName ?? "attachment"
            var line = "- \(fileName) | \(attachment.evidenceKind)"
            if let matterID = attachment.matterID, let name = nameByID[matterID] { line += " | matter=\(name)" }
            if let summary = evidence?.displaySummary { line += " | \(summary)" }
            if let subject = evidence?.subject, !subject.isEmpty { line += " | subject: \(subject)" }
            return line
        }.joined(separator: "\n")
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
