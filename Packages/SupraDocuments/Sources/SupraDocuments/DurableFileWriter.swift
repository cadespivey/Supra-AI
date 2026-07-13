import Darwin
import Foundation

/// Writes and validates a complete same-volume temporary file before atomically
/// installing it at its destination. An existing destination is never removed
/// first: POSIX `rename` performs the only replacement operation.
public struct DurableFileWriter: Sendable {
    public enum FaultStage: String, CaseIterable, Sendable {
        case beforeWrite
        case duringWrite
        case beforeSynchronize
        case beforeValidation
        case beforeInstall
    }

    public enum WriterError: Error, Equatable, Sendable {
        case invalidDestination
        case temporaryFileCreationFailed(Int32)
        case atomicInstallFailed(Int32)
    }

    public typealias FaultInjector = @Sendable (FaultStage) throws -> Void

    private let faultInjector: FaultInjector

    public init(faultInjector: @escaping FaultInjector = { _ in }) {
        self.faultInjector = faultInjector
    }

    /// Convenience for a complete in-memory payload.
    public func write(
        _ data: Data,
        to destination: URL,
        validator: (URL) throws -> Void
    ) throws {
        try write(
            to: destination,
            writer: { sink in try sink.write(data) },
            validator: validator
        )
    }

    /// Streaming entry point. `writer` may call `sink.write` repeatedly. The
    /// sink checks task cancellation at each chunk boundary.
    public func write(
        to destination: URL,
        writer: (DurableFileSink) throws -> Void,
        validator: (URL) throws -> Void
    ) throws {
        try Task.checkCancellation()
        let standardizedDestination = destination.standardizedFileURL
        guard standardizedDestination.isFileURL,
              !standardizedDestination.lastPathComponent.isEmpty else {
            throw WriterError.invalidDestination
        }

        let parent = standardizedDestination.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(
            ".\(standardizedDestination.lastPathComponent).supra-tmp-\(UUID().uuidString)",
            isDirectory: false
        )
        let handle = try Self.createExclusiveTemporaryFile(at: temporary)
        var handleIsOpen = true
        var installed = false
        defer {
            if handleIsOpen { try? handle.close() }
            if !installed { try? FileManager.default.removeItem(at: temporary) }
        }

        try faultInjector(.beforeWrite)
        let sink = DurableFileSink(handle: handle, beforeWrite: {
            try faultInjector(.duringWrite)
        })
        try writer(sink)
        try Task.checkCancellation()
        try faultInjector(.beforeSynchronize)
        try handle.synchronize()
        try handle.close()
        handleIsOpen = false

        try Task.checkCancellation()
        try faultInjector(.beforeValidation)
        try validator(temporary)
        try Task.checkCancellation()
        try faultInjector(.beforeInstall)
        try Self.atomicInstall(temporary, at: standardizedDestination)
        installed = true
    }

    private static func createExclusiveTemporaryFile(at url: URL) throws -> FileHandle {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw WriterError.temporaryFileCreationFailed(errno)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func atomicInstall(_ temporary: URL, at destination: URL) throws {
        let result = temporary.path.withCString { source in
            destination.path.withCString { target in
                Darwin.rename(source, target)
            }
        }
        guard result == 0 else {
            throw WriterError.atomicInstallFailed(errno)
        }
    }
}

/// A chunked sink owned by `DurableFileWriter`. It intentionally exposes no
/// close, synchronize, or destination operation; only the writer can commit.
public final class DurableFileSink {
    private let handle: FileHandle
    private let beforeWrite: () throws -> Void

    fileprivate init(handle: FileHandle, beforeWrite: @escaping () throws -> Void) {
        self.handle = handle
        self.beforeWrite = beforeWrite
    }

    public func write(_ data: Data) throws {
        try Task.checkCancellation()
        try beforeWrite()
        try handle.write(contentsOf: data)
    }
}
