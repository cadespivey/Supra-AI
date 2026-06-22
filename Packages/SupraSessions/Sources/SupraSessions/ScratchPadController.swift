import Combine
import Foundation
import SupraCore
import SupraStore

/// A view-facing snapshot of a ScratchPad day.
public struct ScratchPadDaySummary: Identifiable, Sendable, Equatable {
    public let id: String
    public let day: String
    public let isLocked: Bool

    init(record: ScratchPadDayRecord) {
        self.id = record.id
        self.day = record.day
        self.isLocked = record.lockedAt != nil
    }
}

/// A view-facing snapshot of one note entry. `timestamp` is the silent auto-stamp
/// (the entry's `createdAt`), used downstream as time evidence.
public struct ScratchPadEntryView: Identifiable, Sendable, Equatable {
    public let id: String
    public let seq: Int
    public let text: String
    public let timestamp: Date
    public let mentionMatterIDs: [String]
    public let tags: [String]

    init(record: ScratchPadEntryRecord) {
        self.id = record.id
        self.seq = record.seq
        self.text = record.text
        self.timestamp = record.createdAt
        self.mentionMatterIDs = record.mentions
        self.tags = record.tags
    }
}

/// A view-facing snapshot of a day-level attachment (evidence).
public struct ScratchPadAttachmentView: Identifiable, Sendable, Equatable {
    public let id: String
    public let kind: BillingEvidenceKind
    public let fileName: String
    public let matterID: String?
    public let summary: String

    init(record: ScratchPadAttachmentRecord) {
        self.id = record.id
        let resolvedKind = BillingEvidenceKind(rawValue: record.evidenceKind) ?? .other
        self.kind = resolvedKind
        self.matterID = record.matterID
        let evidence = AttachmentEvidence.decode(record.evidenceSignalsJSON)
        self.fileName = evidence?.fileName ?? "Attachment"
        self.summary = evidence?.displaySummary ?? resolvedKind.displayLabel
    }
}

/// Drives the ScratchPad daily note: loads/creates the day, manages entries, and
/// resolves `@matter` / `#tag` tokens (Milestone 4, Phase 2). UI-agnostic.
@MainActor
public final class ScratchPadController: ObservableObject {
    @Published public private(set) var currentDay: ScratchPadDaySummary?
    @Published public private(set) var entries: [ScratchPadEntryView] = []
    @Published public private(set) var recentDays: [ScratchPadDaySummary] = []
    /// Matters available to the `@` autocomplete.
    @Published public private(set) var matterChips: [MatterChip] = []
    /// Distinct `#tags` seen so far, for the `#` autocomplete.
    @Published public private(set) var knownTags: [String] = []
    /// Day-level attachments (evidence) for the current day.
    @Published public private(set) var attachments: [ScratchPadAttachmentView] = []
    /// Set when an attachment can't be ingested (e.g. `.msg`); the view surfaces it.
    @Published public var lastAttachmentError: String?

    private let store: SupraStore
    private let now: () -> Date
    private let attachmentService: ScratchPadAttachmentService

    public init(
        store: SupraStore,
        now: @escaping () -> Date = { Date() },
        attachmentService: ScratchPadAttachmentService = ScratchPadAttachmentService()
    ) {
        self.store = store
        self.now = now
        self.attachmentService = attachmentService
    }

    public var isCurrentDayLocked: Bool { currentDay?.isLocked ?? false }

    /// Loads (or creates) today's pad and the recent-day list.
    public func load() {
        loadMatterChips()
        guard let day = try? store.scratchPad.fetchOrCreateDay(Self.dayString(now())) else { return }
        setCurrentDay(day)
        reloadRecentDays()
    }

    /// Switches to a previously-recorded day (read or continue editing).
    public func selectDay(id: String) {
        loadMatterChips()
        guard let day = try? store.scratchPad.fetchDay(id: id) else { return }
        setCurrentDay(day)
    }

