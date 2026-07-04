import Foundation

/// SEC EDGAR normalization: works DIRECTLY on `JSONValue` (no intermediate
/// Codable DTO layer — raw-first normalization means nothing the mapper does
/// not understand is ever dropped, and SEC's columnar `filings.recent` shape
/// zips more naturally from raw arrays than through fixed structs).
enum SecEdgarNormalizer {
    /// Bounded flattened-fact summaries (plan amendment #7): the FULL raw
    /// payload always survives on the response model; only the convenience
    /// summary array is capped.
    static let factSummaryCap = 500

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    // MARK: - Submissions

    static func submissions(
        from payload: JSONValue,
        cik: String,
        sourceUrl: String,
        retrievedAt: Date,
        operation: String
    ) throws -> SecCompanySubmissions {
        guard let object = payload.objectValue else {
            throw SecEdgarErrorMapping.parseError(operation: operation, sourceURL: sourceUrl)
        }
        var warnings: [String] = []
        let company = companyRecord(from: payload, cik: cik, sourceUrl: sourceUrl, retrievedAt: retrievedAt)

        var filings: [SecFilingRecord] = []
        var continuationFileNames: [String] = []
        if let filingsObject = object["filings"]?.objectValue {
            if let recent = filingsObject["recent"] {
                filings = zipColumnarFilings(
                    recent,
                    company: company,
                    sourceUrl: sourceUrl,
                    retrievedAt: retrievedAt,
                    warnings: &warnings
                )
            }
            if let files = filingsObject["files"]?.arrayValue {
                continuationFileNames = files.compactMap { $0["name"]?.stringValue }
            }
        }
        return SecCompanySubmissions(
            company: company,
            recentFilings: filings,
            continuationFileNames: continuationFileNames,
            warnings: warnings,
            sourceUrl: sourceUrl,
            retrievedAt: retrievedAt,
            raw: payload
        )
    }

    static func companyRecord(
        from payload: JSONValue,
        cik: String,
        sourceUrl: String,
        retrievedAt: Date
    ) -> SecCompanyRecord {
        SecCompanyRecord(
            cik: cik,
            entityName: nonEmpty(payload["name"]?.stringValue),
            tickers: stringArray(payload["tickers"]),
            exchanges: stringArray(payload["exchanges"]),
            sic: nonEmpty(payload["sic"]?.scalarString),
            sicDescription: nonEmpty(payload["sicDescription"]?.stringValue),
            ein: nonEmpty(payload["ein"]?.scalarString),
            category: nonEmpty(payload["category"]?.stringValue),
            fiscalYearEnd: nonEmpty(payload["fiscalYearEnd"]?.stringValue),
            stateOfIncorporation: nonEmpty(payload["stateOfIncorporation"]?.stringValue),
            stateOfIncorporationDescription: nonEmpty(payload["stateOfIncorporationDescription"]?.stringValue),
            addresses: payload["addresses"],
            phone: nonEmpty(payload["phone"]?.scalarString),
            formerNames: payload["formerNames"],
            insiderTransactionForOwnerExists: flagValue(payload["insiderTransactionForOwnerExists"]),
            insiderTransactionForIssuerExists: flagValue(payload["insiderTransactionForIssuerExists"]),
            sourceUrl: sourceUrl,
            retrievedAt: retrievedAt,
            raw: payload
        )
    }

