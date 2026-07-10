import AppKit
import SwiftUI

/// A drop-catching layer that accepts BOTH real file URLs and file promises —
/// the drag flavor Mail/Outlook messages and browser images arrive as. SwiftUI's
/// `.dropDestination` never completes the promise handshake (the sender only
/// writes the file after an AppKit receiver asks for it), which is why dragging
/// an email onto a SwiftUI drop target does nothing. Surfaces that should take
/// "anything file-shaped" overlay this layer instead.
///
/// The layer is invisible and click-transparent (`hitTest` returns nil); it
/// participates only in drag routing. With `acceptsFileURLs: false` it registers
/// promise types ONLY, so plain Finder drags fall through to any SwiftUI
/// `.dropDestination` targets beneath it — the registered drag types stay
/// disjoint and AppKit never steals SwiftUI's drops.
public extension View {
    /// - Parameters:
    ///   - isEnabled: refuse all drags while false (e.g. a locked day, mid-generation).
    ///   - acceptsFileURLs: also take plain file-URL drags; turn OFF when SwiftUI
    ///     `.dropDestination(for: URL.self)` targets beneath this layer own those.
    ///   - isTargeted: mirrors drag-hover state for "drop here" chrome (`SupraDropHint`).
    ///   - onFiles: one batch of local file URLs per drop; promised files are
    ///     received into a unique temporary directory first.
    func supraFileDrop(
        isEnabled: Bool = true,
        acceptsFileURLs: Bool = true,
        isTargeted: Binding<Bool>? = nil,
        onFiles: @escaping ([URL]) -> Void
    ) -> some View {
        overlay(
            FileDropCatcher(
                isEnabled: isEnabled,
                acceptsFileURLs: acceptsFileURLs,
                isTargeted: isTargeted,
                onFiles: onFiles
            )
        )
    }
}

/// The standard "you can drop here" capsule, shown while a drag hovers a
/// `supraFileDrop` surface (same chrome as the Documents tab's import hint).
public struct SupraDropHint: View {
    private let label: String

    public init(_ label: String) {
        self.label = label
    }

    public var body: some View {
        Text(label)
            .padding(8)
            .background(.thinMaterial, in: Capsule())
            .padding(.top, 8)
    }
}

private struct FileDropCatcher: NSViewRepresentable {
    let isEnabled: Bool
    let acceptsFileURLs: Bool
    let isTargeted: Binding<Bool>?
    let onFiles: ([URL]) -> Void

    func makeNSView(context: Context) -> FileDropCatcherView {
        let view = FileDropCatcherView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: FileDropCatcherView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: FileDropCatcherView) {
        view.isEnabled = isEnabled
        view.acceptsFileURLs = acceptsFileURLs
        view.onTargetedChange = { targeted in isTargeted?.wrappedValue = targeted }
        view.onFiles = onFiles
        view.refreshRegisteredTypes()
    }
}

/// The AppKit half: an invisible NSView registered for file-promise and
/// (optionally) file-URL drag types. Internal, not private, so the package
/// tests can drive its `NSDraggingDestination` conformance directly.
final class FileDropCatcherView: NSView {
    var isEnabled = true
    var acceptsFileURLs = true
    var onTargetedChange: ((Bool) -> Void)?
    var onFiles: (([URL]) -> Void)?

    /// Queue the promise senders write their files on.
    private let promiseOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    func refreshRegisteredTypes() {
        var types = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        if acceptsFileURLs { types.append(.fileURL) }
        registerForDraggedTypes(types)
    }

    // Mouse events pass through — this layer exists only for drag routing.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard isEnabled, hasAcceptableItems(sender.draggingPasteboard) else { return [] }
        onTargetedChange?(true)
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onTargetedChange?(false)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        onTargetedChange?(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onTargetedChange?(false)
        guard isEnabled else { return false }
        let pasteboard = sender.draggingPasteboard

        var immediate: [URL] = []
        if acceptsFileURLs,
           let urls = pasteboard.readObjects(
               forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
           ) as? [URL] {
            immediate = urls
        }
        let receivers = (pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver]) ?? []

        guard !receivers.isEmpty else {
            guard !immediate.isEmpty else { return false }
            onFiles?(immediate)
            return true
        }
        receivePromisedFiles(receivers, alongside: immediate)
        return true
    }

    /// Receives promised files into a unique temp directory, then delivers them
    /// (with any plain URLs from the same drag) as one batch on the main actor.
    /// One leave per receiver: each dragged item is its own pasteboard item, so
    /// a receiver corresponds to one promised file (Apple's file-promise sample
    /// makes the same assumption), and the leave-once flag guards the rare
    /// multi-file receiver from over-leaving the group.
    private func receivePromisedFiles(_ receivers: [NSFilePromiseReceiver], alongside immediate: [URL]) {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("SupraDroppedFiles-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let collector = ReceivedFileCollector(immediate)
        let group = DispatchGroup()
        for receiver in receivers {
            group.enter()
            let leaveOnce = OnceFlag()
            receiver.receivePromisedFiles(
                atDestination: destination, options: [:], operationQueue: promiseOperationQueue
            ) { url, error in
                if error == nil { collector.append(url) }
                if leaveOnce.trip() { group.leave() }
            }
        }
        group.notify(queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let urls = collector.drain()
                guard !urls.isEmpty else { return }
                self.onFiles?(urls)
            }
        }
    }

    private func hasAcceptableItems(_ pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        if acceptsFileURLs, types.contains(.fileURL) { return true }
        return NSFilePromiseReceiver.readableDraggedTypes
            .contains { types.contains(NSPasteboard.PasteboardType($0)) }
    }
}

/// Thread-safe URL collector for the concurrent promise completions.
private final class ReceivedFileCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL]

    init(_ initial: [URL]) {
        self.urls = initial
    }

    func append(_ url: URL) {
        lock.withLock { urls.append(url) }
    }

    func drain() -> [URL] {
        lock.withLock { urls }
    }
}

/// Trips exactly once — a promise receiver's completion may fire per file.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var tripped = false

    func trip() -> Bool {
        lock.withLock {
            guard !tripped else { return false }
            tripped = true
            return true
        }
    }
}
