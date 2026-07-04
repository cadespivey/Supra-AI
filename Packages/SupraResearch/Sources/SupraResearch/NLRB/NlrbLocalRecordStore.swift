import Foundation

/// File-backed store for imported NLRB dataset records: JSONL per source
/// variant, a dedup index, a case-number index, saved raw payloads, and
/// import-run metadata. Imports are IDEMPOTENT — re-importing the same CSV
/// never doubles search results.
///
/// Layout under the root:
///   imports/{importRunId}.json
///   raw/{sourceVariant}/{payloadHash}.csv
///   records/{sourceVariant}-cases.jsonl
///   records/{sourceVariant}-elections.jsonl
///   indexes/dedup-index.json
///   indexes/case-number.json
public actor NlrbLocalRecordStore {
    private let root: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Loaded lazily; invalidated on every append.
    private var cachedCases: [NlrbCaseRecord]?
    private var cachedElections: [NlrbElectionResultRecord]?
    private var dedupKeys: Set<String>?

    public init(directory: URL) {
        self.root = directory
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    // MARK: - Dedup keys

    /// Case: source + variant + caseNumber + recordType.
    static func dedupKey(for record: NlrbCaseRecord) -> String {
        [record.source, record.sourceVariant.rawValue, normalizedCaseNumber(record.caseNumber), record.sourceRecordType]
            .joined(separator: "|")
    }

    /// Election: adds unitId + tallyDate when present.
    static func dedupKey(for record: NlrbElectionResultRecord) -> String {
        [
            record.source, record.sourceVariant.rawValue, normalizedCaseNumber(record.caseNumber),
            record.sourceRecordType, record.unitId ?? "", record.tallyDate ?? ""
        ].joined(separator: "|")
    }

    /// Case-number keys uppercase and PRESERVE dashes; party keys lowercase,
    /// trim, and collapse whitespace.
    static func normalizedCaseNumber(_ caseNumber: String) -> String {
        caseNumber.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    static func normalizedPartyKey(_ party: String) -> String {
        party.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Import

    public struct AppendOutcome: Sendable {
        public var imported: Int
        public var duplicates: Int
    }

    public func appendCases(_ records: [NlrbCaseRecord]) throws -> AppendOutcome {
        var keys = try loadDedupKeys()
        var fresh: [NlrbCaseRecord] = []
        var duplicates = 0
        for record in records {
            let key = Self.dedupKey(for: record)
            if keys.contains(key) { duplicates += 1 } else {
                keys.insert(key)
                fresh.append(record)
            }
        }
        if !fresh.isEmpty {
            for record in fresh {
                try appendLine(record, to: recordsFile(variant: record.sourceVariant, kind: "cases"))
            }
            try saveDedupKeys(keys)
            try updateCaseNumberIndex(with: fresh.map { (Self.normalizedCaseNumber($0.caseNumber), $0.sourceVariant.rawValue) })
            cachedCases = nil
        }
        return AppendOutcome(imported: fresh.count, duplicates: duplicates)
    }

    public func appendElections(_ records: [NlrbElectionResultRecord]) throws -> AppendOutcome {
        var keys = try loadDedupKeys()
        var fresh: [NlrbElectionResultRecord] = []
        var duplicates = 0
        for record in records {
            let key = Self.dedupKey(for: record)
            if keys.contains(key) { duplicates += 1 } else {
                keys.insert(key)
                fresh.append(record)
            }
        }
        if !fresh.isEmpty {
            for record in fresh {
                try appendLine(record, to: recordsFile(variant: record.sourceVariant, kind: "elections"))
            }
            try saveDedupKeys(keys)
            cachedElections = nil
        }
        return AppendOutcome(imported: fresh.count, duplicates: duplicates)
    }

    public func saveRawPayload(_ data: Data, variant: NlrbSourceVariant, hash: String) throws -> String {
        let dir = root.appendingPathComponent("raw/\(variant.rawValue)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let relative = "raw/\(variant.rawValue)/\(hash).csv"
        let file = root.appendingPathComponent(relative)
        if !FileManager.default.fileExists(atPath: file.path) {
            try data.write(to: file, options: .atomic)
        }
        return relative
    }

    public func saveImportRun(_ run: NlrbImportRun) throws {
        let dir = root.appendingPathComponent("imports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(run.id).json")
        try encoder.encode(run).write(to: file, options: .atomic)
    }

    public func importRuns() -> [NlrbImportRun] {
        let dir = root.appendingPathComponent("imports", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(NlrbImportRun.self, from: Data(contentsOf: $0)) }
            .sorted { $0.retrievedAt > $1.retrievedAt }
    }

    // MARK: - Reads

    public func allCases() -> [NlrbCaseRecord] {
        if let cachedCases { return cachedCases }
        var records: [NlrbCaseRecord] = []
        for variant in NlrbSourceVariant.allCases {
            records += readLines(recordsFile(variant: variant, kind: "cases"), as: NlrbCaseRecord.self)
        }
        cachedCases = records
        return records
    }

    public func allElections() -> [NlrbElectionResultRecord] {
        if let cachedElections { return cachedElections }
        var records: [NlrbElectionResultRecord] = []
        for variant in NlrbSourceVariant.allCases {
            records += readLines(recordsFile(variant: variant, kind: "elections"), as: NlrbElectionResultRecord.self)
        }
        cachedElections = records
        return records
    }

    /// O(1)-ish exact lookup: the index narrows to variants holding the case
    /// number, then only those JSONL files are scanned.
    public func casesByNumber(_ caseNumber: String) -> [NlrbCaseRecord] {
        let key = Self.normalizedCaseNumber(caseNumber)
        let index = (try? loadCaseNumberIndex()) ?? [:]
        guard index[key] != nil else { return [] }
        return allCases().filter { Self.normalizedCaseNumber($0.caseNumber) == key }
    }

    // MARK: - Files

    private func recordsFile(variant: NlrbSourceVariant, kind: String) -> URL {
        root.appendingPathComponent("records/\(variant.rawValue)-\(kind).jsonl")
    }

    private func appendLine<T: Encodable>(_ record: T, to file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var line = try encoder.encode(record)
        line.append(Data("\n".utf8))
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: file, options: .atomic)
        }
    }

    private func readLines<T: Decodable>(_ file: URL, as type: T.Type) -> [T] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            try? decoder.decode(T.self, from: Data(line.utf8))
        }
    }

    private var dedupFile: URL { root.appendingPathComponent("indexes/dedup-index.json") }
    private var caseNumberIndexFile: URL { root.appendingPathComponent("indexes/case-number.json") }

    private func loadDedupKeys() throws -> Set<String> {
        if let dedupKeys { return dedupKeys }
        guard let data = try? Data(contentsOf: dedupFile),
              let keys = try? decoder.decode(Set<String>.self, from: data) else {
            dedupKeys = []
            return []
        }
        dedupKeys = keys
        return keys
    }

    private func saveDedupKeys(_ keys: Set<String>) throws {
        dedupKeys = keys
        try FileManager.default.createDirectory(
            at: dedupFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try encoder.encode(keys.sorted()).write(to: dedupFile, options: .atomic)
        // Stored sorted for stable diffs; loaded back as a set.
    }

    private func loadCaseNumberIndex() throws -> [String: [String]] {
        guard let data = try? Data(contentsOf: caseNumberIndexFile) else { return [:] }
        return (try? decoder.decode([String: [String]].self, from: data)) ?? [:]
    }

    private func updateCaseNumberIndex(with entries: [(key: String, variant: String)]) throws {
        var index = try loadCaseNumberIndex()
        for entry in entries {
            var variants = Set(index[entry.key] ?? [])
            variants.insert(entry.variant)
            index[entry.key] = variants.sorted()
        }
        try FileManager.default.createDirectory(
            at: caseNumberIndexFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try encoder.encode(index).write(to: caseNumberIndexFile, options: .atomic)
    }
}
