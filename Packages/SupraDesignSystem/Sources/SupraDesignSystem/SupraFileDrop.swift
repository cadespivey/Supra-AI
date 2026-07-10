import AppKit
import SwiftUI

/// Resource limits applied before receivers are started and again as promised
/// files finish materializing. A promise carries no reliable byte-size metadata,
/// so an oversized individual file can only be rejected and removed on callback.
public struct SupraFileDropLimits: Sendable, Equatable {
    public let maxFiles: Int
    public let maxFileBytes: Int64
    public let maxTotalBytes: Int64

    public init(maxFiles: Int, maxFileBytes: Int64, maxTotalBytes: Int64) {
        self.maxFiles = max(1, maxFiles)
        self.maxFileBytes = max(1, maxFileBytes)
        self.maxTotalBytes = max(1, maxTotalBytes)
    }

    public static let standard = SupraFileDropLimits(
        maxFiles: 20,
        maxFileBytes: 100 * 1_024 * 1_024,
        maxTotalBytes: 250 * 1_024 * 1_024
    )

    public static let chatAttachments = SupraFileDropLimits(
        maxFiles: 10,
        maxFileBytes: 50 * 1_024 * 1_024,
        maxTotalBytes: 100 * 1_024 * 1_024
    )
}

/// A recoverable problem encountered while receiving a drop. Successful files
/// and issues can coexist so callers can ingest the usable subset and still tell
/// the user what was skipped.
public struct SupraFileDropIssue: Sendable, Equatable {
    public enum Kind: String, Sendable, Hashable {
        case receiveFailed
        case tooManyFiles
        case fileTooLarge
        case totalSizeExceeded
        case temporaryDirectoryFailed
    }

    public let kind: Kind
    public let message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}

/// One accepted drop. Promised files live in an owned temporary directory for
/// exactly as long as the async drop handler runs. `cleanup()` is public for an
/// explicit early release; deinit is a final safety net.
public final class SupraFileDropDelivery: @unchecked Sendable {
    public let urls: [URL]
    public let issues: [SupraFileDropIssue]

    private let lock = NSLock()
    private var ownedDirectory: URL?

    init(urls: [URL], issues: [SupraFileDropIssue], ownedDirectory: URL?) {
        self.urls = urls
        self.issues = issues
        self.ownedDirectory = ownedDirectory
    }

    public var issueMessage: String? {
        issues.isEmpty ? nil : issues.map(\.message).joined(separator: "\n")
    }

    public func cleanup() {
        let directory = lock.withLock { () -> URL? in
            defer { ownedDirectory = nil }
            return ownedDirectory
        }
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    deinit {
        cleanup()
    }
}

/// A drop-catching layer that accepts both real file URLs and file promises,
/// including Mail messages and browser images. The async handler owns promised
/// URLs until it returns; the layer then removes its temporary files.
public extension View {
    func supraFileDrop(
        isEnabled: Bool = true,
        acceptsFileURLs: Bool = true,
        limits: SupraFileDropLimits = .standard,
        isTargeted: Binding<Bool>? = nil,
        isProcessing: Binding<Bool>? = nil,
        onDrop: @escaping @MainActor (SupraFileDropDelivery) async -> Void
    ) -> some View {
        overlay(
            FileDropCatcher(
                isEnabled: isEnabled,
                acceptsFileURLs: acceptsFileURLs,
                limits: limits,
                isTargeted: isTargeted,
                isProcessing: isProcessing,
                onDrop: onDrop
            )
        )
    }
}

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
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct FileDropCatcher: NSViewRepresentable {
    let isEnabled: Bool
    let acceptsFileURLs: Bool
    let limits: SupraFileDropLimits
    let isTargeted: Binding<Bool>?
    let isProcessing: Binding<Bool>?
    let onDrop: @MainActor (SupraFileDropDelivery) async -> Void

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
        view.limits = limits
        view.onTargetedChange = { targeted in isTargeted?.wrappedValue = targeted }
        view.onProcessingChange = { processing in isProcessing?.wrappedValue = processing }
        view.onDrop = onDrop
        view.refreshRegisteredTypes()
    }
}

/// Small adapter boundary so the asynchronous promise coordinator can be tested
/// without constructing a live AppKit dragging session.
protocol FilePromiseReceiving: AnyObject, Sendable {
    /// Starts fulfillment and returns the number of reader callbacks expected.
    func receive(
        at destination: URL,
        operationQueue: OperationQueue,
        reader: @escaping @Sendable (URL, (any Error)?) -> Void
    ) -> Int
}

private final class AppKitFilePromiseReceiver: FilePromiseReceiving, @unchecked Sendable {
    private let receiver: NSFilePromiseReceiver

    init(_ receiver: NSFilePromiseReceiver) {
        self.receiver = receiver
    }