    /// Appends a new, freshly-timestamped entry. `explicitMentions` maps a typed
    /// handle to a matter ID for picks made via autocomplete (precise binding); any
    /// other `@handles` in the text are resolved best-effort against the matter list.
    /// Returns false when the text is empty or the day is locked.
    @discardableResult
    public func addEntry(_ text: String, explicitMentions: [String: String] = [:]) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let day = currentDay, !day.isLocked else { return false }
        let parsed = ScratchPadTokenParser.parse(trimmed)
        let mentions = ScratchPadTagResolver.resolveMentions(parsed.mentions, chips: matterChips, explicit: explicitMentions)
        do {
            try store.scratchPad.addEntry(dayID: day.id, text: trimmed, mentions: mentions, tags: parsed.tags, createdAt: now())
            reloadEntries()
            return true
        } catch {
            return false
        }
    }

    public func updateEntry(id: String, text: String, explicitMentions: [String: String] = [:]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !(currentDay?.isLocked ?? true) else { return }
        let parsed = ScratchPadTokenParser.parse(trimmed)
        let mentions = ScratchPadTagResolver.resolveMentions(parsed.mentions, chips: matterChips, explicit: explicitMentions)
        try? store.scratchPad.updateEntry(id: id, text: trimmed, mentions: mentions, tags: parsed.tags)
        reloadEntries()
    }

    public func deleteEntry(id: String) {
        guard !(currentDay?.isLocked ?? true) else { return }
        try? store.scratchPad.deleteEntry(id: id)
        reloadEntries()
    }

    // MARK: - Attachments

    /// The matter most-mentioned in today's entries — the default association for a
    /// dropped file when the caller doesn't specify one.
    public var suggestedMatterID: String? {
        var counts: [String: Int] = [:]
        for entry in entries {
            for matterID in entry.mentionMatterIDs { counts[matterID, default: 0] += 1 }
        }
        return counts.max { $0.value < $1.value }?.key
    }

    /// Extracts a dropped/picked file locally, builds its evidence, and attaches it
    /// to the day. Sets `lastAttachmentError` on failure (e.g. an unsupported `.msg`).
    public func addAttachment(fileURL: URL, matterID: String? = nil, explicitKind: BillingEvidenceKind? = nil) async {
        guard let day = currentDay, !day.isLocked else { return }
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        do {
            let evidence = try await attachmentService.makeEvidence(fileURL: fileURL, explicitKind: explicitKind)
            try store.scratchPad.addAttachment(
                dayID: day.id,
                matterID: matterID ?? suggestedMatterID,
                evidenceKind: evidence.billingKind,
                evidenceSignalsJSON: AttachmentEvidence.encode(evidence)
            )
            lastAttachmentError = nil
            reloadAttachments()
        } catch let error as ScratchPadAttachmentError {
            lastAttachmentError = error.message
        } catch {
            lastAttachmentError = "Couldn't read that file: \(error.localizedDescription)"
        }
    }

    public func removeAttachment(id: String) {
        guard !(currentDay?.isLocked ?? true) else { return }
        try? store.scratchPad.deleteAttachment(id: id)
        reloadAttachments()
    }

    public func lockCurrentDay() {
        guard let day = currentDay else { return }
        try? store.scratchPad.lockDay(id: day.id)
        refreshCurrentDay(id: day.id)
    }

    public func reopenCurrentDay() {
        guard let day = currentDay else { return }
        try? store.scratchPad.reopenDay(id: day.id)
        refreshCurrentDay(id: day.id)
    }

    // MARK: - Helpers

    private func setCurrentDay(_ record: ScratchPadDayRecord) {
        currentDay = ScratchPadDaySummary(record: record)
        reloadEntries()
        reloadAttachments()
    }

    private func reloadAttachments() {
        guard let day = currentDay else { attachments = []; return }
        let records = (try? store.scratchPad.attachments(dayID: day.id)) ?? []
        attachments = records.map(ScratchPadAttachmentView.init)
    }

    private func refreshCurrentDay(id: String) {
        if let refreshed = try? store.scratchPad.fetchDay(id: id) {
            currentDay = ScratchPadDaySummary(record: refreshed)
        }
    }

    private func reloadEntries() {
        guard let day = currentDay else { entries = []; knownTags = []; return }
        let records = (try? store.scratchPad.entries(dayID: day.id)) ?? []
        entries = records.map(ScratchPadEntryView.init)
        var seen = Set<String>()
        var tags: [String] = []
        for entry in entries {
            for tag in entry.tags where seen.insert(tag.lowercased()).inserted {
                tags.append(tag)
            }
        }
        knownTags = tags
    }

    private func reloadRecentDays() {
        recentDays = ((try? store.scratchPad.recentDays()) ?? []).map(ScratchPadDaySummary.init)
    }

    private func loadMatterChips() {
        matterChips = ((try? store.matters.fetchMatters()) ?? []).map { MatterChip(id: $0.id, name: $0.name) }
    }

    static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
