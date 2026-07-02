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

    /// The opinion as paragraphs, scrolled to (and highlighting) the first paragraph
    /// containing the cited passage.
    private func opinionText(_ text: String) -> some View {
        let paragraphs = Self.paragraphs(of: text)
        let highlightIndex = Self.highlightIndex(in: paragraphs, matching: model.highlight)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                        Text(paragraph)
                            .supraReadingBody(measure: nil)
                            .textSelection(.enabled)
                            .padding(.horizontal, 6)
                            .background(
                                index == highlightIndex
                                    ? Color.yellow.opacity(0.22)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 4)
                            )
                            .id(index)
                    }
                }
                .padding()
            }
            .onAppear {
                if let highlightIndex {
                    // Anchor the cited passage near the top so its context reads on.
                    DispatchQueue.main.async {
                        proxy.scrollTo(highlightIndex, anchor: UnitPoint(x: 0, y: 0.15))
                    }
                }
            }
        }
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

    private static func courtListenerURL(_ path: String) -> URL? {
        if path.lowercased().hasPrefix("http") { return URL(string: path) }
        guard path.hasPrefix("/") else { return nil }
        return URL(string: "https://www.courtlistener.com" + path)
    }
}