    /// SEC ships filings as parallel column arrays. Rows are zipped by index up
    /// to the LONGEST column; a row missing its accession number can't be
    /// addressed or deduplicated, so it is skipped with a warning rather than
    /// crashing the whole normalization.
    static func zipColumnarFilings(
        _ recent: JSONValue,
        company: SecCompanyRecord,
        sourceUrl: String,
        retrievedAt: Date,
        warnings: inout [String]
    ) -> [SecFilingRecord] {
        guard let columns = recent.objectValue else { return [] }
        let arrays = columns.compactMapValues { $0.arrayValue }
        guard let accessions = arrays["accessionNumber"] else { return [] }
        let rowCount = arrays.values.map(\.count).max() ?? 0
        if Set(arrays.values.map(\.count)).count > 1 {
            warnings.append("Columnar filing arrays had differing lengths; rows normalized up to the longest column.")
        }

        func cell(_ column: String, _ index: Int) -> JSONValue? {
            guard let array = arrays[column], index < array.count else { return nil }
            let value = array[index]
            if case .null = value { return nil }
            return value
        }

        var records: [SecFilingRecord] = []
        var skipped = 0
        for index in 0..<rowCount {
            guard index < accessions.count,
                  let accession = nonEmpty(accessions[index].stringValue) else {
                skipped += 1
                continue
            }
            // Reconstruct the row as column → value for raw preservation.
            var row: [String: JSONValue] = [:]
            for column in columns.keys {
                if let value = cell(column, index) { row[column] = value }
            }
            let primaryDocument = nonEmpty(cell("primaryDocument", index)?.stringValue)
            let urls = try? SecEdgarConnector.buildFilingUrl(
                cik: company.cik,
                accessionNumber: accession,
                primaryDocument: primaryDocument
            )
            records.append(SecFilingRecord(
                cik: company.cik,
                entityName: company.entityName,
                tickers: company.tickers,
                exchanges: company.exchanges,
                sic: company.sic,
                sicDescription: company.sicDescription,
                ein: company.ein,
                formerNames: company.formerNames,
                accessionNumber: accession,
                filingDate: nonEmpty(cell("filingDate", index)?.stringValue),
                reportDate: nonEmpty(cell("reportDate", index)?.stringValue),
                acceptanceDateTime: nonEmpty(cell("acceptanceDateTime", index)?.stringValue),
                act: nonEmpty(cell("act", index)?.scalarString),
                form: nonEmpty(cell("form", index)?.stringValue),
                fileNumber: nonEmpty(cell("fileNumber", index)?.stringValue),
                filmNumber: nonEmpty(cell("filmNumber", index)?.scalarString),
                items: nonEmpty(cell("items", index)?.stringValue),
                size: cell("size", index)?.numberValue.map(Int.init),
                isXbrl: flagValue(cell("isXBRL", index)),
                isInlineXbrl: flagValue(cell("isInlineXBRL", index)),
                primaryDocument: primaryDocument,
                primaryDocDescription: nonEmpty(cell("primaryDocDescription", index)?.stringValue),
                filingUrl: urls?.filingUrl ?? "",
                primaryDocumentUrl: urls?.primaryDocumentUrl,
                sourceUrl: sourceUrl,
                retrievedAt: retrievedAt,
                raw: .object(row)
            ))
        }
        if skipped > 0 {
            warnings.append("Skipped \(skipped) filing row(s) with no accession number.")
        }
        return records
    }

    // MARK: - XBRL

