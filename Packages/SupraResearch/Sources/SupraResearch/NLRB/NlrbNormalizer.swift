import Foundation

/// NLRB CSV row → normalized record mapping and neutral RAG rendering. Header
/// aliases are matched case- and punctuation-insensitively; unmapped columns
/// survive in `raw`.
enum NlrbNormalizer {
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    // MARK: - Case rows (recent filings export)

    static func caseRecord(
        from row: [String: String],
        variant: NlrbSourceVariant,
        datasetUrl: String?,
        retrievedAt: Date
    ) -> NlrbCaseRecord? {
        guard let caseNumber = NlrbCSVImporter.value(in: row, aliases: ["Case Number", "case_number", "CaseNumber", "Case"]) else {
            return nil
        }
        let explicitType = NlrbCSVImporter.value(in: row, aliases: ["Case Type", "case_type"])
        let (code, category) = NlrbCaseClassifier.classify(caseNumber: caseNumber, explicitCaseType: explicitType)
        return NlrbCaseRecord(
            sourceVariant: variant,
            caseNumber: caseNumber,
            caseName: NlrbCSVImporter.value(in: row, aliases: ["Case Name", "case_name", "Name"]),
            caseType: code,
            caseTypeCategory: category,
            region: NlrbCSVImporter.value(in: row, aliases: ["Region", "Region Assigned", "region_assigned"]),
            status: NlrbCSVImporter.value(in: row, aliases: ["Status", "Case Status"]),
            dateFiled: NlrbCSVImporter.value(in: row, aliases: ["Date Filed", "date_filed", "Filed Date"]),
            employer: NlrbCSVImporter.value(in: row, aliases: ["Employer", "Employer Name"]),
            union: NlrbCSVImporter.value(in: row, aliases: ["Union", "Labor Organization", "Labor Org", "Union Name"]),
            city: NlrbCSVImporter.value(in: row, aliases: ["City"]),
            state: NlrbCSVImporter.value(in: row, aliases: ["State", "States & Territories"]),
            allegations: NlrbCSVImporter.value(in: row, aliases: ["Allegations", "Allegation"]),
            reasonClosed: NlrbCSVImporter.value(in: row, aliases: ["Reason Closed", "reason_closed"]),
            sourceUrl: NlrbSources.casePageURLString(caseNumber: caseNumber),
            datasetUrl: datasetUrl,
            retrievedAt: retrievedAt,
            raw: rawRow(row)
        )
    }

    // MARK: - Election rows (recent election results export)

    static func electionRecord(
        from row: [String: String],
        variant: NlrbSourceVariant,
        datasetUrl: String?,
        retrievedAt: Date
    ) -> NlrbElectionResultRecord? {
        guard let caseNumber = NlrbCSVImporter.value(in: row, aliases: ["Case Number", "case_number", "Case"]) else {
            return nil
        }
        let explicitType = NlrbCSVImporter.value(in: row, aliases: ["Case Type", "case_type"])
        let (code, category) = NlrbCaseClassifier.classify(caseNumber: caseNumber, explicitCaseType: explicitType)
        return NlrbElectionResultRecord(
            sourceVariant: variant,
            caseNumber: caseNumber,
            caseName: NlrbCSVImporter.value(in: row, aliases: ["Case Name", "Name"]),
            caseType: code,
            caseTypeCategory: category,
            region: NlrbCSVImporter.value(in: row, aliases: ["Region"]),
            city: NlrbCSVImporter.value(in: row, aliases: ["City"]),
            state: NlrbCSVImporter.value(in: row, aliases: ["State"]),
            unitId: NlrbCSVImporter.value(in: row, aliases: ["Unit ID", "unit_id"]),
            tallyDate: NlrbCSVImporter.value(in: row, aliases: ["Tally Date", "tally_date", "Date Tally Issued"]),
            electionType: NlrbCSVImporter.value(in: row, aliases: ["Election Type", "Ballot Type"]),
            union: NlrbCSVImporter.value(in: row, aliases: ["Labor Organization", "Union", "Labor Org", "Petitioner"]),
            votesFor: intValue(in: row, aliases: ["Votes For", "Votes for Labor Org", "Union Yes Votes"]),
            votesAgainst: intValue(in: row, aliases: ["Votes Against", "Against Votes", "No Votes"]),
            totalBallotsCounted: intValue(in: row, aliases: ["Total Ballots Counted", "Valid Votes Counted"]),
            unitSize: intValue(in: row, aliases: ["Unit Size"]),
            eligibleVoters: intValue(in: row, aliases: ["Eligible Voters", "Number of Eligible Voters"]),
            certifiedRepresentative: NlrbCSVImporter.value(in: row, aliases: ["Certified Representative", "Certified Rep"]),
            sourceUrl: NlrbSources.casePageURLString(caseNumber: caseNumber),
            datasetUrl: datasetUrl,
            retrievedAt: retrievedAt,
            raw: rawRow(row)
        )
    }

