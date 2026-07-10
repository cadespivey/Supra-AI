import AppKit
@testable import SupraDesignSystem
import XCTest

/// Gating tests for the shared drop layer (T-DD-02…04): the AppKit-backed
/// catcher must deliver dropped file URLs to its handler, refuse drags while
/// disabled, and only accept plain file URLs when configured to (so it never
/// steals drags from SwiftUI `.dropDestination` targets layered beneath it).
///
/// File-promise receiving needs a live drag source writing the promise, so it
/// can't run hermetically — the URL path proves the view/delivery wiring.
@MainActor
final class SupraFileDropTests: XCTestCase {

    private func temporaryFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("supra-drop-test-\(UUID().uuidString).txt")
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// A private, uniquely-named pasteboard carrying one real file URL — the
    /// same shape a Finder drag delivers.
    private func pasteboard(withFileURL url: URL) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("supra-drop-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        return pasteboard
    }

    private func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    // Expected RED: compile error — cannot find 'FileDropCatcherView' in scope
    // (the shared drop layer does not exist yet).
    func testPerformDragOperationDeliversDroppedFileURLs() throws {
        let file = try temporaryFile("Coverage letter for the drop test.")
        defer { try? FileManager.default.removeItem(at: file) }

        var delivered: [[URL]] = []
        let view = FileDropCatcherView()
        view.acceptsFileURLs = true
        view.onFiles = { delivered.append($0) }
        view.refreshRegisteredTypes()

        let info = DragInfoStub(pasteboard: pasteboard(withFileURL: file))
        XCTAssertEqual(view.draggingEntered(info), .copy)
        XCTAssertTrue(view.performDragOperation(info))
        XCTAssertEqual(delivered.count, 1, "one drop must produce exactly one delivery")
        XCTAssertEqual(delivered.first?.map(canonical), [canonical(file)])
    }

    // Expected RED: same missing 'FileDropCatcherView' type.
    func testDraggingIsRejectedWhenDisabled() throws {
        let file = try temporaryFile("Ignored while disabled.")
        defer { try? FileManager.default.removeItem(at: file) }

        var delivered: [[URL]] = []
        let view = FileDropCatcherView()
        view.acceptsFileURLs = true
        view.isEnabled = false
        view.onFiles = { delivered.append($0) }
        view.refreshRegisteredTypes()

        let info = DragInfoStub(pasteboard: pasteboard(withFileURL: file))
        XCTAssertEqual(view.draggingEntered(info), [], "a disabled layer must refuse the drag")
        XCTAssertFalse(view.performDragOperation(info))
        XCTAssertTrue(delivered.isEmpty, "nothing may be delivered while disabled")
    }

    // Expected RED: same missing 'FileDropCatcherView' type. Wire-proof shape:
    // the non-default configuration (acceptsFileURLs: false) must make the
    // default outcome (URL delivery) absent, asserted on the exact callback.
    func testFileURLAcceptanceIsConfigurable() throws {
        let file = try temporaryFile("Should pass through to SwiftUI targets.")
        defer { try? FileManager.default.removeItem(at: file) }

        var delivered: [[URL]] = []
        let view = FileDropCatcherView()
        view.acceptsFileURLs = false
        view.onFiles = { delivered.append($0) }
        view.refreshRegisteredTypes()

        let info = DragInfoStub(pasteboard: pasteboard(withFileURL: file))
        XCTAssertEqual(
            view.draggingEntered(info), [],
            "a promises-only layer must refuse a plain file-URL drag so SwiftUI targets beneath receive it"
        )
        XCTAssertFalse(view.performDragOperation(info))
        XCTAssertTrue(delivered.isEmpty, "a URL-only drag must not be delivered when acceptsFileURLs is off")
    }
}

/// Minimal NSDraggingInfo for driving NSDraggingDestination methods directly.
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
    var animatesToDestination: Bool = false
    var numberOfValidItemsForDrop: Int = 0
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
