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
    /// True when tagged `#Note` — excluded from the billing/time draft.
    public let isNonBillable: Bool

    init(record: ScratchPadEntryRecord) {
        self.id = record.id
        self.seq = record.seq
        self.text = record.text
        self.timestamp = record.createdAt
        self.mentionMatterIDs = record.mentions
        self.tags = record.tags
        self.isNonBillable = record.isNonBillable
    }
}

/// A view-facing snapshot of a day-level attachment (evidence).
public struct ScratchPadAttachmentView: Identifiable, Sendable, Equatable {
    public let id: String
    public let kind: BillingEvidenceKind
    public let fileName: String
    public let matterID: String?
    public let summary: String
    /// The entry this file was attached to, or nil for a legacy day-level attachment.
    public let entryID: String?

    init(record: ScratchPadAttachmentRecord) {
        self.id = record.id
        let resolvedKind = BillingEvidenceKind(rawValue: record.evidenceKind) ?? .other
        self.kind = resolvedKind
        self.matterID = record.matterID
        self.entryID = record.entryID
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
    /// The calendar date currently shown ("yyyy-MM-dd"), even when no day record
    /// exists yet (a freshly-browsed date with no notes). Drives the header title
    /// and the history calendar's selection.
    @Published public private(set) var displayedDate: String = ""
    @Published public private(set) var entries: [ScratchPadEntryView] = []
    @Published public private(set) var recentDays: [ScratchPadDaySummary] = []
    /// Matters available to the `@` autocomplete.
    @Published public private(set) var matterChips: [MatterChip] = []
    /// Distinct `#tags` seen so far, for the `#` autocomplete.
    @Published public private(set) var knownTags: [String] = []
    /// Cross-day note search results (text/tag match); empty when not searching.
    @Published public private(set) var searchResults: [ScratchPadRepository.EntryHit] = []
    /// The `#` autocomplete vocabulary: used tags merged with the curated litigation
    /// starter set, so `#` is useful before the user has built up their own tags.
    @Published public private(set) var tagVocabulary: [String] = ScratchPadTagResolver.mergedTagVocabulary(used: [])
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
        lastAttachmentError = nil
        guard let day = try? store.scratchPad.fetchDay(id: id) else { return }
        setCurrentDay(day)
    }

    /// Opens the pad for an arbitrary calendar date (history navigation). A date
    /// that already has notes loads them; a date with none shows an empty pad whose
    /// day row is created lazily on the first entry/attachment — so browsing the
    /// calendar never leaves a trail of empty days.
    public func selectDate(_ date: Date) {
        loadMatterChips()
        // The attachment error belongs to the day that produced it — clear it so the
        // banner doesn't linger after navigating to a different day.
        lastAttachmentError = nil
        let dayString = Self.dayString(date)
        if let record = try? store.scratchPad.fetchDay(day: dayString) {
            setCurrentDay(record)
        } else {
            displayedDate = dayString
            currentDay = nil
            reloadEntries()       // entries empty, but #tag suggestions stay all-time
            reloadAttachments()
        }
    }

    /// Runs a cross-day note search. Matches entry text (which includes inline `#tags`
    /// and `@mentions`), newest day first. Needs at least 2 characters; shorter terms
    /// clear the results so the normal day view returns.
    public func search(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { searchResults = []; return }
        searchResults = (try? store.scratchPad.searchEntries(term: trimmed)) ?? []
    }

    public func clearSearch() { searchResults = [] }

    /// Opens the day a search hit belongs to and clears the search.
    public func openDay(dayString: String) {
        guard let record = try? store.scratchPad.fetchDay(day: dayString) else { return }
        searchResults = []
        setCurrentDay(record)
    }

    /// Appends a new, freshly-timestamped entry. `explicitMentions` maps a typed
    /// handle to a matter ID for picks made via autocomplete (precise binding); any
    /// other `@handles` in the text are resolved best-effort against the matter list.
    /// Returns false when the text is empty or the day is locked.
    @discardableResult
    public func addEntry(_ text: String, explicitMentions: [String: String] = [:]) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let day = ensurePersistedDay(), !day.isLocked else { return false }
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

