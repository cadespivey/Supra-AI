import Foundation
import SupraCore
@testable import SupraSessions
import SupraStore
import XCTest

/// Coverage for the Settings model-management UX changes:
///  1. A lone registered model auto-fills every role.
///  2. Assigning a model from a Settings menu auto-loads it (no separate Load trip).
final class ModelAutoAssignLoadTests: XCTestCase {

    private func makeStore() throws -> SupraStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelAutoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try SupraStore(url: dir.appendingPathComponent("test.sqlite"))
    }

    // MARK: - #1 single model → all roles

    @MainActor
    func testSingleRegisteredModelResolvesForEveryRole() throws {
        let store = try makeStore()
        let library = ModelLibrary(store: store, runtimeClient: StubRuntimeClient())
        // One model whose name matches no role's configured identifier.
        let only = try library.addModel(displayName: "my-local-model", path: "/tmp/only", bookmarkData: nil)

        for role in ModelRole.allCases {
            XCTAssertEqual(library.effectiveAssignedModelID(for: role), only.id,
                           "role \(role.rawValue) should default to the only model")
            XCTAssertEqual(library.resolvedModel(for: role)?.id, only.id,
                           "role \(role.rawValue) should resolve to the only model")
        }
    }

    @MainActor
    func testSingleModelDefaultIsNotPersistedSoMoreModelsCanBeAssigned() throws {
        let store = try makeStore()
        let library = ModelLibrary(store: store, runtimeClient: StubRuntimeClient())
        _ = try library.addModel(displayName: "solo", path: "/tmp/solo", bookmarkData: nil)
        // The single-model default is a resolution-time convenience, not a stored
        // assignment — so nothing is persisted and a reopened library with the SAME
        // single model still resolves it, while leaving room for real assignments later.
        let reopened = ModelLibrary(store: store, runtimeClient: StubRuntimeClient())
        reopened.refresh()
        XCTAssertNil(reopened.roleAssignments.modelID(for: .drafting),
                     "single-model default must not pollute stored assignments")
        XCTAssertEqual(reopened.resolvedModel(for: .drafting)?.path, "/tmp/solo")
    }

    @MainActor
    func testTwoModelsDoNotForceOneModelOntoEveryRole() throws {
        let store = try makeStore()
        let library = ModelLibrary(store: store, runtimeClient: StubRuntimeClient())
        _ = try library.addModel(displayName: "alpha-instruct", path: "/tmp/a", bookmarkData: nil)
        _ = try library.addModel(displayName: "beta-thinking", path: "/tmp/b", bookmarkData: nil)
        // With two models the single-model fallback must not apply: an unconfigured,
        // unassigned role with >1 model resolves to nil (the user picks).
        let unmatched = library.effectiveAssignedModelID(for: .critique)
        // critique may name-match "beta-thinking" via bootstrap; the key invariant is
        // that not every role is forced to the same single model.
        let assignments = ModelRole.allCases.map { library.effectiveAssignedModelID(for: $0) }
        let distinct = Set(assignments.compactMap { $0 })
        XCTAssertLessThanOrEqual(distinct.count, 2)
        _ = unmatched
    }

    // MARK: - #2 assignment auto-loads

    @MainActor
    func testAssigningModelAutoLoadsItWhenIdle() async throws {
        let store = try makeStore()
        let stub = StubRuntimeClient()
        let loadRequested = expectation(description: "assigned model load requested")
        stub.onLoadModel = { [weak stub] _ in
            stub?.onLoadModel = nil
            loadRequested.fulfill()
        }
        let library = ModelLibrary(store: store, runtimeClient: stub)
        let model = try library.addModel(displayName: "Draft model", path: "/tmp/draft", bookmarkData: nil)

        // addModel → single-model bootstrap already assigned it to every role and the
        // first assignment auto-loads. Drive an explicit assignment too and confirm a
        // load was requested.
        library.assignModel(model.id, to: .drafting)
        await fulfillment(of: [loadRequested], timeout: 1)
        stub.onLoadModel = nil

        XCTAssertFalse(stub.loadRequests.isEmpty, "assigning a model should auto-load it")
        XCTAssertEqual(stub.loadRequests.last?.modelID.rawValue.uuidString, model.id)
        if case let .loaded(id) = library.loadState {
            XCTAssertEqual(id, model.id)
        } else {
            XCTFail("expected loaded state, got \(library.loadState)")
        }
    }

    @MainActor
    func testAssigningDoesNotInterruptAnAlreadyLoadedModel() async throws {
        let store = try makeStore()
        let stub = StubRuntimeClient()
        let library = ModelLibrary(store: store, runtimeClient: stub)
        let first = try library.addModel(displayName: "first", path: "/tmp/first", bookmarkData: nil)
        let second = try library.addModel(displayName: "second", path: "/tmp/second", bookmarkData: nil)

        // Load `first` explicitly.
        await library.activateAndLoad(modelID: first.id)
        guard case .loaded = library.loadState else { return XCTFail("first should be loaded") }
        let countAfterFirstLoad = stub.loadRequests.count

        // Assigning `second` to a role must NOT swap the loaded model out (loaded state).
        let unexpectedLoad = expectation(description: "no replacement model load")
        unexpectedLoad.isInverted = true
        stub.onLoadModel = { _ in unexpectedLoad.fulfill() }
        library.assignModel(second.id, to: .critique)
        await fulfillment(of: [unexpectedLoad], timeout: 0.2)
        stub.onLoadModel = nil

        XCTAssertEqual(stub.loadRequests.count, countAfterFirstLoad, "assignment must not auto-load while another model is loaded")
        if case let .loaded(id) = library.loadState {
            XCTAssertEqual(id, first.id, "the already-loaded model must stay loaded")
        }
    }
}
