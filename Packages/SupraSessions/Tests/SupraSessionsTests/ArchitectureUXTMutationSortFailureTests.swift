import GRDB
import SupraCore
import SupraRuntimeClient
import SupraStore
@testable import SupraSessions
import XCTest

/// T-MUTATION-01 manual-sort fault seam.
///
/// Expected RED: `MattersController.setSortMode` persists the candidate setting
/// before the Store write and suppresses the write failure with `try?`. The UI
/// therefore appears to accept Manual sorting while no manual order exists and
/// publishes neither a typed failure nor a retry action.
@MainActor
final class ArchitectureUXTMutationSortFailureTests: XCTestCase {
    private enum Wire {
        static let firstID = "matter-mutation-sort-941"
        static let secondID = "matter-mutation-sort-947"
        static let failure = "T_MUTATION_SORT_FAILURE_953"
        static let suite = "ArchitectureUXTMutationSortFailureTests.959"
        static let timestamp = Date(timeIntervalSince1970: 1_946_252_959)
    }

    func testFirstManualOrderFailureRetainsCandidateButDoesNotPersistFalseSuccess() throws {
        let store = try SupraStore.inMemory()
        try store.database.writer.write { db in
            try MatterRecord(
                id: Wire.firstID,
                name: "Aster Harbor Sort Matter 941",
                jurisdiction: "Synthetic Jurisdiction 941",
                createdAt: Wire.timestamp,
                updatedAt: Wire.timestamp.addingTimeInterval(2)
            ).insert(db)
            try MatterRecord(
                id: Wire.secondID,
                name: "Northline Sort Matter 947",
                jurisdiction: "Synthetic Jurisdiction 947",
                createdAt: Wire.timestamp.addingTimeInterval(1),
                updatedAt: Wire.timestamp.addingTimeInterval(1)
            ).insert(db)
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Wire.suite))
        defaults.removePersistentDomain(forName: Wire.suite)
        defer { defaults.removePersistentDomain(forName: Wire.suite) }
        defaults.set(MatterSortMode.dateModified.rawValue, forKey: "supra.matterSortMode")
        let controller = MattersController(
            store: store,
            runtimeClient: StubRuntimeClient(),
            defaults: defaults
        )
        controller.loadMatters()
        let originalOrder = controller.matters.map(\.id)
        XCTAssertEqual(controller.sortMode, .dateModified)
        XCTAssertEqual(Set(originalOrder), [Wire.firstID, Wire.secondID])

        try store.database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER t_mutation_sort_failure
                BEFORE UPDATE OF sort_order ON matters
                BEGIN
                    SELECT RAISE(ABORT, '\(Wire.failure)');
                END
                """)
        }

        controller.setSortMode(.manual)

        XCTAssertEqual(
            controller.sortMode,
            .manual,
            "the user's non-default candidate remains selected for correction or retry"
        )
        XCTAssertEqual(
            defaults.string(forKey: "supra.matterSortMode"),
            MatterSortMode.dateModified.rawValue,
            "a failed compound write cannot persist false success"
        )
        XCTAssertEqual(controller.matters.map(\.id), originalOrder)
        XCTAssertTrue(try store.matters.fetchMatters().allSatisfy { $0.sortOrder == nil })
        let failure = try XCTUnwrap(
            controller.lastMutationFailure,
            "Expected RED: setSortMode suppresses the Store failure"
        )
        XCTAssertEqual(failure.operation, .matterReorder)
        XCTAssertTrue(failure.userMessage.contains(Wire.failure))
        XCTAssertTrue(failure.recoveryActions.contains(.retry))

        try store.database.writer.write { db in
            try db.execute(sql: "DROP TRIGGER t_mutation_sort_failure")
        }
        controller.setSortMode(.manual)

        XCTAssertNil(controller.lastMutationFailure)
        XCTAssertEqual(
            defaults.string(forKey: "supra.matterSortMode"),
            MatterSortMode.manual.rawValue
        )
        let persisted = try store.matters.fetchMatters()
        XCTAssertEqual(Set(persisted.compactMap(\.sortOrder)), [0, 1])
        XCTAssertEqual(controller.matters.map(\.id), originalOrder)
    }
}
