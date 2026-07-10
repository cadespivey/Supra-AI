import SupraCore
import SupraDesignSystem
import SupraSessions
import SupraStore
import SwiftUI
import UniformTypeIdentifiers

/// The ScratchPad daily note (Milestone 4, Phase 2): a running list of
/// timestamped entries plus a composer with inline `@matter` / `#tag` autocomplete.
struct ScratchPadView: View {
    @ObservedObject var controller: ScratchPadController
    @ObservedObject var billing: BillingDraftController
    @ObservedObject var billingSettings: BillingSettingsController
    @ObservedObject var library: ModelLibrary

    enum Tab: Hashable { case note, draft }
    @State private var tab: Tab = .note
    @State private var composerText = ""
    /// Handle -> matterID for mentions picked from autocomplete (precise binding).
    @State private var pendingMentions: [String: String] = [:]
    /// Files attached in the composer, saved together with the note on submit so a
    /// document lives inline with its describing note.
    @State private var stagedFiles: [URL] = []
    @State private var showingImporter = false
    @State private var showHistory = false
    /// Highlighted row in the @/# autocomplete dropdown (keyboard navigation).
    @State private var selectedSuggestion = 0
    /// The token the user dismissed with Esc; the menu stays closed until the token
    /// changes (so typing more re-opens it).
    @State private var dismissedToken: String?
    /// Cross-day note search term, shown below the day controls in the header.
    @State private var searchTerm = ""
    /// True while a drag hovers the note surface (drives the drop hint).
    @State private var fileDropTargeted = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch tab {
            case .note:
                noteContent
            case .draft:
                BillingDraftView(
                    billing: billing,
                    library: library,
                    dayID: controller.currentDay?.id,
                    isLocked: controller.isCurrentDayLocked
                )
            }
        }
        .onAppear {
            if controller.currentDay == nil { controller.load() }
            billing.applySettings(billingSettings.settings)
        }
        .onChange(of: billingSettings.settings) { _, settings in
            billing.applySettings(settings)
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: Self.allowedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            guard case let .success(urls) = result else { return }
            stagedFiles.append(contentsOf: urls)
        }
    }

    @ViewBuilder
    private var noteContent: some View {
        if isSearching {
            searchResultsList
        } else {
            VStack(spacing: 0) {
                entryList
                attachmentBar
                errorBanner
                Divider()
                composer
            }
            // The whole Note tab takes file drops (not just the entry list), so an
            // empty day accepts a drop anywhere. A file dropped on the day (not on
            // a specific note) creates a minimal note carrying it, so it's never
            // orphaned in a day-level tray; dropping on a note still attaches to
            // that note (the row's own target wins).
            .dropDestination(for: URL.self) { urls, _ in
                guard !controller.isCurrentDayLocked, !urls.isEmpty else { return false }
                Task { await controller.addEntry("", attachmentURLs: urls) }
                return true
            }
            // Emails and other promised-file drags (Mail/Outlook messages, browser
            // images) never reach SwiftUI's URL target — the promise layer receives
            // them into the same evidence path. Plain file drags stay with the
            // .dropDestination targets above.
            .supraFileDrop(
                isEnabled: !controller.isCurrentDayLocked,
                acceptsFileURLs: false,
                isTargeted: $fileDropTargeted
            ) { urls in
                Task { await controller.addEntry("", attachmentURLs: urls) }
            }
            .overlay(alignment: .top) {
                if fileDropTargeted {
                    SupraDropHint("Drop to add as evidence for this day")
                }
            }
        }
    }

    private var isSearching: Bool {
        searchTerm.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    private var scratchSearchField: some View {
        TextField("Search notes", text: $searchTerm).supraField()
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .onChange(of: searchTerm) { _, term in controller.search(term) }
            .accessibilityIdentifier("scratchpad.search")
    }

    /// Cross-day note search results; tapping a hit opens that day.
    private var searchResultsList: some View {
        ScrollView {
            if controller.searchResults.isEmpty {
                ContentUnavailableView.search(text: searchTerm)
                    .padding(.top, 60)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(controller.searchResults, id: \.entryID) { hit in
                        Button {
                            controller.openDay(dayString: hit.day)
                            searchTerm = ""
                        } label: {
                            searchHitRow(hit)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    @ViewBuilder
    private func searchHitRow(_ hit: ScratchPadRepository.EntryHit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Self.displayDate(hit.day)).font(.supraCaption).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            Text(hit.text).font(.supraBody).lineLimit(3)
            if !hit.tags.isEmpty {
                Text(hit.tags.map { "#\($0)" }.joined(separator: " "))
                    .font(.supraCaption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            // The screen title, sized like every other module header.
            Text("ScratchPad")
                .font(.supraTitle)
            Spacer(minLength: 12)
            weekStrip
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                GhostSegmentedControl(
                    selection: $tab,
                    segments: [(.note, "Note", ""), (.draft, "Billing draft", "")]
                )
                HStack(spacing: 8) {
                    historyButton
                    lockButton
                    scratchSearchField
                        .frame(width: 180)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// The week-strip date navigation: the month heading over seven ghost day
    /// buttons flanked by week chevrons. The grey number under a date is that
    /// day's billable-hour total from its LATEST billing draft; it appears only
    /// once a draft has been run for the day.
    @ViewBuilder
    private var weekStrip: some View {
        if let week = controller.visibleWeek {
            VStack(spacing: 2) {
                Text(week.monthLabel)
                    .font(.supraTitle)
                    .accessibilityIdentifier("scratchpad.week.month")
                HStack(spacing: 2) {
                    Button { controller.stepWeek(-1) } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.ghost)
                    .help("Previous week")
                    .accessibilityLabel("Previous week")
                    .accessibilityIdentifier("scratchpad.week.back")
                    ForEach(week.days) { day in
                        WeekDayButton(
                            day: day,
                            isSelected: day.id == controller.displayedDate,
                            hoursLabel: controller.weekBilledHours[day.id].map(ScratchPadWeek.hoursLabel),
                            fullDate: Self.displayDate(day.id)
                        ) {
                            controller.selectDate(day.date)
                        }
                    }
                    Button { controller.stepWeek(1) } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.ghost)
                    .disabled(week.containsToday)
                    .help("Next week")
                    .accessibilityLabel("Next week")
                    .accessibilityIdentifier("scratchpad.week.forward")
                }
            }
        }
    }

    /// History navigation: a calendar to jump to any day, defaulting to the day on
    /// screen (which starts at today). Future dates are disabled — you can't bill
    /// ahead of today.
    private var historyButton: some View {
        Button { showHistory.toggle() } label: {
            Label("History", systemImage: "calendar")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.ghost)
        .help("Jump to another day")
        .popover(isPresented: $showHistory, arrowEdge: .bottom) {
            SupraPopoverFrame("History") {
                DatePicker(
                    "Day",
                    selection: calendarSelection,
                    in: ...Date(),
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
            }
        }
    }

    /// Binds the calendar to the displayed day. Picking a date jumps to it and
    /// closes the popover; reading falls back to today when nothing is open yet.
    private var calendarSelection: Binding<Date> {
        Binding(
            get: { Self.isoParser.date(from: controller.displayedDate) ?? Date() },
            set: { newDate in
                controller.selectDate(newDate)
                showHistory = false
            }
        )
    }

    @ViewBuilder
    private var lockButton: some View {
        if controller.isCurrentDayLocked {
            Button {
                controller.reopenCurrentDay()
            } label: {
                Label("Locked", systemImage: "lock.fill")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.ghost)
            .help("This day is locked. Reopen to edit.")
        } else if controller.currentDay != nil {
            Button {
                controller.lockCurrentDay()
            } label: {
                Label("Lock day", systemImage: "lock.open")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.ghost)
            .help("Finalize and lock this day (reversible).")
        }
    }

    // MARK: - Entries

    private var entryList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if controller.entries.isEmpty {
                    ContentUnavailableView(
                        "No notes yet",
                        systemImage: "note.text",
                        description: Text("Jot what you're working on. Use @ to tag a matter and # to tag an issue.")
                    )
                    .padding(.top, 60)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(controller.entries) { entry in
                            ScratchPadEntryRow(
                                entry: entry,
                                attachments: controller.attachments(forEntry: entry.id),
                                isLocked: controller.isCurrentDayLocked,
                                showTimestamp: billingSettings.autoTimestamp,
                                onDelete: { controller.deleteEntry(id: entry.id) },
                                onRemoveAttachment: { controller.removeAttachment(id: $0) }
                            )
                            .dropDestination(for: URL.self) { urls, _ in
                                // Dropping on a note attaches the file to that note.
                                guard !controller.isCurrentDayLocked, !urls.isEmpty else { return false }
                                for url in urls {
                                    Task { await controller.addAttachment(fileURL: url, entryID: entry.id) }
                                }
                                return true
                            }
                            .id(entry.id)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .onChange(of: controller.entries.count) {
                if let last = controller.entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    // MARK: - Attachments

    /// Legacy day-level attachments (older days, before files were tied to notes).
    /// New uploads render inline under their note instead.
    @ViewBuilder
    private var attachmentBar: some View {
        if !controller.unfiledAttachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(controller.unfiledAttachments) { attachment in
                        attachmentChip(attachment)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }

    private func attachmentChip(_ attachment: ScratchPadAttachmentView) -> some View {
        HStack(spacing: 8) {
            Image(systemName: Self.icon(for: attachment.kind))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.fileName)
                    .font(.supraCaption)
                    .lineLimit(1)
                Text(subtitle(for: attachment))
                    .font(.supraCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !controller.isCurrentDayLocked {
                Button { controller.removeAttachment(id: attachment.id) } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Remove attachment")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.12)))
        .frame(maxWidth: 300)
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let error = controller.lastAttachmentError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(error)
                    .font(.supraCaption)
                Spacer(minLength: 8)
                Button { controller.lastAttachmentError = nil } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func subtitle(for attachment: ScratchPadAttachmentView) -> String {
        if let name = matterName(attachment.matterID) {
            return "\(attachment.summary) · \(name)"
        }
        return attachment.summary
    }

    private func matterName(_ matterID: String?) -> String? {
        guard let matterID else { return nil }
        return controller.matterChips.first { $0.id == matterID }?.name
    }

    private static func icon(for kind: BillingEvidenceKind) -> String {
        switch kind {
        case .email: "envelope"
        case .workProduct: "doc.text"
        case .filing: "building.columns"
        case .other: "paperclip"
        }
    }

    private static let allowedContentTypes: [UTType] = [
        "pdf", "txt", "md", "markdown", "rtf", "html", "htm", "xml", "doc", "docx", "dotx", "xls", "xlsx", "eml"
    ].compactMap { UTType(filenameExtension: $0) }

    // MARK: - Composer

    @ViewBuilder
    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            if controller.isCurrentDayLocked {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                    Text("This day is locked. Reopen it to add notes.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(16)
            } else {
                if composerIsNonBillable { nonBillableComposerBanner }
                // The @/# type-ahead list is laid out directly above the input box (rather
                // than as an overlay pushed outside the box's bounds — such content renders
                // but can't receive mouse clicks, which is why the popup wasn't selectable).
                // In-flow, its rows are clickable and the field's key handlers drive it, so a
                // matter is one click, or one Return/Tab, away.
                VStack(alignment: .leading, spacing: 6) {
                    if suggestionMenuOpen {
                        suggestionDropdown
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        stagedFilesBar
                        HStack(alignment: .bottom, spacing: 8) {
                            Button { showingImporter = true } label: {
                                Image(systemName: "paperclip")
                                    .font(.body)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Attach a file to this note (work product, email, filing)")
                            TextField("Add a note — @matter, #tag…", text: $composerText, axis: .vertical)
                                .textFieldStyle(.plain)
                                .lineLimit(1...5)
                                .focused($composerFocused)
                                .onChange(of: composerText) { _, _ in selectedSuggestion = 0 }
                                // When the @/# list is open, the arrow keys move the highlight
                                // and Return/Tab accept it; otherwise plain Return adds the note
                                // (Shift-Return / ⌘-Return fall through to a newline or the send
                                // shortcut). Replaces .onSubmit so Return can't fire twice.
                                .onKeyPress(.downArrow) { suggestionMenuOpen ? moveSelection(1) : .ignored }
                                .onKeyPress(.upArrow) { suggestionMenuOpen ? moveSelection(-1) : .ignored }
                                .onKeyPress(.escape) {
                                    guard suggestionMenuOpen else { return .ignored }
                                    dismissedToken = activeToken
                                    return .handled
                                }
                                .onKeyPress(.tab) {
                                    guard suggestionMenuOpen, let item = highlightedSuggestion else { return .ignored }
                                    accept(item)
                                    return .handled
                                }
                                .onKeyPress(keys: [.return]) { keyPress in
                                    guard keyPress.modifiers.isEmpty else { return .ignored }
                                    if suggestionMenuOpen, let item = highlightedSuggestion {
                                        accept(item)
                                        return .handled
                                    }
                                    submit()
                                    return .handled
                                }
                            Button(action: submit) {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.title2)
                            }
                            .buttonStyle(.plain)
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && stagedFiles.isEmpty)
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.secondary.opacity(0.25))
                    )
                }
                .padding(16)
            }
        }
    }

    /// True when the in-progress note carries the reserved `#Note` tag — drives a
    /// near-composer alert that it will be left out of billing.
    private var composerIsNonBillable: Bool {
        ScratchPadTokenParser.parse(composerText).tags
            .contains { $0.caseInsensitiveCompare(ScratchPadEntryRecord.nonBillableTag) == .orderedSame }
    }

    /// Chips for files staged in the composer, saved with the note on submit.
    @ViewBuilder
    private var stagedFilesBar: some View {
        if !stagedFiles.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(stagedFiles, id: \.self) { url in
                        HStack(spacing: 6) {
                            Image(systemName: "paperclip").font(.caption2).foregroundStyle(.secondary)
                            Text(url.lastPathComponent).font(.supraCaption).lineLimit(1).truncationMode(.middle)
                            Button { stagedFiles.removeAll { $0 == url } } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain).foregroundStyle(.tertiary)
                            .accessibilityLabel("Remove staged file")
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.secondary.opacity(0.12)))
                    }
                }
            }
        }
    }

    private var nonBillableComposerBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "nosign")
            Text("Tagged #Note — this won't be counted toward billing or time. Remove #Note to include it.")
                .font(.supraCaption)
            Spacer(minLength: 8)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    // MARK: - @/# autocomplete

    /// A row in the autocomplete dropdown.
    private enum SuggestionItem: Identifiable, Equatable {
        case matter(MatterChip)
        case tag(String)
        case createTag(String)

        var id: String {
            switch self {
            case let .matter(chip): return "m:\(chip.id)"
            case let .tag(tag): return "t:\(tag.lowercased())"
            case let .createTag(tag): return "new:\(tag.lowercased())"
            }
        }
    }

    /// The trailing whitespace-delimited token being typed, if it starts with `@`/`#`.
    /// The bare sigil counts, so `@` alone opens the full matter list.
    private var activeToken: String? {
        guard let last = composerText.split(whereSeparator: { $0.isWhitespace }).last else { return nil }
        let token = String(last)
        guard let first = token.first, first == "@" || first == "#" else { return nil }
        return token
    }

    private var matterSuggestions: [MatterChip] {
        guard let token = activeToken, token.hasPrefix("@") else { return [] }
        return ScratchPadTagResolver.matterSuggestions(prefix: String(token.dropFirst()), chips: controller.matterChips)
    }

    private var tagSuggestions: [String] {
        guard let token = activeToken, token.hasPrefix("#") else { return [] }
        return ScratchPadTagResolver.tagSuggestions(prefix: String(token.dropFirst()), knownTags: controller.tagVocabulary)
    }

    /// The dropdown rows for the active token: matters for `@`; tags for `#`, plus a
    /// "Create #tag" row when the typed tag isn't already in the vocabulary.
    private var suggestionItems: [SuggestionItem] {
        guard let token = activeToken, token != dismissedToken else { return [] }
        if token.hasPrefix("@") {
            return matterSuggestions.map(SuggestionItem.matter)
        }
        var items = tagSuggestions.map(SuggestionItem.tag)
        let typed = String(token.dropFirst()).trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty,
           !tagSuggestions.contains(where: { $0.caseInsensitiveCompare(typed) == .orderedSame }) {
            items.append(.createTag(typed))
        }
        return items
    }

    private var suggestionMenuOpen: Bool { !suggestionItems.isEmpty }

    private var highlightedSuggestion: SuggestionItem? {
        let items = suggestionItems
        guard items.indices.contains(selectedSuggestion) else { return items.first }
        return items[selectedSuggestion]
    }

    private func moveSelection(_ delta: Int) -> KeyPress.Result {
        let count = suggestionItems.count
        guard count > 0 else { return .ignored }
        selectedSuggestion = (selectedSuggestion + delta + count) % count
        return .handled
    }

    private func accept(_ item: SuggestionItem) {
        switch item {
        case let .matter(chip): pickMatter(chip)
        case let .tag(tag): pickTag(tag)
        case let .createTag(tag): pickTag(tag)
        }
        selectedSuggestion = 0
        dismissedToken = nil
    }

    @ViewBuilder
    private var suggestionDropdown: some View {
        let items = suggestionItems
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                suggestionRow(item, selected: index == selectedSuggestion)
                    .contentShape(Rectangle())
                    .onTapGesture { accept(item) }
                    .onHover { if $0 { selectedSuggestion = index } }
            }
            Divider().opacity(0.4).padding(.vertical, 3)
            Text("↑↓ navigate · ↩ or ⇥ select · click to pick")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
        }
        .padding(4)
        .frame(minWidth: 220, maxWidth: 340, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.25))
        )
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }

    @ViewBuilder
    private func suggestionRow(_ item: SuggestionItem, selected: Bool) -> some View {
        HStack(spacing: 8) {
            switch item {
            case let .matter(chip):
                Image(systemName: "folder").foregroundStyle(.secondary).frame(width: 16)
                Text(chip.name).lineLimit(1)
            case let .tag(tag):
                Image(systemName: "number").foregroundStyle(.secondary).frame(width: 16)
                Text(tag).lineLimit(1)
                if tag.caseInsensitiveCompare(ScratchPadEntryRecord.nonBillableTag) == .orderedSame {
                    Text("non-billable").font(.caption2).foregroundStyle(.tertiary)
                }
            case let .createTag(tag):
                Image(systemName: "plus.circle").foregroundStyle(.secondary).frame(width: 16)
                Text("Create #\(tag)").lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
    }

    private func pickMatter(_ chip: MatterChip) {
        let handle = Self.mentionHandle(for: chip.name)
        pendingMentions[handle] = chip.id
        replaceActiveToken(with: "@\(handle)")
    }

    private func pickTag(_ tag: String) {
        replaceActiveToken(with: "#\(tag)")
    }

    private func replaceActiveToken(with replacement: String) {
        guard let token = activeToken,
              let range = composerText.range(of: token, options: .backwards) else { return }
        composerText.replaceSubrange(range, with: replacement + " ")
        composerFocused = true
    }

    private func submit() {
        let text = composerText
        let files = stagedFiles
        let mentions = pendingMentions
        guard !files.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            if await controller.addEntry(text, explicitMentions: mentions, attachmentURLs: files) {
                composerText = ""
                pendingMentions = [:]
                stagedFiles = []
            }
        }
    }

    // MARK: - Formatting

    /// A space-free, punctuation-light handle for an `@`-mention token.
    private static func mentionHandle(for name: String) -> String {
        let scalars = name.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func displayDate(_ isoDay: String?) -> String {
        guard let isoDay, let date = isoParser.date(from: isoDay) else { return "Today" }
        return displayFormatter.string(from: date)
    }

    private static let isoParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        return formatter
    }()

}

/// One selectable day in the header's week strip — the ghost-button visual family
/// (hover wash; the soft fill of `GhostSegmentedControl`'s selected segment) with
/// the day's billable hours in grey beneath the date once a billing draft has been
/// run for it. Future days can't be billed and render disabled.
private struct WeekDayButton: View {
    let day: ScratchPadWeek.Day
    let isSelected: Bool
    let hoursLabel: String?
    let fullDate: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(day.weekdayLabel)
                    .font(.supraCaption.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                Text(day.dayNumber)
                    .font(.supraBody.weight(day.isToday ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(day.isToday ? Color.accentColor : Color.primary)
                // The indicator row is always laid out (invisible when no draft has
                // been run) so day numbers align across the strip.
                Text(hoursLabel ?? "0.0")
                    .font(.supraCaption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .opacity(hoursLabel == nil ? 0 : 1)
            }
            .frame(width: 42)
            .padding(.vertical, 4)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(day.isFuture)
        .opacity(day.isFuture ? 0.35 : 1)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.08) : (hovering ? Color.primary.opacity(0.10) : .clear))
        )
        .onHover { hovering = !day.isFuture && $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(day.isFuture ? "Future day — notes can't be billed ahead" : fullDate)
        .accessibilityLabel(hoursLabel.map { "\(fullDate), \($0) hours drafted" } ?? fullDate)
        .accessibilityIdentifier("scratchpad.week.day.\(day.id)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One entry row with a hover-revealed delete button. The delete affordance lives
/// outside the selectable text so it isn't shadowed by the system text menu.
private struct ScratchPadEntryRow: View {
    let entry: ScratchPadEntryView
    var attachments: [ScratchPadAttachmentView] = []
    let isLocked: Bool
    var showTimestamp: Bool = true
    let onDelete: () -> Void
    var onRemoveAttachment: (String) -> Void = { _ in }
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // The time gutter is hidden when auto-timestamp is off (the stamps are
            // still recorded, just not surfaced or used as duration evidence).
            if showTimestamp {
                Text(ScratchPadFormatting.time(entry.timestamp))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 56, alignment: .trailing)
                    .padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(ScratchPadFormatting.highlighted(entry.text))
                    .supraReadingBody(measure: nil)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if entry.isNonBillable {
                    Label("Non-billable", systemImage: "nosign")
                        .font(.supraCaption.weight(.medium))
                        .foregroundStyle(.orange)
                }
                // Documents uploaded with this note render inline beneath it.
                ForEach(attachments) { attachment in
                    inlineAttachment(attachment)
                }
            }
            if !isLocked {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .opacity(hovering ? 1 : 0)
                .help("Delete entry")
                .accessibilityLabel("Delete entry")
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func inlineAttachment(_ attachment: ScratchPadAttachmentView) -> some View {
        HStack(spacing: 6) {
            Image(systemName: scratchPadAttachmentIcon(attachment.kind))
                .font(.caption2).foregroundStyle(.secondary)
            Text(attachment.fileName).font(.supraCaption).lineLimit(1).truncationMode(.middle)
            Text(attachment.summary).font(.supraCaption).foregroundStyle(.secondary).lineLimit(1)
            if !isLocked {
                Button { onRemoveAttachment(attachment.id) } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Remove attachment")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.secondary.opacity(0.12)))
    }
}

/// Shared SF Symbol for a ScratchPad attachment's evidence kind.
private func scratchPadAttachmentIcon(_ kind: BillingEvidenceKind) -> String {
    switch kind {
    case .email: "envelope"
    case .workProduct: "doc.text"
    case .filing: "building.columns"
    case .other: "paperclip"
    }
}

/// Shared formatting for ScratchPad entry rows.
private enum ScratchPadFormatting {
    static let gold = Color(red: 0.79, green: 0.64, blue: 0.29)

    static func time(_ date: Date) -> String { timeFormatter.string(from: date) }

    static func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            guard let first = token.first, first == "@" || first == "#" else { continue }
            if let range = attributed.range(of: String(token)) {
                // #Note (the non-billable marker) is tinted distinctly from ordinary
                // #tags so an excluded note reads at a glance.
                let isNoteTag = first == "#" && tagBody(token).caseInsensitiveCompare("note") == .orderedSame
                attributed[range].foregroundColor = (first == "@") ? Color.accentColor : (isNoteTag ? .orange : gold)
                attributed[range].font = .body.weight(.medium)
            }
        }
        return attributed
    }

    /// The tag body with the `#` sigil and any trailing punctuation removed.
    private static func tagBody(_ token: Substring) -> String {
        var body = String(token.dropFirst())
        while let last = body.last, !(last.isLetter || last.isNumber) { body.removeLast() }
        return body
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
}
