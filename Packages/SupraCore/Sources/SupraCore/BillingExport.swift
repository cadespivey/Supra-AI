import Foundation

// Milestone 4 (ScratchPad billing) — pure, deterministic billing-line model and
// exporters. No app/store/model dependencies, so the arithmetic and the LEDES/CSV
// formatting are fully unit-testable and can never be produced by the model. The
// model proposes line *content*; this code does all numbers and serialization.

/// A single billable line, decoupled from the GRDB record. Dates are kept as
/// `yyyy-MM-dd` strings to avoid any timezone ambiguity in deterministic output.
public struct BillingLine: Sendable, Equatable {
    public var clientID: String?
    public var lawFirmMatterID: String?
    public var clientMatterID: String?
    public var clientDisplay: String?
    public var matterDisplay: String?
    public var narrative: String
    public var hours: Double
    public var workDate: String
    public var taskCode: String?
    public var activityCode: String?
    public var rate: Double?
    public var confidence: BillingConfidence
    /// The matter's governing code set, used by the pre-export validator to decide
    /// whether a blank task code is acceptable (`.none`) or a blocking gap.
    public var codeSet: BillingCodeSet
    /// How this line's narrative terminal punctuation is normalized at export.
    public var narrativeTerminal: BillingNarrativeTerminal

    public init(
        clientID: String? = nil,
        lawFirmMatterID: String? = nil,
        clientMatterID: String? = nil,
        clientDisplay: String? = nil,
        matterDisplay: String? = nil,
        narrative: String,
        hours: Double,
        workDate: String,
        taskCode: String? = nil,
        activityCode: String? = nil,
        rate: Double? = nil,
        confidence: BillingConfidence = .medium,
        codeSet: BillingCodeSet = .none,
        narrativeTerminal: BillingNarrativeTerminal = .asWritten
    ) {
        self.clientID = clientID
        self.lawFirmMatterID = lawFirmMatterID
        self.clientMatterID = clientMatterID
        self.clientDisplay = clientDisplay
        self.matterDisplay = matterDisplay
        self.narrative = narrative
        self.hours = hours
        self.workDate = workDate
        self.taskCode = taskCode
        self.activityCode = activityCode
        self.rate = rate
        self.confidence = confidence
        self.codeSet = codeSet
        self.narrativeTerminal = narrativeTerminal
    }

    /// The narrative with its terminal punctuation normalized per `narrativeTerminal`.
    public var formattedNarrative: String {
        BillingExporter.formatNarrative(narrative, terminal: narrativeTerminal)
    }

    /// The effective rate for this line (line override, else the timekeeper default).
    public func effectiveRate(_ timekeeper: BillingTimekeeper) -> Double { rate ?? timekeeper.defaultRate }
}

/// The configured timekeeper + firm identity used to populate fee lines.
public struct BillingTimekeeper: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var classification: String
    public var defaultRate: Double
    public var lawFirmID: String

    public init(id: String, name: String, classification: String, defaultRate: Double, lawFirmID: String) {
        self.id = id
        self.name = name
        self.classification = classification
        self.defaultRate = defaultRate
        self.lawFirmID = lawFirmID
    }
}

/// Invoice-level metadata supplied at export time.
public struct BillingInvoiceInfo: Sendable, Equatable {
    public var invoiceDate: String
    public var invoiceDescription: String

    public init(invoiceDate: String, invoiceDescription: String = "Invoice for professional services rendered") {
        self.invoiceDate = invoiceDate
        self.invoiceDescription = invoiceDescription
    }
}

/// Pure serializers for the supported export formats (Milestone 4 §8).
public enum BillingExporter {

    /// The 24 LEDES 1998B fields, in order.
    public static let ledes1998BFields = [
        "INVOICE_DATE", "INVOICE_NUMBER", "CLIENT_ID", "LAW_FIRM_MATTER_ID", "INVOICE_TOTAL",
        "BILLING_START_DATE", "BILLING_END_DATE", "INVOICE_DESCRIPTION", "LINE_ITEM_NUMBER",
        "EXP/FEE/INV_ADJ_TYPE", "LINE_ITEM_NUMBER_OF_UNITS", "LINE_ITEM_ADJUSTMENT_AMOUNT",
        "LINE_ITEM_TOTAL", "LINE_ITEM_DATE", "LINE_ITEM_TASK_CODE", "LINE_ITEM_EXPENSE_CODE",
        "LINE_ITEM_ACTIVITY_CODE", "TIMEKEEPER_ID", "LINE_ITEM_DESCRIPTION", "LAW_FIRM_ID",
        "LINE_ITEM_UNIT_COST", "TIMEKEEPER_NAME", "TIMEKEEPER_CLASSIFICATION", "CLIENT_MATTER_ID"
    ]