    func receive(
        at destination: URL,
        operationQueue: OperationQueue,
        reader: @escaping @Sendable (URL, (any Error)?) -> Void
    ) -> Int {
        receiver.receivePromisedFiles(
            atDestination: destination,
            options: [:],
            operationQueue: operationQueue,
            reader: reader
        )
        // AppKit populates fileNames when the promises are called in. Modern
        // item-based drags report one name; legacy receivers may report several.
        return max(receiver.fileNames.count, 1)
    }
}

/// Invisible NSView registered for promise types and, optionally, file URLs.
/// Internal visibility lets the package tests drive its destination methods.
final class FileDropCatcherView: NSView {
    var isEnabled = true
    var acceptsFileURLs = true
    var limits: SupraFileDropLimits = .standard
    var onTargetedChange: ((Bool) -> Void)?
    var onProcessingChange: ((Bool) -> Void)?
    var onDrop: (@MainActor (SupraFileDropDelivery) async -> Void)?
    private var dropInFlight = false

    func refreshRegisteredTypes() {
        var types = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        if acceptsFileURLs { types.append(.fileURL) }
        // AppKit unions repeated registrations. Clear first so a true -> false
        // configuration change really stops claiming Finder URL drags.
        unregisterDraggedTypes()
        registerForDraggedTypes(types)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !dropInFlight,
              isEnabled,
              onDrop != nil,
              hasAcceptableItems(sender.draggingPasteboard) else { return [] }
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
        // Snapshot all mutable configuration at acceptance. Later SwiftUI updates
        // must not retarget an in-flight promise to a different day or chat.
        guard !dropInFlight, isEnabled, let handler = onDrop else { return false }
        let acceptedLimits = limits
        let processingChange = onProcessingChange
        let pasteboard = sender.draggingPasteboard

        let immediate: [URL]
        if acceptsFileURLs {
            immediate = pasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
            ) as? [URL] ?? []
        } else {
            immediate = []
        }
        let receivers = (
            pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver]
        )?.map(AppKitFilePromiseReceiver.init) ?? []

        guard !immediate.isEmpty || !receivers.isEmpty else { return false }
        dropInFlight = true
        processingChange?(true)
        receivePromisedFiles(
            receivers,
            alongside: immediate,
            limits: acceptedLimits,
            completion: { [weak self] in
                self?.dropInFlight = false
                processingChange?(false)
            },
            handler: handler
        )
        return true
    }

    /// Waits for every callback promised by every receiver before delivering a
    /// batch. A legacy receiver may invoke its reader more than once, and AppKit
    /// may schedule those reader operations after this method returns.
    func receivePromisedFiles(
        _ receivers: [any FilePromiseReceiving],
        alongside immediate: [URL],
        limits: SupraFileDropLimits,
        completion: (@MainActor () -> Void)? = nil,
        handler: @escaping @MainActor (SupraFileDropDelivery) async -> Void
    ) {
        let collector = ReceivedFileCollector(limits: limits)
        for (index, url) in immediate.enumerated() {
            collector.record(
                url: url,
                error: nil,
                isOwned: false,
                sourceIndex: index,
                callbackIndex: 0
            )
        }

        guard !receivers.isEmpty else {
            deliver(collector.delivery(ownedDirectory: nil), completion: completion, using: handler)
            return
        }

        let allowedReceiverCount = max(0, limits.maxFiles - collector.acceptedCount)
        let acceptedReceivers = Array(receivers.prefix(allowedReceiverCount))
        if receivers.count > acceptedReceivers.count {
            collector.recordIssue(
                kind: .tooManyFiles,
                message: "Only the first \(limits.maxFiles) dropped files can be received; the rest were skipped."
            )
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("SupraDroppedFiles-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            collector.recordIssue(
                kind: .temporaryDirectoryFailed,
                message: "Couldn't create temporary storage for the dropped files: \(error.localizedDescription)"
            )
            deliver(collector.delivery(ownedDirectory: nil), completion: completion, using: handler)
            return
        }

        guard !acceptedReceivers.isEmpty else {
            deliver(collector.delivery(ownedDirectory: destination), completion: completion, using: handler)
            return
        }

        let operationQueue = OperationQueue()
        operationQueue.name = "com.supralegal.file-promise-receiver"
        operationQueue.qualityOfService = .userInitiated
        // Preserve pasteboard receiver order. Feature consumers use the URL order
        // for attachment chips and ScratchPad's generated note text.
        operationQueue.maxConcurrentOperationCount = 1
        let coordinator = PromiseCallbackCoordinator(receiverCount: acceptedReceivers.count) {
            _ = operationQueue
            _ = acceptedReceivers
            let delivery = collector.delivery(ownedDirectory: destination)
            Task { @MainActor in
                defer {
                    delivery.cleanup()
                    completion?()
                }
                await handler(delivery)
            }
        }
        let callbackOrdinals = acceptedReceivers.map { _ in CallbackOrdinal() }
        for (index, receiver) in acceptedReceivers.enumerated() {
            let expectedCallbacks = receiver.receive(
                at: destination,
                operationQueue: operationQueue
            ) { url, error in
                collector.record(
                    url: url,
                    error: error,
                    isOwned: true,
                    sourceIndex: immediate.count + index,
                    callbackIndex: callbackOrdinals[index].next()
                )
                coordinator.recordCallback(forReceiverAt: index)
            }
            coordinator.setExpectedCallbacks(max(expectedCallbacks, 1), forReceiverAt: index)
        }
    }

    private func deliver(
        _ delivery: SupraFileDropDelivery,
        completion: (@MainActor () -> Void)?,
        using handler: @escaping @MainActor (SupraFileDropDelivery) async -> Void
    ) {
        Task { @MainActor in
            defer {
                delivery.cleanup()
                completion?()
            }
            await handler(delivery)
        }
    }

    private func hasAcceptableItems(_ pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        if acceptsFileURLs, types.contains(.fileURL) { return true }
        return NSFilePromiseReceiver.readableDraggedTypes
            .contains { types.contains(NSPasteboard.PasteboardType($0)) }
    }
}

