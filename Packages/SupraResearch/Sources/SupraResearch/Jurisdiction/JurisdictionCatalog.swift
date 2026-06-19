import Foundation

public enum JurisdictionSystem: String, Codable, CaseIterable, Sendable {
    case federal
    case state

    public var displayName: String {
        switch self {
        case .federal: "Federal"
        case .state: "State"
        }
    }
}

public enum JurisdictionCourtLevel: String, Codable, CaseIterable, Sendable {
    case jurisdiction
    case supreme
    case intermediateAppellate
    case federalAppellate
    case federalTrial
    case bankruptcy
    case trial
    case administrative
    case specialty

    public var displayName: String {
        switch self {
        case .jurisdiction: "Jurisdiction"
        case .supreme: "Supreme Court"
        case .intermediateAppellate: "Intermediate Appellate"
        case .federalAppellate: "Federal Appellate"
        case .federalTrial: "Federal Trial"
        case .bankruptcy: "Bankruptcy"
        case .trial: "Trial"
        case .administrative: "Administrative"
        case .specialty: "Specialty"
        }
    }
}

public struct JurisdictionOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let jurisdictionName: String
    public let courtName: String
    public let system: JurisdictionSystem
    public let level: JurisdictionCourtLevel
    public let state: String?
    public let county: String?
    public let judicialCircuit: String?
    public let courtListenerIDs: [String]

    public init(
        id: String,
        displayName: String,
        jurisdictionName: String,
        courtName: String,
        system: JurisdictionSystem,
        level: JurisdictionCourtLevel,
        state: String? = nil,
        county: String? = nil,
        judicialCircuit: String? = nil,
        courtListenerIDs: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.jurisdictionName = jurisdictionName
        self.courtName = courtName
        self.system = system
        self.level = level
        self.state = state
        self.county = county
        self.judicialCircuit = judicialCircuit
        self.courtListenerIDs = courtListenerIDs
    }

    public var menuTitle: String {
        let suffix = [state, county]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " - ")
        return suffix.isEmpty ? displayName : "\(displayName) (\(suffix))"
    }

    var searchableText: String {
        [
            id,
            displayName,
            jurisdictionName,
            courtName,
            system.displayName,
            level.displayName,
            state,
            county,
            judicialCircuit,
            courtListenerIDs.joined(separator: " ")
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }
}

public struct JurisdictionAuthorityScope: Hashable, Sendable {
    public let selectedCourtName: String
    public let jurisdictionName: String
    public let mandatoryAuthorities: [String]
    public let persuasiveAuthorities: [String]
    public let courtListenerIDs: [String]

    public init(
        selectedCourtName: String,
        jurisdictionName: String,
        mandatoryAuthorities: [String],
        persuasiveAuthorities: [String] = [],
        courtListenerIDs: [String] = []
    ) {
        self.selectedCourtName = selectedCourtName
        self.jurisdictionName = jurisdictionName
        self.mandatoryAuthorities = mandatoryAuthorities
        self.persuasiveAuthorities = persuasiveAuthorities
        self.courtListenerIDs = courtListenerIDs
    }

    public var preferredCourtNames: [String] {
        uniquePreservingOrder([selectedCourtName] + mandatoryAuthorities)
    }

    public var modelContext: String {
        let mandatory = mandatoryAuthorities.isEmpty
            ? "Unspecified; ask the user to confirm governing jurisdiction before treating authority as binding."
            : mandatoryAuthorities.joined(separator: "; ")
        let persuasive = persuasiveAuthorities.isEmpty
            ? "Other jurisdictions only after binding authority is exhausted or unavailable."
            : persuasiveAuthorities.joined(separator: "; ")
        let filters = courtListenerIDs.isEmpty
            ? "No reliable CourtListener court filters inferred from this selection."
            : courtListenerIDs.joined(separator: ", ")
        return """
        Jurisdiction selection:
        - Selected court or scope: \(selectedCourtName)
        - Governing jurisdiction: \(jurisdictionName)
        - Mandatory/controlling authorities to prioritize: \(mandatory)
        - Persuasive or supplemental authorities: \(persuasive)
        - CourtListener court filters when available: \(filters)
        Verify current jurisdiction-specific hierarchy, local rules, and issue-specific federal/state boundaries before relying on the final analysis.
        """
    }
}

