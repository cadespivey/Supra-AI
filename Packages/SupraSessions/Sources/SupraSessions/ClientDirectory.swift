import Foundation
import SupraStore

/// One known client, aggregated from the matters that reference it.
public struct ClientDirectoryEntry: Identifiable, Sendable, Equatable {
    /// LEDES `CLIENT_ID` (the client number); nil for clients recorded by name only.
    public let clientID: String?
    /// Canonical display name: the spelling used by the most matters (ties break
    /// to the most recently touched), so accepting a recommendation converges
    /// every matter on one spelling.
    public let name: String?
    public let matterCount: Int

    public var id: String { "\(clientID ?? "")|\(name ?? "")" }
}

/// A directory of the clients already entered on matters, used by the matter
/// form to recommend the client number when a name is typed and vice versa.
/// Derived on demand from the matters table — never stored, so it can't drift.
public struct ClientDirectory: Sendable, Equatable {
    /// Most-used clients first, so the likeliest picks lead the suggestions.
    public let entries: [ClientDirectoryEntry]

    public static let empty = ClientDirectory(entries: [])

    init(entries: [ClientDirectoryEntry]) {
        self.entries = entries
    }

    public static func build(from rows: [MattersRepository.ClientUsageRow]) -> ClientDirectory {
        // Tally name spellings per client number; the dominant spelling becomes
        // the entry's canonical name.
        struct Tally {
            var total = 0
            var spellings: [String: (count: Int, lastUsed: Date)] = [:]

            mutating func add(_ row: MattersRepository.ClientUsageRow) {
                total += row.matterCount
                guard let name = row.clientNames else { return }
                var spelling = spellings[name] ?? (0, .distantPast)
                spelling.count += row.matterCount
                spelling.lastUsed = max(spelling.lastUsed, row.lastUsedAt)
                spellings[name] = spelling
            }

            var dominantName: String? {
                spellings.max { lhs, rhs in
                    (lhs.value.count, lhs.value.lastUsed) < (rhs.value.count, rhs.value.lastUsed)
                }?.key
            }
        }

        var numbered: [String: Tally] = [:]
        var nameOnly: [String: Tally] = [:]
        for row in rows {
            if let clientID = row.clientID {
                numbered[clientID, default: Tally()].add(row)
            } else if let name = row.clientNames {
                nameOnly[Self.fold(name), default: Tally()].add(row)
            }
        }

        var entries = numbered.map { clientID, tally in
            ClientDirectoryEntry(clientID: clientID, name: tally.dominantName, matterCount: tally.total)
        }

        // A name-only client whose name matches exactly one numbered client is
        // the same client missing its number — fold it in so typing that name
        // recommends the number. Ambiguous names (two client numbers sharing a
        // name) stay separate rather than guessing.
        for (foldedName, tally) in nameOnly {
            let matches = entries.indices.filter { index in
                entries[index].name.map { Self.fold($0) == foldedName } ?? false
            }
            if matches.count == 1 {
                let match = entries[matches[0]]
                entries[matches[0]] = ClientDirectoryEntry(
                    clientID: match.clientID,
                    name: match.name,
                    matterCount: match.matterCount + tally.total
                )
            } else {
                entries.append(
                    ClientDirectoryEntry(clientID: nil, name: tally.dominantName, matterCount: tally.total)
                )
            }
        }

        entries.sort { lhs, rhs in
            if lhs.matterCount != rhs.matterCount { return lhs.matterCount > rhs.matterCount }
            return (lhs.name ?? lhs.clientID ?? "") < (rhs.name ?? rhs.clientID ?? "")
        }
        return ClientDirectory(entries: entries)
    }

    /// Clients whose number starts with the typed digits, exact match first.
    public func suggestions(forNumber query: String, limit: Int = 6) -> [ClientDirectoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }
        let matches = entries.filter { $0.clientID?.lowercased().hasPrefix(trimmed) ?? false }
        return Array(rankedFirst(matches) { $0.clientID?.lowercased() == trimmed }.prefix(limit))
    }

    /// Clients whose name contains the typed text (case/diacritic-insensitive),
    /// prefix matches first.
    public func suggestions(forName query: String, limit: Int = 6) -> [ClientDirectoryEntry] {
        let folded = Self.fold(query)
        guard !folded.isEmpty else { return [] }
        let matches = entries.filter { $0.name.map { Self.fold($0).contains(folded) } ?? false }
        return Array(rankedFirst(matches) { $0.name.map { Self.fold($0).hasPrefix(folded) } ?? false }.prefix(limit))
    }

    /// The client with exactly this number, if known.
    public func entry(forNumber number: String) -> ClientDirectoryEntry? {
        let trimmed = number.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        return entries.first { $0.clientID?.lowercased() == trimmed }
    }

    /// Canonical sidebar-group identity for a matter's client fields, using the
    /// directory's own notion of "the same client": name spellings fold, and a
    /// name-only matter joins the numbered client it unambiguously matches. The
    /// label is the canonical spelling. Nil when the matter has no client info.
    ///
    /// Keys keep the "id:"/"name:" prefixes, which also makes name-only clients
    /// deliberately sort after all numbered clients in the client sort.
    public func groupIdentity(clientID: String?, clientNames: String?) -> (key: String, label: String)? {
        let trimmedID = clientID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedName = clientNames?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedID.isEmpty {
            let label = entry(forNumber: trimmedID)?.name ?? trimmedName
            return ("id:\(trimmedID.lowercased())", label.isEmpty ? "Client \(trimmedID)" : label)
        }
        guard !trimmedName.isEmpty else { return nil }
        let folded = Self.fold(trimmedName)
        let matches = entries.filter { $0.name.map { Self.fold($0) == folded } ?? false }
        if matches.count == 1, let match = matches.first, let number = match.clientID {
            return ("id:\(number.lowercased())", match.name ?? trimmedName)
        }
        return ("name:\(folded)", matches.first?.name ?? trimmedName)
    }

    /// True when the form's fields already carry this entry — both the number
    /// and the canonical spelling — so no recommendation remains to make.
    public func isApplied(_ entry: ClientDirectoryEntry, number: String, name: String) -> Bool {
        let trimmedNumber = number.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let clientID = entry.clientID, clientID != trimmedNumber { return false }
        if let entryName = entry.name, entryName != trimmedName { return false }
        return true
    }

    /// Stable partition: matches satisfying `leads` first, relative order (most
    /// used first) preserved within each half.
    private func rankedFirst(
        _ matches: [ClientDirectoryEntry],
        leads: (ClientDirectoryEntry) -> Bool
    ) -> [ClientDirectoryEntry] {
        matches.filter(leads) + matches.filter { !leads($0) }
    }

    private static func fold(_ value: String) -> String {
        // Locale nil: grouping keys must not shift with the user's locale
        // (e.g. Turkish dotless-ı case rules changing what "the same name" is).
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