    /// Renders fee lines as a LEDES 1998B file. Lines are grouped into one invoice
    /// per (client, law-firm-matter); `LINE_ITEM_NUMBER` restarts per invoice and
    /// `INVOICE_TOTAL` is the sum of that invoice's line totals. Fees only (type `F`).
    public static func ledes1998B(lines: [BillingLine], timekeeper: BillingTimekeeper, invoice: BillingInvoiceInfo) -> String {
        var out = ["LEDES1998B[]", ledes1998BFields.joined(separator: "|") + "[]"]
        let invoiceDate = compactDate(invoice.invoiceDate)

        var groupOrder: [String] = []
        var groups: [String: [BillingLine]] = [:]
        for line in lines {
            let key = (line.clientID ?? "") + "\u{1}" + (line.lawFirmMatterID ?? "")
            if groups[key] == nil { groupOrder.append(key) }
            groups[key, default: []].append(line)
        }

        for key in groupOrder {
            let groupLines = groups[key] ?? []
            let invoiceTotal = groupLines.reduce(0.0) { $0 + $1.hours * $1.effectiveRate(timekeeper) }
            let sortedDates = groupLines.map(\.workDate).sorted()
            let clientID = groupLines.first?.clientID ?? ""
            let lawFirmMatterID = groupLines.first?.lawFirmMatterID ?? ""
            let invoiceNumber = "\(lawFirmMatterID.isEmpty ? clientID : lawFirmMatterID)-\(invoiceDate)"

            for (index, line) in groupLines.enumerated() {
                let rate = line.effectiveRate(timekeeper)
                let lineTotal = line.hours * rate
                let fields = [
                    invoiceDate,
                    invoiceNumber,
                    clientID,
                    lawFirmMatterID,
                    money(invoiceTotal),
                    compactDate(sortedDates.first ?? invoice.invoiceDate),
                    compactDate(sortedDates.last ?? invoice.invoiceDate),
                    sanitize(invoice.invoiceDescription),
                    "\(index + 1)",
                    "F",
                    money(line.hours),
                    "0.00",
                    money(lineTotal),
                    compactDate(line.workDate),
                    line.taskCode ?? "",
                    "",
                    line.activityCode ?? "",
                    timekeeper.id,
                    sanitize(line.formattedNarrative),
                    timekeeper.lawFirmID,
                    money(rate),
                    sanitize(timekeeper.name),
                    sanitize(timekeeper.classification),
                    line.clientMatterID ?? ""
                ]
                out.append(fields.joined(separator: "|") + "[]")
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// Renders fee lines as a review/spreadsheet CSV with a trailing total row.
    public static func csv(lines: [BillingLine], timekeeper: BillingTimekeeper) -> String {
        var rows = ["Date,Client,Matter,Timekeeper,Task Code,Activity Code,Narrative,Hours,Rate,Amount"]
        var totalHours = 0.0
        var totalAmount = 0.0
        for line in lines {
            let rate = line.effectiveRate(timekeeper)
            let amount = line.hours * rate
            totalHours += line.hours
            totalAmount += amount
            let columns = [
                line.workDate,
                line.clientDisplay ?? line.clientID ?? "",
                line.matterDisplay ?? line.lawFirmMatterID ?? "",
                timekeeper.name,
                line.taskCode ?? "",
                line.activityCode ?? "",
                line.formattedNarrative,
                hoursString(line.hours),
                money(rate),
                money(amount)
            ].map(csvCell)
            rows.append(columns.joined(separator: ","))
        }
        let totalRow = ["", "", "", "", "", "", "TOTAL", hoursString(totalHours), "", money(totalAmount)]
        rows.append(totalRow.map(csvCell).joined(separator: ","))
        return rows.joined(separator: "\n") + "\n"
    }

    /// Renders fee lines as tab-separated text for pasting into a practice-management timesheet.
    public static func clipboardTSV(lines: [BillingLine], timekeeper: BillingTimekeeper) -> String {
        var rows = ["Date\tClient / Matter\tHours\tNarrative"]
        for line in lines {
            let matter = [line.clientDisplay ?? line.clientID, line.matterDisplay ?? line.lawFirmMatterID]
                .compactMap { $0 }.joined(separator: " / ")
            let columns = [line.workDate, matter, hoursString(line.hours), line.formattedNarrative].map { tabSanitize(formulaHardened($0)) }
            rows.append(columns.joined(separator: "\t"))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    /// Renders fee lines as a copy/paste-ready Markdown table with the columns used by
    /// the weekly-timekeeper workflow: `DATE | CLIENT / MATTER | MATTER NO. | NARRATIVE
    /// | TIME`. Dates are `MM/DD/YYYY`; time is one decimal place.
    public static func weeklyTable(lines: [BillingLine]) -> String {
        var rows = [
            "| DATE | CLIENT / MATTER | MATTER NO. | NARRATIVE | TIME |",
            "|---|---|---|---|---:|"
        ]
        for line in lines {
            let clientMatter = line.matterDisplay ?? line.clientDisplay ?? line.clientID ?? ""
            let matterNo = line.lawFirmMatterID ?? line.clientMatterID ?? ""
            let cells = [usDate(line.workDate), clientMatter, matterNo, line.formattedNarrative]
                .map(mdCell)
            rows.append("| " + cells.joined(separator: " | ") + " | " + oneDecimal(line.hours) + " |")
        }
        return rows.joined(separator: "\n") + "\n"
    }

    // MARK: - Narrative terminal punctuation

    /// Normalizes a narrative's terminal punctuation for export. `.asWritten` returns
    /// the narrative verbatim (no behavior change); `.noPeriod` strips a trailing
    /// period/semicolon; `.semicolon` ensures a single trailing semicolon (so an entry
    /// ending "(split)" becomes "(split);").
    public static func formatNarrative(_ narrative: String, terminal: BillingNarrativeTerminal) -> String {
        switch terminal {
        case .asWritten:
            return narrative
        case .noPeriod:
            return stripTerminalPunctuation(narrative)
        case .semicolon:
            return stripTerminalPunctuation(narrative) + ";"
        }
    }

    /// Trims trailing whitespace and any trailing run of `.`/`;` characters.
    static func stripTerminalPunctuation(_ value: String) -> String {
        var result = value
        while let last = result.last, last == "." || last == ";" || last == " " || last == "\t" {
            result.removeLast()
        }
        return result
    }

    // MARK: - Formatting helpers

    /// `yyyy-MM-dd` → `MM/DD/YYYY`, string-only so there's no timezone ambiguity.
    static func usDate(_ iso: String) -> String {
        let parts = iso.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return iso }
        return "\(parts[1])/\(parts[2])/\(parts[0])"
    }

    /// Hours to a fixed one decimal place (1.0 → "1.0", 0.5 → "0.5").
    static func oneDecimal(_ value: Double) -> String { String(format: "%.1f", value) }

    /// A Markdown table cell: escape pipes and collapse newlines so the row stays intact.
    static func mdCell(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    static func compactDate(_ date: String) -> String { date.replacingOccurrences(of: "-", with: "") }
    static func money(_ value: Double) -> String { String(format: "%.2f", value) }

    /// Human-friendly hours (trailing zeros trimmed): 0.60 -> "0.6", 1.00 -> "1", 0.25 -> "0.25".
    public static func hoursString(_ value: Double) -> String {
        var string = String(format: "%.2f", value)
        if string.contains(".") {
            while string.hasSuffix("0") { string.removeLast() }
            if string.hasSuffix(".") { string.removeLast() }
        }
        return string
    }

    /// LEDES/TSV fields must not contain the delimiter or newlines.
    static func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "/")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    static func tabSanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    static func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    /// A CSV cell: formula-injection-hardened, then delimiter-escaped.
    static func csvCell(_ value: String) -> String { csvEscape(formulaHardened(value)) }

    /// Neutralizes spreadsheet formula injection: a cell beginning with `= + - @`
    /// (or a tab/CR control char) is prefixed with an apostrophe so spreadsheets
    /// import it as literal text rather than evaluating it as a formula.
    static func formulaHardened(_ value: String) -> String {
        guard let first = value.first, "=+-@\t\r".contains(first) else { return value }
        return "'" + value
    }
}
