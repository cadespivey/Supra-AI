import AppKit
@testable import SupraDesignSystem
import XCTest

/// Gating tests for the shared AppKit drop layer. Actual `NSFilePromiseReceiver`
/// fulfillment requires a live drag session, so synthetic receivers exercise the
/// same asynchronous coordinator without depending on Finder or Mail.
@MainActor
final class SupraFileDropTests: XCTestCase {

    private func temporaryFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("supra-drop-test-\(UUID().uuidString).txt")
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func pasteboard(withFileURL url: URL) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("supra-drop-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        return pasteboard
    }

    private func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    // Expected RED before the delivery-lifetime fix: the callback accepted only
    // `[URL]`, so it could not hold and deterministically release promised files.
    func testPerformDragOperationDeliversDroppedFileURLs() async throws {
        let file = try temporaryFile("Coverage letter for the drop test.")
        defer { try? FileManager.default.removeItem(at: file) }

        var delivered: [[URL]] = []
        let callback = expectation(description: "drop callback")
        let view = FileDropCatcherView()
        view.acceptsFileURLs = true
        view.onDrop = { delivery in
            delivered.append(delivery.urls)
            callback.fulfill()
        }
        view.refreshRegisteredTypes()

        let info = DragInfoStub(pasteboard: pasteboard(withFileURL: file))
        XCTAssertEqual(view.draggingEntered(info), .copy)
        XCTAssertTrue(view.performDragOperation(info))
        await fulfillment(of: [callback], timeout: 2)
        XCTAssertEqual(delivered.count, 1, "one drop must produce exactly one delivery")
        XCTAssertEqual(delivered.first?.map(canonical), [canonical(file)])
    }

    // Expected RED: compile error because the old catcher exposes only `onFiles`,
    // not the new async `onDrop` contract. This also preserves the existing
    // disabled-state guard through the callback migration.
    func testDraggingIsRejectedWhenDisabled() throws {
        let file = try temporaryFile("Ignored while disabled.")
        defer { try? FileManager.default.removeItem(at: file) }

        var delivered = false
        let view = FileDropCatcherView()
        view.acceptsFileURLs = true
        view.isEnabled = false
        view.onDrop = { _ in delivered = true }
        view.refreshRegisteredTypes()

        let info = DragInfoStub(pasteboard: pasteboard(withFileURL: file))
        XCTAssertEqual(view.draggingEntered(info), [], "a disabled layer must refuse the drag")
        XCTAssertFalse(view.performDragOperation(info))
        XCTAssertFalse(delivered, "nothing may be delivered while disabled")
    }

    // Expected RED: compile error because the old catcher exposes only `onFiles`,
    // not the new async `onDrop` contract. This also preserves configurable URL
    // acceptance through the callback migration.
    func testFileURLAcceptanceIsConfigurable() throws {
        let file = try temporaryFile("Should pass through to SwiftUI targets.")
        defer { try? FileManager.default.removeItem(at: file) }

        var delivered = false
        let view = FileDropCatcherView()
        view.acceptsFileURLs = false
        view.onDrop = { _ in delivered = true }
        view.refreshRegisteredTypes()

        let info = DragInfoStub(pasteboard: pasteboard(withFileURL: file))
        XCTAssertEqual(
            view.draggingEntered(info), [],
            "a promises-only layer must refuse a plain file-URL drag so SwiftUI targets beneath receive it"
        )
        XCTAssertFalse(view.performDragOperation(info))
        XCTAssertFalse(delivered)
    }

    // Expected RED: `registerForDraggedTypes` unions registrations, so changing
    // true -> false left `.fileURL` registered and could still steal Finder drops.
    func testRefreshingRegistrationRemovesPreviouslyAcceptedFileURLs() {
        let view = FileDropCatcherView()
        view.acceptsFileURLs = true
        view.refreshRegisteredTypes()
        XCTAssertTrue(view.registeredDraggedTypes.contains(.fileURL))

        view.acceptsFileURLs = false
        view.refreshRegisteredTypes()

        XCTAssertFalse(view.registeredDraggedTypes.contains(.fileURL))
    }

