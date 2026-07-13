import Foundation

// Milestone 4 — deterministic day reconciliation. The model never computes these
// numbers; this code does. Gaps/overlaps depend on the note timeline and are
// filled in by the generation pipeline (Phase 4b); the line-item math here
// (totals, per-matter subtotals, amounts, rounding/confidence flags) is complete
// and pure.

public struct BillingEvidenceValidationSummary: Codable, Sendable, Equatable {
    public var version: Int
    public var candidateMatterIDs: [String]
    public var includedEntryIDs: [String]
    public var includedAttachmentIDs: [String]

    public init(
        version: Int,
        candidateMatterIDs: [String],
        includedEntryIDs: [String],
        includedAttachmentIDs: [String]
    ) {
        self.version = version
        self.candidateMatterIDs = candidateMatterIDs
        self.includedEntryIDs = includedEntryIDs
        self.includedAttachmentIDs = includedAttachmentIDs
    }
}

public struct BillingReconciliation: Codable, Sendable, Equatable {
    public struct MatterSubtotal: Codable, Sendable, Equatable {
        public var matterKey: String
        public var hours: Double
        public var amount: Double

        public init(matterKey: String, hours: Double, amount: Double) {
            self.matterKey = matterKey
            self.hours = hours
            self.amount = amount
        }
    }

    public var billableTotalHours: Double
    public var totalAmount: Double
    public var byMatter: [MatterSubtotal]
    public var gaps: [String]
    public var overlaps: [String]
    public var flags: [String]
    public var nonBillableExcluded: String?
    /// The evidence-derived authorization scope used before this draft was persisted.
    /// Optional for backwards-compatible decoding of existing reconciliation JSON.
    public var evidenceValidation: BillingEvidenceValidationSummary?

    public init(
        billableTotalHours: Double,
        totalAmount: Double,
        byMatter: [MatterSubtotal],
        gaps: [String] = [],
        overlaps: [String] = [],
        flags: [String] = [],
        nonBillableExcluded: String? = nil,
        evidenceValidation: BillingEvidenceValidationSummary? = nil
    ) {
        self.billableTotalHours = billableTotalHours
        self.totalAmount = totalAmount
        self.byMatter = byMatter
        self.gaps = gaps
        self.overlaps = overlaps
        self.flags = flags
        self.nonBillableExcluded = nonBillableExcluded
        self.evidenceValidation = evidenceValidation
    }
}

public enum BillingReconciliationEngine {
    /// Computes the day total, per-matter subtotals, amounts, and the
    /// rounding/confidence/unassigned flags from the fee lines.
    public static func reconcile(
        lines: [BillingLine],
        timekeeper: BillingTimekeeper,
        increment: Double = 0.1
    ) -> BillingReconciliation {
        var flags: [String] = []
        var totalHours = 0.0
        var totalAmount = 0.0
        var order: [String] = []
        var hoursByKey: [String: Double] = [:]
        var amountByKey: [String: Double] = [:]

        for (index, line) in lines.enumerated() {
            totalHours += line.hours
            let amount = line.hours * line.effectiveRate(timekeeper)
            totalAmount += amount

            let key = line.matterDisplay ?? line.lawFirmMatterID ?? line.clientDisplay ?? line.clientID ?? "Unassigned"
            if hoursByKey[key] == nil { order.append(key) }
            hoursByKey[key, default: 0] += line.hours
            amountByKey[key, default: 0] += amount

            if !isMultiple(line.hours, of: increment) {
                flags.append("Line \(index + 1): \(BillingExporter.hoursString(line.hours))h isn't a \(BillingExporter.hoursString(increment))h multiple")
            }
            if line.confidence == .low {
                flags.append("Line \(index + 1): low confidence — confirm")
            }
            if line.lawFirmMatterID == nil && line.clientID == nil {
                flags.append("Line \(index + 1): no matter assigned")
            }
        }

        let subtotals = order.map { key in
            BillingReconciliation.MatterSubtotal(
                matterKey: key,
                hours: round2(hoursByKey[key] ?? 0),
                amount: round2(amountByKey[key] ?? 0)
            )
        }

        return BillingReconciliation(
            billableTotalHours: round2(totalHours),
            totalAmount: round2(totalAmount),
            byMatter: subtotals,
            flags: flags
        )
    }

    /// Whether `value` is an integer multiple of `increment` (within tolerance).
    static func isMultiple(_ value: Double, of increment: Double) -> Bool {
        guard increment > 0 else { return true }
        let ratio = (value / increment).rounded()
        return abs(ratio * increment - value) < 0.0001
    }

    static func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}
