import Combine
import Foundation
import SupraCore
import SupraStore

public enum BillingExportFormat: String, CaseIterable, Sendable, Identifiable {
    case ledes
    case csv
    case clipboard

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .ledes: "LEDES 1998B"
        case .csv: "CSV"
        case .clipboard: "Copy to clipboard"
        }
    }

    public var fileExtension: String {
        switch self {
        case .ledes: "txt"
        case .csv: "csv"
        case .clipboard: "txt"
        }
    }
}

/// Drives the billing-draft review surface for the current day (Milestone 4
/// Phase 5): generation, the editable line table, recomputed reconciliation,
/// regeneration that preserves manual edits, and export. UI-agnostic.
@MainActor
public final class BillingDraftController: ObservableObject {
    @Published public private(set) var lines: [BillingLineItemRecord] = []
    @Published public private(set) var reconciliation: BillingReconciliation?
    @Published public private(set) var draftVersion: Int?
    @Published public private(set) var isGenerating = false
    @Published public var statusMessage: String?

    public var timekeeper: BillingTimekeeper
    public var increment: Double = 0.1
    /// Generation inputs sourced from Settings (Phase 7). `generate()` uses these
    /// unless an explicit value is passed.
    public var sensitivity: Double = BillingSensitivity.defaultValue
    public var globalInstructions: String = ""
    public var utbmsAutoCoding: Bool = true
    public var autoTimestamp: Bool = true

    private let store: SupraStore
    private let service: BillingDraftService
    private var dayID: String?
    private(set) var draftID: String?

    public init(store: SupraStore, service: BillingDraftService, timekeeper: BillingTimekeeper) {
        self.store = store
        self.service = service
        self.timekeeper = timekeeper
    }

    /// Applies the firm's billing settings so generation and export use the
    /// configured timekeeper, rounding, sensitivity, instructions, and auto-coding.
    public func applySettings(_ settings: BillingSettings) {
        timekeeper = settings.timekeeper
        increment = settings.roundingIncrement
        sensitivity = settings.sensitivity
        globalInstructions = settings.globalInstructions
        utbmsAutoCoding = settings.utbmsAutoCoding
        autoTimestamp = settings.autoTimestamp
    }

    public var hasDraft: Bool { draftID != nil }

    /// Points the controller at a day and loads that day's latest draft (if any).
    public func bind(dayID: String?) {
        self.dayID = dayID
        loadLatest()
    }

    public func loadLatest() {
        guard let dayID, let draft = try? store.billing.latestDraft(dayID: dayID) else {
            draftID = nil; draftVersion = nil; lines = []; reconciliation = nil
            return
        }
        draftID = draft.id
        draftVersion = draft.version
        lines = (try? store.billing.lineItems(draftID: draft.id)) ?? []
        reconciliation = Self.decodeReconciliation(draft.reconciliationJSON)
    }

    /// Generates a new draft version for the day, carrying over any manual edits
    /// from the previous version, then recomputes reconciliation. Without arguments
    /// it uses the applied Settings (sensitivity, instructions, auto-coding).
    public func generate(sensitivity: Double? = nil, globalInstructions: String? = nil) async {
        guard let dayID else { return }
        isGenerating = true
        statusMessage = nil
        do {
            let invoiceDate = (try? store.scratchPad.fetchDay(id: dayID))?.day ?? Self.todayString()
            let previousDraftID = try? store.billing.latestDraft(dayID: dayID)?.id
            let result = try await service.generateDraft(
                dayID: dayID,
                sensitivity: sensitivity ?? self.sensitivity,
                timekeeper: timekeeper,
                invoiceDate: invoiceDate,
                globalInstructions: globalInstructions ?? self.globalInstructions,
                increment: increment,
                autoCoding: utbmsAutoCoding,
                autoTimestamp: autoTimestamp
            )
            if let previousDraftID {
                preserveUserEdits(from: previousDraftID, into: result.draftID)
            }
            draftID = result.draftID
            loadLatest()
            recomputeReconciliation()
        } catch BillingDraftError.emptyDay {
            statusMessage = "Add some notes to this day first."
        } catch BillingDraftError.noModelAvailable {
            statusMessage = "Load a model (Models tab) to generate a billing draft."
        } catch BillingDraftError.unparseable {
            statusMessage = "The model's output couldn't be parsed into entries — try again."
        } catch {
            statusMessage = "Generation failed: \(error.localizedDescription)"
        }
        isGenerating = false
    }

    /// Applies a manual edit to a line (marks it user-edited) and recomputes totals.
    public func editLine(id: String, narrative: String, hours: Double, taskCode: String?, activityCode: String?) {
        let rate = lines.first { $0.id == id }?.rate
        try? store.billing.updateLineItem(
            id: id, narrative: narrative, hours: hours,
            utbmsTaskCode: taskCode, utbmsActivityCode: activityCode, rate: rate
        )
        loadLatest()
        recomputeReconciliation()
    }