private final class PromiseCallbackCoordinator: @unchecked Sendable {
    private struct ReceiverState {
        var expectedCallbacks: Int?
        var receivedCallbacks = 0
    }

    private let lock = NSLock()
    private var states: [ReceiverState]
    private var completion: (() -> Void)?

    init(receiverCount: Int, completion: @escaping () -> Void) {
        states = Array(repeating: ReceiverState(), count: receiverCount)
        self.completion = completion
    }

    func setExpectedCallbacks(_ count: Int, forReceiverAt index: Int) {
        finishIfReady(after: {
            states[index].expectedCallbacks = count
        })
    }

    func recordCallback(forReceiverAt index: Int) {
        finishIfReady(after: {
            states[index].receivedCallbacks += 1
        })
    }

    private func finishIfReady(after mutation: () -> Void) {
        let action = lock.withLock { () -> (() -> Void)? in
            mutation()
            guard states.allSatisfy({ state in
                guard let expected = state.expectedCallbacks else { return false }
                return state.receivedCallbacks >= expected
            }) else { return nil }
            defer { completion = nil }
            return completion
        }
        action?()
    }
}

private final class CallbackOrdinal: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            defer { value += 1 }
            return value
        }
    }
}

private final class ReceivedFileCollector: @unchecked Sendable {
    private struct OrderedURL {
        let sourceIndex: Int
        let callbackIndex: Int
        let url: URL
    }

    private let lock = NSLock()
    private let limits: SupraFileDropLimits
    private var urls: [OrderedURL] = []
    private var issues: [SupraFileDropIssue] = []
    private var totalBytes: Int64 = 0

    init(limits: SupraFileDropLimits) {
        self.limits = limits
    }

    var acceptedCount: Int {
        lock.withLock { urls.count }
    }

    func record(
        url: URL,
        error: (any Error)?,
        isOwned: Bool,
        sourceIndex: Int,
        callbackIndex: Int
    ) {
        if let error {
            if isOwned { try? FileManager.default.removeItem(at: url) }
            recordIssue(
                kind: .receiveFailed,
                message: "Couldn't receive \(url.lastPathComponent): \(error.localizedDescription)"
            )
            return
        }

        let byteCount = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let rejection: SupraFileDropIssue? = lock.withLock {
            if urls.count >= limits.maxFiles {
                return SupraFileDropIssue(
                    kind: .tooManyFiles,
                    message: "Only \(limits.maxFiles) dropped files can be accepted; \(url.lastPathComponent) was skipped."
                )
            }
            if byteCount > limits.maxFileBytes {
                return SupraFileDropIssue(
                    kind: .fileTooLarge,
                    message: "\(url.lastPathComponent) is too large to receive."
                )
            }
            if totalBytes + byteCount > limits.maxTotalBytes {
                return SupraFileDropIssue(
                    kind: .totalSizeExceeded,
                    message: "The dropped files exceed the total size limit; \(url.lastPathComponent) was skipped."
                )
            }
            urls.append(
                OrderedURL(sourceIndex: sourceIndex, callbackIndex: callbackIndex, url: url)
            )
            totalBytes += byteCount
            return nil
        }

        if let rejection {
            if isOwned { try? FileManager.default.removeItem(at: url) }
            lock.withLock { issues.append(rejection) }
        }
    }

    func recordIssue(kind: SupraFileDropIssue.Kind, message: String) {
        lock.withLock { issues.append(SupraFileDropIssue(kind: kind, message: message)) }
    }

    func delivery(ownedDirectory: URL?) -> SupraFileDropDelivery {
        lock.withLock {
            let orderedURLs = urls.sorted { lhs, rhs in
                (lhs.sourceIndex, lhs.callbackIndex) < (rhs.sourceIndex, rhs.callbackIndex)
            }.map(\.url)
            return SupraFileDropDelivery(urls: orderedURLs, issues: issues, ownedDirectory: ownedDirectory)
        }
    }
}