public struct JurisdictionCatalog: Sendable {
    public static let shared = JurisdictionCatalog()

    public let options: [JurisdictionOption]
    private let optionByID: [String: JurisdictionOption]

    public init(text: String? = nil) {
        let parsed = Self.parse(text ?? Self.loadBundledCourtList())
        self.options = parsed
        self.optionByID = Dictionary(uniqueKeysWithValues: parsed.map { ($0.id, $0) })
    }

    public func option(id: String) -> JurisdictionOption? {
        optionByID[id]
    }

    public func search(_ query: String, limit: Int = 80) -> [JurisdictionOption] {
        let normalized = Self.normalized(query)
        guard !normalized.isEmpty else {
            return Array(options.prefix(limit))
        }
        let terms = normalized.split(separator: " ").map(String.init)
        let matches = options.filter { option in
            let haystack = Self.normalized(option.searchableText)
            return terms.allSatisfy { haystack.contains($0) }
        }
        .sorted { lhs, rhs in
            let left = score(lhs, query: normalized)
            let right = score(rhs, query: normalized)
            if left != right { return left > right }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
        return Array(matches.prefix(limit))
    }

    public func bestMatch(jurisdiction: String, court: String? = nil) -> JurisdictionOption? {
        let normalizedJurisdiction = Self.normalized(jurisdiction)
        let normalizedCourt = Self.normalized(court ?? "")

        if !normalizedCourt.isEmpty {
            if let exact = options.first(where: { Self.normalized($0.courtName) == normalizedCourt }) {
                return exact
            }
            if let exact = options.first(where: { Self.normalized($0.displayName) == normalizedCourt }) {
                return exact
            }
            if let scoped = options.first(where: {
                Self.normalized($0.jurisdictionName) == normalizedJurisdiction
                    && Self.normalized($0.courtName).contains(normalizedCourt)
            }) {
                return scoped
            }
            if let loose = search(court ?? "", limit: 1).first {
                return loose
            }
        }

        guard !normalizedJurisdiction.isEmpty else { return nil }
        if let exact = options.first(where: { Self.normalized($0.jurisdictionName) == normalizedJurisdiction && $0.level == .jurisdiction }) {
            return exact
        }
        return options.first { Self.normalized($0.displayName) == normalizedJurisdiction }
    }

    public func authorityScope(for option: JurisdictionOption) -> JurisdictionAuthorityScope {
        switch option.system {
        case .federal:
            return federalScope(for: option)
        case .state:
            return stateScope(for: option)
        }
    }

    public func authorityScope(jurisdiction: String, court: String? = nil) -> JurisdictionAuthorityScope? {
        bestMatch(jurisdiction: jurisdiction, court: court).map(authorityScope(for:))
    }

    public static func courtFilterIDs(from filter: String?) -> [String] {
        uniquePreservingOrder(
            (filter ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    public static func courtFilterString(_ ids: [String]) -> String? {
        let value = uniquePreservingOrder(ids).joined(separator: ",")
        return value.isEmpty ? nil : value
    }

    private func stateScope(for option: JurisdictionOption) -> JurisdictionAuthorityScope {
        let state = option.state ?? option.jurisdictionName
        let supreme = stateSupremeCourtName(state)
        let appellate = stateIntermediateCourtNames(state)
        var mandatory = [supreme] + appellate
        if state == "Florida", let dca = floridaDistrictCourtOfAppeal(for: option) {
            mandatory = uniquePreservingOrder([dca] + mandatory)
        }
        mandatory.append("Supreme Court of the United States for federal questions")

        var ids = stateAuthorityCourtIDs[state] ?? option.courtListenerIDs
        if ids.isEmpty {
            ids = option.courtListenerIDs
        }
        ids.append("scotus")

        let persuasive = [
            "Other state appellate courts when no controlling decision exists",
            "Federal courts only for federal law, constitutional issues, or persuasive treatment of state law"
        ]
        return JurisdictionAuthorityScope(
            selectedCourtName: option.displayName,
            jurisdictionName: state,
            mandatoryAuthorities: uniquePreservingOrder(mandatory),
            persuasiveAuthorities: persuasive,
            courtListenerIDs: uniquePreservingOrder(ids)
        )
    }

    private func federalScope(for option: JurisdictionOption) -> JurisdictionAuthorityScope {
        if option.id == "federal-courts" {
            return JurisdictionAuthorityScope(
                selectedCourtName: option.displayName,
                jurisdictionName: "Federal",
                mandatoryAuthorities: ["Supreme Court of the United States", "Relevant United States Court of Appeals"],
                persuasiveAuthorities: ["Federal district courts and specialty tribunals as appropriate to the issue"],
                courtListenerIDs: []
            )
        }

        var mandatory: [String] = []
        var ids = option.courtListenerIDs
        if option.level == .federalAppellate {
            mandatory = [option.displayName, "Supreme Court of the United States"]
            ids.append("scotus")
        } else if let circuit = federalCircuit(for: option) {
            mandatory = [circuit.name, "Supreme Court of the United States"]
            ids.append(circuit.id)
            ids.append("scotus")
        } else {
            mandatory = ["Supreme Court of the United States", "Relevant United States Court of Appeals"]
            ids.append("scotus")
        }

        var persuasive = ["Other federal district courts on analogous issues"]
        if option.level == .federalTrial || option.level == .bankruptcy {
            persuasive.insert("\(option.displayName) opinions for same-court treatment and local practice", at: 0)
        }
        return JurisdictionAuthorityScope(
            selectedCourtName: option.displayName,
            jurisdictionName: option.jurisdictionName,
            mandatoryAuthorities: uniquePreservingOrder(mandatory),
            persuasiveAuthorities: persuasive,
            courtListenerIDs: uniquePreservingOrder(ids)
        )
    }

    private func stateSupremeCourtName(_ state: String) -> String {
        options.first {
            $0.state == state && $0.level == .supreme
        }?.displayName ?? "Supreme Court of \(state)"
    }

    private func stateIntermediateCourtNames(_ state: String) -> [String] {
        let names = options
            .filter { $0.state == state && $0.level == .intermediateAppellate }
            .map(\.displayName)
        if !names.isEmpty { return uniquePreservingOrder(names) }
        return ["Intermediate appellate courts of \(state)"]
    }

    private func floridaDistrictCourtOfAppeal(for option: JurisdictionOption) -> String? {
        guard option.state == "Florida", let judicialCircuit = option.judicialCircuit else { return nil }
        let normalizedCircuit = Self.normalized(judicialCircuit)
        let district: String?
        if ["first judicial circuit", "second judicial circuit", "third judicial circuit", "eighth judicial circuit", "fourteenth judicial circuit"].contains(normalizedCircuit) {
            district = "First District Court of Appeal of Florida"
        } else if ["sixth judicial circuit", "twelfth judicial circuit", "thirteenth judicial circuit"].contains(normalizedCircuit) {
            district = "Second District Court of Appeal of Florida"
        } else if ["eleventh judicial circuit", "sixteenth judicial circuit"].contains(normalizedCircuit) {
            district = "Third District Court of Appeal of Florida"
        } else if ["fifteenth judicial circuit", "seventeenth judicial circuit", "nineteenth judicial circuit"].contains(normalizedCircuit) {
            district = "Fourth District Court of Appeal of Florida"
        } else if ["fourth judicial circuit", "fifth judicial circuit", "seventh judicial circuit", "eighteenth judicial circuit"].contains(normalizedCircuit) {
            district = "Fifth District Court of Appeal of Florida"
        } else if ["ninth judicial circuit", "tenth judicial circuit", "twentieth judicial circuit"].contains(normalizedCircuit) {
            district = "Sixth District Court of Appeal of Florida"
        } else {
            district = nil
        }
        return district
    }

    private func federalCircuit(for option: JurisdictionOption) -> (name: String, id: String)? {
        if option.level == .federalAppellate, let id = option.courtListenerIDs.first {
            return (option.displayName, id)
        }
        if let state = option.state, let circuit = federalCircuitByState[state] {
            return circuit
        }
        if option.displayName.contains("District of Columbia") {
            return federalCircuitByState["District of Columbia"]
        }
        return nil
    }

    private func score(_ option: JurisdictionOption, query: String) -> Int {
        let display = Self.normalized(option.displayName)
        let court = Self.normalized(option.courtName)
        let jurisdiction = Self.normalized(option.jurisdictionName)
        if display == query || court == query || jurisdiction == query { return 100 }
        if display.hasPrefix(query) || court.hasPrefix(query) { return 80 }
        if option.level == .jurisdiction { return 50 }
        if option.level == .supreme || option.level == .intermediateAppellate || option.level == .federalAppellate { return 40 }
        return 10
    }
}

// MARK: - Parsing

private extension JurisdictionCatalog {
    enum Section {
        case none
        case federal
        case state
    }

    static func loadBundledCourtList() -> String {
        guard
            let url = Bundle.module.url(forResource: "jurisdiction-courts-v1", withExtension: "txt"),
            let content = try? String(contentsOf: url, encoding: .utf8)
        else {
            return ""
        }
        return content
    }

    static func parse(_ text: String) -> [JurisdictionOption] {
        var options: [JurisdictionOption] = []
        var usedIDs: [String: Int] = [:]
        var section: Section = .none
        var currentState: String?
        var emittedStateAggregates = Set<String>()

        func append(_ option: JurisdictionOption) {
            var option = option
            let baseID = option.id
            let occurrence = usedIDs[baseID, default: 0]
            usedIDs[baseID] = occurrence + 1
            if occurrence > 0 {
                option = JurisdictionOption(
                    id: "\(baseID)-\(occurrence + 1)",
                    displayName: option.displayName,
                    jurisdictionName: option.jurisdictionName,
                    courtName: option.courtName,
                    system: option.system,
                    level: option.level,
                    state: option.state,
                    county: option.county,
                    judicialCircuit: option.judicialCircuit,
                    courtListenerIDs: option.courtListenerIDs
                )
            }
            options.append(option)
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, line != "Federal and State Courts" else { continue }
            if line == "FEDERAL COURTS AND TRIBUNALS" {
                section = .federal
                append(
                    JurisdictionOption(
                        id: "federal-courts",
                        displayName: "Federal Courts",
                        jurisdictionName: "Federal",
                        courtName: "Federal Courts",
                        system: .federal,
                        level: .jurisdiction
                    )
                )
                continue
            }
            if line == "STATE, COUNTY, AND MUNICIPAL COURTS" {
                section = .state
                currentState = nil
                continue
            }
            if section == .state, let stateName = stateName(forHeader: line) {
                currentState = stateName
                if !emittedStateAggregates.contains(stateName) {
                    emittedStateAggregates.insert(stateName)
                    append(makeStateAggregateOption(stateName))
                }
                continue
            }

            switch section {
            case .federal:
                append(makeFederalOption(line))
            case .state:
                guard let currentState else { continue }
                append(makeStateOption(line, state: currentState))
            case .none:
                continue
            }
        }
        return options
    }

    static func makeFederalOption(_ name: String) -> JurisdictionOption {
        let state = federalState(in: name)
        let level = inferLevel(name, system: .federal)
        let ids = inferFederalCourtIDs(name, state: state, level: level)
        return JurisdictionOption(
            id: slug(["federal", state, name].compactMap { $0 }.joined(separator: " ")),
            displayName: name,
            jurisdictionName: federalJurisdictionName(for: name, state: state),
            courtName: name,
            system: .federal,
            level: level,
            state: state,
            county: nil,
            judicialCircuit: nil,
            courtListenerIDs: ids
        )
    }

    static func makeStateAggregateOption(_ state: String) -> JurisdictionOption {
        JurisdictionOption(
            id: slug("state \(state) courts"),
            displayName: "\(state) State Courts",
            jurisdictionName: state,
            courtName: "\(state) State Courts",
            system: .state,
            level: .jurisdiction,
            state: state,
            courtListenerIDs: stateAuthorityCourtIDs[state] ?? []
        )
    }

    static func makeStateOption(_ name: String, state: String) -> JurisdictionOption {
        let level = inferLevel(name, system: .state)
        return JurisdictionOption(
            id: slug(["state", state, name].joined(separator: " ")),
            displayName: name,
            jurisdictionName: state,
            courtName: name,
            system: .state,
            level: level,
            state: state,
            county: county(in: name),
            judicialCircuit: judicialCircuit(in: name),
            courtListenerIDs: inferStateCourtIDs(name, state: state, level: level)
        )
    }

    static func inferLevel(_ name: String, system: JurisdictionSystem) -> JurisdictionCourtLevel {
        let lower = name.lowercased()
        if lower == "federal courts" || lower.hasSuffix("state courts") {
            return .jurisdiction
        }
        if lower.contains("bankruptcy court") || lower.contains("bankruptcy appellate panel") {
            return .bankruptcy
        }
        if lower.contains("united states court of appeals") {
            return .federalAppellate
        }
        if lower.contains("united states district court") {
            return .federalTrial
        }
        if lower.contains("supreme court") {
            return .supreme
        }
        if lower.contains("district court of appeal")
            || lower.contains("court of appeal")
            || lower.contains("court of appeals")
            || lower.contains("appellate court") {
            return system == .federal ? .federalAppellate : .intermediateAppellate
        }
        if lower.contains("board")
            || lower.contains("commission")
            || lower.contains("office of")
            || lower.contains("administrative")
            || lower.contains("department")
            || lower.contains("agency") {
            return .administrative
        }
        if lower.contains("tax court")
            || lower.contains("court of federal claims")
            || lower.contains("court of international trade")
            || lower.contains("veterans claims")
            || lower.contains("armed forces")
            || lower.contains("intelligence surveillance") {
            return .specialty
        }
        if lower.contains("circuit court")
            || lower.contains("superior court")
            || lower.contains("county court")
            || lower.contains("state court")
            || lower.contains("court of chancery")
            || lower.contains("court of common pleas")
            || lower.contains("family court")
            || lower.contains("probate court")
            || lower.contains("juvenile court")
            || lower.contains("magistrate court")
            || lower.contains("municipal court")
            || lower.contains("justice of the peace")
            || lower.contains("alderman court") {
            return .trial
        }
        return .specialty
    }

    static func federalJurisdictionName(for name: String, state: String?) -> String {
        if let circuit = federalAppealsID(name) {
            switch circuit {
            case "cadc": return "District of Columbia Circuit"
            case "cafc": return "Federal Circuit"
            default:
                let number = circuit.replacingOccurrences(of: "ca", with: "")
                return "United States Court of Appeals for the \(ordinalName(number)) Circuit"
            }
        }
        if let state, let circuit = federalCircuitByState[state] {
            return circuit.name
        }
        return "Federal"
    }

    static func inferFederalCourtIDs(_ name: String, state: String?, level: JurisdictionCourtLevel) -> [String] {
        if name == "Supreme Court of the United States" { return ["scotus"] }
        if let id = federalAppealsID(name) { return [id] }
        if let id = federalDistrictID(name, bankruptcy: level == .bankruptcy) { return [id] }
        let special = [
            "United States Court of International Trade": "cit",
            "United States Court of Federal Claims": "uscfc",
            "United States Tax Court": "ustc"
        ]
        if let id = special[name] { return [id] }
        return []
    }

    static func inferStateCourtIDs(_ name: String, state: String, level: JurisdictionCourtLevel) -> [String] {
        if let special = stateSpecialCourtIDs[state]?[name] {
            return [special]
        }
        switch level {
        case .supreme:
            return stateSupremeCourtIDs[state].map { [$0] } ?? []
        case .intermediateAppellate:
            return stateIntermediateCourtIDs[state] ?? []
        case .jurisdiction, .trial:
            return stateAuthorityCourtIDs[state] ?? []
        default:
            return []
        }
    }

    static func federalAppealsID(_ name: String) -> String? {
        let lower = name.lowercased()
        guard lower.contains("united states court of appeals") else { return nil }
        if lower.contains("district of columbia circuit") { return "cadc" }
        if lower.contains("federal circuit") { return "cafc" }
        let ordinals = [
            "first": "ca1",
            "second": "ca2",
            "third": "ca3",
            "fourth": "ca4",
            "fifth": "ca5",
            "sixth": "ca6",
            "seventh": "ca7",
            "eighth": "ca8",
            "ninth": "ca9",
            "tenth": "ca10",
            "eleventh": "ca11"
        ]
        return ordinals.first { lower.contains($0.key) }?.value
    }

    static func federalDistrictID(_ name: String, bankruptcy: Bool) -> String? {
        let courtPrefix = bankruptcy
            ? "United States Bankruptcy Court for the "
            : "United States District Court for the "
        guard name.hasPrefix(courtPrefix) else { return nil }
        let remainder = String(name.dropFirst(courtPrefix.count))
        if let special = federalDistrictSpecialIDs[remainder] {
            return special + (bankruptcy ? "b" : "d")
        }

        let districts = [
            "Central District of ": "c",
            "Eastern District of ": "e",
            "Middle District of ": "m",
            "Northern District of ": "n",
            "Southern District of ": "s",
            "Western District of ": "w",
            "District of ": ""
        ]
        for (prefix, marker) in districts where remainder.hasPrefix(prefix) {
            let stateName = String(remainder.dropFirst(prefix.count))
            guard let postal = statePostalCodes[stateName] else { return nil }
            return "\(postal.lowercased())\(marker)\(bankruptcy ? "b" : "d")"
        }
        return nil
    }

    static func federalState(in name: String) -> String? {
        for (state, _) in statePostalCodes.sorted(by: { $0.key.count > $1.key.count }) {
            if name.localizedCaseInsensitiveContains(state) {
                return state
            }
        }
        if name.localizedCaseInsensitiveContains("District of Columbia") {
            return "District of Columbia"
        }
        return nil
    }

    static func county(in name: String) -> String? {
        if let county = firstCapture(#"(?i)\bin and for ([A-Z][A-Za-z.' -]+ County)\b"#, in: name) {
            return county
        }
        if let county = firstCapture(#"(?i)\bfor ([A-Z][A-Za-z.' -]+ County)\b"#, in: name) {
            return county
        }
        if let county = firstCapture(#"(?i)\bof ([A-Z][A-Za-z.' -]+ County)\b"#, in: name) {
            return county
        }
        return firstCapture(#"(?i)\b([A-Z][A-Za-z.'-]+ County)\b"#, in: name)
    }

    static func judicialCircuit(in name: String) -> String? {
        firstCapture(#"(?i)\b((?:First|Second|Third|Fourth|Fifth|Sixth|Seventh|Eighth|Ninth|Tenth|Eleventh|Twelfth|Thirteenth|Fourteenth|Fifteenth|Sixteenth|Seventeenth|Eighteenth|Nineteenth|Twentieth) Judicial Circuit)\b"#, in: name)
    }

    static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let swiftRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[swiftRange])
    }

    static func stateName(forHeader line: String) -> String? {
        stateHeaders[line]
    }

    static func slug(_ value: String) -> String {
        let normalized = normalized(value)
        var result = ""
        var lastWasHyphen = false
        for scalar in normalized.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                result.append("-")
                lastWasHyphen = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func ordinalName(_ number: String) -> String {
        switch number {
        case "1": "First"
        case "2": "Second"
        case "3": "Third"
        case "4": "Fourth"
        case "5": "Fifth"
        case "6": "Sixth"
        case "7": "Seventh"
        case "8": "Eighth"
        case "9": "Ninth"
        case "10": "Tenth"
        case "11": "Eleventh"
        default: number
        }
    }
}

private let stateHeaders: [String: String] = {
    Dictionary(uniqueKeysWithValues: statePostalCodes.keys.map { ($0.uppercased(), $0) })
}()

private let statePostalCodes: [String: String] = [
    "Alabama": "AL",
    "Alaska": "AK",
    "Arizona": "AZ",
    "Arkansas": "AR",
    "California": "CA",
    "Colorado": "CO",
    "Connecticut": "CT",
    "Delaware": "DE",
    "District of Columbia": "DC",
    "Florida": "FL",
    "Georgia": "GA",
    "Guam": "GU",
    "Hawaii": "HI",
    "Idaho": "ID",
    "Illinois": "IL",
    "Indiana": "IN",
    "Iowa": "IA",
    "Kansas": "KS",
    "Kentucky": "KY",
    "Louisiana": "LA",
    "Maine": "ME",
    "Maryland": "MD",
    "Massachusetts": "MA",
    "Michigan": "MI",
    "Minnesota": "MN",
    "Mississippi": "MS",
    "Missouri": "MO",
    "Montana": "MT",
    "Nebraska": "NE",
    "Nevada": "NV",
    "New Hampshire": "NH",
    "New Jersey": "NJ",
    "New Mexico": "NM",
    "New York": "NY",
    "North Carolina": "NC",
    "North Dakota": "ND",
    "Northern Mariana Islands": "MP",
    "Ohio": "OH",
    "Oklahoma": "OK",
    "Oregon": "OR",
    "Pennsylvania": "PA",
    "Puerto Rico": "PR",
    "Rhode Island": "RI",
    "South Carolina": "SC",
    "South Dakota": "SD",
    "Tennessee": "TN",
    "Texas": "TX",
    "Utah": "UT",
    "Vermont": "VT",
    "Virgin Islands": "VI",
    "Virginia": "VA",
    "Washington": "WA",
    "West Virginia": "WV",
    "Wisconsin": "WI",
    "Wyoming": "WY"
]

private let federalDistrictSpecialIDs: [String: String] = [
    "District of Columbia": "dc",
    "District of Guam": "gu",
    "District of Puerto Rico": "pr",
    "District of the Virgin Islands": "vi",
    "District of the Northern Mariana Islands": "nmi"
]

private let federalCircuitByState: [String: (name: String, id: String)] = [
    "Alabama": ("United States Court of Appeals for the Eleventh Circuit", "ca11"),
    "Alaska": ("United States Court of Appeals for the Ninth Circuit", "ca9"),
    "Arizona": ("United States Court of Appeals for the Ninth Circuit", "ca9"),
    "Arkansas": ("United States Court of Appeals for the Eighth Circuit", "ca8"),
    "California": ("United States Court of Appeals for the Ninth Circuit", "ca9"),
    "Colorado": ("United States Court of Appeals for the Tenth Circuit", "ca10"),
    "Connecticut": ("United States Court of Appeals for the Second Circuit", "ca2"),
    "Delaware": ("United States Court of Appeals for the Third Circuit", "ca3"),
    "District of Columbia": ("United States Court of Appeals for the District of Columbia Circuit", "cadc"),
    "Florida": ("United States Court of Appeals for the Eleventh Circuit", "ca11"),
    "Georgia": ("United States Court of Appeals for the Eleventh Circuit", "ca11"),
    "Guam": ("United States Court of Appeals for the Ninth Circuit", "ca9"),
    "Hawaii": ("United States Court of Appeals for the Ninth Circuit", "ca9"),
    "Idaho": ("United States Court of Appeals for the Ninth Circuit", "ca9"),
    "Illinois": ("United States Court of Appeals for the Seventh Circuit", "ca7"),
    "Indiana": ("United States Court of Appeals for the Seventh Circuit", "ca7"),
    "Iowa": ("United States Court of Appeals for the Eighth Circuit", "ca8"),
    "Kansas": ("United States Court of Appeals for the Tenth Circuit", "ca10"),
    "Kentucky": ("United States Court of Appeals for the Sixth Circuit", "ca6"),
    "Louisiana": ("United States Court of Appeals for the Fifth Circuit", "ca5"),
    "Maine": ("United States Court of Appeals for the First Circuit", "ca1"),
    "Maryland": ("United States Court of Appeals for the Fourth Circuit", "ca4"),
    "Massachusetts": ("United States Court of Appeals for the First Circuit", "ca1"),
    "Michigan": ("United States Court of Appeals for the Sixth Circuit", "ca6"),
    "Minnesota": ("United States Court of Appeals for the Eighth Circuit", "ca8"),
    "Mississippi": ("United States Court of Appeals for the Fifth Circuit", "ca5"),
    "Missouri": ("United States Court of Appeals for the Eighth Circuit", "ca8"),
    "Montana": ("United States Court of Appeals for the Ninth Circuit", "ca9"),
    "Nebraska": ("United States Court of Appeals for the Eighth Circuit", "ca8"),
    "Nevada": ("United States Court of Appeals for the Ninth Circuit", "ca9"),
    "New Hampshire": ("United States Court of Appeals for the First Circuit", "ca1"),
    "New Jersey": ("United States Court of Appeals for the Third Circuit", "ca3"),
    "New Mexico": ("United States Court of Appeals for the Tenth Circuit", "ca10"),
    "New York": ("United States Court of Appeals for the Second Circuit", "ca2"),
    "North Carolina": ("United States Court of Appeals for the Fourth Circuit", "ca4"),
    "North Dakota": ("United States Court of Appeals for the Eighth Circuit", "ca8"),
    "Northern Mariana Islands": ("United States Court of Appeals for the Ninth Circuit", "ca9"),
    "Ohio": ("United States Court of Appeals for the Sixth Circuit", "ca6"),
    "Oklahoma": ("United States Court of Appeals for the Tenth Circuit", "ca10"),
    "Oregon": ("United States Court of Appeals for the Ninth Circuit", "ca9"),
    "Pennsylvania": ("United States Court of Appeals for the Third Circuit", "ca3"),
    "Puerto Rico": ("United States Court of Appeals for the First Circuit", "ca1"),
    "Rhode Island": ("United States Court of Appeals for the First Circuit", "ca1"),
    "South Carolina": ("United States Court of Appeals for the Fourth Circuit", "ca4"),
    "South Dakota": ("United States Court of Appeals for the Eighth Circuit", "ca8"),
    "Tennessee": ("United States Court of Appeals for the Sixth Circuit", "ca6"),
    "Texas": ("United States Court of Appeals for the Fifth Circuit", "ca5"),
    "Utah": ("United States Court of Appeals for the Tenth Circuit", "ca10"),
    "Vermont": ("United States Court of Appeals for the Second Circuit", "ca2"),
    "Virgin Islands": ("United States Court of Appeals for the Third Circuit", "ca3"),
    "Virginia": ("United States Court of Appeals for the Fourth Circuit", "ca4"),
    "Washington": ("United States Court of Appeals for the Ninth Circuit", "ca9"),
    "West Virginia": ("United States Court of Appeals for the Fourth Circuit", "ca4"),
    "Wisconsin": ("United States Court of Appeals for the Seventh Circuit", "ca7"),
    "Wyoming": ("United States Court of Appeals for the Tenth Circuit", "ca10")
]

private let stateSupremeCourtIDs: [String: String] = [
    "Alabama": "ala",
    "California": "cal",
    "Delaware": "del",
    "District of Columbia": "dc",
    "Florida": "fla",
    "Georgia": "ga",
    "Illinois": "ill",
    "Mississippi": "miss",
    "New York": "ny",
    "North Carolina": "nc",
    "South Carolina": "sc",
    "Tennessee": "tenn",
    "Texas": "tex"
]

private let stateIntermediateCourtIDs: [String: [String]] = [
    "Alabama": ["alacivapp", "alacrimapp"],
    "California": ["calctapp"],
    "Delaware": ["delch"],
    "District of Columbia": ["dc"],
    "Florida": ["fladistctapp"],
    "Georgia": ["gactapp"],
    "Illinois": ["illappct"],
    "Mississippi": ["missctapp"],
    "New York": ["nyappdiv"],
    "North Carolina": ["ncctapp"],
    "South Carolina": ["scctapp"],
    "Tennessee": ["tennctapp", "tenncrimapp"],
    "Texas": ["texapp"]
]

private let stateAuthorityCourtIDs: [String: [String]] = {
    var result: [String: [String]] = [:]
    for (state, supreme) in stateSupremeCourtIDs {
        result[state] = uniquePreservingOrder([supreme] + (stateIntermediateCourtIDs[state] ?? []))
    }
    return result
}()

private let stateSpecialCourtIDs: [String: [String: String]] = [
    "Delaware": [
        "Court of Chancery of Delaware": "delch",
        "Court of Chancery in and for New Castle County": "delch",
        "Court of Chancery in and for Kent County": "delch",
        "Court of Chancery in and for Sussex County": "delch"
    ]
]

private func uniquePreservingOrder(_ values: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for value in values {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
        seen.insert(trimmed)
        result.append(trimmed)
    }
    return result
}