    public func exportString(format: BillingExportFormat) -> String {
        let invoiceDate = dayID.flatMap { try? store.scratchPad.fetchDay(id: $0)?.day } ?? Self.todayString()
        let billingLines = self.billingLines()
        switch format {
        case .ledes:
            return BillingExporter.ledes1998B(lines: billingLines, timekeeper: timekeeper, invoice: BillingInvoiceInfo(invoiceDate: invoiceDate ?? Self.todayString()))
        case .csv:
            return BillingExporter.csv(lines: billingLines, timekeeper: timekeeper)
        case .clipboard:
            return BillingExporter.clipboardTSV(lines: billingLines, timekeeper: timekeeper)
        }
    }

    /// The display name for a line's matter (for grouping/labeling in the table).
    public func matterName(for line: BillingLineItemRecord) -> String? {
        guard let matterID = line.matterID else { return nil }
        return (try? store.matters.fetchMatter(id: matterID))?.name
    }

    // MARK: - Helpers

    private func billingLines() -> [BillingLine] {
        let matters = (try? store.matters.fetchMatters()) ?? []
        let byID = Dictionary(uniqueKeysWithValues: matters.map { ($0.id, $0) })
        var codeSetCache: [String: BillingCodeSet] = [:]
        return lines.map { record in
            let matter = record.matterID.flatMap { byID[$0] }
            return BillingLine(
                clientID: matter?.clientID,
                lawFirmMatterID: matter?.internalMatterID,
                clientMatterID: matter?.clientMatterID,
                clientDisplay: matter?.clientNames ?? matter?.name,
                matterDisplay: matter?.name,
                narrative: record.narrative,
                hours: record.hours,
                workDate: record.workDate,
                taskCode: record.utbmsTaskCode,
                activityCode: record.utbmsActivityCode,
                rate: record.rate,
                confidence: BillingConfidence(rawValue: record.confidence) ?? .medium,
                codeSet: record.matterID.map { codeSet(for: $0, cache: &codeSetCache) } ?? .none
            )
        }
    }

    /// The governing code set for a matter (cached per render), used by the
    /// pre-export validator to decide whether a blank task code is a blocking gap.
    private func codeSet(for matterID: String, cache: inout [String: BillingCodeSet]) -> BillingCodeSet {
        if let cached = cache[matterID] { return cached }
        let resolved = (try? store.billing.billingProfile(matterID: matterID))
            .flatMap { BillingCodeSet(rawValue: $0.billingCodeSet) } ?? .none
        cache[matterID] = resolved
        return resolved
    }

    /// Blocking issues that must be fixed before LEDES export (spec §8). Empty means
    /// the current draft is export-ready.
    public func exportIssues() -> [BillingExportIssue] {
        BillingExportValidator.validateForLEDES(lines: billingLines(), timekeeper: timekeeper)
    }

    private func recomputeReconciliation() {
        guard let draftID else { return }
        let recon = BillingReconciliationEngine.reconcile(lines: billingLines(), timekeeper: timekeeper, increment: increment)
        reconciliation = recon
        if let data = try? JSONEncoder().encode(recon), let json = String(data: data, encoding: .utf8) {
            try? store.billing.updateReconciliation(draftID: draftID, reconciliationJSON: json)
        }
    }

    private func preserveUserEdits(from previousDraftID: String, into newDraftID: String) {
        let previousEdited = ((try? store.billing.lineItems(draftID: previousDraftID)) ?? []).filter { $0.userEdited }
        guard !previousEdited.isEmpty else { return }
        let newLines = (try? store.billing.lineItems(draftID: newDraftID)) ?? []
        var claimed = Set<String>()
        for edited in previousEdited {
            guard let match = Self.preservationMatch(for: edited, in: newLines, excluding: claimed) else { continue }
            claimed.insert(match.id)
            try? store.billing.updateLineItem(
                id: match.id, narrative: edited.narrative, hours: edited.hours,
                utbmsTaskCode: edited.utbmsTaskCode, utbmsActivityCode: edited.utbmsActivityCode, rate: edited.rate
            )
        }
    }

    /// Matches a previously user-edited line to a freshly-generated line: first by
    /// overlapping source entry ids (the stable key), then by same matter.
    static func preservationMatch(
        for edited: BillingLineItemRecord,
        in candidates: [BillingLineItemRecord],
        excluding claimed: Set<String> = []
    ) -> BillingLineItemRecord? {
        let editedSources = Set(edited.sourceEntryIDs)
        if !editedSources.isEmpty {
            if let bySource = candidates.first(where: { !claimed.contains($0.id) && !Set($0.sourceEntryIDs).isDisjoint(with: editedSources) }) {
                return bySource
            }
        }
        return candidates.first { !claimed.contains($0.id) && $0.matterID == edited.matterID }
    }

    static func decodeReconciliation(_ json: String?) -> BillingReconciliation? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BillingReconciliation.self, from: data)
    }

    static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
