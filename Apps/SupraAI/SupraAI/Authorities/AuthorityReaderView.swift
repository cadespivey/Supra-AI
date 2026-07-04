import AppKit
import SupraResearch
import SupraSessions
import SwiftUI

/// The in-app `[A#]` opinion reader (spec §2.5, locked §8.4): case header + full
/// opinion text with the cited passage highlighted + "Open on CourtListener".
/// Text comes from the persisted copy on a saved authority, else a one-shot
/// hydration — both behind the injected `loadText`.
struct AuthorityReaderView: View {
    let model: GlobalChatController.AuthorityReaderModel
    let loadText: () async -> String?
    let onClose: () -> Void

    @State private var text: String?
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: model.id) {
            isLoading = true
            text = await loadText()
            isLoading = false
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.caseName)
                    .font(.supraTitle)
                    .lineLimit(2)
                Spacer()
                Button("Done", action: onClose)
                    .buttonStyle(.ghost)
                    .keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 6) {
                Text(headerLine)
                    .font(.supraSubheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if let url = model.url.flatMap(Self.courtListenerURL) {
                    Link(destination: url) {
                        Label("Open on CourtListener", systemImage: "arrow.up.right.square")
                    }
                    .font(.supraSubheadline)
                }
            }
        }
        .padding()
    }

    private var headerLine: String {
        [model.citationText, model.court, model.dateFiled]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading opinion…").font(.supraCaption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let text, !text.isEmpty {
            opinionText(text)
        } else {
            ContentUnavailableView(
                "Opinion text unavailable",
                systemImage: "text.book.closed",
                description: Text("The full text isn't stored offline and couldn't be fetched. Use “Open on CourtListener” above to read it there.")
            )
        }
    }

    /// The opinion rendered by the shared citation-copying reader, scrolled to
    /// the cited passage.
    private func opinionText(_ text: String) -> some View {
        OpinionParagraphsView(text: text, highlight: model.highlight, citation: readerCitation)
    }

    private var readerCitation: BluebookCitation {
        BluebookCitation(
            caseName: model.caseName,
            citation: model.citationText,
            court: model.court,
            year: BluebookCitation.year(fromDateFiled: model.dateFiled)
        )
    }

    static func paragraphs(of text: String) -> [String] {
        text.components(separatedBy: "\n\n")
            .flatMap { $0.count > 4000 ? $0.components(separatedBy: "\n") : [$0] }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The first paragraph containing the longest word-run of the cited snippet —
    /// exact matching fails on ellipses/highlight artifacts, so match on a
    /// mid-snippet phrase instead.
    static func highlightIndex(in paragraphs: [String], matching highlight: String?) -> Int? {
        guard let highlight, !highlight.isEmpty else { return nil }
        let words = highlight
            .replacingOccurrences(of: "…", with: " ")
            .split(separator: " ")
            .map(String.init)
        guard !words.isEmpty else { return nil }
        // Try a few phrase lengths, longest first, sliding from the snippet middle.
        for phraseLength in [8, 5, 3] where words.count >= phraseLength {
            let start = max(0, (words.count - phraseLength) / 2)
            let phrase = words[start..<min(words.count, start + phraseLength)].joined(separator: " ")
            if let index = paragraphs.firstIndex(where: { $0.localizedCaseInsensitiveContains(phrase) }) {
                return index
            }
        }
        return nil
    }

    static func courtListenerURL(_ path: String) -> URL? {
        if path.lowercased().hasPrefix("http") { return URL(string: path) }
        guard path.hasPrefix("/") else { return nil }
        return URL(string: "https://www.courtlistener.com" + path)
    }
}

/// The opinion body as selectable reading text. Copy (⌘C, or the context
/// menu) puts the SELECTION plus the full Bluebook citation — with a pin cite
/// derived from the opinion's star pagination — on the clipboard, so a quote
/// pulled here drops into a brief already cited. Shared by the chat's `[A#]`
/// reader and the Research/Authorities case readers.
struct OpinionParagraphsView: NSViewRepresentable {
    let text: String
    var highlight: String?
    var citation: BluebookCitation?

    func makeNSView(context: Context) -> NSScrollView {
        let textView = CitationCopyingTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 20, height: 16)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = textView
        apply(to: textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? CitationCopyingTextView else { return }
        apply(to: textView)
    }

