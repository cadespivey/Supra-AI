import Darwin
import Foundation

/// Writes and validates a complete same-volume temporary file before atomically
/// installing it at its destination. An existing destination is never removed
/// first: POSIX `rename` performs the only replacement operation.
public struct DurableFileWriter: Sendable {
    fileprivate final class ManagedFileAnchor: @unchecked Sendable {
        let rootDescriptor: Int32
        let parentDescriptor: Int32
        let managedRootURL: URL?
        let parentURL: URL
        let relativeComponents: [String]
        let parentIdentity: InstalledFileIdentity
        let destinationName: String
        let allowsDetachedParentCleanup: Bool
        let exactFileDescriptor: Int32?

        init(
            retaining parent: ManagedParent,
            destinationName: String,
            allowsDetachedParentCleanup: Bool,
            exactFileDescriptor: Int32? = nil
        ) throws {
            let retainedRoot = DurableFileWriter.duplicateDescriptor(parent.rootDescriptor)
            guard retainedRoot >= 0 else {
                throw WriterError.unsafeManagedParent(errno)
            }
            let retainedParent = DurableFileWriter.duplicateDescriptor(parent.parentDescriptor)
            guard retainedParent >= 0 else {
                let code = errno
                Darwin.close(retainedRoot)
                throw WriterError.unsafeManagedParent(code)
            }
            let retainedFile: Int32?
            if let exactFileDescriptor {
                let duplicate = DurableFileWriter.duplicateDescriptor(exactFileDescriptor)
                guard duplicate >= 0 else {
                    let code = errno
                    Darwin.close(retainedParent)
                    Darwin.close(retainedRoot)
                    throw WriterError.fileIdentityInspectionFailed(code)
                }
                retainedFile = duplicate
            } else {
                retainedFile = nil
            }
            rootDescriptor = retainedRoot
            parentDescriptor = retainedParent
            self.exactFileDescriptor = retainedFile
            managedRootURL = parent.rootURL
            parentURL = parent.parentURL
            relativeComponents = parent.relativeComponents
            parentIdentity = parent.identity
            self.destinationName = destinationName
            self.allowsDetachedParentCleanup = allowsDetachedParentCleanup
        }

        init(
            parentDescriptor: Int32,
            parentURL: URL,
            destinationName: String,
            exactFileDescriptor: Int32? = nil
        ) throws {
            let identity: InstalledFileIdentity
            do {
                guard let captured = try DurableFileWriter.fileIdentity(
                    descriptor: parentDescriptor
                ) else {
                    throw WriterError.fileIdentityInspectionFailed(ENOENT)
                }
                identity = captured
            } catch {
                Darwin.close(parentDescriptor)
                throw error
            }
            let retainedRoot = DurableFileWriter.duplicateDescriptor(parentDescriptor)
            guard retainedRoot >= 0 else {
                let code = errno
                Darwin.close(parentDescriptor)
                throw WriterError.unsafeManagedParent(code)
            }
            let retainedFile: Int32?
            if let exactFileDescriptor {
                let duplicate = DurableFileWriter.duplicateDescriptor(exactFileDescriptor)
                guard duplicate >= 0 else {
                    let code = errno
                    Darwin.close(retainedRoot)
                    Darwin.close(parentDescriptor)
                    throw WriterError.fileIdentityInspectionFailed(code)
                }
                retainedFile = duplicate
            } else {
                retainedFile = nil
            }
            rootDescriptor = retainedRoot
            self.parentDescriptor = parentDescriptor
            self.exactFileDescriptor = retainedFile
            managedRootURL = nil
            self.parentURL = parentURL
            relativeComponents = []
            parentIdentity = identity
            self.destinationName = destinationName
            allowsDetachedParentCleanup = false
        }

        deinit {
            if let exactFileDescriptor { Darwin.close(exactFileDescriptor) }
            Darwin.close(parentDescriptor)
            Darwin.close(rootDescriptor)
        }

        func matches(destination: URL) -> Bool {
            destination.standardizedFileURL.deletingLastPathComponent().path
                    == parentURL.standardizedFileURL.path
                && destination.lastPathComponent == destinationName
        }

        func matches(destination: URL, managedRoot: URL) -> Bool {
            matches(destination: destination)
                && managedRootURL?.standardizedFileURL.path
                    == managedRoot.standardizedFileURL.path
        }
    }

    /// Opaque ownership token captured from the temporary file immediately before
    /// its atomic create-only install. Callers can later prove a quarantined file
    /// is still the exact installed inode rather than a same-path replacement.
    public struct InstalledFileIdentity: Equatable, @unchecked Sendable {
        fileprivate let device: dev_t
        fileprivate let inode: ino_t
        fileprivate let generation: UInt32
        fileprivate let managedAnchor: ManagedFileAnchor?

        fileprivate init(
            device: dev_t,
            inode: ino_t,
            generation: UInt32,
            managedAnchor: ManagedFileAnchor? = nil
        ) {
            self.device = device
            self.inode = inode
            self.generation = generation
            self.managedAnchor = managedAnchor
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.device == rhs.device
                && lhs.inode == rhs.inode
                && lhs.generation == rhs.generation
        }