    /// Adds a note AND attaches the given files to it inline, in one go — so an
    /// uploaded document lives with its describing note rather than in a detached
    /// day-level tray. A bare drop (no text) still creates a minimal note so a file is
    /// always tied to a note. The attachment's matter is the note's own `@matter`
    /// (falling back to the day's most-mentioned). Returns false if there is nothing
    /// to add or the day is locked.
    @discardableResult
    public func addEntry(
        _ text: String,
        explicitMentions: [String: String] = [:],
        attachmentURLs: [URL]
    ) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachmentURLs.isEmpty else { return false }
        guard let day = ensurePersistedDay(), !day.isLocked else { return false }
        let entryText = trimmed.isEmpty ? Self.defaultText(forAttachments: attachmentURLs) : trimmed
        let parsed = ScratchPadTokenParser.parse(entryText)
        let mentions = ScratchPadTagResolver.resolveMentions(parsed.mentions, chips: matterChips, explicit: explicitMentions)
        guard let entry = try? store.scratchPad.addEntry(
            dayID: day.id, text: entryText, mentions: mentions, tags: parsed.tags, createdAt: now()
        ) else { return false }
        let entryMatter = mentions.first ?? suggestedMatterID
        for url in attachmentURLs {
            await addAttachment(fileURL: url, matterID: entryMatter, entryID: entry.id)
        }
        reloadEntries()
        return true
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
        reloadAttachments()
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

    /// Attachments tied to a specific note entry (rendered inline under that note).
    public func attachments(forEntry entryID: String) -> [ScratchPadAttachmentView] {
        attachments.filter { $0.entryID == entryID }
    }

    /// Legacy day-level attachments not tied to any note (older days only).
    public var unfiledAttachments: [ScratchPadAttachmentView] {
        attachments.filter { $0.entryID == nil }
    }

    /// Extracts a dropped/picked file locally, builds its evidence, and attaches it.
    /// When `entryID` is given the file is recorded inline with that note (and inherits
    /// the note's matter when one isn't passed). Sets `lastAttachmentError` on failure
    /// (e.g. an unsupported `.msg`).
    public func addAttachment(
        fileURL: URL,
        matterID: String? = nil,
        explicitKind: BillingEvidenceKind? = nil,
        entryID: String? = nil
    ) async {
        guard let day = ensurePersistedDay(), !day.isLocked else { return }
        let resolvedMatter = matterID ?? entryMatterID(entryID) ?? suggestedMatterID
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        do {
            let evidence = try await attachmentService.makeEvidence(fileURL: fileURL, explicitKind: explicitKind)
            try store.scratchPad.addAttachment(
                dayID: day.id,
                entryID: entryID,
                matterID: resolvedMatter,
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

    /// The matter mentioned by a given entry (for attributing a file dropped onto it).
    private func entryMatterID(_ entryID: String?) -> String? {
        guard let entryID else { return nil }
        return entries.first { $0.id == entryID }?.mentionMatterIDs.first
    }

    /// A minimal note for a bare file drop (no typed text), so the file is still tied
    /// to a note in the timeline.
    private static func defaultText(forAttachments urls: [URL]) -> String {
        if urls.count == 1 { return "Attached \(urls[0].lastPathComponent)" }
        return "Attached \(urls.count) files"
    }

    public func lockCurrentDay() {
        guard let day = currentDay else { return }
        try? store.scratchPad.lockDay(id: day.id)
        _ = try? store.auditEvents.recordEvent(eventType: "scratchpad_day_locked", actor: "user", summary: "Locked ScratchPad day \(day.day)")
        refreshCurrentDay(id: day.id)
    }

    public func reopenCurrentDay() {
        guard let day = currentDay else { return }
        try? store.scratchPad.reopenDay(id: day.id)
        _ = try? store.auditEvents.recordEvent(eventType: "scratchpad_day_reopened", actor: "user", summary: "Reopened ScratchPad day \(day.day)")
        refreshCurrentDay(id: day.id)
    }

    // MARK: - Helpers

    private func setCurrentDay(_ record: ScratchPadDayRecord) {
        currentDay = ScratchPadDaySummary(record: record)
        displayedDate = record.day
        reloadEntries()
        reloadAttachments()
    }

    /// Returns the current day's record, persisting it from the displayed date if
    /// the user is on a freshly-browsed date with no row yet. The row (and the
    /// recent-days list) materializes only when the day gets its first content.
    private func ensurePersistedDay() -> ScratchPadDaySummary? {
        if let day = currentDay { return day }
        guard !displayedDate.isEmpty,
              let record = try? store.scratchPad.fetchOrCreateDay(displayedDate) else { return nil }
        setCurrentDay(record)
        reloadRecentDays()
        return currentDay
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
        let records = currentDay.flatMap { try? store.scratchPad.entries(dayID: $0.id) } ?? []
        entries = records.map(ScratchPadEntryView.init)
        // Suggest #tags from every day, not just the one on screen (spec §3).
        knownTags = (try? store.scratchPad.distinctTags()) ?? []
        tagVocabulary = ScratchPadTagResolver.mergedTagVocabulary(used: knownTags)
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