    static func companyFacts(
        from payload: JSONValue,
        cik: String,
        sourceUrl: String,
        retrievedAt: Date,
        operation: String
    ) throws -> SecCompanyFacts {
        guard let object = payload.objectValue else {
            throw SecEdgarErrorMapping.parseError(operation: operation, sourceURL: sourceUrl)
        }
        let entityName = nonEmpty(object["entityName"]?.stringValue)
        var summaries: [SecXbrlRecord] = []
        var truncated = false
        outer: for (taxonomy, concepts) in (object["facts"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
            for (concept, conceptObject) in (concepts.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
                let label = nonEmpty(conceptObject["label"]?.stringValue)
                let description = nonEmpty(conceptObject["description"]?.stringValue)
                for (unit, facts) in (conceptObject["units"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
                    for fact in facts.arrayValue ?? [] {
                        if summaries.count >= factSummaryCap { truncated = true; break outer }
                        summaries.append(xbrlRecord(
                            fact: fact, recordType: "company_fact", cik: cik, entityName: entityName,
                            taxonomy: taxonomy, concept: concept, label: label, description: description,
                            unit: unit, sourceUrl: sourceUrl, retrievedAt: retrievedAt
                        ))
                    }
                }
            }
        }
        return SecCompanyFacts(
            cik: cik,
            entityName: entityName,
            factSummaries: summaries,
            isFactSummaryTruncated: truncated,
            sourceUrl: sourceUrl,
            retrievedAt: retrievedAt,
            raw: payload
        )
    }

    static func companyConcept(
        from payload: JSONValue,
        cik: String,
        taxonomy: String,
        concept: String,
        sourceUrl: String,
        retrievedAt: Date,
        operation: String
    ) throws -> SecCompanyConcept {
        guard let object = payload.objectValue else {
            throw SecEdgarErrorMapping.parseError(operation: operation, sourceURL: sourceUrl)
        }
        let entityName = nonEmpty(object["entityName"]?.stringValue)
        let label = nonEmpty(object["label"]?.stringValue)
        let description = nonEmpty(object["description"]?.stringValue)
        var summaries: [SecXbrlRecord] = []
        var truncated = false
        outer: for (unit, facts) in (object["units"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
            for fact in facts.arrayValue ?? [] {
                if summaries.count >= factSummaryCap { truncated = true; break outer }
                summaries.append(xbrlRecord(
                    fact: fact, recordType: "company_concept", cik: cik, entityName: entityName,
                    taxonomy: taxonomy, concept: concept, label: label, description: description,
                    unit: unit, sourceUrl: sourceUrl, retrievedAt: retrievedAt
                ))
            }
        }
        return SecCompanyConcept(
            cik: cik,
            entityName: entityName,
            taxonomy: taxonomy,
            concept: concept,
            label: label,
            conceptDescription: description,
            factSummaries: summaries,
            isFactSummaryTruncated: truncated,
            sourceUrl: sourceUrl,
            retrievedAt: retrievedAt,
            raw: payload
        )
    }

    static func frame(
        from payload: JSONValue,
        taxonomy: String,
        concept: String,
        unit: String,
        frame: String,
        sourceUrl: String,
        retrievedAt: Date,
        operation: String
    ) throws -> SecFrame {
        guard let object = payload.objectValue else {
            throw SecEdgarErrorMapping.parseError(operation: operation, sourceURL: sourceUrl)
        }
        let label = nonEmpty(object["label"]?.stringValue)
        let description = nonEmpty(object["description"]?.stringValue)
        var summaries: [SecXbrlRecord] = []
        var truncated = false
        for fact in object["data"]?.arrayValue ?? [] {
            if summaries.count >= factSummaryCap { truncated = true; break }
            var record = xbrlRecord(
                fact: fact, recordType: "frame", cik: fact["cik"]?.scalarString,
                entityName: nonEmpty(fact["entityName"]?.stringValue),
                taxonomy: taxonomy, concept: concept, label: label, description: description,
                unit: unit, sourceUrl: sourceUrl, retrievedAt: retrievedAt
            )
            if record.period == nil { record.period = frame }
            summaries.append(record)
        }
        return SecFrame(
            taxonomy: taxonomy,
            concept: concept,
            unit: unit,
            frame: frame,
            label: label,
            conceptDescription: description,
            factSummaries: summaries,
            isFactSummaryTruncated: truncated,
            sourceUrl: sourceUrl,
            retrievedAt: retrievedAt,
            raw: payload
        )
    }

    private static func xbrlRecord(
        fact: JSONValue,
        recordType: String,
        cik: String?,
        entityName: String?,
        taxonomy: String?,
        concept: String?,
        label: String?,
        description: String?,
        unit: String?,
        sourceUrl: String,
        retrievedAt: Date
    ) -> SecXbrlRecord {
        let start = nonEmpty(fact["start"]?.stringValue)
        let end = nonEmpty(fact["end"]?.stringValue)
        let period: String?
        switch (start, end) {
        case let (start?, end?): period = "\(start)/\(end)"
        case let (nil, end?): period = end
        case let (start?, nil): period = start
        default: period = nil
        }
        return SecXbrlRecord(
            sourceRecordType: recordType,
            cik: cik,
            entityName: entityName ?? nonEmpty(fact["entityName"]?.stringValue),
            taxonomy: taxonomy,
            concept: concept,
            label: label,
            conceptDescription: description,
            unit: unit,
            period: period,
            fiscalYear: fact["fy"]?.numberValue.map(Int.init),
            fiscalPeriod: nonEmpty(fact["fp"]?.stringValue),
            form: nonEmpty(fact["form"]?.stringValue),
            filedDate: nonEmpty(fact["filed"]?.stringValue),
            accessionNumber: nonEmpty(fact["accn"]?.stringValue),
            value: fact["val"],
            sourceUrl: sourceUrl,
            retrievedAt: retrievedAt,
            raw: fact
        )
    }

    // MARK: - RAG text

    /// Neutral, source-attributed filing text. Empty fields are OMITTED — no
    /// placeholders — and the template never characterizes legal significance.
    static func ragText(for filing: SecFilingRecord) -> String {
        var lines: [String] = ["SEC EDGAR filing record."]
        var companyLine = "Company: " + (filing.entityName ?? "CIK \(filing.cik)")
        if filing.entityName != nil { companyLine += " (CIK \(filing.cik))" }
        if !filing.tickers.isEmpty { companyLine += ", tickers: \(filing.tickers.joined(separator: ", "))" }
        lines.append(companyLine + ".")
        if let form = filing.form {
            var formLine = "Form: \(form)"
            if let date = filing.filingDate { formLine += ", filed \(date)" }
            lines.append(formLine + ".")
        } else if let date = filing.filingDate {
            lines.append("Filed \(date).")
        }
        lines.append("Accession number: \(filing.accessionNumber).")
        if let reportDate = filing.reportDate { lines.append("Period of report: \(reportDate).") }
        if let items = filing.items { lines.append("Items: \(items).") }
        if let document = filing.primaryDocument {
            var documentLine = "Primary document: \(document)"
            if let description = filing.primaryDocDescription { documentLine += " — \(description)" }
            lines.append(documentLine + ".")
        }
        if !filing.filingUrl.isEmpty { lines.append("Filing archive: \(filing.filingUrl)") }
        lines.append("Source: \(filing.sourceUrl) (retrieved \(dayFormatter.string(from: filing.retrievedAt))).")
        return lines.joined(separator: "\n")
    }

    static func ragText(for record: SecXbrlRecord) -> String {
        var lines: [String] = ["SEC EDGAR XBRL fact."]
        if let entity = record.entityName {
            lines.append("Entity: \(entity)\(record.cik.map { " (CIK \($0))" } ?? "").")
        } else if let cik = record.cik {
            lines.append("Entity: CIK \(cik).")
        }
        if let concept = record.concept {
            lines.append("Concept: \(record.taxonomy.map { "\($0)/" } ?? "")\(concept)\(record.label.map { " (\($0))" } ?? "").")
        }
        if let value = record.value?.scalarString {
            var valueLine = "Reported value: \(value)"
            if let unit = record.unit { valueLine += " \(unit)" }
            if let period = record.period { valueLine += " for \(period)" }
            lines.append(valueLine + ".")
        }
        if let form = record.form {
            var formLine = "Reported on form \(form)"
            if let filed = record.filedDate { formLine += ", filed \(filed)" }
            lines.append(formLine + ".")
        }
        if let accession = record.accessionNumber { lines.append("Accession number: \(accession).") }
        lines.append("Source: \(record.sourceUrl) (retrieved \(dayFormatter.string(from: record.retrievedAt))).")
        return lines.joined(separator: "\n")
    }

    // MARK: - Small shared coercions

    /// SEC uses empty strings for absent values; those normalize to nil.
    static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Flags arrive as 0/1 numbers or booleans depending on the endpoint.
    static func flagValue(_ value: JSONValue?) -> Bool? {
        switch value {
        case .bool(let flag): return flag
        case .number(let number): return number != 0
        default: return nil
        }
    }

    private static func stringArray(_ value: JSONValue?) -> [String] {
        (value?.arrayValue ?? []).compactMap { $0.stringValue }.filter { !$0.isEmpty }
    }
}
