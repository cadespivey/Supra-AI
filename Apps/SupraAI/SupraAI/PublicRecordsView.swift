import SupraResearch
import SupraSessions
import SwiftUI

/// Public Records: key-less searches of official government data — SEC EDGAR
/// filings, the CFPB consumer-complaint database, and locally imported NLRB
/// exports. Results are sourced public records with links to the official
/// pages; nothing here feeds model prompts, and nothing is presented as a
/// finding or legal conclusion.
struct PublicRecordsView: View {
    @ObservedObject var controller: PublicRecordsController

    enum Source: String, CaseIterable, Identifiable {
        case sec = "SEC EDGAR"
        case cfpb = "CFPB Complaints"
        case nlrb = "NLRB"
        var id: String { rawValue }
    }

    @State private var source: Source = .sec
    // SEC
    @State private var secCIK = ""
    @State private var secScope: PublicRecordsController.SecFormScope = .all
    // CFPB
    @State private var cfpbCompany = ""
    @State private var cfpbState = ""
    @State private var cfpbProduct = ""
    // NLRB
    @State private var nlrbParty = ""
    @State private var nlrbCaseNumber = ""
    @State private var showNlrbFileImporter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Picker("Source", selection: $source) {
                ForEach(Source.allCases) { source in
                    Text(source.rawValue).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(16)
            .accessibilityIdentifier("publicRecords.sourcePicker")
            .background {
                // Keyboard source switching (⌘⌥1/2/3) — ⌘⇧3/4 are the
                // system screenshot shortcuts, so option is the safe modifier.
                ForEach(Array(Source.allCases.enumerated()), id: \.element) { index, target in
                    Button("") { source = target }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
                        .hidden()
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch source {
                    case .sec: secSection
                    case .cfpb: cfpbSection
                    case .nlrb: nlrbSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .frame(maxWidth: 760, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Public Records").font(.supraTitle)
            Text("Official government data — filings, complaints, and case records. These are public records and allegations as filed, not findings or conclusions.")
                .font(.supraSubheadline)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    // MARK: - SEC

    @ViewBuilder
    private var secSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Company filings").font(.supraHeadline)
            HStack(spacing: 8) {
                TextField("CIK (e.g. 320193)", text: $secCIK)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .accessibilityIdentifier("publicRecords.sec.cik")
                    .onSubmit { runSecSearch() }
                Picker("Forms", selection: $secScope) {
                    ForEach(PublicRecordsController.SecFormScope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 180)
                Button("Search Filings") { runSecSearch() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(secCIK.trimmingCharacters(in: .whitespaces).isEmpty || controller.secPhase == .loading)
                    .accessibilityIdentifier("publicRecords.sec.search")
            }
            Text("EDGAR indexes companies by CIK number. Look one up on [EDGAR company search](https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany) — filings below link to the official archive.")
                .font(.supraCaption)
                .foregroundStyle(.secondary)
        }

        switch controller.secPhase {
        case .idle:
            EmptyView()
        case .loading:
            ProgressView("Fetching from data.sec.gov…").font(.supraCaption)
        case .failed(let message):
            errorLine(message)
        case .loaded:
            if let company = controller.secCompany {
                VStack(alignment: .leading, spacing: 2) {
                    Text(company.entityName ?? "CIK \(company.cik)").font(.supraHeadline)
                    Text(secCompanySubtitle(company))
                        .font(.supraCaption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("publicRecords.sec.company")
            }
            if controller.secFilings.isEmpty {
                Text("No filings matched this scope.").font(.supraBody).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(controller.secFilings.enumerated()), id: \.element.accessionNumber) { index, filing in
                        if index > 0 { Divider() }
                        secFilingRow(filing)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .quaternarySystemFill)))
            }
        }
    }

    private func runSecSearch() {
        Task { await controller.searchSecFilings(cik: secCIK, scope: secScope) }
    }

    /// EDGAR often omits `primaryDocDescription`; the raw primary-document
    /// path (`xsl144X01/primary_doc.xml`) is noise to a reader, so fall back
    /// to a plain form label instead.
    private func filingFallbackTitle(_ filing: SecFilingRecord) -> String {
        if let form = filing.form { return "Form \(form) filing" }
        return "Filing \(filing.accessionNumber)"
    }

    private func secCompanySubtitle(_ company: SecCompanyRecord) -> String {
        var pieces = ["CIK \(company.cik)"]
        if !company.tickers.isEmpty { pieces.append(company.tickers.joined(separator: ", ")) }
        if let sic = company.sicDescription { pieces.append(sic) }
        return pieces.joined(separator: " · ")
    }

    private func secFilingRow(_ filing: SecFilingRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(filing.form ?? "—")
                .font(.supraBody.weight(.medium))
                .frame(width: 90, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(filing.primaryDocDescription ?? filingFallbackTitle(filing))
                    .font(.supraBody)
                    .lineLimit(1)
                Text(filing.filingDate ?? "undated")
                    .font(.supraCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let url = URL(string: filing.primaryDocumentUrl ?? filing.filingUrl) {
                Link("View", destination: url).font(.supraCaption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - CFPB

    @ViewBuilder
    private var cfpbSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Consumer complaints").font(.supraHeadline)
            HStack(spacing: 8) {
                TextField("Company name", text: $cfpbCompany)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("publicRecords.cfpb.company")
                    .onSubmit { runCfpbSearch() }
                TextField("State (FL)", text: $cfpbState)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 90)
                TextField("Product (optional)", text: $cfpbProduct)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                Button("Search Complaints") { runCfpbSearch() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(cfpbInputEmpty || controller.cfpbPhase == .loading)
                    .accessibilityIdentifier("publicRecords.cfpb.search")
            }
            Text("Complaints are consumer allegations as submitted to the CFPB. The database does not verify or adjudicate them.")
                .font(.supraCaption)
                .foregroundStyle(.secondary)
        }

        switch controller.cfpbPhase {
        case .idle:
            EmptyView()
        case .loading:
            ProgressView("Searching the CFPB complaint database…").font(.supraCaption)
        case .failed(let message):
            errorLine(message)
        case .loaded:
            if let result = controller.cfpbResult {
                VStack(alignment: .leading, spacing: 8) {
                    Text(cfpbCountLine(result))
                        .font(.supraSubheadline)
                        .accessibilityIdentifier("publicRecords.cfpb.count")
                    ForEach(result.sourceLimitations, id: \.self) { limitation in
                        Text(limitation).font(.supraCaption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(result.complaints.enumerated()), id: \.element.complaintId) { index, complaint in
                            if index > 0 { Divider() }
                            cfpbRow(complaint)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .quaternarySystemFill)))
                }
            }
        }
    }

    private var cfpbInputEmpty: Bool {
        [cfpbCompany, cfpbState, cfpbProduct]
            .allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func runCfpbSearch() {
        guard !cfpbInputEmpty else { return }
        Task { await controller.searchCfpbComplaints(company: cfpbCompany, state: cfpbState, product: cfpbProduct) }
    }

    private func cfpbCountLine(_ result: CfpbComplaintSearchResult) -> String {
        if let total = result.totalCount {
            return "\(result.complaints.count) of \(total) matching complaint record(s) shown."
        }
        return "\(result.complaints.count) complaint record(s) retrieved."
    }

    private func cfpbRow(_ complaint: CfpbComplaintRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text([complaint.product, complaint.issue].compactMap { $0 }.joined(separator: " — "))
                    .font(.supraBody)
                    .lineLimit(2)
                Text(cfpbRowSubtitle(complaint))
                    .font(.supraCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let url = URL(string: complaint.sourceUrl) {
                Link("View", destination: url).font(.supraCaption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func cfpbRowSubtitle(_ complaint: CfpbComplaintRecord) -> String {
        var pieces: [String] = ["#\(complaint.complaintId)"]
        if let company = complaint.company { pieces.append(company) }
        if let state = complaint.state { pieces.append(state) }
        if let received = complaint.dateReceived { pieces.append("received \(received)") }
        if let response = complaint.companyResponse { pieces.append(response) }
        return pieces.joined(separator: " · ")
    }

    // MARK: - NLRB

    @ViewBuilder
    private var nlrbSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Labor case records").font(.supraHeadline)
            Text("The NLRB publishes recent filings and election results as official CSV exports. Import them once, then search locally — records describe filings and allegations, never findings.")
                .font(.supraCaption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Check Official Datasets") {
                    Task { await controller.refreshNlrbDatasets() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(controller.nlrbDatasetsPhase == .loading)
                .accessibilityIdentifier("publicRecords.nlrb.refresh")
                Button("Import All Available") {
                    Task {
                        for dataset in controller.nlrbDatasets where dataset.status == .available {
                            await controller.importNlrbDataset(dataset)
                        }
                    }
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(controller.nlrbDatasets.allSatisfy { $0.status != .available })
                .accessibilityIdentifier("publicRecords.nlrb.importAll")
                Button("Import Downloaded CSV…") { showNlrbFileImporter = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .accessibilityIdentifier("publicRecords.nlrb.importFile")
                if controller.nlrbDatasetsPhase == .loading {
                    ProgressView().controlSize(.small)
                }
            }
            .fileImporter(
                isPresented: $showNlrbFileImporter,
                allowedContentTypes: [.commaSeparatedText, .plainText]
            ) { outcome in
                if case .success(let url) = outcome {
                    Task { await controller.importNlrbLocalFile(url) }
                }
            }
            Text("If a dataset shows as not importable, the NLRB page is keeping its CSV behind an interactive download — open the page, download the CSV in your browser, then use Import Downloaded CSV.")
                .font(.supraCaption)
                .foregroundStyle(.secondary)
            if case .failed(let message) = controller.nlrbDatasetsPhase {
                errorLine(message)
            }
            ForEach(controller.nlrbDatasets, id: \.name) { dataset in
                nlrbDatasetRow(dataset)
            }
            if let status = controller.nlrbImportStatus {
                Text(status)
                    .font(.supraCaption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("publicRecords.nlrb.importStatus")
            }
        }

        VStack(alignment: .leading, spacing: 10) {
            Text("Search imported records").font(.supraHeadline)
            HStack(spacing: 8) {
                TextField("Party name (employer or union)", text: $nlrbParty)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("publicRecords.nlrb.party")
                    .onSubmit { runNlrbPartySearch() }
                Button("Party History") { runNlrbPartySearch() }
                    .disabled(nlrbParty.trimmingCharacters(in: .whitespaces).isEmpty || controller.nlrbPhase == .loading)
                    .accessibilityIdentifier("publicRecords.nlrb.partySearch")
            }
            HStack(spacing: 8) {
                TextField("Case number (e.g. 12-CA-345678)", text: $nlrbCaseNumber)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                    .onSubmit { runNlrbCaseLookup() }
                Button("Look Up Case") { runNlrbCaseLookup() }
                    .disabled(nlrbCaseNumber.trimmingCharacters(in: .whitespaces).isEmpty || controller.nlrbPhase == .loading)
            }
        }

        switch controller.nlrbPhase {
        case .idle:
            EmptyView()
        case .loading:
            ProgressView("Searching imported records…").font(.supraCaption)
        case .failed(let message):
            errorLine(message)
        case .loaded:
            if let summary = controller.nlrbSummary {
                VStack(alignment: .leading, spacing: 6) {
                    Text(summary.summaryText)
                        .font(.supraBody)
                        .accessibilityIdentifier("publicRecords.nlrb.summary")
                    ForEach(summary.limitations, id: \.self) { limitation in
                        Text(limitation).font(.supraCaption).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .quaternarySystemFill)))
            }
            if controller.nlrbCaseMatches.isEmpty {
                Text("No matching records in the imported datasets. Import the official datasets above, or broaden the search.")
                    .font(.supraBody)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(controller.nlrbCaseMatches.enumerated()), id: \.element.caseNumber) { index, record in
                        if index > 0 { Divider() }
                        nlrbCaseRow(record)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .quaternarySystemFill)))
            }
        }
    }

    private func nlrbCaseRow(_ record: NlrbCaseRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text([record.caseNumber, record.caseName].compactMap { $0 }.joined(separator: " — "))
                    .font(.supraBody)
                    .lineLimit(2)
                Text(nlrbCaseSubtitle(record))
                    .font(.supraCaption)
                    .foregroundStyle(.secondary)
                if let allegations = record.allegations {
                    Text("Allegations as filed: \(allegations)")
                        .font(.supraCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if let url = URL(string: record.sourceUrl) {
                Link("Case page", destination: url).font(.supraCaption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func nlrbCaseSubtitle(_ record: NlrbCaseRecord) -> String {
        var pieces: [String] = []
        if let type = record.caseType { pieces.append(type) }
        if let filed = record.dateFiled { pieces.append("filed \(filed)") }
        if let region = record.region { pieces.append(region) }
        if let status = record.status { pieces.append(status) }
        return pieces.joined(separator: " · ")
    }

    private func runNlrbPartySearch() {
        Task { await controller.searchNlrbParty(nlrbParty) }
    }

    private func runNlrbCaseLookup() {
        Task { await controller.lookupNlrbCase(nlrbCaseNumber) }
    }

    @ViewBuilder
    private func nlrbDatasetRow(_ dataset: NlrbDatasetSource) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(dataset.name).font(.supraBody)
                Text(dataset.note ?? nlrbStatusLabel(dataset.status))
                    .font(.supraCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if dataset.status == .available {
                Button("Import") {
                    Task { await controller.importNlrbDataset(dataset) }
                }
                .controlSize(.small)
            }
            if dataset.status != .available, let page = dataset.pageUrl, let url = URL(string: page) {
                Link("Open Page", destination: url).font(.supraCaption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .quaternarySystemFill)))
    }

    private func nlrbStatusLabel(_ status: NlrbDatasetSource.Status) -> String {
        switch status {
        case .available: "Official download available."
        case .discoveredButNotImported: "Listed for reference — import not available."
        case .unsupported: "Not importable."
        }
    }

    // MARK: - Shared

    private func errorLine(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.supraCaption)
            .foregroundStyle(.orange)
            .accessibilityIdentifier("publicRecords.error")
    }
}
