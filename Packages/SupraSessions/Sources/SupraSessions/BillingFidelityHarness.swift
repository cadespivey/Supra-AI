import Foundation
import SupraCore
import SupraStore

// Milestone 4 Phase 4c — the golden-fixture fidelity harness. It runs representative
// days through BillingDraftService and scores the result against expectations
// (matter accuracy, narrative subject, time-within-tolerance). The scorer is pure
// and tested here; the harness is generator-agnostic, so Diagnostics can run the
// SAME cases against a real loaded model to produce the actual fidelity numbers
// the spec's Phase-4 gate requires (matter ≥95%, near-perfect time).

/// What a fixture line is expected to look like.
public struct BillingFidelityExpectation: Sendable, Equatable {
    public let matterID: String?
    public let subjectKeywords: [String]
    public let hours: Double
    public let hoursTolerance: Double

    public init(matterID: String?, subjectKeywords: [String], hours: Double, hoursTolerance: Double = 0.1) {
        self.matterID = matterID
        self.subjectKeywords = subjectKeywords
        self.hours = hours
        self.hoursTolerance = hoursTolerance
    }
}

public struct BillingFidelityScore: Sendable, Equatable {
    public let expectedCount: Int
    public let lineMatches: Int
    public let timeMatches: Int

    /// Fraction of expected lines matched by matter + subject keyword.
    public var lineAccuracy: Double { expectedCount == 0 ? 1 : Double(lineMatches) / Double(expectedCount) }
    /// Fraction of expected lines whose matched actual line is within the time tolerance.
    public var timeAccuracy: Double { expectedCount == 0 ? 1 : Double(timeMatches) / Double(expectedCount) }
}

/// Pure scorer: greedily matches each expectation to an unused actual line that
/// shares the matter and contains a subject keyword, then checks time tolerance.
public enum BillingFidelityScorer {
    public struct Line: Sendable, Equatable {
        public let matterID: String?
        public let narrative: String
        public let hours: Double
        public init(matterID: String?, narrative: String, hours: Double) {
            self.matterID = matterID
            self.narrative = narrative
            self.hours = hours
        }
    }

    public static func score(expected: [BillingFidelityExpectation], actual: [Line]) -> BillingFidelityScore {
        var used = Set<Int>()
        var lineMatches = 0
        var timeMatches = 0
        for expectation in expected {
            let match = actual.indices.first { index in
                guard !used.contains(index) else { return false }
                let line = actual[index]
                let matterOK = expectation.matterID == nil || line.matterID == expectation.matterID
                let subjectOK = expectation.subjectKeywords.contains {
                    line.narrative.range(of: $0, options: .caseInsensitive) != nil
                }
                return matterOK && subjectOK
            }
            if let index = match {
                used.insert(index)
                lineMatches += 1
                if abs(actual[index].hours - expectation.hours) <= expectation.hoursTolerance { timeMatches += 1 }
            }
        }
        return BillingFidelityScore(expectedCount: expected.count, lineMatches: lineMatches, timeMatches: timeMatches)
    }
}

/// A fixture day: matter setup, note entries, and expected billing lines.
public struct BillingFidelityCase: Sendable {
    public struct Matter: Sendable {
        public let id: String
        public let name: String
        public let clientID: String?
        public let internalMatterID: String?
        public let codeSet: BillingCodeSet
        public init(id: String, name: String, clientID: String?, internalMatterID: String?, codeSet: BillingCodeSet) {
            self.id = id; self.name = name; self.clientID = clientID; self.internalMatterID = internalMatterID; self.codeSet = codeSet
        }
    }
    public struct Entry: Sendable {
        public let text: String
        public let mentionIDs: [String]
        public let tags: [String]
        public init(text: String, mentionIDs: [String] = [], tags: [String] = []) {
            self.text = text; self.mentionIDs = mentionIDs; self.tags = tags
        }
    }

    public let name: String
    public let dayDate: String
    public let matters: [Matter]
    public let entries: [Entry]
    public let expectations: [BillingFidelityExpectation]

    public init(name: String, dayDate: String, matters: [Matter], entries: [Entry], expectations: [BillingFidelityExpectation]) {
        self.name = name; self.dayDate = dayDate; self.matters = matters; self.entries = entries; self.expectations = expectations
    }
}

@MainActor
public enum BillingFidelityHarness {
    public struct CaseResult: Sendable {
        public let name: String
        public let parsed: Bool
        public let score: BillingFidelityScore?
    }

    /// Builds a throwaway store from the fixture, runs the draft through the injected
    /// generator, and scores the persisted lines. `parsed` is false if generation
    /// couldn't produce usable JSON.
    public static func run(
        _ testCase: BillingFidelityCase,
        timekeeper: BillingTimekeeper,
        sensitivity: Double = 0.6,
        generate: @escaping BillingDraftService.Generate
    ) async -> CaseResult {
        guard let store = try? SupraStore.inMemory(),
              let day = try? store.scratchPad.fetchOrCreateDay(testCase.dayDate) else {
            return CaseResult(name: testCase.name, parsed: false, score: nil)
        }
        for matter in testCase.matters {
            try? await store.database.writer.write { db in
                try MatterRecord(
                    id: matter.id, name: matter.name,
                    clientNames: matter.name, internalMatterID: matter.internalMatterID,
                    clientID: matter.clientID
                ).insert(db)
            }
            _ = try? store.billing.upsertBillingProfile(matterID: matter.id, overrideInstructions: nil, billingCodeSet: matter.codeSet)
        }
        for entry in testCase.entries {
            _ = try? store.scratchPad.addEntry(dayID: day.id, text: entry.text, mentions: entry.mentionIDs, tags: entry.tags)
        }

        let service = BillingDraftService(store: store, generate: generate)
        do {
            let result = try await service.generateDraft(
                dayID: day.id, sensitivity: sensitivity, timekeeper: timekeeper, invoiceDate: testCase.dayDate
            )
            let lines = ((try? store.billing.lineItems(draftID: result.draftID)) ?? []).map {
                BillingFidelityScorer.Line(matterID: $0.matterID, narrative: $0.narrative, hours: $0.hours)
            }
            return CaseResult(name: testCase.name, parsed: true, score: BillingFidelityScorer.score(expected: testCase.expectations, actual: lines))
        } catch {
            return CaseResult(name: testCase.name, parsed: false, score: nil)
        }
    }
}

/// The seed golden-fixture corpus. Expand over time; this is what the Diagnostics
/// fidelity run scores a real model against.
public enum BillingFidelityFixtures {
    public static func cases() -> [BillingFidelityCase] {
        [vyStarLitigationDay]
    }

    public static let vyStarLitigationDay = BillingFidelityCase(
        name: "VyStar litigation day",
        dayDate: "2026-06-22",
        matters: [
            .init(id: "m-vystar", name: "Reardon v. VyStar", clientID: "VYSTAR", internalMatterID: "12044-0007", codeSet: .litigation)
        ],
        entries: [
            .init(text: "Reviewed Defendant's motion to compel re ESI custodian list", mentionIDs: ["m-vystar"], tags: ["review"]),
            .init(text: "Drafted opposition to the motion to compel — proportionality + meet-and-confer", mentionIDs: ["m-vystar"], tags: ["drafting"])
        ],
        expectations: [
            .init(matterID: "m-vystar", subjectKeywords: ["motion to compel", "reviewed"], hours: 0.6, hoursTolerance: 0.3),
            .init(matterID: "m-vystar", subjectKeywords: ["opposition", "drafted"], hours: 1.3, hoursTolerance: 0.3)
        ]
    )
}