        fileprivate func anchored(to anchor: ManagedFileAnchor) -> Self {
            Self(
                device: device,
                inode: inode,
                generation: generation,
                managedAnchor: anchor
            )
        }
    }

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
        case destinationExists
        case atomicInstallFailed(Int32)
        case parentDirectorySynchronizationFailed(Int32)
        case anchoredParentDirectorySynchronizationFailed(String)
        case restoredEntrySynchronizationFailed(String)
        case fileIdentityInspectionFailed(Int32)
        case unsafeManagedParent(Int32)
        case fileUnlinkFailed(Int32)
        case createOnlyRollbackFailed(Int32)
        case createOnlyRollbackConflict(String, Int32)
        case createOnlyRollbackSynchronizationFailed(String)
        case publicDestinationStillLinked(String)
        case publicDestinationStillLinkedWithoutRetainedQuarantine
        case publicDestinationStillLinkedAfterRemoval
        case quarantinePathChanged(String)
        case retainedQuarantineChanged(String)
        case postInstallStateUncertain(String)
        case managedTemporaryCleanupUncertain(String, String)
        case sourceNameReappeared(String)
        case retainedManagedFileChanged(String)
        case exactFileHasRemainingLinks(String, UInt64)
        case exactFileLinkStateUncertain(String, String)
        case exactFileSynchronizationFailed(Int32)
    }

    public typealias FaultInjector = @Sendable (FaultStage) throws -> Void
    typealias ParentDirectorySynchronizer = @Sendable (URL) throws -> Void
    typealias AnchoredParentDirectorySynchronizer = @Sendable (URL, Int32) throws -> Void
    typealias FileUnlinkCheckpoint = @Sendable (URL) throws -> Void
    typealias ManagedAnchorRetentionCheckpoint = @Sendable (URL) throws -> Void

    private let faultInjector: FaultInjector
    private let parentDirectorySynchronizer: ParentDirectorySynchronizer
    private let anchoredParentDirectorySynchronizer: AnchoredParentDirectorySynchronizer
    private let fileUnlinkCheckpoint: FileUnlinkCheckpoint
    private let beforeManagedAnchorRetention: ManagedAnchorRetentionCheckpoint

    public init(faultInjector: @escaping FaultInjector = { _ in }) {
        self.faultInjector = faultInjector
        self.parentDirectorySynchronizer = Self.synchronizeParentDirectory
        self.anchoredParentDirectorySynchronizer = { _, descriptor in
            try Self.synchronizeDirectory(descriptor)
        }
        self.fileUnlinkCheckpoint = { _ in }
        self.beforeManagedAnchorRetention = { _ in }
    }

    init(
        faultInjector: @escaping FaultInjector,
        parentDirectorySynchronizer: @escaping ParentDirectorySynchronizer,
        fileUnlinkCheckpoint: @escaping FileUnlinkCheckpoint = { _ in }
    ) {
        self.faultInjector = faultInjector
        self.parentDirectorySynchronizer = parentDirectorySynchronizer
        self.anchoredParentDirectorySynchronizer = { url, _ in
            try parentDirectorySynchronizer(url)
        }
        self.fileUnlinkCheckpoint = fileUnlinkCheckpoint
        self.beforeManagedAnchorRetention = { _ in }
    }

    /// Test seam for proving that descriptor-relative durability operations use
    /// the descriptor belonging to the labeled containing directory.
    init(
        faultInjector: @escaping FaultInjector,
        anchoredParentDirectorySynchronizer: @escaping AnchoredParentDirectorySynchronizer,
        beforeManagedAnchorRetention: @escaping ManagedAnchorRetentionCheckpoint = { _ in },
        fileUnlinkCheckpoint: @escaping FileUnlinkCheckpoint = { _ in }
    ) {
        self.faultInjector = faultInjector
        self.parentDirectorySynchronizer = Self.synchronizeParentDirectory
        self.anchoredParentDirectorySynchronizer = anchoredParentDirectorySynchronizer
        self.fileUnlinkCheckpoint = fileUnlinkCheckpoint
        self.beforeManagedAnchorRetention = beforeManagedAnchorRetention
    }

    /// Commits a caller-owned namespace change in the same durability domain as
    /// this writer's installs. Compensation code uses this after removing an
    /// installed file so it cannot report success before the parent directory
    /// records the unlink.
    public func synchronizeParentDirectory(of destination: URL) throws {
        let standardizedDestination = destination.standardizedFileURL
        guard standardizedDestination.isFileURL,
              !standardizedDestination.lastPathComponent.isEmpty else {
            throw WriterError.invalidDestination
        }
        try parentDirectorySynchronizer(
            standardizedDestination.deletingLastPathComponent()
        )
    }

    /// Convenience for a complete in-memory payload.
    public func write(
        _ data: Data,
        to destination: URL,
        validator: (URL) throws -> Void
    ) throws {
        _ = try performWrite(
            to: destination,
            installPolicy: .replace,
            writer: { sink in try sink.write(data) },
            validator: validator
        )
    }

    /// Writes a new file without replacing a destination that already exists.
    /// The exclusive rename is the collision boundary; callers must not rely on
    /// a prior `fileExists` check for correctness.
    public func writeNew(
        _ data: Data,
        to destination: URL,
        validator: (URL) throws -> Void
    ) throws {
        _ = try writeNewOwned(data, to: destination, validator: validator)
    }

    /// Create-only write that returns the exact installed file identity for a
    /// later ownership-safe compensation attempt.
    public func writeNewOwned(
        _ data: Data,
        to destination: URL,
        validator: (URL) throws -> Void
    ) throws -> InstalledFileIdentity {
        try performWrite(
            to: destination,
            installPolicy: .createExclusive,
            writer: { sink in try sink.write(data) },
            validator: validator
        )
    }

    /// Create-only write whose directory creation, temporary-file creation, and
    /// install are anchored to no-follow directory descriptors beneath a
    /// caller-configured managed root. A symlink occupying the root or any
    /// descendant parent is rejected before bytes are written through it.
    public func writeNewOwned(
        _ data: Data,
        to destination: URL,
        containedIn managedRoot: URL,
        validator: (Data) throws -> Void
    ) throws -> InstalledFileIdentity {
        try performContainedCreateOnlyWrite(
            data,
            to: destination,
            managedRoot: managedRoot,
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
        _ = try performWrite(
            to: destination,
            installPolicy: .replace,
            writer: writer,
            validator: validator
        )
    }

    /// Streaming create-only counterpart to `writeNew(_:to:validator:)`.
    public func writeNew(
        to destination: URL,
        writer: (DurableFileSink) throws -> Void,
        validator: (URL) throws -> Void
    ) throws {
        _ = try performWrite(
            to: destination,
            installPolicy: .createExclusive,
            writer: writer,
            validator: validator
        )
    }

    private enum InstallPolicy {
        case replace
        case createExclusive
    }

    private enum ManagedByteCountConstraint {
        case exact(Int)
        case maximum(Int)
    }

    private func performWrite(
        to destination: URL,
        installPolicy: InstallPolicy,
        writer: (DurableFileSink) throws -> Void,
        validator: (URL) throws -> Void
    ) throws -> InstalledFileIdentity {
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
        guard let installedFileIdentity = try Self.fileIdentity(at: temporary) else {
            throw WriterError.fileIdentityInspectionFailed(ENOENT)
        }
        try Self.atomicInstall(temporary, at: standardizedDestination, policy: installPolicy)
        installed = true
        do {
            try parentDirectorySynchronizer(parent)
        } catch {
            let installSynchronizationError = error
            guard installPolicy == .createExclusive else { throw error }
            let changedDirectory = try Self.rollbackCreateExclusiveInstall(
                at: standardizedDestination,
                quarantine: temporary,
                expectedIdentity: installedFileIdentity
            )
            if changedDirectory {
                do {
                    try parentDirectorySynchronizer(parent)
                } catch {
                    throw WriterError.createOnlyRollbackSynchronizationFailed(
                        error.localizedDescription
                    )
                }
            }
            throw installSynchronizationError
        }
        return installedFileIdentity
    }

    /// Compares a no-follow pathname identity with an install-time ownership
    /// token. A public-path comparison is suitable for fail-closed validation;
    /// destructive callers must still quarantine first so no pathname race can
    /// occur between comparison and deletion.
    public func matchesInstalledFileIdentity(
        _ expected: InstalledFileIdentity,
        at url: URL
    ) throws -> Bool {
        try Self.fileIdentity(at: url) == expected
    }

    /// Captures the no-follow identity currently occupying a path. Relaunch
    /// reconciliation uses this as an inspection token; it conveys no claim that
    /// the file was installed by this process.
    public func installedFileIdentity(at url: URL) throws -> InstalledFileIdentity? {
        try Self.fileIdentity(at: url)
    }

    /// Captures a no-follow identity together with duplicated descriptors for
    /// the managed root and final parent directory. The descriptors keep later
    /// destructive work bound to the directory inspected here even if its
    /// pathname is concurrently renamed or replaced.
    public func installedFileIdentity(
        at url: URL,
        containedIn managedRoot: URL
    ) throws -> InstalledFileIdentity? {
        let destination = url.standardizedFileURL
        let managedParent = try Self.openManagedParent(
            for: destination,
            managedRoot: managedRoot.standardizedFileURL,
            createMissingDirectories: false
        )
        defer { Self.close(managedParent) }
        guard let namedStatus = try Self.fileStatus(
            named: destination.lastPathComponent,
            in: managedParent.parentDescriptor
        ) else {
            return nil
        }
        guard Self.isRegularFile(namedStatus) else {
            throw WriterError.fileIdentityInspectionFailed(EFTYPE)
        }
        let identity = Self.fileIdentity(status: namedStatus)
        let exactFileDescriptor = destination.lastPathComponent.withCString {
            Darwin.openat(
                managedParent.parentDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard exactFileDescriptor >= 0 else {
            throw WriterError.fileIdentityInspectionFailed(errno)
        }
        defer { Darwin.close(exactFileDescriptor) }
        let exactStatus = try Self.fileStatus(descriptor: exactFileDescriptor)
        guard Self.isRegularFile(exactStatus),
              exactStatus.st_dev == identity.device,
              exactStatus.st_ino == identity.inode,
              exactStatus.st_gen == identity.generation else {
            throw WriterError.fileIdentityInspectionFailed(ESTALE)
        }
        let anchor = try ManagedFileAnchor(
            retaining: managedParent,
            destinationName: destination.lastPathComponent,
            allowsDetachedParentCleanup: false,
            exactFileDescriptor: exactFileDescriptor
        )
        return identity.anchored(to: anchor)
    }

    /// Reads and validates the exact installed inode through its retained
    /// managed-directory capability. The caller receives bytes only after the
    /// managed root/parent chain, descriptor identity, and public name have
    /// remained stable across validation and two equal reads from the same file
    /// descriptor. No pathname-based validator participates in this boundary.
    public func validatedInstalledFileData(
        matching expected: InstalledFileIdentity,
        at url: URL,
        containedIn managedRoot: URL,
        expectedByteCount: Int,
        validator: (Data) throws -> Void
    ) throws -> Data {
        let destination = url.standardizedFileURL
        let standardizedRoot = managedRoot.standardizedFileURL
        guard let anchor = expected.managedAnchor,
              anchor.matches(destination: destination, managedRoot: standardizedRoot),
              Self.managedAnchorIsReachable(anchor),
              try Self.fileIdentity(
                  named: destination.lastPathComponent,
                  in: anchor.parentDescriptor
              ) == expected else {
            throw WriterError.unsafeManagedParent(ESTALE)
        }

        let descriptor = try Self.exactFileDescriptor(
            from: anchor,
            named: destination.lastPathComponent
        )
        guard try Self.fileIdentity(descriptor: descriptor) == expected else {
            throw WriterError.fileIdentityInspectionFailed(ESTALE)
        }
        let first = try Self.fileData(
            descriptor: descriptor,
            matching: expected,
            expectedByteCount: expectedByteCount,
            named: destination.lastPathComponent
        )
        guard try Self.managedFileMatches(
            expected: expected,
            data: first,
            destination: destination,
            anchor: anchor,
            descriptor: descriptor,
            expectedByteCount: expectedByteCount,
            requiresSingleLink: true
        ) else {
            throw WriterError.retainedManagedFileChanged(destination.lastPathComponent)
        }

        try validator(first)

        guard try Self.managedFileMatches(
            expected: expected,
            data: first,
            destination: destination,
            anchor: anchor,
            descriptor: descriptor,
            expectedByteCount: expectedByteCount,
            requiresSingleLink: true
        ) else {
            throw WriterError.retainedManagedFileChanged(destination.lastPathComponent)
        }
        return first
    }

    /// Relaunch finalization durability boundary. The same exact descriptor is
    /// validated, synchronized, and reread before and after the retained parent
    /// directory is synchronized; Store finalization may follow only after this
    /// method returns the still-identical bytes.
    public func durablyValidatedInstalledFileData(
        matching expected: InstalledFileIdentity,
        at url: URL,
        containedIn managedRoot: URL,
        expectedByteCount: Int,
        validator: (Data) throws -> Void
    ) throws -> Data {
        let destination = url.standardizedFileURL
        let standardizedRoot = managedRoot.standardizedFileURL
        guard let anchor = expected.managedAnchor,
              anchor.matches(destination: destination, managedRoot: standardizedRoot),
              Self.managedAnchorIsReachable(anchor),
              try Self.fileIdentity(
                  named: destination.lastPathComponent,
                  in: anchor.parentDescriptor
              ) == expected else {
            throw WriterError.unsafeManagedParent(ESTALE)
        }
        let descriptor = try Self.exactFileDescriptor(
            from: anchor,
            named: destination.lastPathComponent
        )
        guard try Self.fileIdentity(descriptor: descriptor) == expected else {
            throw WriterError.fileIdentityInspectionFailed(ESTALE)
        }
        let validated = try Self.fileData(
            descriptor: descriptor,
            matching: expected,
            expectedByteCount: expectedByteCount,
            named: destination.lastPathComponent
        )
        guard try Self.managedFileMatches(
            expected: expected,
            data: validated,
            destination: destination,
            anchor: anchor,
            descriptor: descriptor,
            expectedByteCount: expectedByteCount,
            requiresSingleLink: true
        ) else {
            throw WriterError.retainedManagedFileChanged(destination.lastPathComponent)
        }
        try validator(validated)
        guard try Self.managedFileMatches(
            expected: expected,
            data: validated,
            destination: destination,
            anchor: anchor,
            descriptor: descriptor,
            expectedByteCount: expectedByteCount,
            requiresSingleLink: true
        ) else {
            throw WriterError.retainedManagedFileChanged(destination.lastPathComponent)
        }

        try faultInjector(.beforeSynchronize)
        guard Darwin.fsync(descriptor) == 0 else {
            throw WriterError.exactFileSynchronizationFailed(errno)
        }
        guard try Self.managedFileMatches(
            expected: expected,
            data: validated,
            destination: destination,
            anchor: anchor,
            descriptor: descriptor,
            expectedByteCount: expectedByteCount,
            requiresSingleLink: true
        ) else {
            throw WriterError.retainedManagedFileChanged(destination.lastPathComponent)
        }
        do {
            try anchoredParentDirectorySynchronizer(
                anchor.parentURL,
                anchor.parentDescriptor
            )
        } catch {
            throw WriterError.anchoredParentDirectorySynchronizationFailed(
                error.localizedDescription
            )
        }
        guard try Self.managedFileMatches(
            expected: expected,
            data: validated,
            destination: destination,
            anchor: anchor,
            descriptor: descriptor,
            expectedByteCount: expectedByteCount,
            requiresSingleLink: true
        ) else {
            throw WriterError.retainedManagedFileChanged(destination.lastPathComponent)
        }
        return validated
    }

    /// Removes a pathname only when its current no-follow identity still equals
    /// the caller's inspection token. POSIX `unlink` is intentionally
    /// nonrecursive: a directory substituted after inspection is preserved.
    @discardableResult
    public func unlinkFile(
        matching expected: InstalledFileIdentity,
        at url: URL
    ) throws -> Bool {
        let destination = url.standardizedFileURL
        let anchor = try Self.anchor(for: expected, destination: destination)
        guard try Self.fileIdentity(
            named: destination.lastPathComponent,
            in: anchor.parentDescriptor
        ) == expected else {
            return false
        }
        try fileUnlinkCheckpoint(url)
        return try Self.removeEntry(
            named: destination.lastPathComponent,
            matching: expected,
            in: anchor.parentDescriptor
        )
    }

    /// Managed-root counterpart to `unlinkFile(matching:at:)`. The ownership
    /// token's retained descriptor is preferred; relaunch callers can obtain one
    /// with `installedFileIdentity(at:containedIn:)`. A successful unlink is
    /// synchronized through the same anchored parent descriptor.
    @discardableResult
    public func unlinkFile(
        matching expected: InstalledFileIdentity,
        at url: URL,
        containedIn managedRoot: URL
    ) throws -> Bool {
        try unlinkFile(
            matching: expected,
            at: url,
            containedIn: managedRoot,
            maximumByteCount: ImportPolicy.default.maxInputBytes,
            contentValidator: { _ in }
        )
    }

    /// Content-bound managed unlink used by relaunch cleanup. The writer owns
    /// the last callback and performs a final exact-descriptor reread after it;
    /// no caller-controlled work occurs between that rebind and unlink.
    @discardableResult
    public func unlinkFile(
        matching expected: InstalledFileIdentity,
        at url: URL,
        containedIn managedRoot: URL,
        expectedByteCount: Int,
        contentValidator: (Data) throws -> Void
    ) throws -> Bool {
        try unlinkFile(
            matching: expected,
            at: url,
            containedIn: managedRoot,
            byteCountConstraint: .exact(expectedByteCount),
            contentValidator: contentValidator
        )
    }

    /// Managed temporary cleanup accepts an authoritative maximum because an
    /// interrupted writer may have durably produced only a payload prefix.
    @discardableResult
    public func unlinkFile(
        matching expected: InstalledFileIdentity,
        at url: URL,
        containedIn managedRoot: URL,
        maximumByteCount: Int,
        contentValidator: (Data) throws -> Void
    ) throws -> Bool {
        try unlinkFile(
            matching: expected,
            at: url,
            containedIn: managedRoot,
            byteCountConstraint: .maximum(maximumByteCount),
            contentValidator: contentValidator
        )
    }

    private func unlinkFile(
        matching expected: InstalledFileIdentity,
        at url: URL,
        containedIn managedRoot: URL,
        byteCountConstraint: ManagedByteCountConstraint,
        contentValidator: (Data) throws -> Void
    ) throws -> Bool {
        let destination = url.standardizedFileURL
        let anchor = try Self.anchor(
            for: expected,
            destination: destination,
            managedRoot: managedRoot.standardizedFileURL
        )
        let exactFileDescriptor = try Self.exactFileDescriptor(
            from: anchor,
            named: destination.lastPathComponent
        )
        guard try Self.fileIdentity(
            named: destination.lastPathComponent,
            in: anchor.parentDescriptor
        ) == expected else {
            let count = try Self.linkCount(
                descriptor: exactFileDescriptor,
                named: destination.lastPathComponent
            )
            if count > 0 {
                throw WriterError.exactFileHasRemainingLinks(
                    destination.lastPathComponent,
                    count
                )
            }
            return false
        }
        guard try Self.fileIdentity(descriptor: exactFileDescriptor) == expected else {
            throw WriterError.fileIdentityInspectionFailed(ESTALE)
        }
        let validatedData = try Self.fileData(
            descriptor: exactFileDescriptor,
            matching: expected,
            constraint: byteCountConstraint,
            named: destination.lastPathComponent
        )
        try contentValidator(validatedData)
        guard try Self.managedFileMatches(
            expected: expected,
            data: validatedData,
            destination: destination,
            anchor: anchor,
            descriptor: exactFileDescriptor,
            expectedByteCount: validatedData.count,
            requiresSingleLink: false
        ) else {
            throw WriterError.retainedManagedFileChanged(destination.lastPathComponent)
        }
        try fileUnlinkCheckpoint(url)
        guard (anchor.allowsDetachedParentCleanup || Self.managedAnchorIsReachable(anchor)),
              try Self.fileIdentity(descriptor: exactFileDescriptor) == expected,
              try Self.fileIdentity(
                  named: destination.lastPathComponent,
                  in: anchor.parentDescriptor
              ) == expected,
              try Self.fileData(
                  descriptor: exactFileDescriptor,
                  matching: expected,
                  expectedByteCount: validatedData.count,
                  named: destination.lastPathComponent
              ) == validatedData,
              try Self.fileData(
                  named: destination.lastPathComponent,
                  in: anchor.parentDescriptor,
                  matching: expected,
                  expectedByteCount: validatedData.count
              ) == validatedData else {
            throw WriterError.retainedManagedFileChanged(destination.lastPathComponent)
        }
        let removed = try Self.removeEntry(
            named: destination.lastPathComponent,
            matching: expected,
            in: anchor.parentDescriptor
        )
        if removed {
            var synchronizationError: Error?
            do {
                try anchoredParentDirectorySynchronizer(anchor.parentURL, anchor.parentDescriptor)
            } catch {
                synchronizationError = error
            }
            guard try Self.fileIdentity(
                named: destination.lastPathComponent,
                in: anchor.parentDescriptor
            ) == nil,
                  try Self.fileIdentity(at: destination) == nil else {
                throw WriterError.sourceNameReappeared(destination.lastPathComponent)
            }
            let remainingLinkCount = try Self.linkCount(
                descriptor: exactFileDescriptor,
                named: destination.lastPathComponent
            )
            if remainingLinkCount > 0 {
                throw WriterError.exactFileHasRemainingLinks(
                    destination.lastPathComponent,
                    remainingLinkCount
                )
            }
            if let synchronizationError {
                throw WriterError.anchoredParentDirectorySynchronizationFailed(
                    synchronizationError.localizedDescription
                )
            }
        }
        return removed
    }

    /// Quarantines a just-installed managed file through the retained parent
    /// descriptor, validates its exact bytes, then removes only the owned inode.
    /// The exact quarantine is restored only when initial content validation or
    /// a callback fails without changing its identity. Changed or missing names
    /// are left untouched and surfaced as explicit recovery states.
    @discardableResult
    public func removeInstalledFile(
        matching expected: InstalledFileIdentity,
        at url: URL,
        containedIn managedRoot: URL,
        missingIsSuccess: Bool = false,
        quarantineCheckpoint: (URL, URL) throws -> Void = { _, _ in },
        contentValidator: (Data) throws -> Void,
        preRemovalCheckpoint: (URL) throws -> Void = { _ in }
    ) throws -> Bool {
        try removeInstalledFile(
            matching: expected,
            at: url,
            containedIn: managedRoot,
            byteCountConstraint: .maximum(ImportPolicy.default.maxInputBytes),
            missingIsSuccess: missingIsSuccess,
            quarantineCheckpoint: quarantineCheckpoint,
            contentValidator: contentValidator,
            preRemovalCheckpoint: preRemovalCheckpoint
        )
    }

    @discardableResult
    public func removeInstalledFile(
        matching expected: InstalledFileIdentity,
        at url: URL,
        containedIn managedRoot: URL,
        expectedByteCount: Int,
        missingIsSuccess: Bool = false,
        quarantineCheckpoint: (URL, URL) throws -> Void = { _, _ in },
        contentValidator: (Data) throws -> Void,
        preRemovalCheckpoint: (URL) throws -> Void = { _ in }
    ) throws -> Bool {
        try removeInstalledFile(
            matching: expected,
            at: url,
            containedIn: managedRoot,
            byteCountConstraint: .exact(expectedByteCount),
            missingIsSuccess: missingIsSuccess,
            quarantineCheckpoint: quarantineCheckpoint,
            contentValidator: contentValidator,
            preRemovalCheckpoint: preRemovalCheckpoint
        )
    }

    private func removeInstalledFile(
        matching expected: InstalledFileIdentity,
        at url: URL,
        containedIn managedRoot: URL,
        byteCountConstraint: ManagedByteCountConstraint,
        missingIsSuccess: Bool,
        quarantineCheckpoint: (URL, URL) throws -> Void,
        contentValidator: (Data) throws -> Void,
        preRemovalCheckpoint: (URL) throws -> Void
    ) throws -> Bool {
        do {
            return try removeInstalledFileBound(
                matching: expected,
                at: url,
                containedIn: managedRoot,
                byteCountConstraint: byteCountConstraint,
                missingIsSuccess: missingIsSuccess,
                quarantineCheckpoint: quarantineCheckpoint,
                contentValidator: contentValidator,
                preRemovalCheckpoint: preRemovalCheckpoint
            )
        } catch let WriterError.retainedManagedFileChanged(name) {
            throw WriterError.retainedQuarantineChanged(name)
        }
    }

    private func removeInstalledFileBound(
        matching expected: InstalledFileIdentity,
        at url: URL,
        containedIn managedRoot: URL,
        byteCountConstraint: ManagedByteCountConstraint,
        missingIsSuccess: Bool,
        quarantineCheckpoint: (URL, URL) throws -> Void,
        contentValidator: (Data) throws -> Void,
        preRemovalCheckpoint: (URL) throws -> Void
    ) throws -> Bool {
        let destination = url.standardizedFileURL
        guard let anchor = expected.managedAnchor,
              anchor.matches(
                  destination: destination,
                  managedRoot: managedRoot.standardizedFileURL
        ) else {
            throw WriterError.unsafeManagedParent(ESTALE)
        }
        let exactFileDescriptor = try Self.exactFileDescriptor(
            from: anchor,
            named: destination.lastPathComponent
        )
        guard try Self.fileIdentity(descriptor: exactFileDescriptor) == expected else {
            throw WriterError.fileIdentityInspectionFailed(ESTALE)
        }
        if try Self.fileIdentity(
            named: destination.lastPathComponent,
            in: anchor.parentDescriptor
        ) == expected {
            let preflightData = try Self.fileData(
                descriptor: exactFileDescriptor,
                matching: expected,
                constraint: byteCountConstraint,
                named: destination.lastPathComponent
            )
            guard try Self.fileData(
                named: destination.lastPathComponent,
                in: anchor.parentDescriptor,
                matching: expected,
                expectedByteCount: preflightData.count
            ) == preflightData,
                  try Self.fileData(
                      descriptor: exactFileDescriptor,
                      matching: expected,
                      expectedByteCount: preflightData.count,
                      named: destination.lastPathComponent
                  ) == preflightData,
                  try Self.fileIdentity(
                      named: destination.lastPathComponent,
                      in: anchor.parentDescriptor
                  ) == expected else {
                throw WriterError.retainedManagedFileChanged(
                    destination.lastPathComponent
                )
            }
        }
        guard let quarantineName = try Self.quarantineEntry(
            named: destination.lastPathComponent,
            in: anchor.parentDescriptor,
            quarantineName: {
                ".supra-draft-rollback-\(UUID().uuidString.lowercased())-\(destination.lastPathComponent)"
            }
        ) else {
            if try Self.fileIdentity(at: destination) == expected {
                throw WriterError.publicDestinationStillLinkedWithoutRetainedQuarantine
            }
            let count = try Self.linkCount(
                descriptor: exactFileDescriptor,
                named: destination.lastPathComponent
            )
            guard count == 0 else {
                throw WriterError.exactFileHasRemainingLinks(
                    destination.lastPathComponent,
                    count
                )
            }
            return missingIsSuccess
        }
        let quarantineURL = anchor.parentURL.appendingPathComponent(
            quarantineName,
            isDirectory: false
        )
        guard let quarantinedIdentity = try Self.fileIdentity(
            named: quarantineName,
            in: anchor.parentDescriptor
        ) else {
            if try Self.fileIdentity(at: destination) == expected {
                throw WriterError.publicDestinationStillLinkedWithoutRetainedQuarantine
            }
            return false
        }
        if quarantinedIdentity != expected {
            var checkpointError: Error?
            do {
                try quarantineCheckpoint(destination, quarantineURL)
            } catch {
                checkpointError = error
            }
            let currentQuarantineIdentity = try Self.fileIdentity(
                named: quarantineName,
                in: anchor.parentDescriptor
            )
            let exactFileRemainsPublic = try Self.fileIdentity(at: destination) == expected
            guard currentQuarantineIdentity == quarantinedIdentity else {
                if exactFileRemainsPublic {
                    throw WriterError.publicDestinationStillLinkedWithoutRetainedQuarantine
                }
                throw WriterError.quarantinePathChanged(quarantineName)
            }
            if exactFileRemainsPublic {
                throw WriterError.publicDestinationStillLinkedWithoutRetainedQuarantine
            }
            guard try restoreOwnedEntryDurably(
                named: quarantineName,
                to: destination.lastPathComponent,
                matching: quarantinedIdentity,
                anchor: anchor
            ) else {
                throw WriterError.createOnlyRollbackConflict(quarantineName, ESTALE)
            }
            if let checkpointError { throw checkpointError }
            return false
        }
        let initialQuarantineData = try Self.fileData(
            descriptor: exactFileDescriptor,
            matching: expected,
            constraint: byteCountConstraint,
            named: quarantineName
        )
        guard try Self.fileData(
            named: quarantineName,
            in: anchor.parentDescriptor,
            matching: expected,
            expectedByteCount: initialQuarantineData.count
        ) == initialQuarantineData else {
            throw WriterError.retainedQuarantineChanged(quarantineName)
        }

        do {
            try quarantineCheckpoint(destination, quarantineURL)
        } catch {
            switch try Self.quarantinePublicState(
                quarantineName: quarantineName,
                parentDescriptor: anchor.parentDescriptor,
                destination: destination,
                expected: expected
            ) {
            case .exactQuarantineOnly:
                guard try Self.fileData(
                    named: quarantineName,
                    in: anchor.parentDescriptor,
                    matching: expected,
                    expectedByteCount: initialQuarantineData.count
                ) == initialQuarantineData,
                      try Self.fileData(
                          descriptor: exactFileDescriptor,
                          matching: expected,
                          expectedByteCount: initialQuarantineData.count,
                          named: quarantineName
                      )
                        == initialQuarantineData else {
                    throw WriterError.retainedQuarantineChanged(quarantineName)
                }
                guard try restoreOwnedEntryDurably(
                    named: quarantineName,
                    to: destination.lastPathComponent,
                    matching: expected,
                    anchor: anchor
                ) else {
                    throw WriterError.createOnlyRollbackConflict(quarantineName, ESTALE)
                }
                throw error
            case .exactQuarantineAndPublic:
                throw WriterError.publicDestinationStillLinked(quarantineName)
            case .publicWithoutExactQuarantine:
                throw WriterError.publicDestinationStillLinkedWithoutRetainedQuarantine
            case .quarantineChangedOrMissing:
                throw WriterError.quarantinePathChanged(quarantineName)
            }
        }
        try Self.requireExactQuarantineOnly(
            quarantineName: quarantineName,
            parentDescriptor: anchor.parentDescriptor,
            destination: destination,
            expected: expected
        )

        var firstCandidate: Data?
        do {
            let candidate = try Self.fileData(
                descriptor: exactFileDescriptor,
                matching: expected,
                expectedByteCount: initialQuarantineData.count,
                named: quarantineName
            )
            guard try Self.fileData(
                named: quarantineName,
                in: anchor.parentDescriptor,
                matching: expected,
                expectedByteCount: initialQuarantineData.count
            ) == candidate else {
                throw WriterError.retainedQuarantineChanged(quarantineName)
            }
            firstCandidate = candidate
            try contentValidator(candidate)
        } catch {
            switch try Self.quarantinePublicState(
                quarantineName: quarantineName,
                parentDescriptor: anchor.parentDescriptor,
                destination: destination,
                expected: expected
            ) {
            case .exactQuarantineOnly:
                if let firstCandidate,
                   try Self.fileData(
                       named: quarantineName,
                       in: anchor.parentDescriptor,
                       matching: expected,
                       expectedByteCount: firstCandidate.count
                   ) != firstCandidate
                    || (try Self.fileData(
                        descriptor: exactFileDescriptor,
                        matching: expected,
                        expectedByteCount: firstCandidate.count,
                        named: quarantineName
                    ))
                        != firstCandidate {
                    throw WriterError.retainedQuarantineChanged(quarantineName)
                }
                guard try restoreOwnedEntryDurably(
                    named: quarantineName,
                    to: destination.lastPathComponent,
                    matching: expected,
                    anchor: anchor
                ) else {
                    throw WriterError.createOnlyRollbackConflict(quarantineName, ESTALE)
                }
                throw error
            case .exactQuarantineAndPublic:
                throw WriterError.publicDestinationStillLinked(quarantineName)
            case .publicWithoutExactQuarantine:
                throw WriterError.publicDestinationStillLinkedWithoutRetainedQuarantine
            case .quarantineChangedOrMissing:
                throw WriterError.quarantinePathChanged(quarantineName)
            }
        }
        try Self.requireExactQuarantineOnly(
            quarantineName: quarantineName,
            parentDescriptor: anchor.parentDescriptor,
            destination: destination,
            expected: expected
        )
        guard let validatedQuarantineData = firstCandidate,
              try Self.fileData(
                  descriptor: exactFileDescriptor,
                  matching: expected,
                  expectedByteCount: validatedQuarantineData.count,
                  named: quarantineName
              )
                == validatedQuarantineData,
              try Self.fileData(
                  named: quarantineName,
                  in: anchor.parentDescriptor,
                  matching: expected,
                  expectedByteCount: validatedQuarantineData.count
              ) == validatedQuarantineData else {
            throw WriterError.retainedQuarantineChanged(quarantineName)
        }

        do {
            try preRemovalCheckpoint(quarantineURL)
        } catch {
            switch try Self.quarantinePublicState(
                quarantineName: quarantineName,
                parentDescriptor: anchor.parentDescriptor,
                destination: destination,
                expected: expected
            ) {
            case .exactQuarantineOnly:
                guard try Self.fileData(
                    named: quarantineName,
                    in: anchor.parentDescriptor,
                    matching: expected,
                    expectedByteCount: validatedQuarantineData.count
                ) == validatedQuarantineData,
                      try Self.fileData(
                          descriptor: exactFileDescriptor,
                          matching: expected,
                          expectedByteCount: validatedQuarantineData.count,
                          named: quarantineName
                      )
                        == validatedQuarantineData else {
                    throw WriterError.retainedQuarantineChanged(quarantineName)
                }
                guard try restoreOwnedEntryDurably(
                    named: quarantineName,
                    to: destination.lastPathComponent,
                    matching: expected,
                    anchor: anchor
                ) else {
                    throw WriterError.createOnlyRollbackConflict(quarantineName, ESTALE)
                }
                throw error
            case .exactQuarantineAndPublic:
                throw WriterError.publicDestinationStillLinked(quarantineName)
            case .publicWithoutExactQuarantine:
                throw WriterError.publicDestinationStillLinkedWithoutRetainedQuarantine
            case .quarantineChangedOrMissing:
                throw WriterError.quarantinePathChanged(quarantineName)
            }
        }
        try Self.requireExactQuarantineOnly(
            quarantineName: quarantineName,
            parentDescriptor: anchor.parentDescriptor,
            destination: destination,
            expected: expected
        )
        guard try Self.fileData(
            named: quarantineName,
            in: anchor.parentDescriptor,
            matching: expected,
            expectedByteCount: validatedQuarantineData.count
        ) == validatedQuarantineData,
              try Self.fileData(
                  descriptor: exactFileDescriptor,
                  matching: expected,
                  expectedByteCount: validatedQuarantineData.count,
                  named: quarantineName
              )
                == validatedQuarantineData else {
            throw WriterError.retainedQuarantineChanged(quarantineName)
        }

        var finalCandidate: Data?
        do {
            let candidate = try Self.fileData(
                descriptor: exactFileDescriptor,
                matching: expected,
                expectedByteCount: validatedQuarantineData.count,
                named: quarantineName
            )
            guard try Self.fileData(
                named: quarantineName,
                in: anchor.parentDescriptor,
                matching: expected,
                expectedByteCount: validatedQuarantineData.count
            ) == candidate else {
                throw WriterError.retainedQuarantineChanged(quarantineName)
            }
            guard candidate == validatedQuarantineData else {
                throw WriterError.retainedQuarantineChanged(quarantineName)
            }
            finalCandidate = candidate
            try contentValidator(candidate)
        } catch {
            switch try Self.quarantinePublicState(
                quarantineName: quarantineName,
                parentDescriptor: anchor.parentDescriptor,
                destination: destination,
                expected: expected
            ) {
            case .exactQuarantineOnly:
                throw WriterError.retainedQuarantineChanged(quarantineName)
            case .exactQuarantineAndPublic:
                throw WriterError.publicDestinationStillLinked(quarantineName)
            case .publicWithoutExactQuarantine:
                throw WriterError.publicDestinationStillLinkedWithoutRetainedQuarantine
            case .quarantineChangedOrMissing:
                throw WriterError.quarantinePathChanged(quarantineName)
            }
        }
        try Self.requireExactQuarantineOnly(
            quarantineName: quarantineName,
            parentDescriptor: anchor.parentDescriptor,
            destination: destination,
            expected: expected
        )
        guard let finalCandidate,
              try Self.fileData(
                  descriptor: exactFileDescriptor,
                  matching: expected,
                  expectedByteCount: finalCandidate.count,
                  named: quarantineName
              ) == finalCandidate,
              try Self.fileData(
                  named: quarantineName,
                  in: anchor.parentDescriptor,
                  matching: expected,
                  expectedByteCount: finalCandidate.count
              ) == finalCandidate else {
            throw WriterError.retainedQuarantineChanged(quarantineName)
        }
        let removed = try Self.removeEntry(
            named: quarantineName,
            matching: expected,
            in: anchor.parentDescriptor
        )
        if removed {
            var synchronizationError: Error?
            do {
                try anchoredParentDirectorySynchronizer(anchor.parentURL, anchor.parentDescriptor)
            } catch {
                synchronizationError = error
            }
            guard try Self.fileIdentity(
                named: quarantineName,
                in: anchor.parentDescriptor
            ) == nil,
                  try Self.fileIdentity(at: quarantineURL) == nil else {
                throw WriterError.sourceNameReappeared(quarantineName)
            }
            if try Self.fileIdentity(at: destination) == expected {
                throw WriterError.publicDestinationStillLinkedAfterRemoval
            }
            let remainingLinkCount = try Self.linkCount(
                descriptor: exactFileDescriptor,
                named: quarantineName
            )
            if remainingLinkCount > 0 {
                throw WriterError.exactFileHasRemainingLinks(
                    quarantineName,
                    remainingLinkCount
                )
            }
            if let synchronizationError {
                throw WriterError.anchoredParentDirectorySynchronizationFailed(
                    synchronizationError.localizedDescription
                )
            }
        }
        if !removed, try Self.fileIdentity(at: destination) == expected {
            throw WriterError.publicDestinationStillLinkedAfterRemoval
        }
        return removed
    }

    /// Restoring a quarantined entry is itself a namespace mutation. Commit the
    /// restore through the retained parent descriptor before reporting either a
    /// not-owned result or the caller error that triggered compensation.
    private func restoreOwnedEntryDurably(
        named quarantineName: String,
        to destinationName: String,
        matching expected: InstalledFileIdentity,
        anchor: ManagedFileAnchor
    ) throws -> Bool {
        guard try Self.restoreOwnedEntry(
            named: quarantineName,
            to: destinationName,
            matching: expected,
            in: anchor.parentDescriptor
        ) else {
            return false
        }
        do {
            try anchoredParentDirectorySynchronizer(
                anchor.parentURL,
                anchor.parentDescriptor
            )
        } catch {
            throw WriterError.restoredEntrySynchronizationFailed(
                error.localizedDescription
            )
        }
        return true
    }

    fileprivate struct ManagedParent {
        let rootDescriptor: Int32
        let parentDescriptor: Int32
        let rootURL: URL
        let parentURL: URL
        let relativeComponents: [String]
        let identity: InstalledFileIdentity
    }

    private func performContainedCreateOnlyWrite(
        _ data: Data,
        to destination: URL,
        managedRoot: URL,
        validator: (Data) throws -> Void
    ) throws -> InstalledFileIdentity {
        try Task.checkCancellation()
        let standardizedDestination = destination.standardizedFileURL
        let standardizedRoot = managedRoot.standardizedFileURL
        guard standardizedDestination.isFileURL,
              standardizedRoot.isFileURL,
              !standardizedDestination.lastPathComponent.isEmpty else {
            throw WriterError.invalidDestination
        }

        let managedParent = try Self.openManagedParent(
            for: standardizedDestination,
            managedRoot: standardizedRoot,
            directoryAuthenticator: anchoredParentDirectorySynchronizer
        )
        var temporaryName = ".\(standardizedDestination.lastPathComponent).supra-tmp-\(UUID().uuidString)"
        let temporaryURL = managedParent.parentURL.appendingPathComponent(
            temporaryName,
            isDirectory: false
        )
        let descriptor = temporaryName.withCString {
            Darwin.openat(
                managedParent.parentDescriptor,
                $0,
                O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            let code = errno
            Self.close(managedParent)
            throw WriterError.temporaryFileCreationFailed(code)
        }
        let createdTemporaryIdentity: InstalledFileIdentity
        do {
            createdTemporaryIdentity = try Self.fileIdentity(descriptor: descriptor)
                ?? { throw WriterError.fileIdentityInspectionFailed(ENOENT) }()
        } catch {
            Darwin.close(descriptor)
            Self.close(managedParent)
            throw WriterError.managedTemporaryCleanupUncertain(
                temporaryName,
                "temporary identity capture failed, so identity-bound cleanup could not be authorized: \(String(describing: error))"
            )
        }
        let retainedAnchor: ManagedFileAnchor
        do {
            try beforeManagedAnchorRetention(temporaryURL)
            retainedAnchor = try ManagedFileAnchor(
                retaining: managedParent,
                destinationName: standardizedDestination.lastPathComponent,
                allowsDetachedParentCleanup: true,
                exactFileDescriptor: descriptor
            )
        } catch {
            let retentionError = error
            do {
                try cleanupManagedTemporary(
                    named: temporaryName,
                    matching: createdTemporaryIdentity,
                    expectedData: Data(),
                    exactFileDescriptor: descriptor,
                    in: managedParent
                )
            } catch {
                Darwin.close(descriptor)
                Self.close(managedParent)
                throw error
            }
            Darwin.close(descriptor)
            Self.close(managedParent)
            throw retentionError
        }
        let retainedExactDescriptor = try Self.exactFileDescriptor(
            from: retainedAnchor,
            named: temporaryName
        )
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var handleIsOpen = true
        var installed = false
        var cleanupAuthorizedData = Data()
        defer {
            if handleIsOpen { try? handle.close() }
            Self.close(managedParent)
        }

        do {
            try faultInjector(.beforeWrite)
            guard try Self.fileData(
                descriptor: retainedExactDescriptor,
                matching: createdTemporaryIdentity,
                expectedByteCount: cleanupAuthorizedData.count,
                named: temporaryName
            )
                    == cleanupAuthorizedData else {
                throw WriterError.retainedManagedFileChanged(temporaryName)
            }
            let sink = DurableFileSink(handle: handle, beforeWrite: {
                let beforeCallback = try Self.fileData(
                    descriptor: retainedExactDescriptor,
                    matching: createdTemporaryIdentity,
                    expectedByteCount: cleanupAuthorizedData.count,
                    named: temporaryName
                )
                try faultInjector(.duringWrite)
                guard try Self.fileData(
                    descriptor: retainedExactDescriptor,
                    matching: createdTemporaryIdentity,
                    expectedByteCount: cleanupAuthorizedData.count,
                    named: temporaryName
                )
                        == beforeCallback else {
                    throw WriterError.retainedManagedFileChanged(temporaryName)
                }
            })
            try sink.write(data)
            cleanupAuthorizedData = try Self.fileData(
                descriptor: retainedExactDescriptor,
                matching: createdTemporaryIdentity,
                expectedByteCount: data.count,
                named: temporaryName
            )
            try Task.checkCancellation()
            try faultInjector(.beforeSynchronize)
            guard try Self.fileData(
                descriptor: retainedExactDescriptor,
                matching: createdTemporaryIdentity,
                expectedByteCount: cleanupAuthorizedData.count,
                named: temporaryName
            )
                    == cleanupAuthorizedData else {
                throw WriterError.retainedManagedFileChanged(temporaryName)
            }
            try handle.synchronize()
            try handle.close()
            handleIsOpen = false

            try Task.checkCancellation()
            try faultInjector(.beforeValidation)
            guard Self.managedParentIsReachable(managedParent),
                  try Self.fileIdentity(
                      named: temporaryName,
                      in: managedParent.parentDescriptor
                  ) == createdTemporaryIdentity,
                  try Self.fileIdentity(at: temporaryURL) == createdTemporaryIdentity else {
                throw WriterError.unsafeManagedParent(ESTALE)
            }
            let validatedData = try Self.fileData(
                named: temporaryName,
                in: managedParent.parentDescriptor,
                matching: createdTemporaryIdentity,
                expectedByteCount: data.count
            )
            guard validatedData == cleanupAuthorizedData,
                  try Self.fileData(
                      descriptor: retainedExactDescriptor,
                      matching: createdTemporaryIdentity,
                      expectedByteCount: cleanupAuthorizedData.count,
                      named: temporaryName
                  )
                    == cleanupAuthorizedData else {
                throw WriterError.retainedManagedFileChanged(temporaryName)
            }
            cleanupAuthorizedData = validatedData
            try validator(validatedData)
            guard try Self.fileData(
                descriptor: retainedExactDescriptor,
                matching: createdTemporaryIdentity,
                expectedByteCount: validatedData.count,
                named: temporaryName
            ) == validatedData else {
                throw WriterError.retainedManagedFileChanged(temporaryName)
            }
            try Task.checkCancellation()
            guard Self.managedParentIsReachable(managedParent),
                  try Self.fileIdentity(
                      named: temporaryName,
                      in: managedParent.parentDescriptor
                  ) == createdTemporaryIdentity,
                  try Self.fileIdentity(at: temporaryURL) == createdTemporaryIdentity else {
                throw WriterError.unsafeManagedParent(ESTALE)
            }

            try faultInjector(.beforeInstall)
            guard Self.managedParentIsReachable(managedParent),
                  try Self.fileIdentity(
                      named: temporaryName,
                      in: managedParent.parentDescriptor
                  ) == createdTemporaryIdentity,
                  try Self.fileIdentity(at: temporaryURL) == createdTemporaryIdentity else {
                throw WriterError.unsafeManagedParent(ESTALE)
            }

            // No caller callback observes the fresh name below. Isolating the
            // validated inode after the final callback narrows the remaining
            // identity-check-to-rename boundary to an unpredictable exact temporary
            // name that still matches reconciliation's temporary grammar.
            guard let isolatedName = try Self.quarantineEntry(
                named: temporaryName,
                in: managedParent.parentDescriptor,
                quarantineName: {
                    ".\(standardizedDestination.lastPathComponent).supra-tmp-\(UUID().uuidString)"
                }
            ) else {
                throw WriterError.fileIdentityInspectionFailed(ENOENT)
            }
            temporaryName = isolatedName
            let isolatedURL = managedParent.parentURL.appendingPathComponent(
                temporaryName,
                isDirectory: false
            )
            guard try Self.managedFileMatches(
                expected: createdTemporaryIdentity,
                data: validatedData,
                destination: isolatedURL,
                managedParent: managedParent,
                descriptor: retainedExactDescriptor,
                expectedByteCount: data.count,
                requiresSingleLink: true
            ) else {
                throw WriterError.retainedManagedFileChanged(temporaryName)
            }
            try Self.atomicInstall(
                temporaryName,
                at: standardizedDestination.lastPathComponent,
                in: managedParent.parentDescriptor
            )
            installed = true
            do {
                guard try Self.installedPublicationMatches(
                    destination: standardizedDestination,
                    expected: createdTemporaryIdentity,
                    validatedData: validatedData,
                    exactFileDescriptor: retainedExactDescriptor,
                    in: managedParent
                ) else {
                    throw WriterError.postInstallStateUncertain(
                        "the installed destination changed before final synchronization"
                    )
                }
            } catch {
                let verificationDetail = String(describing: error)
                try rollbackUncertainContainedInstall(
                    destination: standardizedDestination,
                    temporaryName: temporaryName,
                    expected: createdTemporaryIdentity,
                    validatedData: validatedData,
                    exactFileDescriptor: retainedExactDescriptor,
                    in: managedParent
                )
                throw WriterError.postInstallStateUncertain(
                    "post-install verification failed before final synchronization: \(verificationDetail)"
                )
            }
            do {
                try anchoredParentDirectorySynchronizer(
                    managedParent.parentURL,
                    managedParent.parentDescriptor
                )
            } catch {
                let installSynchronizationError = error
                try rollbackUncertainContainedInstall(
                    destination: standardizedDestination,
                    temporaryName: temporaryName,
                    expected: createdTemporaryIdentity,
                    validatedData: validatedData,
                    exactFileDescriptor: retainedExactDescriptor,
                    in: managedParent
                )
                throw WriterError.postInstallStateUncertain(
                    "final directory synchronization failed after installation: \(installSynchronizationError.localizedDescription)"
                )
            }
            do {
                guard try Self.installedPublicationMatches(
                    destination: standardizedDestination,
                    expected: createdTemporaryIdentity,
                    validatedData: validatedData,
                    exactFileDescriptor: retainedExactDescriptor,
                    in: managedParent
                ) else {
                    throw WriterError.postInstallStateUncertain(
                        "the managed parent, installed destination, or validated bytes changed during final synchronization"
                    )
                }
            } catch let error as WriterError {
                if case .postInstallStateUncertain = error { throw error }
                throw WriterError.postInstallStateUncertain(
                    "post-install inspection failed after final synchronization: \(String(describing: error))"
                )
            } catch {
                throw WriterError.postInstallStateUncertain(
                    "post-install inspection failed after final synchronization: \(error.localizedDescription)"
                )
            }
            return createdTemporaryIdentity.anchored(to: retainedAnchor)
        } catch {
            let operationError = error
            if !installed {
                if handleIsOpen {
                    try? handle.close()
                    handleIsOpen = false
                }
                try cleanupManagedTemporary(
                    named: temporaryName,
                    matching: createdTemporaryIdentity,
                    expectedData: cleanupAuthorizedData,
                    exactFileDescriptor: retainedExactDescriptor,
                    in: managedParent
                )
            }
            throw operationError
        }
    }

    private static func installedPublicationMatches(
        destination: URL,
        expected: InstalledFileIdentity,
        validatedData: Data,
        exactFileDescriptor: Int32,
        in managedParent: ManagedParent
    ) throws -> Bool {
        try managedFileMatches(
            expected: expected,
            data: validatedData,
            destination: destination,
            managedParent: managedParent,
            descriptor: exactFileDescriptor,
            expectedByteCount: validatedData.count,
            requiresSingleLink: true
        )
    }

    /// Once create-only installation has occurred, any inability to prove and
    /// durably remove the exact installed inode is a recovery state. A throwing
    /// callback may have moved or hard-linked the inode under an unknown name,
    /// so even a successful best-effort rollback does not restore abort-level
    /// certainty for the intent.
    private func rollbackUncertainContainedInstall(
        destination: URL,
        temporaryName: String,
        expected: InstalledFileIdentity,
        validatedData: Data,
        exactFileDescriptor: Int32,
        in managedParent: ManagedParent
    ) throws {
        let changedDirectory: Bool
        do {
            guard Self.managedParentIsReachable(managedParent),
                  try Self.fileIdentity(descriptor: exactFileDescriptor) == expected,
                  try Self.fileIdentity(
                      named: destination.lastPathComponent,
                      in: managedParent.parentDescriptor
                  ) == expected,
                  try Self.fileData(
                      descriptor: exactFileDescriptor,
                      matching: expected,
                      expectedByteCount: validatedData.count,
                      named: destination.lastPathComponent
                  ) == validatedData,
                  try Self.fileData(
                      named: destination.lastPathComponent,
                      in: managedParent.parentDescriptor,
                      matching: expected,
                      expectedByteCount: validatedData.count
                  ) == validatedData else {
                throw WriterError.retainedManagedFileChanged(
                    destination.lastPathComponent
                )
            }
            changedDirectory = try Self.rollbackCreateExclusiveInstall(
                destinationName: destination.lastPathComponent,
                quarantineName: temporaryName,
                parentDescriptor: managedParent.parentDescriptor,
                expectedIdentity: expected,
                expectedData: validatedData,
                exactFileDescriptor: exactFileDescriptor
            )
        } catch {
            throw WriterError.postInstallStateUncertain(
                "rollback of the installed destination could not be verified: \(String(describing: error))"
            )
        }
        guard changedDirectory else {
            throw WriterError.postInstallStateUncertain(
                "the exact installed inode was no longer available at its retained destination for rollback"
            )
        }
        var synchronizationError: Error?
        do {
            try anchoredParentDirectorySynchronizer(
                managedParent.parentURL,
                managedParent.parentDescriptor
            )
        } catch {
            synchronizationError = error
        }
        do {
            let retainedDestination = try Self.fileIdentity(
                named: destination.lastPathComponent,
                in: managedParent.parentDescriptor
            )
            let retainedTemporary = try Self.fileIdentity(
                named: temporaryName,
                in: managedParent.parentDescriptor
            )
            let publicDestination = try Self.fileIdentity(at: destination)
            guard retainedDestination != expected,
                  retainedTemporary != expected,
                  publicDestination != expected else {
                throw WriterError.postInstallStateUncertain(
                    "the exact installed inode remains reachable after rollback synchronization"
                )
            }
            let remainingLinkCount = try Self.linkCount(
                descriptor: exactFileDescriptor,
                named: temporaryName
            )
            if remainingLinkCount > 0 {
                throw WriterError.postInstallStateUncertain(
                    "the exact installed inode still has \(remainingLinkCount) filesystem link(s) after rollback"
                )
            }
        } catch let error as WriterError {
            if case .postInstallStateUncertain = error { throw error }
            throw WriterError.postInstallStateUncertain(
                "post-rollback inspection failed: \(String(describing: error))"
            )
        } catch {
            throw WriterError.postInstallStateUncertain(
                "post-rollback inspection failed: \(error.localizedDescription)"
            )
        }
        if let synchronizationError {
            throw WriterError.createOnlyRollbackSynchronizationFailed(
                synchronizationError.localizedDescription
            )
        }
    }

    private func cleanupManagedTemporary(
        named temporaryName: String,
        matching expected: InstalledFileIdentity,
        expectedData: Data,
        exactFileDescriptor: Int32,
        in managedParent: ManagedParent
    ) throws {
        let removed: Bool
        do {
            guard Self.managedParentIsReachable(managedParent),
                  try Self.fileIdentity(descriptor: exactFileDescriptor) == expected,
                  try Self.fileIdentity(
                      named: temporaryName,
                      in: managedParent.parentDescriptor
                  ) == expected,
                  try Self.fileData(
                      descriptor: exactFileDescriptor,
                      matching: expected,
                      expectedByteCount: expectedData.count,
                      named: temporaryName
                  ) == expectedData,
                  try Self.fileData(
                      named: temporaryName,
                      in: managedParent.parentDescriptor,
                      matching: expected,
                      expectedByteCount: expectedData.count
                  ) == expectedData else {
                throw WriterError.retainedManagedFileChanged(temporaryName)
            }
            removed = try Self.removeEntry(
                named: temporaryName,
                matching: expected,
                in: managedParent.parentDescriptor
            )
        } catch {
            throw WriterError.managedTemporaryCleanupUncertain(
                temporaryName,
                "exact temporary unlink failed: \(String(describing: error))"
            )
        }
        guard removed else {
            throw WriterError.managedTemporaryCleanupUncertain(
                temporaryName,
                "the exact managed temporary could not be verified at its retained name"
            )
        }
        var synchronizationError: Error?
        do {
            try anchoredParentDirectorySynchronizer(
                managedParent.parentURL,
                managedParent.parentDescriptor
            )
        } catch {
            synchronizationError = error
        }
        do {
            guard try Self.fileIdentity(
                named: temporaryName,
                in: managedParent.parentDescriptor
            ) == nil,
                  try Self.fileIdentity(
                      at: managedParent.parentURL.appendingPathComponent(
                          temporaryName,
                          isDirectory: false
                      )
                  ) == nil else {
                throw WriterError.managedTemporaryCleanupUncertain(
                    temporaryName,
                    "the removed temporary name reappeared after directory synchronization"
                )
            }
            let remainingLinkCount = try Self.linkCount(
                descriptor: exactFileDescriptor,
                named: temporaryName
            )
            if remainingLinkCount > 0 {
                throw WriterError.managedTemporaryCleanupUncertain(
                    temporaryName,
                    "the exact temporary still has \(remainingLinkCount) filesystem link(s) after unlink"
                )
            }
        } catch let error as WriterError {
            if case .managedTemporaryCleanupUncertain = error { throw error }
            throw WriterError.managedTemporaryCleanupUncertain(
                temporaryName,
                "post-cleanup inspection failed: \(String(describing: error))"
            )
        } catch {
            throw WriterError.managedTemporaryCleanupUncertain(
                temporaryName,
                "post-cleanup inspection failed: \(error.localizedDescription)"
            )
        }
        if let synchronizationError {
            throw WriterError.managedTemporaryCleanupUncertain(
                temporaryName,
                "directory synchronization failed: \(synchronizationError.localizedDescription)"
            )
        }
    }

    private static func openManagedParent(
        for destination: URL,
        managedRoot: URL,
        createMissingDirectories: Bool = true,
        directoryAuthenticator: AnchoredParentDirectorySynchronizer? = nil
    ) throws -> ManagedParent {
        let parent = destination.deletingLastPathComponent().standardizedFileURL
        let rootPath = managedRoot.path
        let parentPath = parent.path
        guard parentPath.hasPrefix(rootPath + "/") else {
            throw WriterError.invalidDestination
        }
        let relativePath = String(parentPath.dropFirst(rootPath.count + 1))
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw WriterError.invalidDestination
        }

        let rootDescriptor: Int32
        if createMissingDirectories {
            guard let directoryAuthenticator else {
                throw WriterError.unsafeManagedParent(EINVAL)
            }
            rootDescriptor = try openOrCreateManagedRoot(
                at: managedRoot,
                directoryAuthenticator: directoryAuthenticator
            )
        } else {
            rootDescriptor = managedRoot.path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
        }
        guard rootDescriptor >= 0 else {
            throw WriterError.unsafeManagedParent(errno)
        }

        var currentDescriptor = rootDescriptor
        var currentURL = managedRoot
        do {
            for component in components {
                let nextDescriptor = try openOrCreateManagedDirectory(
                    named: component,
                    in: currentDescriptor,
                    containingURL: currentURL,
                    createIfMissing: createMissingDirectories,
                    directoryAuthenticator: createMissingDirectories
                        ? directoryAuthenticator
                        : nil
                )
                if currentDescriptor != rootDescriptor {
                    Darwin.close(currentDescriptor)
                }
                currentDescriptor = nextDescriptor
                currentURL.appendPathComponent(component, isDirectory: true)
            }
            guard let identity = try fileIdentity(descriptor: currentDescriptor) else {
                throw WriterError.fileIdentityInspectionFailed(ENOENT)
            }
            return ManagedParent(
                rootDescriptor: rootDescriptor,
                parentDescriptor: currentDescriptor,
                rootURL: managedRoot,
                parentURL: parent,
                relativeComponents: components,
                identity: identity
            )
        } catch {
            if currentDescriptor != rootDescriptor {
                Darwin.close(currentDescriptor)
            }
            Darwin.close(rootDescriptor)
            throw error
        }
    }

    private static func openOrCreateManagedDirectory(
        named name: String,
        in parentDescriptor: Int32,
        containingURL: URL,
        createIfMissing: Bool,
        directoryAuthenticator: AnchoredParentDirectorySynchronizer?
    ) throws -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        var descriptor = name.withCString {
            Darwin.openat(parentDescriptor, $0, flags)
        }
        if descriptor < 0, errno == ENOENT, createIfMissing {
            let createResult = name.withCString {
                Darwin.mkdirat(parentDescriptor, $0, S_IRWXU)
            }
            if createResult != 0, errno != EEXIST {
                throw WriterError.unsafeManagedParent(errno)
            }
            descriptor = name.withCString {
                Darwin.openat(parentDescriptor, $0, flags)
            }
        }
        guard descriptor >= 0 else {
            throw WriterError.unsafeManagedParent(errno)
        }
        let openedIdentity: InstalledFileIdentity
        do {
            guard let identity = try fileIdentity(descriptor: descriptor) else {
                throw WriterError.fileIdentityInspectionFailed(ENOENT)
            }
            openedIdentity = identity
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        if let directoryAuthenticator {
            do {
                try directoryAuthenticator(containingURL, parentDescriptor)
            } catch {
                Darwin.close(descriptor)
                throw WriterError.anchoredParentDirectorySynchronizationFailed(
                    error.localizedDescription
                )
            }
            let edgeStillMatches: Bool
            do {
                let descriptorIdentity = try fileIdentity(descriptor: descriptor)
                let namedIdentity = try fileIdentity(named: name, in: parentDescriptor)
                edgeStillMatches = descriptorIdentity == openedIdentity
                    && namedIdentity == openedIdentity
            } catch {
                Darwin.close(descriptor)
                throw error
            }
            guard edgeStillMatches else {
                Darwin.close(descriptor)
                throw WriterError.unsafeManagedParent(ESTALE)
            }
        }
        return descriptor
    }

    /// Opens the nearest existing configured ancestor without following its
    /// final component, then creates/authenticates each missing component with
    /// descriptor-relative operations. Every managed-root edge is synchronized
    /// on every publication, including retries after a prior mkdir fsync failed.
    private static func openOrCreateManagedRoot(
        at managedRoot: URL,
        directoryAuthenticator: @escaping AnchoredParentDirectorySynchronizer
    ) throws -> Int32 {
        let standardizedRoot = managedRoot.standardizedFileURL
        guard standardizedRoot.isFileURL,
              !standardizedRoot.lastPathComponent.isEmpty,
              standardizedRoot.path != "/" else {
            throw WriterError.invalidDestination
        }

        var componentsToOpen = [standardizedRoot.lastPathComponent]
        var existingAncestor = standardizedRoot.deletingLastPathComponent()
        var ancestorDescriptor: Int32 = -1
        while ancestorDescriptor < 0 {
            ancestorDescriptor = existingAncestor.path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            if ancestorDescriptor >= 0 { break }
            let code = errno
            guard code == ENOENT,
                  existingAncestor.path != "/",
                  !existingAncestor.lastPathComponent.isEmpty else {
                throw WriterError.unsafeManagedParent(code)
            }
            componentsToOpen.append(existingAncestor.lastPathComponent)
            existingAncestor.deleteLastPathComponent()
        }

        var currentDescriptor = ancestorDescriptor
        var currentURL = existingAncestor
        do {
            for component in componentsToOpen.reversed() {
                let nextDescriptor = try openOrCreateManagedDirectory(
                    named: component,
                    in: currentDescriptor,
                    containingURL: currentURL,
                    createIfMissing: true,
                    directoryAuthenticator: directoryAuthenticator
                )
                Darwin.close(currentDescriptor)
                currentDescriptor = nextDescriptor
                currentURL.appendPathComponent(component, isDirectory: true)
            }
            return currentDescriptor
        } catch {
            Darwin.close(currentDescriptor)
            throw error
        }
    }

    private static func managedParentIsReachable(_ managedParent: ManagedParent) -> Bool {
        guard var currentDescriptor = reachableManagedRootDescriptor(
            retainedDescriptor: managedParent.rootDescriptor,
            rootURL: managedParent.rootURL
        ) else {
            return false
        }
        defer { Darwin.close(currentDescriptor) }
        for component in managedParent.relativeComponents {
            let nextDescriptor = component.withCString {
                Darwin.openat(
                    currentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard nextDescriptor >= 0 else { return false }
            Darwin.close(currentDescriptor)
            currentDescriptor = nextDescriptor
        }
        return (try? fileIdentity(descriptor: currentDescriptor)) == managedParent.identity
    }

    private static func close(_ managedParent: ManagedParent) {
        Darwin.close(managedParent.parentDescriptor)
        Darwin.close(managedParent.rootDescriptor)
    }

    private static func anchor(
        for expected: InstalledFileIdentity,
        destination: URL
    ) throws -> ManagedFileAnchor {
        if let retained = expected.managedAnchor,
           retained.matches(destination: destination) {
            return retained
        }
        let parentURL = destination.deletingLastPathComponent().standardizedFileURL
        let descriptor = parentURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw WriterError.unsafeManagedParent(errno)
        }
        var callerOwnsParentDescriptor = true
        defer {
            if callerOwnsParentDescriptor { Darwin.close(descriptor) }
        }
        guard let namedStatus = try fileStatus(
            named: destination.lastPathComponent,
            in: descriptor
        ) else {
            throw WriterError.fileIdentityInspectionFailed(ESTALE)
        }
        guard isRegularFile(namedStatus) else {
            throw WriterError.fileIdentityInspectionFailed(EFTYPE)
        }
        guard fileIdentity(status: namedStatus) == expected else {
            throw WriterError.fileIdentityInspectionFailed(ESTALE)
        }
        let exactFileDescriptor = destination.lastPathComponent.withCString {
            Darwin.openat(
                descriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard exactFileDescriptor >= 0 else {
            throw WriterError.fileIdentityInspectionFailed(errno)
        }
        defer { Darwin.close(exactFileDescriptor) }
        let exactStatus = try fileStatus(descriptor: exactFileDescriptor)
        guard isRegularFile(exactStatus),
              fileIdentity(status: exactStatus) == expected else {
            throw WriterError.fileIdentityInspectionFailed(ESTALE)
        }
        callerOwnsParentDescriptor = false
        return try ManagedFileAnchor(
            parentDescriptor: descriptor,
            parentURL: parentURL,
            destinationName: destination.lastPathComponent,
            exactFileDescriptor: exactFileDescriptor
        )
    }

    private static func anchor(
        for expected: InstalledFileIdentity,
        destination: URL,
        managedRoot: URL
    ) throws -> ManagedFileAnchor {
        if let retained = expected.managedAnchor,
           retained.matches(destination: destination, managedRoot: managedRoot) {
            return retained
        }
        let managedParent = try openManagedParent(
            for: destination,
            managedRoot: managedRoot,
            createMissingDirectories: false
        )
        defer { close(managedParent) }
        guard let namedStatus = try fileStatus(
            named: destination.lastPathComponent,
            in: managedParent.parentDescriptor
        ) else {
            throw WriterError.fileIdentityInspectionFailed(ESTALE)
        }
        guard isRegularFile(namedStatus) else {
            throw WriterError.fileIdentityInspectionFailed(EFTYPE)
        }
        guard fileIdentity(status: namedStatus) == expected else {
            throw WriterError.fileIdentityInspectionFailed(ESTALE)
        }
        let exactFileDescriptor = destination.lastPathComponent.withCString {
            Darwin.openat(
                managedParent.parentDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard exactFileDescriptor >= 0 else {
            throw WriterError.fileIdentityInspectionFailed(errno)
        }
        defer { Darwin.close(exactFileDescriptor) }
        let exactStatus = try fileStatus(descriptor: exactFileDescriptor)
        guard isRegularFile(exactStatus),
              fileIdentity(status: exactStatus) == expected else {
            throw WriterError.fileIdentityInspectionFailed(ESTALE)
        }
        return try ManagedFileAnchor(
            retaining: managedParent,
            destinationName: destination.lastPathComponent,
            allowsDetachedParentCleanup: false,
            exactFileDescriptor: exactFileDescriptor
        )
    }

    private static func managedAnchorIsReachable(_ anchor: ManagedFileAnchor) -> Bool {
        guard let rootURL = anchor.managedRootURL,
              var currentDescriptor = reachableManagedRootDescriptor(
                  retainedDescriptor: anchor.rootDescriptor,
                  rootURL: rootURL
              ) else {
            return false
        }
        defer { Darwin.close(currentDescriptor) }
        for component in anchor.relativeComponents {
            let nextDescriptor = component.withCString {
                Darwin.openat(
                    currentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard nextDescriptor >= 0 else { return false }
            Darwin.close(currentDescriptor)
            currentDescriptor = nextDescriptor
        }
        return (try? fileIdentity(descriptor: currentDescriptor)) == anchor.parentIdentity
    }

    private static func managedFileMatches(
        expected: InstalledFileIdentity,
        data: Data,
        destination: URL,
        anchor: ManagedFileAnchor,
        descriptor: Int32,
        expectedByteCount: Int,
        requiresSingleLink: Bool
    ) throws -> Bool {
        try managedFileMatches(
            expected: expected,
            data: data,
            destination: destination,
            parentDescriptor: anchor.parentDescriptor,
            descriptor: descriptor,
            expectedByteCount: expectedByteCount,
            requiresSingleLink: requiresSingleLink,
            parentIsReachable: { Self.managedAnchorIsReachable(anchor) }
        )
    }

    private static func managedFileMatches(
        expected: InstalledFileIdentity,
        data: Data,
        destination: URL,
        managedParent: ManagedParent,
        descriptor: Int32,
        expectedByteCount: Int,
        requiresSingleLink: Bool
    ) throws -> Bool {
        try managedFileMatches(
            expected: expected,
            data: data,
            destination: destination,
            parentDescriptor: managedParent.parentDescriptor,
            descriptor: descriptor,
            expectedByteCount: expectedByteCount,
            requiresSingleLink: requiresSingleLink,
            parentIsReachable: { Self.managedParentIsReachable(managedParent) }
        )
    }

    private static func managedFileMatches(
        expected: InstalledFileIdentity,
        data: Data,
        destination: URL,
        parentDescriptor: Int32,
        descriptor: Int32,
        expectedByteCount: Int,
        requiresSingleLink: Bool,
        parentIsReachable: () -> Bool
    ) throws -> Bool {
        guard data.count == expectedByteCount,
              try managedFileBindingMatches(
                  expected: expected,
                  destination: destination,
                  parentDescriptor: parentDescriptor,
                  descriptor: descriptor,
                  expectedByteCount: expectedByteCount,
                  requiresSingleLink: requiresSingleLink,
                  parentIsReachable: parentIsReachable
              ) else {
            return false
        }
        let first = try fileData(
            descriptor: descriptor,
            matching: expected,
            expectedByteCount: expectedByteCount,
            named: destination.lastPathComponent
        )
        guard first == data,
              try managedFileBindingMatches(
                  expected: expected,
                  destination: destination,
                  parentDescriptor: parentDescriptor,
                  descriptor: descriptor,
                  expectedByteCount: expectedByteCount,
                  requiresSingleLink: requiresSingleLink,
                  parentIsReachable: parentIsReachable
              ) else {
            return false
        }
        let final = try fileData(
            descriptor: descriptor,
            matching: expected,
            expectedByteCount: expectedByteCount,
            named: destination.lastPathComponent
        )
        guard final == first,
              try managedFileBindingMatches(
                  expected: expected,
                  destination: destination,
                  parentDescriptor: parentDescriptor,
                  descriptor: descriptor,
                  expectedByteCount: expectedByteCount,
                  requiresSingleLink: requiresSingleLink,
                  parentIsReachable: parentIsReachable
              ) else {
            return false
        }
        return true
    }

    private static func managedFileBindingMatches(
        expected: InstalledFileIdentity,
        destination: URL,
        parentDescriptor: Int32,
        descriptor: Int32,
        expectedByteCount: Int,
        requiresSingleLink: Bool,
        parentIsReachable: () -> Bool
    ) throws -> Bool {
        guard expectedByteCount >= 0,
              parentIsReachable(),
              try fileIdentity(descriptor: descriptor) == expected,
              try fileIdentity(
                  named: destination.lastPathComponent,
                  in: parentDescriptor
              ) == expected,
              try fileIdentity(at: destination) == expected else {
            return false
        }
        let status = try fileStatus(descriptor: descriptor)
        guard isRegularFile(status),
              status.st_mode & S_IRUSR == S_IRUSR,
              status.st_size == off_t(expectedByteCount) else {
            return false
        }
        if requiresSingleLink {
            let count = UInt64(status.st_nlink)
            guard count == 1 else {
                if count > 0 {
                    throw WriterError.exactFileHasRemainingLinks(
                        destination.lastPathComponent,
                        count
                    )
                }
                return false
            }
        }
        return true
    }

    /// Opens the root through its current caller-configured pathname and proves
    /// it is still the exact directory retained during inspection. Walking only
    /// from the retained descriptor would incorrectly treat a renamed, detached
    /// tree as reachable after the managed-root pathname is replaced.
    private static func reachableManagedRootDescriptor(
        retainedDescriptor: Int32,
        rootURL: URL
    ) -> Int32? {
        let currentDescriptor = rootURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard currentDescriptor >= 0 else { return nil }
        guard let retainedIdentity = try? fileIdentity(descriptor: retainedDescriptor),
              let currentIdentity = try? fileIdentity(descriptor: currentDescriptor),
              retainedIdentity == currentIdentity else {
            Darwin.close(currentDescriptor)
            return nil
        }
        return currentDescriptor
    }

    /// `dup` clears close-on-exec. Retained directory capabilities must never be
    /// inherited by a subprocess, so every duplicate restores that boundary.
    private static func duplicateDescriptor(_ descriptor: Int32) -> Int32 {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0 else { return duplicate }
        guard Darwin.fcntl(duplicate, F_SETFD, FD_CLOEXEC) == 0 else {
            let code = errno
            Darwin.close(duplicate)
            errno = code
            return -1
        }
        return duplicate
    }

    private static func exactFileDescriptor(
        from anchor: ManagedFileAnchor,
        named name: String
    ) throws -> Int32 {
        guard let descriptor = anchor.exactFileDescriptor else {
            throw WriterError.exactFileLinkStateUncertain(
                name,
                "no retained exact-file descriptor was available"
            )
        }
        return descriptor
    }

    private static func fileStatus(descriptor: Int32) throws -> stat {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw WriterError.fileIdentityInspectionFailed(errno)
        }
        return status
    }

    private static func fileStatus(
        named name: String,
        in parentDescriptor: Int32
    ) throws -> stat? {
        var status = stat()
        let result = name.withCString {
            Darwin.fstatat(parentDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else {
            let code = errno
            if code == ENOENT { return nil }
            throw WriterError.fileIdentityInspectionFailed(code)
        }
        return status
    }

    private static func isRegularFile(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFREG
    }

    private static func linkCount(
        descriptor: Int32,
        named name: String
    ) throws -> UInt64 {
        do {
            return UInt64(try fileStatus(descriptor: descriptor).st_nlink)
        } catch {
            throw WriterError.exactFileLinkStateUncertain(
                name,
                String(describing: error)
            )
        }
    }

    private static func fileData(
        descriptor: Int32,
        matching expected: InstalledFileIdentity,
        expectedByteCount: Int,
        named name: String
    ) throws -> Data {
        try fileData(
            descriptor: descriptor,
            matching: expected,
            constraint: .exact(expectedByteCount),
            named: name
        )
    }

    private static func fileData(
        descriptor: Int32,
        matching expected: InstalledFileIdentity,
        constraint: ManagedByteCountConstraint,
        named name: String
    ) throws -> Data {
        let initialStatus = try fileStatus(descriptor: descriptor)
        guard isRegularFile(initialStatus),
              initialStatus.st_dev == expected.device,
              initialStatus.st_ino == expected.inode,
              initialStatus.st_gen == expected.generation,
              initialStatus.st_size >= 0 else {
            throw WriterError.retainedManagedFileChanged(name)
        }
        let expectedByteCount: Int
        switch constraint {
        case let .exact(count):
            guard count >= 0,
                  initialStatus.st_size == off_t(count) else {
                throw WriterError.retainedManagedFileChanged(name)
            }
            expectedByteCount = count
        case let .maximum(maximum):
            guard maximum >= 0,
                  UInt64(initialStatus.st_size) <= UInt64(maximum) else {
                throw WriterError.retainedManagedFileChanged(name)
            }
            expectedByteCount = Int(initialStatus.st_size)
        }
        let result = try readFileData(
            descriptor: descriptor,
            expectedByteCount: expectedByteCount
        )
        let finalStatus = try fileStatus(descriptor: descriptor)
        guard isRegularFile(finalStatus),
              finalStatus.st_dev == expected.device,
              finalStatus.st_ino == expected.inode,
              finalStatus.st_gen == expected.generation,
              finalStatus.st_size == off_t(expectedByteCount) else {
            throw WriterError.retainedManagedFileChanged(name)
        }
        return result
    }

    private static func readFileData(
        descriptor: Int32,
        expectedByteCount: Int
    ) throws -> Data {
        var result = Data()
        result.reserveCapacity(expectedByteCount)
        var offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while result.count < expectedByteCount {
            let remaining = expectedByteCount - result.count
            let count: Int = buffer.withUnsafeMutableBytes { bytes in
                while true {
                    let readCount = Darwin.pread(
                        descriptor,
                        bytes.baseAddress,
                        min(bytes.count, remaining),
                        offset
                    )
                    if readCount < 0, errno == EINTR { continue }
                    return readCount
                }
            }
            guard count >= 0 else {
                throw WriterError.fileIdentityInspectionFailed(errno)
            }
            guard count > 0 else {
                throw WriterError.fileIdentityInspectionFailed(ESTALE)
            }
            result.append(contentsOf: buffer.prefix(count))
            offset += off_t(count)
        }

        var sentinel = [UInt8](repeating: 0, count: 1)
        let trailingCount: Int = sentinel.withUnsafeMutableBytes { bytes in
            while true {
                let readCount = Darwin.pread(
                    descriptor,
                    bytes.baseAddress,
                    bytes.count,
                    offset
                )
                if readCount < 0, errno == EINTR { continue }
                return readCount
            }
        }
        guard trailingCount >= 0 else {
            throw WriterError.fileIdentityInspectionFailed(errno)
        }
        guard trailingCount == 0 else {
            throw WriterError.fileIdentityInspectionFailed(ESTALE)
        }
        return result
    }

    private enum QuarantinePublicState {
        case exactQuarantineOnly
        case exactQuarantineAndPublic
        case publicWithoutExactQuarantine
        case quarantineChangedOrMissing
    }

    /// Classifies both names after every caller-controlled rollback boundary.
    /// The retained descriptor is authoritative for the quarantine; the public
    /// pathname is intentionally checked separately because it may now resolve
    /// through a replacement managed-parent chain.
    private static func quarantinePublicState(
        quarantineName: String,
        parentDescriptor: Int32,
        destination: URL,
        expected: InstalledFileIdentity
    ) throws -> QuarantinePublicState {
        let exactQuarantine = try fileIdentity(
            named: quarantineName,
            in: parentDescriptor
        ) == expected
        let exactPublic = try fileIdentity(at: destination) == expected
        switch (exactQuarantine, exactPublic) {
        case (true, false):
            return .exactQuarantineOnly
        case (true, true):
            return .exactQuarantineAndPublic
        case (false, true):
            return .publicWithoutExactQuarantine
        case (false, false):
            return .quarantineChangedOrMissing
        }
    }

    private static func requireExactQuarantineOnly(
        quarantineName: String,
        parentDescriptor: Int32,
        destination: URL,
        expected: InstalledFileIdentity
    ) throws {
        switch try quarantinePublicState(
            quarantineName: quarantineName,
            parentDescriptor: parentDescriptor,
            destination: destination,
            expected: expected
        ) {
        case .exactQuarantineOnly:
            return
        case .exactQuarantineAndPublic:
            throw WriterError.publicDestinationStillLinked(quarantineName)
        case .publicWithoutExactQuarantine:
            throw WriterError.publicDestinationStillLinkedWithoutRetainedQuarantine
        case .quarantineChangedOrMissing:
            throw WriterError.quarantinePathChanged(quarantineName)
        }
    }

    private static func quarantineEntry(
        named sourceName: String,
        in parentDescriptor: Int32,
        quarantineName makeQuarantineName: () -> String
    ) throws -> String? {
        for _ in 0..<32 {
            let quarantineName = makeQuarantineName()
            let result = sourceName.withCString { source in
                quarantineName.withCString { destination in
                    Darwin.renameatx_np(
                        parentDescriptor,
                        source,
                        parentDescriptor,
                        destination,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            if result == 0 { return quarantineName }
            let code = errno
            if code == ENOENT { return nil }
            if code == EEXIST { continue }
            throw WriterError.createOnlyRollbackFailed(code)
        }
        throw WriterError.createOnlyRollbackFailed(EEXIST)
    }

    private static func restoreEntry(
        named quarantineName: String,
        to destinationName: String,
        in parentDescriptor: Int32
    ) throws {
        let result = quarantineName.withCString { source in
            destinationName.withCString { destination in
                Darwin.renameatx_np(
                    parentDescriptor,
                    source,
                    parentDescriptor,
                    destination,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            throw WriterError.createOnlyRollbackConflict(quarantineName, errno)
        }
    }

    /// Atomically moves the current entry out of its caller-visible name before
    /// deciding whether it is owned. A mismatched entry is restored exclusively;
    /// only an identity-matching quarantine is passed to `unlinkat`.
    private static func removeEntry(
        named sourceName: String,
        matching expected: InstalledFileIdentity,
        in parentDescriptor: Int32
    ) throws -> Bool {
        guard let quarantineName = try quarantineEntry(
            named: sourceName,
            in: parentDescriptor,
            quarantineName: { recoveryQuarantineName(for: sourceName) }
        ) else {
            return false
        }
        guard let quarantinedIdentity = try fileIdentity(
            named: quarantineName,
            in: parentDescriptor
        ) else {
            return false
        }
        guard quarantinedIdentity == expected else {
            guard try restoreOwnedEntry(
                named: quarantineName,
                to: sourceName,
                matching: quarantinedIdentity,
                in: parentDescriptor
            ) else {
                throw WriterError.createOnlyRollbackConflict(quarantineName, ESTALE)
            }
            return false
        }

        let result = quarantineName.withCString {
            Darwin.unlinkat(parentDescriptor, $0, 0)
        }
        guard result == 0 else {
            let code = errno
            guard try restoreOwnedEntry(
                named: quarantineName,
                to: sourceName,
                matching: expected,
                in: parentDescriptor
            ) else {
                throw WriterError.createOnlyRollbackConflict(quarantineName, ESTALE)
            }
            throw WriterError.fileUnlinkFailed(code)
        }
        return true
    }

    /// Safely restores the exact entry captured before an untrusted callback.
    /// The first rename is non-overwriting and descriptor-relative; a replacement
    /// is returned to the quarantine name rather than installed publicly.
    private static func restoreOwnedEntry(
        named quarantineName: String,
        to destinationName: String,
        matching expected: InstalledFileIdentity,
        in parentDescriptor: Int32
    ) throws -> Bool {
        guard let isolatedName = try quarantineEntry(
            named: quarantineName,
            in: parentDescriptor,
            quarantineName: { recoveryQuarantineName(for: quarantineName) }
        ) else {
            return false
        }
        guard try fileIdentity(named: isolatedName, in: parentDescriptor) == expected else {
            try restoreEntry(
                named: isolatedName,
                to: quarantineName,
                in: parentDescriptor
            )
            return false
        }
        do {
            try restoreEntry(
                named: isolatedName,
                to: destinationName,
                in: parentDescriptor
            )
        } catch {
            do {
                try restoreEntry(
                    named: isolatedName,
                    to: quarantineName,
                    in: parentDescriptor
                )
            } catch {
                throw WriterError.createOnlyRollbackConflict(isolatedName, errno)
            }
            throw error
        }
        return true
    }

    /// Crash residues stay inside grammars already reconciled against a Store
    /// intent: writer temporaries remain exact writer temporaries and rollback
    /// quarantines remain exact rollback quarantines.
    private static func recoveryQuarantineName(for sourceName: String) -> String {
        let temporaryMarker = ".supra-tmp-"
        if let marker = sourceName.range(of: temporaryMarker, options: .backwards) {
            let suffix = String(sourceName[marker.upperBound...])
            if UUID(uuidString: suffix) != nil {
                return String(sourceName[..<marker.upperBound]) + UUID().uuidString
            }
        }

        let rollbackPrefix = ".supra-draft-rollback-"
        if sourceName.hasPrefix(rollbackPrefix) {
            let remainder = String(sourceName.dropFirst(rollbackPrefix.count))
            if remainder.count > 37 {
                let identifierText = String(remainder.prefix(36))
                let separator = remainder.index(remainder.startIndex, offsetBy: 36)
                if remainder[separator] == "-", UUID(uuidString: identifierText) != nil {
                    return rollbackPrefix
                        + UUID().uuidString.lowercased()
                        + String(remainder.dropFirst(36))
                }
            }
        }

        return rollbackPrefix
            + UUID().uuidString.lowercased()
            + "-"
            + sourceName
    }

    private static func fileData(
        named name: String,
        in parentDescriptor: Int32,
        matching expected: InstalledFileIdentity,
        expectedByteCount: Int
    ) throws -> Data {
        let descriptor = name.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            throw WriterError.fileIdentityInspectionFailed(errno)
        }
        defer { Darwin.close(descriptor) }
        return try fileData(
            descriptor: descriptor,
            matching: expected,
            expectedByteCount: expectedByteCount,
            named: name
        )
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

    private static func atomicInstall(
        _ temporary: URL,
        at destination: URL,
        policy: InstallPolicy
    ) throws {
        let result: Int32 = temporary.path.withCString { source in
            destination.path.withCString { target in
                switch policy {
                case .replace:
                    Darwin.rename(source, target)
                case .createExclusive:
                    Darwin.renamex_np(source, target, UInt32(RENAME_EXCL))
                }
            }
        }
        guard result == 0 else {
            let code = errno
            if policy == .createExclusive, code == EEXIST {
                throw WriterError.destinationExists
            }
            throw WriterError.atomicInstallFailed(code)
        }
    }

    private static func atomicInstall(
        _ temporaryName: String,
        at destinationName: String,
        in parentDescriptor: Int32
    ) throws {
        let result = temporaryName.withCString { source in
            destinationName.withCString { target in
                Darwin.renameatx_np(
                    parentDescriptor,
                    source,
                    parentDescriptor,
                    target,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            let code = errno
            if code == EEXIST {
                throw WriterError.destinationExists
            }
            throw WriterError.atomicInstallFailed(code)
        }
    }

    private static func synchronizeParentDirectory(_ directory: URL) throws {
        let descriptor = directory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw WriterError.parentDirectorySynchronizationFailed(errno)
        }
        defer { Darwin.close(descriptor) }

        guard Darwin.fsync(descriptor) == 0 else {
            throw WriterError.parentDirectorySynchronizationFailed(errno)
        }
    }

    private static func synchronizeDirectory(_ descriptor: Int32) throws {
        guard Darwin.fsync(descriptor) == 0 else {
            throw WriterError.parentDirectorySynchronizationFailed(errno)
        }
    }

    /// Removes a failed create-only install only when the destination is still
    /// the exact file moved there by this writer. The old temporary pathname is
    /// reused as a quarantine so a replacement race can be restored without
    /// overwriting any newer destination.
    private static func rollbackCreateExclusiveInstall(
        at destination: URL,
        quarantine: URL,
        expectedIdentity: InstalledFileIdentity
    ) throws -> Bool {
        let parent = destination.deletingLastPathComponent().standardizedFileURL
        guard quarantine.deletingLastPathComponent().standardizedFileURL == parent else {
            throw WriterError.invalidDestination
        }
        let descriptor = parent.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw WriterError.unsafeManagedParent(errno)
        }
        defer { Darwin.close(descriptor) }
        return try rollbackCreateExclusiveInstall(
            destinationName: destination.lastPathComponent,
            quarantineName: quarantine.lastPathComponent,
            parentDescriptor: descriptor,
            expectedIdentity: expectedIdentity
        )
    }

    private static func rollbackCreateExclusiveInstall(
        destinationName: String,
        quarantineName: String,
        parentDescriptor: Int32,
        expectedIdentity: InstalledFileIdentity,
        expectedData: Data? = nil,
        exactFileDescriptor: Int32? = nil
    ) throws -> Bool {
        guard try fileIdentity(named: destinationName, in: parentDescriptor) == expectedIdentity else {
            return false
        }

        let renameResult = destinationName.withCString { source in
            quarantineName.withCString { target in
                Darwin.renameatx_np(
                    parentDescriptor,
                    source,
                    parentDescriptor,
                    target,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard renameResult == 0 else {
            let code = errno
            if code == ENOENT { return false }
            throw WriterError.createOnlyRollbackFailed(code)
        }

        let quarantinedIdentity: InstalledFileIdentity?
        do {
            quarantinedIdentity = try fileIdentity(
                named: quarantineName,
                in: parentDescriptor
            )
        } catch {
            throw error
        }

        guard quarantinedIdentity == expectedIdentity else {
            if let quarantinedIdentity {
                guard try restoreOwnedEntry(
                    named: quarantineName,
                    to: destinationName,
                    matching: quarantinedIdentity,
                    in: parentDescriptor
                ) else {
                    throw WriterError.createOnlyRollbackConflict(quarantineName, ESTALE)
                }
            }
            return true
        }

        if let expectedData, let exactFileDescriptor {
            guard try fileIdentity(descriptor: exactFileDescriptor) == expectedIdentity,
                  try fileData(
                      descriptor: exactFileDescriptor,
                      matching: expectedIdentity,
                      expectedByteCount: expectedData.count,
                      named: quarantineName
                  ) == expectedData,
                  try fileData(
                      named: quarantineName,
                      in: parentDescriptor,
                      matching: expectedIdentity,
                      expectedByteCount: expectedData.count
                  ) == expectedData else {
                throw WriterError.retainedManagedFileChanged(quarantineName)
            }
        }

        guard try removeEntry(
            named: quarantineName,
            matching: expectedIdentity,
            in: parentDescriptor
        ) else {
            throw WriterError.createOnlyRollbackConflict(quarantineName, ESTALE)
        }
        return true
    }

    private static func fileIdentity(at url: URL) throws -> InstalledFileIdentity? {
        var status = stat()
        let result = url.path.withCString { Darwin.lstat($0, &status) }
        guard result == 0 else {
            let code = errno
            if code == ENOENT { return nil }
            throw WriterError.fileIdentityInspectionFailed(code)
        }
        return fileIdentity(status: status)
    }

    private static func fileIdentity(
        named name: String,
        in parentDescriptor: Int32
    ) throws -> InstalledFileIdentity? {
        guard let status = try fileStatus(named: name, in: parentDescriptor) else {
            return nil
        }
        return fileIdentity(status: status)
    }

    private static func fileIdentity(descriptor: Int32) throws -> InstalledFileIdentity? {
        fileIdentity(status: try fileStatus(descriptor: descriptor))
    }

    private static func fileIdentity(status: stat) -> InstalledFileIdentity {
        InstalledFileIdentity(
            device: status.st_dev,
            inode: status.st_ino,
            generation: status.st_gen
        )
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
