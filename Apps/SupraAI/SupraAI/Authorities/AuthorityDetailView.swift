import AppKit
import SupraCore
import SupraResearch
import SupraSessions
import SwiftUI
import WebKit

/// Authority detail: metadata, editable preferred citation + notes, and a
/// use-status changer limited to the permitted transitions (spec §11.3–§11.4).
struct AuthorityDetailView: View {
    @ObservedObject var controller: AuthoritiesController
    let authorityID: String

    @Environment(\.dismiss) private var dismiss
    @State private var citation = ""
    @State private var notes = ""
    @State private var confirmingDelete = false
    @State private var opinion: CourtListenerOpinionDetailDTO?
    @State private var loadingOpinion = false
    @State private var showHTML = false

    var body: some View {
        Group {
            if let authority = controller.authorities.first(where: { $0.id == authorityID }) {
                form(authority)
            } else {
                ContentUnavailableView("Authority not found", systemImage: "questionmark.circle")
            }
        }
        .navigationTitle("Authority")
    }

    private func form(_ authority: AuthoritiesController.AuthorityItem) -> some View {
        Form {
            Section {
                Text(authority.caseNameFull ?? authority.caseName).font(.headline)
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
                } else if opinion?.bestHTML != nil {
                    Button { showHTML = true } label: { Label("View opinion (HTML)", systemImage: "doc.richtext") }
                }
            }

            if loadingOpinion || opinionPassage != nil {
                Section("Opinion text") {
                    if let passage = opinionPassage {
                        Text(passage).font(.callout).textSelection(.enabled)
                    } else {
                        Text("Loading…").foregroundStyle(.secondary)
                    }
                }
            }

            Section("Citations") {
                ForEach(authority.citations, id: \.self) { Text($0).font(.callout) }
                TextField("Preferred citation", text: $citation)
                Button("Save Citation") { controller.updatePreferredCitation(authorityID: authorityID, citation) }
                    .disabled(citation.trimmingCharacters(in: .whitespacesAndNewlines) == (authority.preferredCitation ?? ""))
            }

            Section("Status") {
                LabeledContent("Review") { ReviewBadge(state: authority.reviewState) }
                LabeledContent("Use status", value: authority.useStatus.rawValue)
                let allowed = authority.useStatus.allowedTransitions
                if allowed.isEmpty {
                    Text("No further transitions available.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Menu("Change Use Status") {
                        ForEach(allowed, id: \.self) { target in
                            Button(target.rawValue) { controller.changeUseStatus(authorityID: authorityID, to: target) }
                        }
                    }
                }
            }

            Section("Notes") {
                TextField("User notes", text: $notes, axis: .vertical).lineLimit(2...5)
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
        .sheet(isPresented: $showHTML) {
            if let html = opinion?.bestHTML {
                OpinionHTMLSheet(
                    title: authority.caseName,
                    html: html,
                    suggestedFileName: Self.fileName(for: authority.caseName)
                )
            }
        }
        .onAppear {
            citation = authority.preferredCitation ?? ""
            notes = authority.userNotes ?? ""
            loadOpinionIfPossible(authority)
        }
    }

    /// A ~80-word excerpt of the opinion body, once fetched.
    private var opinionPassage: String? {
        CourtListenerText.passage(from: opinion?.bodyText)
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

    static func fileName(for caseName: String) -> String {
        let base = caseName
            .replacingOccurrences(of: "[^A-Za-z0-9 .-]", with: "", options: .regularExpression)
            .replacingOccurrences(of: " ", with: "-")
        return (base.isEmpty ? "opinion" : String(base.prefix(80))) + ".html"
    }
}

/// Renders fetched opinion HTML in a sheet (JavaScript disabled; clicked links
/// open in the browser) with a Download action that writes the HTML to disk.
struct OpinionHTMLSheet: View {
    let title: String
    let html: String
    let suggestedFileName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline).lineLimit(1)
                Spacer()
                Button { downloadHTML() } label: { Label("Download HTML…", systemImage: "arrow.down.circle") }
                Button("Done") { dismiss() }
            }
            .padding(12)
            Divider()
            OpinionWebView(html: html)
        }
        .frame(minWidth: 680, minHeight: 560)
    }

    private func downloadHTML() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = suggestedFileName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(OpinionWebView.document(for: html).utf8).write(to: url)
    }
}

private struct OpinionWebView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.load(Self.document(for: html), into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Coordinator no-ops if the document is unchanged, so SwiftUI re-renders
        // don't reload (and don't re-issue resource loads).
        context.coordinator.load(Self.document(for: html), into: webView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

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

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var loadedDocument: String?
        private var ruleList: WKContentRuleList?

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
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
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