    // MARK: - Dates

    /// NLRB exports use `MM/dd/yyyy`; ISO days are accepted too. Comparisons
    /// happen on parsed dates only — unparseable dates never silently match.
    static func parseDay(_ value: String?) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            return dayFormatter.date(from: value)
        }
        if value.range(of: #"^\d{1,2}/\d{1,2}/\d{4}$"#, options: .regularExpression) != nil {
            let parts = value.split(separator: "/").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            return dayFormatter.date(from: String(format: "%04d-%02d-%02d", parts[2], parts[0], parts[1]))
        }
        return nil
    }

    // MARK: - RAG text

    /// Neutral case rendering: filings and allegations are described as
    /// FILED/ALLEGED, never as findings; missing fields are omitted.
    static func ragText(for record: NlrbCaseRecord) -> String {
        var lines: [String] = ["NLRB case record (case number \(record.caseNumber))."]
        if let name = record.caseName { lines.append("Case name: \(name).") }
        var typeLine: [String] = []
        if let type = record.caseType { typeLine.append("type \(type)") }
        if record.caseTypeCategory != .unknown {
            typeLine.append(record.caseTypeCategory.rawValue.replacingOccurrences(of: "_", with: " "))
        }
        if !typeLine.isEmpty { lines.append("Case \(typeLine.joined(separator: ", ")).") }
        if let filed = record.dateFiled { lines.append("Filed: \(filed).") }
        if let region = record.region { lines.append("Region: \(region).") }
        if let employer = record.employer { lines.append("Employer named in the filing: \(employer).") }
        if let union = record.union { lines.append("Labor organization named in the filing: \(union).") }
        if let city = record.city, let state = record.state {
            lines.append("Location: \(city), \(state).")
        } else if let state = record.state {
            lines.append("Location: \(state).")
        }
        if let allegations = record.allegations {
            lines.append("Allegations as categorized in the filing: \(allegations).")
        }
        if let status = record.status { lines.append("Status per the export: \(status).") }
        if let reason = record.reasonClosed { lines.append("Reason closed per the export: \(reason).") }
        lines.append("Case page: \(record.sourceUrl)")
        lines.append("Source: official NLRB export\(record.datasetUrl.map { " (\($0))" } ?? "") retrieved \(dayFormatter.string(from: record.retrievedAt)).")
        return lines.joined(separator: "\n")
    }

    static func ragText(for record: NlrbElectionResultRecord) -> String {
        var lines: [String] = ["NLRB election result record (case number \(record.caseNumber))."]
        if let name = record.caseName { lines.append("Case name: \(name).") }
        if let union = record.union { lines.append("Labor organization: \(union).") }
        if let tally = record.tallyDate { lines.append("Tally date: \(tally).") }
        if let electionType = record.electionType { lines.append("Election type: \(electionType).") }
        var votes: [String] = []
        if let votesFor = record.votesFor { votes.append("\(votesFor) for") }
        if let votesAgainst = record.votesAgainst { votes.append("\(votesAgainst) against") }
        if !votes.isEmpty {
            var voteLine = "Tally: \(votes.joined(separator: ", "))"
            if let total = record.totalBallotsCounted { voteLine += " of \(total) ballots counted" }
            lines.append(voteLine + ".")
        }
        if let eligible = record.eligibleVoters { lines.append("Eligible voters: \(eligible).") }
        if let certified = record.certifiedRepresentative {
            lines.append("Certified representative per the export: \(certified).")
        }
        if let region = record.region { lines.append("Region: \(region).") }
        if let city = record.city, let state = record.state { lines.append("Location: \(city), \(state).") }
        lines.append("Case page: \(record.sourceUrl)")
        lines.append("Source: official NLRB export\(record.datasetUrl.map { " (\($0))" } ?? "") retrieved \(dayFormatter.string(from: record.retrievedAt)).")
        return lines.joined(separator: "\n")
    }

    // MARK: - Shared

    static func rawRow(_ row: [String: String]) -> JSONValue {
        .object(row.mapValues { .string($0) })
    }

    private static func intValue(in row: [String: String], aliases: [String]) -> Int? {
        guard let value = NlrbCSVImporter.value(in: row, aliases: aliases) else { return nil }
        return Int(value.replacingOccurrences(of: ",", with: ""))
    }
}
