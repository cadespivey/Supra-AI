import AppKit
import PDFKit
import SupraCore
import SupraResearch
import SupraSessions
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Authority detail: metadata, editable preferred citation + notes, and a
/// use-status changer limited to the permitted transitions (spec §11.3–§11.4).
struct AuthorityDetailView: View {
    @ObservedObject var controller: AuthoritiesController
    let authorityID: String
    /// Loads the summarization model on demand (nil disables Generate Summary).
    var library: ModelLibrary?

    @Environment(\.dismiss) private var dismiss
    @State private var citation = ""
    @State private var notes = ""
    @State private var confirmingDelete = false
    @State private var opinion: CourtListenerOpinionDetailDTO?
    @State private var loadingOpinion = false
    @State private var storedText: String?
    @State private var showReader = false
    @State private var readerWidth: CGFloat = 760

    /// The panel must never outgrow the pane it slides over (narrow windows).
    private func clampedReaderWidth(container: CGFloat) -> Binding<CGFloat> {
        Binding(
            get: { min(readerWidth, max(420, container - 24)) },
            set: { readerWidth = $0 }
        )
    }
    @State private var htmlExporting = false
    @State private var pdfURL: URL?
    @State private var downloadingPDF = false
    @State private var pdfExporting = false
    @State private var summaryError: String?