    private func apply(to textView: CitationCopyingTextView) {
        textView.bluebook = citation
        guard textView.string != text else { return }
        textView.textStorage?.setAttributedString(Self.attributed(text))
        if let range = Self.highlightRange(in: text, matching: highlight) {
            textView.textStorage?.addAttribute(
                .backgroundColor,
                value: NSColor.systemYellow.withAlphaComponent(0.25),
                range: range
            )
            DispatchQueue.main.async {
                textView.scrollRangeToVisible(range)
            }
        } else {
            DispatchQueue.main.async {
                textView.scroll(.zero)
            }
        }
    }

    static func attributed(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 8
        return NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
        )
    }

    /// The paragraph containing the best phrase match for the cited snippet
    /// (same sliding-phrase approach as the paragraph-index variant).
    static func highlightRange(in text: String, matching highlight: String?) -> NSRange? {
        guard let highlight, !highlight.isEmpty else { return nil }
        let words = highlight
            .replacingOccurrences(of: "…", with: " ")
            .split(separator: " ")
            .map(String.init)
        guard !words.isEmpty else { return nil }
        for phraseLength in [8, 5, 3] where words.count >= phraseLength {
            let start = max(0, (words.count - phraseLength) / 2)
            let phrase = words[start..<min(words.count, start + phraseLength)].joined(separator: " ")
            if let found = text.range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive]) {
                return (text as NSString).paragraphRange(for: NSRange(found, in: text))
            }
        }
        return nil
    }
}

/// NSTextView whose copy appends the Bluebook cite (+ star-pagination pin) to
/// the selection. Plain copy semantics are preserved when no citation context
/// exists or nothing is selected.
final class CitationCopyingTextView: NSTextView {
    var bluebook: BluebookCitation?

    override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard let bluebook, range.length > 0 else { return super.copy(sender) }
        let selected = (string as NSString).substring(with: range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty else { return super.copy(sender) }
        let pin = StarPagination.pages(
            forSelectionAt: range.location,
            length: range.length,
            in: string,
            firstPage: bluebook.firstPage
        )
        let payload = selected + "\n\n" + bluebook.formatted(pinPages: pin)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
    }
}

/// A full-height case reader for the Research and Authorities slideovers:
/// case header, caller-supplied action row (review/status/download controls),
/// and the opinion in the richest available format — official HTML, downloaded
/// PDF, or plain text — switchable when more than one is on hand.
struct CaseReaderPanel<Actions: View>: View {
    enum Format: String, CaseIterable, Identifiable {
        case html = "HTML"
        case pdf = "PDF"
        case text = "Text"
        var id: String { rawValue }
    }

    let title: String
    let subtitle: String
    let courtListenerURL: URL?
    var html: String?
    var pdfURL: URL?
    var text: String?
    var highlight: String?
    var bluebook: BluebookCitation?
    var isLoading = false
    let onClose: () -> Void
    @ViewBuilder let actions: () -> Actions

    @State private var selectedFormat: Format?

    private var availableFormats: [Format] {
        var formats: [Format] = []
        if html?.isEmpty == false { formats.append(.html) }
        if pdfURL != nil { formats.append(.pdf) }
        if text?.isEmpty == false { formats.append(.text) }
        return formats
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.supraTitle)
                    .lineLimit(2)
                Spacer()
                Button("Done", action: onClose)
                    .buttonStyle(.ghost)
                    .keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 6) {
                Text(subtitle)
                    .font(.supraSubheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if let courtListenerURL {
                    Link(destination: courtListenerURL) {
                        Label("Open on CourtListener", systemImage: "arrow.up.right.square")
                    }
                    .font(.supraSubheadline)
                }
            }
            HStack(spacing: 10) {
                actions()
                Spacer()
                if availableFormats.count > 1 {
                    Picker("Format", selection: formatSelection) {
                        ForEach(availableFormats) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
        .padding()
    }

    private var formatSelection: Binding<Format> {
        Binding(
            get: { selectedFormat ?? availableFormats.first ?? .text },
            set: { selectedFormat = $0 }
        )
    }

    @ViewBuilder
    private var content: some View {
        let format = selectedFormat.flatMap { availableFormats.contains($0) ? $0 : nil }
            ?? availableFormats.first
        switch format {
        case .html:
            if let html { OpinionWebView(html: html) }
        case .pdf:
            if let pdfURL { OpinionPDFView(url: pdfURL) }
        case .text:
            if let text { OpinionParagraphsView(text: text, highlight: highlight, citation: bluebook) }
        case nil:
            if isLoading {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading opinion…").font(.supraCaption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Opinion not available",
                    systemImage: "text.book.closed",
                    description: Text("The opinion isn't stored offline and couldn't be fetched. Use “Open on CourtListener” above to read it there.")
                )
            }
        }
    }
}
