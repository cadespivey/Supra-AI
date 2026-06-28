import SupraCore
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
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack {
                Spacer()
                Picker("View", selection: $tab) {
                    Text("Note").tag(Tab.note)
                    Text("Billing draft").tag(Tab.draft)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            .padding(.vertical, 8)
            Divider()
            switch tab {
            case .note:
                noteContent
            case .draft:
                BillingDraftView(
                    billing: billing,
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
        entryList
            .dropDestination(for: URL.self) { urls, _ in
                // A file dropped on the timeline (not on a specific note) creates a
                // minimal note carrying it, so it's never orphaned in a day-level tray.
                guard !controller.isCurrentDayLocked, !urls.isEmpty else { return false }
                Task { await controller.addEntry("", attachmentURLs: urls) }
                return true
            }
        attachmentBar
        errorBanner
        Divider()
        composer
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ScratchPad")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(Self.displayDate(controller.displayedDate))
                    .font(.title3.weight(.semibold))
            }
            Spacer()
            historyButton
            lockButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// History navigation: a calendar to jump to any day, defaulting to the day on
    /// screen (which starts at today). Future dates are disabled — you can't bill
    /// ahead of today.
    private var historyButton: some View {
        Button { showHistory.toggle() } label: {
            Label("History", systemImage: "calendar")
        }
        .help("Jump to another day")
        .popover(isPresented: $showHistory, arrowEdge: .bottom) {
            DatePicker(
                "Day",
                selection: calendarSelection,
                in: ...Date(),
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            .padding()
            .frame(width: 320)
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
            }
            .help("This day is locked. Reopen to edit.")
        } else if controller.currentDay != nil {
            Button {
                controller.lockCurrentDay()
            } label: {
                Label("Lock day", systemImage: "lock.open")
            }
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
                    .font(.caption)
                    .lineLimit(1)
                Text(subtitle(for: attachment))
                    .font(.caption2)
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
                    .font(.caption)
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
                suggestionsBar
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
                            // Plain Return adds the note; Shift-Return (and ⌘-Return) fall
                            // through so the field inserts a newline / the button shortcut
                            // fires. Replaces .onSubmit so Return cannot fire twice.
                            .onKeyPress(keys: [.return]) { keyPress in
                                guard keyPress.modifiers.isEmpty else { return .ignored }
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
                            Text(url.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
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
                .font(.caption)
            Spacer(minLength: 8)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var suggestionsBar: some View {
        let matters = matterSuggestions
        let tags = tagSuggestions
        if !matters.isEmpty || !tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(matters) { chip in
                        Button { pickMatter(chip) } label: {
                            Label(chip.name, systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    ForEach(tags, id: \.self) { tag in
                        Button { pickTag(tag) } label: {
                            Text("#\(tag)")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 4)
        }
    }

    // MARK: - Autocomplete logic

    /// The trailing whitespace-delimited token currently being typed, if it is an
    /// `@`/`#` token with at least one character after the sigil.
    private var activeToken: String? {
        guard let last = composerText.split(whereSeparator: { $0.isWhitespace }).last else { return nil }
        let token = String(last)
        guard token.count > 1, let first = token.first, first == "@" || first == "#" else { return nil }
        return token
    }

    private var matterSuggestions: [MatterChip] {
        guard let token = activeToken, token.hasPrefix("@") else { return [] }
        return ScratchPadTagResolver.matterSuggestions(prefix: String(token.dropFirst()), chips: controller.matterChips)
    }

    private var tagSuggestions: [String] {
        guard let token = activeToken, token.hasPrefix("#") else { return [] }
        return ScratchPadTagResolver.tagSuggestions(prefix: String(token.dropFirst()), knownTags: controller.knownTags)
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
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if entry.isNonBillable {
                    Label("Non-billable", systemImage: "nosign")
                        .font(.caption2.weight(.medium))
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
            Text(attachment.fileName).font(.caption).lineLimit(1).truncationMode(.middle)
            Text(attachment.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
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