    var body: some View {
        Group {
            if let authority = controller.authorities.first(where: { $0.id == authorityID }) {
                form(authority)
                    // The opinion opens as a wide, resizable READER sliding over
                    // the detail form (the chat's [A#] inspector pattern) — not a
                    // modal web sheet or a PDF squeezed into a form row.
                    .overlay(alignment: .trailing) {
                        if showReader {
                            GeometryReader { geo in
                                SlideOverPanel(
                                    width: clampedReaderWidth(container: geo.size.width),
                                    minWidth: 420,
                                    onClose: { showReader = false }
                                ) {
                                    reader(authority)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                            }
                        }
                    }
                    .animation(.snappy(duration: 0.25), value: showReader)
                    .closesOnEscape(when: showReader) { showReader = false }
            } else {
                ContentUnavailableView("Authority not found", systemImage: "questionmark.circle")
            }
        }
        .navigationTitle("Authority")
    }

    private func reader(_ authority: AuthoritiesController.AuthorityItem) -> some View {
        CaseReaderPanel(
            title: authority.caseNameFull ?? authority.caseName,
            subtitle: readerSubtitle(authority),
            courtListenerURL: authority.absoluteURL.flatMap(AuthorityReaderView.courtListenerURL),
            html: opinion?.bestHTML,
            pdfURL: pdfURL,
            text: storedText ?? opinion?.bodyText,
            bluebook: BluebookCitation(
                caseName: authority.caseNameFull ?? authority.caseName,
                citation: authority.preferredCitation ?? authority.citations.first,
                court: authority.court,
                year: authority.dateFiled.map { Calendar.current.component(.year, from: $0) }
            ),
            isLoading: loadingOpinion || downloadingPDF,
            onClose: { showReader = false }
        ) {
            if opinion?.bestHTML != nil {
                Button { htmlExporting = true } label: {
                    Label("Download HTML…", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.ghost)
            }
            if pdfURL != nil {
                Button { pdfExporting = true } label: {
                    Label("Save PDF…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.ghost)
            } else if !downloadingPDF, opinion?.courtListenerPDFURL != nil {
                Button { downloadPDF() } label: {
                    Label("Download PDF", systemImage: "arrow.down.doc")
                }
                .buttonStyle(.ghost)
            }
        }
        .fileExporter(
            isPresented: $htmlExporting,
            document: (opinion?.bestHTML).map { HTMLFileDocument(text: OpinionWebView.document(for: $0)) },
            contentType: .html,
            defaultFilename: Self.fileName(for: authority.caseName)
        ) { _ in }
    }

    private func readerSubtitle(_ authority: AuthoritiesController.AuthorityItem) -> String {
        var parts: [String] = []
        if let citation = authority.preferredCitation ?? authority.citations.first { parts.append(citation) }
        if let court = authority.court { parts.append(court) }
        if let date = authority.dateFiled { parts.append(date.formatted(date: .abbreviated, time: .omitted)) }
        if let docket = authority.docketNumber { parts.append("No. " + docket) }
        return parts.joined(separator: " · ")
    }

    private func form(_ authority: AuthoritiesController.AuthorityItem) -> some View {
        Form {
            Section {
                Text(authority.caseNameFull ?? authority.caseName).font(.supraTitle)
                if let court = authority.court { LabeledContent("Court", value: court) }
                if let date = authority.dateFiled {
                    LabeledContent("Date filed") { Text(date, format: .dateTime.year().month().day()) }
                }
                if let docket = authority.docketNumber { LabeledContent("Docket", value: docket) }
                if let path = authority.absoluteURL, let url = URL(string: "https://www.courtlistener.com" + path) {
                    Link("View on CourtListener", destination: url)
                }
                if loadingOpinion {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Loading opinion…").foregroundStyle(.secondary) }
                } else if hasReadableOpinion(authority) {
                    Button { showReader = true } label: { Label("Read Opinion", systemImage: "book") }
                        .help("Opens the full opinion in a wide reader — HTML, PDF, or stored text.")
                }
            }

            Section("Summary") {
                if controller.summarizingAuthorityIDs.contains(authority.id) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Summarizing…").foregroundStyle(.secondary)
                    }
                } else if let summary = authority.caseSummary {
                    Text(summary).supraReadingBody().textSelection(.enabled)
                    Button("Regenerate Summary") { generateSummary(authority) }
                        .disabled(library == nil)
                } else {
                    Text("A 100-word summary of the holding and key reasoning, generated locally from the opinion text.")
                        .font(.supraCaption)
                        .foregroundStyle(.secondary)
                    Button { generateSummary(authority) } label: {
                        Label("Generate Summary", systemImage: "text.badge.star")
                    }
                    .disabled(library == nil)
                }
                if let summaryError {
                    Text(summaryError).font(.supraCaption).foregroundStyle(.orange)
                }
            }

            Section("Citations") {
                ForEach(authority.citations, id: \.self) { Text($0).font(.supraBody) }
                BoxedLeadingTextField(placeholder: "Preferred citation", text: $citation)
                Button("Save Citation") { controller.updatePreferredCitation(authorityID: authorityID, citation) }
                    .disabled(citation.trimmingCharacters(in: .whitespacesAndNewlines) == (authority.preferredCitation ?? ""))
            }

            Section("Status") {
                LabeledContent("Review") { ReviewBadge(state: authority.reviewState) }
                LabeledContent("Use status", value: authority.useStatus.displayName)
                let allowed = authority.useStatus.allowedTransitions
                if allowed.isEmpty {
                    Text("No further transitions available.").font(.supraCaption).foregroundStyle(.secondary)
                } else {
                    Menu {
                        ForEach(allowed, id: \.self) { target in
                            Button(target.displayName) { controller.changeUseStatus(authorityID: authorityID, to: target) }
                        }
                    } label: {
                        Label("Change Use Status", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            }

            Section("Notes") {
                MultilineField(placeholder: "User notes", text: $notes, minLines: 3)
                Button("Save Notes") { controller.updateUserNotes(authorityID: authorityID, notes) }
                    .disabled(notes == (authority.userNotes ?? ""))
            }

            Section("Raw metadata") {
                DisclosureGroup("Raw CourtListener JSON") {
                    Text(authority.rawMetadataJSON)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            Section {
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label("Delete Authority", systemImage: "trash")
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Remove “\(authority.caseName)”?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Remove Authority", role: .destructive) {
                controller.deleteAuthority(id: authorityID)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes it from the matter's authority library. You can re-add it by saving the result again from Research.")
        }
        .fileExporter(
            isPresented: $pdfExporting,
            document: pdfURL.flatMap { try? PDFFileDocument(url: $0) },
            contentType: .pdf,
            defaultFilename: Self.fileName(for: authority.caseName)
        ) { _ in }
        .onAppear {
            citation = authority.preferredCitation ?? ""
            notes = authority.userNotes ?? ""
            pdfURL = controller.storedOpinionPDF(opinionID: authority.opinionID)
            // Loaded ONCE: fetching every saved authority's full text from the
            // form body would re-read megabytes on each keystroke in Notes.
            storedText = controller.storedOpinionText(authorityID: authority.id)
            loadOpinionIfPossible(authority)
        }
    }

    /// Whether the reader has ANYTHING to show: fetched HTML, a downloaded PDF,
    /// persisted opinion text, or fetched body text.
    private func hasReadableOpinion(_ authority: AuthoritiesController.AuthorityItem) -> Bool {
        opinion?.bestHTML != nil
            || pdfURL != nil
            || storedText != nil
            || opinion?.bodyText?.isEmpty == false
            || opinion?.courtListenerPDFURL != nil
    }

    private func loadOpinionIfPossible(_ authority: AuthoritiesController.AuthorityItem) {
        guard opinion == nil, !loadingOpinion,
              authority.opinionID != nil, controller.hasCourtListenerToken else { return }
        loadingOpinion = true
        Task { @MainActor in
            opinion = await controller.fetchOpinionDetail(opinionID: authority.opinionID)
            loadingOpinion = false
        }
    }

    private func generateSummary(_ authority: AuthoritiesController.AuthorityItem) {
        summaryError = nil
        Task { @MainActor in
            guard let library else {
                summaryError = "Model library unavailable."
                return
            }
            switch await library.ensureLoadedChatModelID(for: .legalReasoning) {
            case .success(let modelID):
                summaryError = await controller.generateSummary(authorityID: authority.id, modelID: modelID)
            case .failure(let issue):
                summaryError = issue.message
            }
        }
    }

    private func downloadPDF() {
        guard let authority = controller.authorities.first(where: { $0.id == authorityID }),
              let cdnURL = opinion?.courtListenerPDFURL else { return }
        downloadingPDF = true
        Task { @MainActor in
            pdfURL = await controller.downloadOpinionPDF(opinionID: authority.opinionID, from: cdnURL)
            downloadingPDF = false
        }
    }

    /// A filesystem-safe base name (no extension) derived from the case name.
    static func fileName(for caseName: String) -> String {
        let base = caseName
            .replacingOccurrences(of: "[^A-Za-z0-9 .-]", with: "", options: .regularExpression)
            .replacingOccurrences(of: " ", with: "-")
        return base.isEmpty ? "opinion" : String(base.prefix(80))
    }
}


/// A minimal HTML document for SwiftUI's `.fileExporter`.
struct HTMLFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.html] }
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

struct OpinionWebView: NSViewRepresentable {
    let html: String
    /// When set, copying a selection appends this citation (with a star-
    /// pagination pin located in the page text) — same behavior as the Text
    /// view. CONTENT JavaScript stays disabled; per Apple's documented model,
    /// app-injected WKUserScripts still run, so the hook is ours alone and
    /// third-party opinion markup remains inert.
    var bluebook: BluebookCitation?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        if bluebook != nil {
            config.userContentController.add(context.coordinator, name: "citedCopy")
            config.userContentController.addUserScript(
                WKUserScript(
                    source: Self.citedCopyScript(firstPage: bluebook?.firstPage ?? 0),
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true
                )
            )
        }
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.bluebook = bluebook
        context.coordinator.load(Self.document(for: html), into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Coordinator no-ops if the document is unchanged, so SwiftUI re-renders
        // don't reload (and don't re-issue resource loads).
        context.coordinator.bluebook = bluebook
        context.coordinator.load(Self.document(for: html), into: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        // The controller retains its message handler strongly — break the cycle.
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "citedCopy")
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Intercepts copy, locates the reporter pages in force at the selection's
    /// ends from *NNN star-pagination in the rendered text, and hands the
    /// selection to native code, which writes selection + citation to the
    /// pasteboard. On any failure the default copy proceeds untouched.
    static func citedCopyScript(firstPage: Int) -> String {
        """
        (function() {
          function lastMarker(text) {
            // Same families as the native scanner: *152 stars, Justia-style
            // "Page 436 U. S. 152" headers, bare "-152-" page lines.
            var re = /\\[?\\*\\s?(\\d{1,5})\\]?|[Pp]age\\s+\\d{1,4}\\s+[A-Za-z][A-Za-z0-9. ]{0,12}?\\s+(\\d{1,5})\\b|^\\s*-\\s?(\\d{1,5})\\s?-\\s*$/gm;
            var m, last = null;
            while ((m = re.exec(text)) !== null) {
              var v = parseInt(m[1] || m[2] || m[3], 10);
              if (isNaN(v)) continue;
              if (\(firstPage) > 0 && (v < \(firstPage) || v > \(firstPage) + 2000)) continue;
              last = v;
            }
            return last;
          }
          document.addEventListener('copy', function(e) {
            var sel = window.getSelection();
            if (!sel || sel.rangeCount === 0) return;
            var text = sel.toString();
            if (!text || !text.trim()) return;
            var pinStart = null, pinEnd = null;
            try {
              var range = sel.getRangeAt(0);
              var pre = document.createRange();
              pre.selectNodeContents(document.body);
              pre.setEnd(range.startContainer, range.startOffset);
              pinStart = lastMarker(pre.toString());
              pre.selectNodeContents(document.body);
              pre.setEnd(range.endContainer, range.endOffset);
              pinEnd = lastMarker(pre.toString());
            } catch (err) { pinStart = null; pinEnd = null; }
            try {
              window.webkit.messageHandlers.citedCopy.postMessage({ text: text, pinStart: pinStart, pinEnd: pinEnd });
              e.preventDefault();
            } catch (err) { /* no native handler: default copy proceeds */ }
          });
        })();
        """
    }

    /// Wraps the opinion HTML in a minimal readable document.
    static func document(for body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          body { font: 16px/1.65 Georgia, 'Times New Roman', serif; margin: 28px auto; max-width: 46em; padding: 0 16px; color: #1c1c1e; }
          a { color: #0a6c3a; text-decoration: none; }
          blockquote { border-left: 3px solid #ccc; margin-left: 0; padding-left: 14px; color: #444; }
          @media (prefers-color-scheme: dark) { body { background: #1c1c1e; color: #e5e5ea; } a { color: #4cd07d; } }
        </style></head><body>\(body)</body></html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private var loadedDocument: String?
        private var ruleList: WKContentRuleList?
        var bluebook: BluebookCitation?

        /// The injected copy hook's payload: selection text + optional star-
        /// pagination pins. Types are validated; anything unexpected is ignored
        /// (the page can't reach this handler — content JS is disabled — but
        /// defense in depth costs nothing).
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "citedCopy",
                  let bluebook,
                  let body = message.body as? [String: Any],
                  let raw = body["text"] as? String else { return }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            var pins: (Int, Int)?
            if let start = body["pinStart"] as? Int {
                let end = body["pinEnd"] as? Int ?? start
                pins = (start, max(start, end))
            }
            // Inline, Bluebook-style: the cite follows the quoted text directly.
            let payload = text + " " + bluebook.formatted(pinPages: pins)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(payload, forType: .string)
        }

        /// Loads the opinion document once, only AFTER installing a content-rule
        /// list that blocks every remote (http/https) load. Third-party opinion
        /// markup can carry absolute-URL images/stylesheets/iframes; with
        /// JavaScript already disabled, this also stops those subresources from
        /// reaching off-`courtlistener.com` hosts (which would bypass the app's
        /// network allow-list). The in-memory document still renders; clicked links
        /// are intercepted below and opened in the browser.
        func load(_ document: String, into webView: WKWebView) {
            guard loadedDocument != document else { return }
            loadedDocument = document
            installBlockRule(on: webView) {
                webView.loadHTMLString(document, baseURL: nil)
            }
        }

        private func installBlockRule(on webView: WKWebView, then load: @escaping () -> Void) {
            if let ruleList {
                webView.configuration.userContentController.add(ruleList)
                load()
                return
            }
            let source = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
            guard let store = WKContentRuleListStore.default() else { load(); return }
            store.compileContentRuleList(forIdentifier: "supra-block-remote", encodedContentRuleList: source) { [weak self] list, _ in
                if let list {
                    self?.ruleList = list
                    webView.configuration.userContentController.add(list)
                }
                load()
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            // Allow the initial in-memory load; clicked links open in the browser.
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

/// In-app opinion PDF rendering (shared with the case readers).
struct OpinionPDFView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
    }
}

/// Wraps an on-disk PDF for SwiftUI's `.fileExporter` ("Save a copy…").
struct PDFFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    let data: Data

    init(url: URL) throws { data = try Data(contentsOf: url) }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
