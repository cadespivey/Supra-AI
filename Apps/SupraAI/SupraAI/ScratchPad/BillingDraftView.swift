import AppKit
import SupraCore
import SupraSessions
import SupraStore
import SwiftUI

/// The billing-draft review surface (Milestone 4, Phase 5): generate from a day's
/// notes, review/edit the Client·Matter·Narrative·Time table grouped by matter,
/// see the day reconciliation, regenerate (manual edits preserved), and export.
struct BillingDraftView: View {
    @ObservedObject var billing: BillingDraftController
    let dayID: String?
    let isLocked: Bool

    @State private var editing: BillingLineItemRecord?
    @State private var exportBlockers: [BillingExportIssue] = []
    @State private var showingExportBlock = false

    private let goldAccent = Color(red: 0.79, green: 0.64, blue: 0.29)

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let status = billing.statusMessage {
                statusRow(status)
            }
            if let reconciliation = billing.reconciliation {
                reconciliationBanner(reconciliation)
                Divider()
            }
            content
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { billing.bind(dayID: dayID) }
        .onChange(of: dayID) { _, newID in billing.bind(dayID: newID) }
        .sheet(item: $editing) { line in
            EditLineSheet(line: line, codeSet: billing.codeSet(forLine: line)) { narrative, hours, task, activity in
                billing.editLine(id: line.id, narrative: narrative, hours: hours, taskCode: task, activityCode: activity)
                editing = nil
            }
        }
        .alert("Can't export to LEDES yet", isPresented: $showingExportBlock) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportBlockerMessage)
        }
    }

    private var exportBlockerMessage: String {
        let lines = exportBlockers.prefix(6).map { issue -> String in
            if let narrative = issue.lineNarrative {
                return "• \(issue.message) (\(narrative.prefix(40))…)"
            }
            return "• \(issue.message)"
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                Task { await billing.generate() }
            } label: {
                if billing.isGenerating {
                    ProgressView().controlSize(.small)
                } else {
                    Label(billing.hasDraft ? "Regenerate" : "Generate billing draft", systemImage: "wand.and.stars")
                }
            }
            .disabled(billing.isGenerating || dayID == nil || isLocked)
            if let version = billing.draftVersion {
                Text("v\(version)").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            if billing.hasDraft {
                Menu {
                    ForEach(BillingExportFormat.allCases) { format in
                        Button(format.label) { export(format) }
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(12)
    }

    private func statusRow(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
            Text(message).font(.caption)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Reconciliation

    private func reconciliationBanner(_ reconciliation: BillingReconciliation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                metric("Billable", "\(BillingExporter.hoursString(reconciliation.billableTotalHours)) h")
                metric("Amount", reconciliation.totalAmount.formatted(.currency(code: "USD")))
                if !reconciliation.flags.isEmpty {
                    metric("Flags", "\(reconciliation.flags.count)", warning: true)
                }
            }
            if !reconciliation.flags.isEmpty {
                ForEach(reconciliation.flags.prefix(4), id: \.self) { flag in
                    Label(flag, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func metric(_ label: String, _ value: String, warning: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium)).foregroundStyle(warning ? Color.orange : .primary)
        }
    }

    // MARK: - Table

    @ViewBuilder
    private var content: some View {
        if !billing.hasDraft {
            ContentUnavailableView(
                "No billing draft yet",
                systemImage: "tablecells",
                description: Text(dayID == nil ? "Open a day first." : "Generate a draft from this day's notes and attachments. Nothing is billed automatically.")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.key) { group in
                        matterHeader(group)
                        ForEach(group.lines, id: \.id) { line in
                            lineRow(line)
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func matterHeader(_ group: MatterGroup) -> some View {
        HStack {
            Text(group.name).font(.callout.weight(.medium))
            Spacer()
            Text("\(BillingExporter.hoursString(group.hours)) h").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .padding(.top, 4)
    }

    private func lineRow(_ line: BillingLineItemRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(line.narrative).font(.callout)
                HStack(spacing: 6) {
                    codeChip(line.utbmsTaskCode, fallback: "—")
                    codeChip(line.utbmsActivityCode, fallback: "A—")
                    confidencePill(line.confidence)
                    if line.userEdited {
                        Label("edited", systemImage: "pencil").font(.caption2).foregroundStyle(goldAccent)
                    }
                }
            }
            Spacer(minLength: 8)
            Text("\(BillingExporter.hoursString(line.hours)) h")
                .font(.callout.monospacedDigit())
                .frame(width: 56, alignment: .trailing)
            rowMenu(line)
        }
        .padding(.vertical, 8)
    }

    /// Per-line actions that let the user resolve every validator blocker: edit
    /// (narrative/hours/codes), reassign the matter, or delete the line.
    private func rowMenu(_ line: BillingLineItemRecord) -> some View {
        Menu {
            Button { editing = line } label: { Label("Edit…", systemImage: "pencil") }
            Menu("Reassign matter") {
                Button("Unassigned") { billing.reassignMatter(lineID: line.id, to: nil) }
                Divider()
                ForEach(billing.availableMatters()) { option in
                    Button(option.name) { billing.reassignMatter(lineID: line.id, to: option.id) }
                }
            }
            Divider()
            Button(role: .destructive) { billing.deleteLine(id: line.id) } label: {
                Label("Delete line", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(isLocked)
        .accessibilityLabel("Line actions")
    }

    private func codeChip(_ code: String?, fallback: String) -> some View {
        Text(code ?? fallback)
            .font(.caption2.monospaced())
            .foregroundStyle(code == nil ? .tertiary : .secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.12)))
    }

    private func confidencePill(_ raw: String) -> some View {
        let confidence = BillingConfidence(rawValue: raw) ?? .medium
        let color: Color = confidence == .high ? .green : (confidence == .low ? .red : .orange)
        return Text(confidence.rawValue)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    // MARK: - Grouping

    private struct MatterGroup {
        let key: String
        let name: String
        let lines: [BillingLineItemRecord]
        var hours: Double { lines.reduce(0) { $0 + $1.hours } }
    }

    private var groups: [MatterGroup] {
        var order: [String] = []
        var byKey: [String: [BillingLineItemRecord]] = [:]
        var names: [String: String] = [:]
        for line in billing.lines {
            let key = line.matterID ?? "unassigned"
            if byKey[key] == nil { order.append(key); names[key] = billing.matterName(for: line) ?? "Unassigned" }
            byKey[key, default: []].append(line)
        }
        return order.map { MatterGroup(key: $0, name: names[$0] ?? "Unassigned", lines: byKey[$0] ?? []) }
    }

    // MARK: - Export

    private func export(_ format: BillingExportFormat) {
        // LEDES is machine-ingested and strict — block it on missing required fields
        // (spec §8). CSV/clipboard are review aids and export as-is.
        if format == .ledes {
            let issues = billing.exportIssues()
            if !issues.isEmpty {
                exportBlockers = issues
                showingExportBlock = true
                return
            }
        }
        let text = billing.exportString(format: format)
        if format.isClipboard {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            billing.statusMessage = "Copied \(billing.lines.count) line(s) to the clipboard."
            billing.markExported(format: format)
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "billing-draft.\(format.fileExtension)"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                Task { @MainActor in billing.markExported(format: format) }
            } catch {
                Task { @MainActor in billing.statusMessage = "Couldn't write the file: \(error.localizedDescription)" }
            }
        }
    }
}

/// A small editor for one billing line (narrative, hours, UTBMS codes). Task and
/// activity codes use real UTBMS pickers filtered by the matter's code set, so an
/// invalid code can't be entered; firm-specific (transactional/advisory) task codes
/// fall back to free text since they aren't a built-in list.
private struct EditLineSheet: View {
    let line: BillingLineItemRecord
    let codeSet: BillingCodeSet
    let onSave: (_ narrative: String, _ hours: Double, _ taskCode: String?, _ activityCode: String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var narrative: String
    @State private var hoursText: String
    @State private var taskCode: String
    @State private var activityCode: String

    init(line: BillingLineItemRecord, codeSet: BillingCodeSet, onSave: @escaping (String, Double, String?, String?) -> Void) {
        self.line = line
        self.codeSet = codeSet
        self.onSave = onSave
        _narrative = State(initialValue: line.narrative)
        _hoursText = State(initialValue: BillingExporter.hoursString(line.hours))
        _taskCode = State(initialValue: line.utbmsTaskCode ?? "")
        _activityCode = State(initialValue: line.utbmsActivityCode ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit line").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("Narrative").font(.caption).foregroundStyle(.secondary)
                TextField("Narrative", text: $narrative, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder)
            }
            HStack(alignment: .top, spacing: 12) {
                field("Hours", text: $hoursText, width: 80)
                taskCodeField
                activityCodeField
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    let hours = Double(hoursText.trimmingCharacters(in: .whitespaces)) ?? line.hours
                    onSave(
                        narrative.trimmingCharacters(in: .whitespacesAndNewlines),
                        hours,
                        taskCode.isEmpty ? nil : taskCode,
                        activityCode.isEmpty ? nil : activityCode
                    )
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    @ViewBuilder
    private var taskCodeField: some View {
        let options = UTBMSCodes.taskCodes(for: codeSet)
        VStack(alignment: .leading, spacing: 4) {
            Text("Task code").font(.caption).foregroundStyle(.secondary)
            if options.isEmpty {
                // .none → no task code; transactional/advisory → firm-specific free text.
                if codeSet == .none {
                    Text("—").foregroundStyle(.tertiary).frame(width: 150, alignment: .leading)
                } else {
                    TextField("Firm code", text: $taskCode).textFieldStyle(.roundedBorder).frame(width: 150)
                }
            } else {
                codePicker(selection: $taskCode, options: options)
            }
        }
    }

    private var activityCodeField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Activity").font(.caption).foregroundStyle(.secondary)
            codePicker(selection: $activityCode, options: UTBMSCodes.activity)
        }
    }

    private func codePicker(selection: Binding<String>, options: [UTBMSCode]) -> some View {
        Picker("", selection: selection) {
            Text("None").tag("")
            ForEach(options) { code in
                Text("\(code.code) — \(code.title)").tag(code.code)
            }
            // Preserve a pre-existing non-standard value so editing doesn't drop it.
            if !selection.wrappedValue.isEmpty, !options.contains(where: { $0.code == selection.wrappedValue }) {
                Text(selection.wrappedValue).tag(selection.wrappedValue)
            }
        }
        .labelsHidden()
        .frame(width: 180)
    }

    private func field(_ label: String, text: Binding<String>, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: text).textFieldStyle(.roundedBorder).frame(width: width)
        }
    }
}