    // Expected RED: the DispatchGroup left after the first callback from each
    // receiver, so a legacy receiver promising multiple files delivered only a
    // timing-dependent subset and had no cleanup contract.
    func testSyntheticPromiseDeliversEveryCallbackThenCleansTemporaryDirectory() async throws {
        let receiver = SyntheticPromiseReceiver(events: [
            .file(name: "first.txt", contents: "first"),
            .file(name: "second.txt", contents: "second")
        ])
        let callback = expectation(description: "promise callback")
        let cleanup = expectation(description: "temporary directory cleanup")
        var names: [String] = []
        var ownedDirectory: URL?
        let view = FileDropCatcherView()

        view.receivePromisedFiles(
            [receiver],
            alongside: [],
            limits: .standard,
            completion: { cleanup.fulfill() }
        ) { delivery in
            names = delivery.urls.map(\.lastPathComponent).sorted()
            ownedDirectory = delivery.urls.first?.deletingLastPathComponent()
            XCTAssertTrue(ownedDirectory.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
            try? await Task.sleep(for: .milliseconds(25))
            XCTAssertTrue(
                ownedDirectory.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
                "promised files must remain available while the async handler is suspended"
            )
            callback.fulfill()
        }

        await fulfillment(of: [callback], timeout: 2)
        XCTAssertEqual(names, ["first.txt", "second.txt"])
        let directory = try XCTUnwrap(ownedDirectory)
        await fulfillment(of: [cleanup], timeout: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    // Expected RED: every receiver was materialized before the feature-level cap,
    // and promise errors disappeared without reaching the UI.
    func testSyntheticPromiseEnforcesLimitsAndReportsFailures() async {
        let receiver = SyntheticPromiseReceiver(events: [
            .file(name: "one.txt", contents: "1"),
            .file(name: "two.txt", contents: "22"),
            .failure(name: "broken.eml")
        ])
        let callback = expectation(description: "limited callback")
        var deliveredCount = -1
        var issueKinds: Set<SupraFileDropIssue.Kind> = []
        let view = FileDropCatcherView()

        view.receivePromisedFiles(
            [receiver],
            alongside: [],
            limits: SupraFileDropLimits(maxFiles: 1, maxFileBytes: 10, maxTotalBytes: 10)
        ) { delivery in
            deliveredCount = delivery.urls.count
            issueKinds = Set(delivery.issues.map(\.kind))
            callback.fulfill()
        }

        await fulfillment(of: [callback], timeout: 2)
        XCTAssertEqual(deliveredCount, 1)
        XCTAssertTrue(issueKinds.contains(.tooManyFiles))
        XCTAssertTrue(issueKinds.contains(.receiveFailed))
    }

    // Expected RED: promise callbacks ran on a concurrent queue and were appended
    // in completion order, so a fast later receiver could reorder attachments.
    func testSyntheticPromisePreservesReceiverOrder() async {
        let first = DeferredSchedulingPromiseReceiver(fileName: "first.txt")
        let second = SyntheticPromiseReceiver(events: [.file(name: "second.txt", contents: "second")])
        let callback = expectation(description: "ordered callback")
        var names: [String] = []
        let view = FileDropCatcherView()

        view.receivePromisedFiles([first, second], alongside: [], limits: .standard) { delivery in
            names = delivery.urls.map(\.lastPathComponent)
            callback.fulfill()
        }

        await fulfillment(of: [callback], timeout: 2)
        XCTAssertEqual(names, ["first.txt", "second.txt"])
    }

    // Expected RED: an OperationQueue barrier can run before AppKit schedules a
    // reader operation for a promise that is not ready yet, delivering an empty
    // batch and deleting the destination before the callback arrives.
    func testPromiseWaitsForReaderScheduledAfterReceiveReturns() async {
        let receiver = DeferredSchedulingPromiseReceiver()
        let callback = expectation(description: "deferred promise callback")
        var names: [String] = []
        let view = FileDropCatcherView()

        view.receivePromisedFiles([receiver], alongside: [], limits: .standard) { delivery in
            names = delivery.urls.map(\.lastPathComponent)
            callback.fulfill()
        }

        await fulfillment(of: [callback], timeout: 2)
        XCTAssertEqual(names, ["deferred.txt"])
    }

    // Expected RED: the catcher accepted another operation while the first async
    // handler was suspended, so one completion could clear the shared busy state
    // while the other drop still owned temporary files.
    func testCatcherRejectsOverlappingDropsUntilHandlerCompletes() async throws {
        let file = try temporaryFile("Serialized drop delivery.")
        defer { try? FileManager.default.removeItem(at: file) }

        let firstStarted = expectation(description: "first handler started")
        let firstFinished = expectation(description: "first drop finished")
        let secondFinished = expectation(description: "second drop finished")
        var releaseFirst: CheckedContinuation<Void, Never>?
        var deliveryCount = 0
        var idleCount = 0
        let view = FileDropCatcherView()
        view.onProcessingChange = { processing in
            if !processing {
                idleCount += 1
                if idleCount == 1 { firstFinished.fulfill() }
                if idleCount == 2 { secondFinished.fulfill() }
            }
        }
        view.onDrop = { _ in
            deliveryCount += 1
            if deliveryCount == 1 {
                firstStarted.fulfill()
                await withCheckedContinuation { releaseFirst = $0 }
            }
        }
        view.refreshRegisteredTypes()

        let info = DragInfoStub(pasteboard: pasteboard(withFileURL: file))
        XCTAssertTrue(view.performDragOperation(info))
        await fulfillment(of: [firstStarted], timeout: 2)

        XCTAssertEqual(view.draggingEntered(info), [])
        XCTAssertFalse(view.performDragOperation(info), "an in-flight catcher must reject a second drop")
        XCTAssertEqual(deliveryCount, 1)

        try XCTUnwrap(releaseFirst).resume()
        await fulfillment(of: [firstFinished], timeout: 2)

        XCTAssertEqual(view.draggingEntered(info), .copy)
        XCTAssertTrue(view.performDragOperation(info))
        await fulfillment(of: [secondFinished], timeout: 2)
        XCTAssertEqual(deliveryCount, 2)
    }
}

private final class SyntheticPromiseReceiver: FilePromiseReceiving, @unchecked Sendable {
    enum Event: Sendable {
        case file(name: String, contents: String)
        case failure(name: String)
    }

    let events: [Event]
    let delay: TimeInterval

    init(events: [Event], delay: TimeInterval = 0) {
        self.events = events
        self.delay = delay
    }

    func receive(
        at destination: URL,
        operationQueue: OperationQueue,
        reader: @escaping @Sendable (URL, (any Error)?) -> Void
    ) -> Int {
        operationQueue.addOperation { [events, delay] in
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            for event in events {
                switch event {
                case let .file(name, contents):
                    let url = destination.appendingPathComponent(name)
                    do {
                        try Data(contents.utf8).write(to: url)
                        reader(url, nil)
                    } catch {
                        reader(url, error)
                    }
                case let .failure(name):
                    reader(
                        destination.appendingPathComponent(name),
                        NSError(domain: "SyntheticPromiseReceiver", code: 1)
                    )
                }
            }
        }
        return events.count
    }
}

private final class DeferredSchedulingPromiseReceiver: FilePromiseReceiving, @unchecked Sendable {
    let fileName: String

    init(fileName: String = "deferred.txt") {
        self.fileName = fileName
    }

    func receive(
        at destination: URL,
        operationQueue: OperationQueue,
        reader: @escaping @Sendable (URL, (any Error)?) -> Void
    ) -> Int {
        Task.detached { [fileName] in
            try? await Task.sleep(for: .milliseconds(50))
            operationQueue.addOperation {
                let url = destination.appendingPathComponent(fileName)
                do {
                    try Data("deferred".utf8).write(to: url)
                    reader(url, nil)
                } catch {
                    reader(url, error)
                }
            }
        }
        return 1
    }
}

private final class DragInfoStub: NSObject, NSDraggingInfo {
    private let pasteboard: NSPasteboard
    init(pasteboard: NSPasteboard) { self.pasteboard = pasteboard }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
