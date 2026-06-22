import SupraSessions
import SwiftUI

/// The ScratchPad daily note (Milestone 4, Phase 2): a running list of
/// timestamped entries plus a composer with inline `@matter` / `#tag` autocomplete.
struct ScratchPadView: View {
    @ObservedObject var controller: ScratchPadController

    @State private var composerText = ""
    /// Handle -> matterID for mentions picked from autocomplete (precise binding).
    @State private var pendingMentions: [String: String] = [:]
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            entryList
            Divider()
            composer
        }
        .onAppear { if controller.currentDay == nil { controller.load() } }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ScratchPad")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(Self.displayDate(controller.currentDay?.day))
                    .font(.title3.weight(.semibold))
            }
            Spacer()
            if !controller.recentDays.isEmpty {
                Menu {
                    ForEach(controller.recentDays) { day in
                        Button(Self.displayDate(day.day)) { controller.selectDay(id: day.id) }
                    }
                } label: {
                    Label("History", systemImage: "calendar")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            lockButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
                                isLocked: controller.isCurrentDayLocked,
                                onDelete: { controller.deleteEntry(id: entry.id) }
                            )
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
                suggestionsBar
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Add a note — @matter, #tag…", text: $composerText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .focused($composerFocused)
                        .onSubmit(submit)
                    Button(action: submit) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        guard controller.addEntry(composerText, explicitMentions: pendingMentions) else { return }
        composerText = ""
        pendingMentions = [:]
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
    let isLocked: Bool
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(ScratchPadFormatting.time(entry.timestamp))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 56, alignment: .trailing)
                .padding(.top, 2)
            Text(ScratchPadFormatting.highlighted(entry.text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                attributed[range].foregroundColor = (first == "@") ? Color.accentColor : gold
                attributed[range].font = .body.weight(.medium)
            }
        }
        return attributed
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
}
