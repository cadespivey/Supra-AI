import CryptoKit
import Darwin
import Foundation
import OSLog
import SupraRuntimeInterface

/// An independently-owned, content-verified model tree used for one runtime
/// load. The snapshot never aliases a source inode and owns its private
/// temporary directory until `remove()` or deinitialization.
public final class RuntimeModelSnapshot: @unchecked Sendable {
    public let snapshotURL: URL
    public let verifiedModelSHA256: String

    private let contentBinding: RuntimeModelContentBinding
    private let expectedNodeIdentities: [String: NodeIdentity]
    private let privateRoot: PrivateRoot
    private let stateLock = NSLock()
    private var isRemoved = false

    private static let constructionLock = NSLock()
    private static let failedConstructionCleanupRegistry =
        FailedConstructionCleanupRegistry()
    private static let cleanupLogger = Logger(
        subsystem: "com.cadespivey.SupraAI",
        category: "RuntimeModelSnapshotCleanup"
    )

    public init(
        sourceURL: URL,
        contentBinding: RuntimeModelContentBinding
    ) throws {
        try Self.verifyBindingFingerprint(contentBinding)

        Self.constructionLock.lock()
        defer { Self.constructionLock.unlock() }
        try Self.drainFailedConstructionCleanups()

        let sourceRoot = try Self.openRootDirectory(
            at: sourceURL.standardizedFileURL,
            purpose: .source
        )
        let privateRoot = try Self.makePrivateTemporaryRoot()
        do {
            try Self.copyDeclaredFiles(
                contentBinding.files,
                sourceRoot: sourceRoot,
                snapshotRoot: privateRoot.descriptor
            )
            let identities = try Self.captureVerifiedSnapshot(
                root: privateRoot.descriptor,
                files: contentBinding.files
            )

            self.snapshotURL = privateRoot.url
            self.verifiedModelSHA256 = contentBinding.fingerprintSHA256
            self.contentBinding = contentBinding
            self.expectedNodeIdentities = identities
            self.privateRoot = privateRoot
        } catch {
            Self.cleanupFailedConstruction(privateRoot)
            throw error
        }
    }

    deinit {
        try? remove()
    }

    /// Re-opens the retained tree without following links and verifies its
    /// exact topology, inode identities, sizes, link counts, and byte hashes.
    public func reverify() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isRemoved else {
            throw RuntimeModelSnapshotError.snapshotRemoved
        }

        let root = try Self.openRootDirectory(at: snapshotURL, purpose: .snapshot)
        let identities = try Self.captureVerifiedSnapshot(
            root: root,
            files: contentBinding.files
        )
        guard identities == expectedNodeIdentities else {
            throw RuntimeModelSnapshotError.snapshotIdentityChanged
        }
        try Self.verifyBindingFingerprint(contentBinding)
    }

    /// Removes the owned temporary root. Repeated calls after successful
    /// removal (or after external removal) are harmless.
    public func remove() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isRemoved else { return }

        try Self.removeOwnedRoot(privateRoot)
        isRemoved = true
    }
}

public enum RuntimeModelSnapshotError: Error, Equatable, Sendable {
    case invalidSourceURL
    case contentBindingFingerprintMismatch
    case temporaryRootCreationFailed(Int32)
    case systemCallFailed(operation: String, path: String, code: Int32)
    case unsafeRelativePath(String)
    case nonDirectory(String)
    case nonRegularFile(String)
    case symbolicLink(String)
    case hardLinkedFile(String)
    case invalidPrivatePermissions(String)
    case sizeMismatch(path: String, expected: Int64, actual: Int64)
    case hashMismatch(String)
    case sourceChangedDuringCopy(String)
    case sourceAndSnapshotShareInode(String)
    case unexpectedSnapshotEntry(String)
    case missingSnapshotEntry(String)
    case crossDeviceDirectory(String)
    case snapshotIdentityChanged
    case snapshotRemoved
}

extension RuntimeModelSnapshotError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidSourceURL:
            "The model source must be a local file URL."
        case .contentBindingFingerprintMismatch:
            "The model content binding fingerprint is invalid."
        case let .temporaryRootCreationFailed(code):
            "Unable to create a private model snapshot (errno \(code))."
        case let .systemCallFailed(operation, path, code):
            "\(operation) failed for \(path) (errno \(code))."
        case let .unsafeRelativePath(path):
            "The declared model path is unsafe: \(path)."
        case let .nonDirectory(path):
            "A model path component is not a directory: \(path)."
        case let .nonRegularFile(path):
            "A declared model entry is not a regular file: \(path)."
        case let .symbolicLink(path):
            "A symbolic link is not allowed in a model snapshot: \(path)."
        case let .hardLinkedFile(path):
            "A hard-linked model file is not allowed: \(path)."
        case let .invalidPrivatePermissions(path):
            "A private snapshot entry has unsafe permissions: \(path)."
        case let .sizeMismatch(path, expected, actual):
            "Model file \(path) has size \(actual), expected \(expected)."
        case let .hashMismatch(path):
            "Model file \(path) does not match its authorized SHA-256."
        case let .sourceChangedDuringCopy(path):
            "Model source changed while it was being copied: \(path)."
        case let .sourceAndSnapshotShareInode(path):
            "Model snapshot unexpectedly aliases its source inode: \(path)."
        case let .unexpectedSnapshotEntry(path):
            "The model snapshot contains an undeclared entry: \(path)."
        case let .missingSnapshotEntry(path):
            "The model snapshot is missing a declared entry: \(path)."
        case let .crossDeviceDirectory(path):
            "Snapshot cleanup refused to cross a filesystem boundary at \(path)."
        case .snapshotIdentityChanged:
            "The retained model snapshot identity changed."
        case .snapshotRemoved:
            "The retained model snapshot has been removed."
        }
    }
}

private extension RuntimeModelSnapshot {
    enum RootPurpose {
        case source
        case snapshot
    }

    struct PrivateRoot {
        let url: URL
        let name: String
        let parentDescriptor: OwnedFileDescriptor
        let descriptor: OwnedFileDescriptor
    }

    final class FailedConstructionCleanupRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var pendingRoots: [PrivateRoot] = []

        func retain(_ privateRoot: PrivateRoot) {
            lock.lock()
            pendingRoots.append(privateRoot)
            lock.unlock()
        }

        func drain(
            using cleanup: (PrivateRoot) throws -> Void
        ) throws {
            lock.lock()
            defer { lock.unlock() }

            var remaining: [PrivateRoot] = []
            var firstError: Error?
            for privateRoot in pendingRoots {
                do {
                    try cleanup(privateRoot)
                } catch {
                    remaining.append(privateRoot)
                    if firstError == nil {
                        firstError = error
                    }
                }
            }
            pendingRoots = remaining
            if let firstError {
                throw firstError
            }
        }
    }

    struct NodeIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64

        init(_ value: stat) {
            self.device = UInt64(value.st_dev)
            self.inode = UInt64(value.st_ino)
        }
    }

    struct StableFileState: Equatable {
        let identity: NodeIdentity
        let mode: mode_t
        let linkCount: UInt64
        let size: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64

        init(_ value: stat) {
            self.identity = NodeIdentity(value)
            self.mode = value.st_mode
            self.linkCount = UInt64(value.st_nlink)
            self.size = value.st_size
            self.modificationSeconds = Int64(value.st_mtimespec.tv_sec)
            self.modificationNanoseconds = Int64(value.st_mtimespec.tv_nsec)
            self.changeSeconds = Int64(value.st_ctimespec.tv_sec)
            self.changeNanoseconds = Int64(value.st_ctimespec.tv_nsec)
        }
    }

    final class OwnedFileDescriptor {
        let rawValue: Int32

        init(_ rawValue: Int32) {
            self.rawValue = rawValue
        }

        deinit {
            _ = Darwin.close(rawValue)
        }
    }

    static func verifyBindingFingerprint(
        _ binding: RuntimeModelContentBinding
    ) throws {
        let fingerprint = try RuntimeModelContentBinding.canonicalFingerprintSHA256(
            algorithm: binding.algorithm,
            schemaVersion: binding.schemaVersion,
            repositoryID: binding.repositoryID,
            revision: binding.revision,
            files: binding.files
        )
        guard constantTimeEqual(fingerprint, binding.fingerprintSHA256) else {
            throw RuntimeModelSnapshotError.contentBindingFingerprintMismatch
        }
    }

    static func makePrivateTemporaryRoot() throws -> PrivateRoot {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let parentDescriptor = try openRootDirectory(
            at: temporaryDirectory,
            purpose: .source
        )

        var createdName: String?
        var lastCreationError = EEXIST
        for _ in 0..<64 {
            let candidate = "SupraRuntimeModelSnapshot." + UUID().uuidString
            let result = candidate.withCString { name in
                Darwin.mkdirat(parentDescriptor.rawValue, name, mode_t(0o700))
            }
            if result == 0 {
                createdName = candidate
                break
            }
            lastCreationError = errno
            guard lastCreationError == EEXIST else { break }
        }
        guard let createdName else {
            throw RuntimeModelSnapshotError.temporaryRootCreationFailed(lastCreationError)
        }

        let url = temporaryDirectory.appendingPathComponent(
            createdName,
            isDirectory: true
        )
        do {
            let descriptor = try openDirectory(
                at: parentDescriptor.rawValue,
                name: createdName,
                path: createdName
            )
            guard Darwin.fchmod(descriptor.rawValue, mode_t(0o700)) == 0 else {
                throw systemError("fchmod", path: url.path)
            }
            let value = try status(of: descriptor.rawValue, path: "")
            try requireDirectory(value, path: "")
            try requirePermissions(value, expected: mode_t(0o700), path: "")
            return PrivateRoot(
                url: url,
                name: createdName,
                parentDescriptor: parentDescriptor,
                descriptor: descriptor
            )
        } catch {
            _ = createdName.withCString { name in
                Darwin.unlinkat(parentDescriptor.rawValue, name, AT_REMOVEDIR)
            }
            throw error
        }
    }

    static func openDirectory(
        at parent: Int32,
        name: String,
        path: String
    ) throws -> OwnedFileDescriptor {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let descriptor = name.withCString { component in
            Darwin.openat(parent, component, flags)
        }
        guard descriptor >= 0 else {
            throw systemError("openat", path: path)
        }
        let owned = OwnedFileDescriptor(descriptor)
        let value = try status(of: descriptor, path: path)
        try requireDirectory(value, path: path)
        return owned
    }

    static func openRootDirectory(
        at url: URL,
        purpose: RootPurpose
    ) throws -> OwnedFileDescriptor {
        guard url.isFileURL else {
            throw RuntimeModelSnapshotError.invalidSourceURL
        }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let descriptor = url.path.withCString { path in
            Darwin.open(path, flags)
        }
        guard descriptor >= 0 else {
            let code = errno
            if code == ELOOP {
                throw RuntimeModelSnapshotError.symbolicLink(".")
            }
            throw RuntimeModelSnapshotError.systemCallFailed(
                operation: "open",
                path: url.path,
                code: code
            )
        }
        let owned = OwnedFileDescriptor(descriptor)
        let value = try status(of: descriptor, path: ".")
        try requireDirectory(value, path: ".")
        if purpose == .snapshot {
            try requirePermissions(value, expected: mode_t(0o700), path: ".")
        }
        return owned
    }

    static func cleanupFailedConstruction(_ privateRoot: PrivateRoot) {
        do {
            try removeOwnedRoot(privateRoot)
        } catch {
            failedConstructionCleanupRegistry.retain(privateRoot)
            let diagnostic = String(describing: error)
            cleanupLogger.fault(
                "Failed model snapshot construction cleanup; retained for retry: \(diagnostic, privacy: .private)"
            )
        }
    }

    static func drainFailedConstructionCleanups() throws {
        do {
            try failedConstructionCleanupRegistry.drain { privateRoot in
                try removeOwnedRoot(privateRoot)
            }
        } catch {
            let diagnostic = String(describing: error)
            cleanupLogger.fault(
                "Pending model snapshot construction cleanup still failed; refusing another allocation: \(diagnostic, privacy: .private)"
            )
            throw error
        }
    }

    static func removeOwnedRoot(_ privateRoot: PrivateRoot) throws {
        let rootStatus = try status(
            of: privateRoot.descriptor.rawValue,
            path: privateRoot.name
        )
        try requireDirectory(rootStatus, path: privateRoot.name)
        let rootIdentity = NodeIdentity(rootStatus)

        try removeDirectoryContents(
            descriptor: privateRoot.descriptor.rawValue,
            relativePath: "",
            rootDevice: rootStatus.st_dev
        )

        for _ in 0..<3 {
            let names = try directoryEntryNames(
                descriptor: privateRoot.parentDescriptor.rawValue,
                path: privateRoot.url.deletingLastPathComponent().path
            )
            for name in names {
                guard let entryStatus = try status(
                    at: privateRoot.parentDescriptor.rawValue,
                    name: name,
                    path: name
                ), NodeIdentity(entryStatus) == rootIdentity else {
                    continue
                }
                try requireDirectory(entryStatus, path: name)

                let candidate = try openDirectory(
                    at: privateRoot.parentDescriptor.rawValue,
                    name: name,
                    path: name
                )
                let openedStatus = try status(of: candidate.rawValue, path: name)
                guard NodeIdentity(openedStatus) == rootIdentity else {
                    throw RuntimeModelSnapshotError.snapshotIdentityChanged
                }

                let result = name.withCString { component in
                    Darwin.unlinkat(
                        privateRoot.parentDescriptor.rawValue,
                        component,
                        AT_REMOVEDIR
                    )
                }
                if result == 0 {
                    return
                }
                let code = errno
                if code == ENOENT {
                    continue
                }
                throw RuntimeModelSnapshotError.systemCallFailed(
                    operation: "unlinkat",
                    path: name,
                    code: code
                )
            }

            let retainedStatus = try status(
                of: privateRoot.descriptor.rawValue,
                path: privateRoot.name
            )
            if retainedStatus.st_nlink == 0 {
                return
            }
        }

        throw RuntimeModelSnapshotError.snapshotIdentityChanged
    }

    static func removeDirectoryContents(
        descriptor: Int32,
        relativePath: String,
        rootDevice: dev_t
    ) throws {
        let names = try directoryEntryNames(
            descriptor: descriptor,
            path: relativePath
        )
        for name in names {
            let path = relativePath.isEmpty ? name : relativePath + "/" + name
            guard let entryStatus = try status(
                at: descriptor,
                name: name,
                path: path
            ) else {
                continue
            }

            if entryStatus.st_mode & S_IFMT == S_IFDIR {
                guard entryStatus.st_dev == rootDevice else {
                    throw RuntimeModelSnapshotError.crossDeviceDirectory(path)
                }
                let child = try openDirectory(
                    at: descriptor,
                    name: name,
                    path: path
                )
                let openedStatus = try status(of: child.rawValue, path: path)
                guard openedStatus.st_dev == rootDevice else {
                    throw RuntimeModelSnapshotError.crossDeviceDirectory(path)
                }
                let childIdentity = NodeIdentity(openedStatus)
                guard childIdentity == NodeIdentity(entryStatus) else {
                    throw RuntimeModelSnapshotError.snapshotIdentityChanged
                }

                try removeDirectoryContents(
                    descriptor: child.rawValue,
                    relativePath: path,
                    rootDevice: rootDevice
                )
                guard let beforeUnlink = try status(
                    at: descriptor,
                    name: name,
                    path: path
                ) else {
                    continue
                }
                guard beforeUnlink.st_mode & S_IFMT == S_IFDIR,
                      NodeIdentity(beforeUnlink) == childIdentity else {
                    throw RuntimeModelSnapshotError.snapshotIdentityChanged
                }

                let result = name.withCString { component in
                    Darwin.unlinkat(descriptor, component, AT_REMOVEDIR)
                }
                if result != 0 {
                    let code = errno
                    if code == ENOENT { continue }
                    throw RuntimeModelSnapshotError.systemCallFailed(
                        operation: "unlinkat",
                        path: path,
                        code: code
                    )
                }
            } else {
                let result = name.withCString { component in
                    Darwin.unlinkat(descriptor, component, 0)
                }
                if result != 0 {
                    let code = errno
                    if code == ENOENT { continue }
                    throw RuntimeModelSnapshotError.systemCallFailed(
                        operation: "unlinkat",
                        path: path,
                        code: code
                    )
                }
            }
        }
    }

    static func directoryEntryNames(
        descriptor: Int32,
        path: String
    ) throws -> [String] {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let duplicate = ".".withCString { component in
            Darwin.openat(descriptor, component, flags)
        }
        guard duplicate >= 0 else {
            throw systemError("openat", path: path)
        }
        guard let stream = Darwin.fdopendir(duplicate) else {
            let code = errno
            _ = Darwin.close(duplicate)
            throw RuntimeModelSnapshotError.systemCallFailed(
                operation: "fdopendir",
                path: path,
                code: code
            )
        }
        defer { Darwin.closedir(stream) }

        var names: [String] = []
        while true {
            errno = 0
            guard let entry = Darwin.readdir(stream) else {
                if errno != 0 {
                    throw systemError("readdir", path: path)
                }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." {
                names.append(name)
            }
        }
        return names
    }

    static func status(
        at parent: Int32,
        name: String,
        path: String
    ) throws -> stat? {
        var value = stat()
        let result = name.withCString { component in
            Darwin.fstatat(
                parent,
                component,
                &value,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if result == 0 {
            return value
        }
        let code = errno
        if code == ENOENT {
            return nil
        }
        throw RuntimeModelSnapshotError.systemCallFailed(
            operation: "fstatat",
            path: path,
            code: code
        )
    }

    static func copyDeclaredFiles(
        _ files: [RuntimeModelContentBinding.File],
        sourceRoot: OwnedFileDescriptor,
        snapshotRoot: OwnedFileDescriptor
    ) throws {
        for file in files {
            let components = try safeComponents(for: file.path)
            let sourceParent = try traverseDirectories(
                from: sourceRoot,
                components: Array(components.dropLast()),
                create: false,
                path: file.path
            )
            let sourceParentFD = sourceParent?.rawValue ?? sourceRoot.rawValue
            let source = try openReadOnlyFile(
                at: sourceParentFD,
                name: components[components.count - 1],
                path: file.path
            )
            let sourceBefore = try validatedRegularFileState(
                descriptor: source.rawValue,
                path: file.path,
                expectedSize: file.size,
                requirePrivatePermissions: false
            )

            let snapshotParent = try traverseDirectories(
                from: snapshotRoot,
                components: Array(components.dropLast()),
                create: true,
                path: file.path
            )
            let snapshotParentFD = snapshotParent?.rawValue ?? snapshotRoot.rawValue
            let destination = try createPrivateFile(
                at: snapshotParentFD,
                name: components[components.count - 1],
                path: file.path
            )

            let copied = try copyAndHash(
                source: source.rawValue,
                destination: destination.rawValue,
                path: file.path
            )
            guard copied.byteCount == file.size else {
                throw RuntimeModelSnapshotError.sizeMismatch(
                    path: file.path,
                    expected: file.size,
                    actual: copied.byteCount
                )
            }
            guard constantTimeEqual(copied.sha256, file.actualSHA256) else {
                throw RuntimeModelSnapshotError.hashMismatch(file.path)
            }
            guard Darwin.fsync(destination.rawValue) == 0 else {
                throw systemError("fsync", path: file.path)
            }

            let sourceAfter = try validatedRegularFileState(
                descriptor: source.rawValue,
                path: file.path,
                expectedSize: file.size,
                requirePrivatePermissions: false
            )
            guard sourceBefore == sourceAfter else {
                throw RuntimeModelSnapshotError.sourceChangedDuringCopy(file.path)
            }
            let destinationState = try validatedRegularFileState(
                descriptor: destination.rawValue,
                path: file.path,
                expectedSize: file.size,
                requirePrivatePermissions: true
            )
            guard sourceBefore.identity != destinationState.identity else {
                throw RuntimeModelSnapshotError.sourceAndSnapshotShareInode(file.path)
            }
        }
    }

    static func traverseDirectories(
        from root: OwnedFileDescriptor,
        components: [String],
        create: Bool,
        path: String
    ) throws -> OwnedFileDescriptor? {
        var current = root.rawValue
        var opened: [OwnedFileDescriptor] = []
        var relativeComponents: [String] = []

        for component in components {
            relativeComponents.append(component)
            let relativePath = relativeComponents.joined(separator: "/")
            if create {
                let result = component.withCString { name in
                    Darwin.mkdirat(current, name, mode_t(0o700))
                }
                if result != 0, errno != EEXIST {
                    throw systemError("mkdirat", path: relativePath)
                }
            }

            let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            let descriptor = component.withCString { name in
                Darwin.openat(current, name, flags)
            }
            guard descriptor >= 0 else {
                let code = errno
                if code == ELOOP {
                    throw RuntimeModelSnapshotError.symbolicLink(relativePath)
                }
                if code == ENOTDIR {
                    throw RuntimeModelSnapshotError.nonDirectory(relativePath)
                }
                throw RuntimeModelSnapshotError.systemCallFailed(
                    operation: "openat",
                    path: relativePath.isEmpty ? path : relativePath,
                    code: code
                )
            }
            let owned = OwnedFileDescriptor(descriptor)
            let value = try status(of: descriptor, path: relativePath)
            try requireDirectory(value, path: relativePath)
            if create {
                guard Darwin.fchmod(descriptor, mode_t(0o700)) == 0 else {
                    throw systemError("fchmod", path: relativePath)
                }
                let secured = try status(of: descriptor, path: relativePath)
                try requirePermissions(
                    secured,
                    expected: mode_t(0o700),
                    path: relativePath
                )
            }
            opened.append(owned)
            current = descriptor
        }
        return opened.last
    }

    static func openReadOnlyFile(
        at parent: Int32,
        name: String,
        path: String
    ) throws -> OwnedFileDescriptor {
        let flags = O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        let descriptor = name.withCString { component in
            Darwin.openat(parent, component, flags)
        }
        guard descriptor >= 0 else {
            let code = errno
            if code == ELOOP {
                throw RuntimeModelSnapshotError.symbolicLink(path)
            }
            throw RuntimeModelSnapshotError.systemCallFailed(
                operation: "openat",
                path: path,
                code: code
            )
        }
        return OwnedFileDescriptor(descriptor)
    }

    static func createPrivateFile(
        at parent: Int32,
        name: String,
        path: String
    ) throws -> OwnedFileDescriptor {
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        let descriptor = name.withCString { component in
            Darwin.openat(parent, component, flags, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw systemError("openat", path: path)
        }
        let owned = OwnedFileDescriptor(descriptor)
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw systemError("fchmod", path: path)
        }
        return owned
    }

    static func captureVerifiedSnapshot(
        root: OwnedFileDescriptor,
        files: [RuntimeModelContentBinding.File]
    ) throws -> [String: NodeIdentity] {
        let expectedFiles = Set(files.map(\.path))
        let expectedDirectories = directoryPaths(for: files)
        let expectedPaths = expectedFiles.union(expectedDirectories).union([""])
        let topologyBefore = try inspectExactTopology(
            root: root,
            expectedFiles: expectedFiles,
            expectedDirectories: expectedDirectories
        )
        guard Set(topologyBefore.keys) == expectedPaths else {
            let missing = expectedPaths.subtracting(topologyBefore.keys).sorted().first ?? ""
            throw RuntimeModelSnapshotError.missingSnapshotEntry(missing)
        }

        for file in files {
            let components = try safeComponents(for: file.path)
            let parent = try traverseDirectories(
                from: root,
                components: Array(components.dropLast()),
                create: false,
                path: file.path
            )
            let parentFD = parent?.rawValue ?? root.rawValue
            let descriptor = try openReadOnlyFile(
                at: parentFD,
                name: components[components.count - 1],
                path: file.path
            )
            let value = try validatedRegularFileState(
                descriptor: descriptor.rawValue,
                path: file.path,
                expectedSize: file.size,
                requirePrivatePermissions: true
            )
            guard value.identity == topologyBefore[file.path] else {
                throw RuntimeModelSnapshotError.snapshotIdentityChanged
            }
            let hash = try hashFile(
                descriptor: descriptor.rawValue,
                path: file.path
            )
            guard hash.byteCount == file.size else {
                throw RuntimeModelSnapshotError.sizeMismatch(
                    path: file.path,
                    expected: file.size,
                    actual: hash.byteCount
                )
            }
            guard constantTimeEqual(hash.sha256, file.actualSHA256) else {
                throw RuntimeModelSnapshotError.hashMismatch(file.path)
            }
            let afterHash = try validatedRegularFileState(
                descriptor: descriptor.rawValue,
                path: file.path,
                expectedSize: file.size,
                requirePrivatePermissions: true
            )
            guard value == afterHash else {
                throw RuntimeModelSnapshotError.snapshotIdentityChanged
            }
        }

        let topologyAfter = try inspectExactTopology(
            root: root,
            expectedFiles: expectedFiles,
            expectedDirectories: expectedDirectories
        )
        guard topologyBefore == topologyAfter else {
            throw RuntimeModelSnapshotError.snapshotIdentityChanged
        }
        return topologyAfter
    }

    static func inspectExactTopology(
        root: OwnedFileDescriptor,
        expectedFiles: Set<String>,
        expectedDirectories: Set<String>
    ) throws -> [String: NodeIdentity] {
        let rootStatus = try status(of: root.rawValue, path: "")
        try requireDirectory(rootStatus, path: "")
        try requirePermissions(rootStatus, expected: mode_t(0o700), path: "")
        var identities = ["": NodeIdentity(rootStatus)]
        try inspectDirectory(
            descriptor: root.rawValue,
            relativePath: "",
            expectedFiles: expectedFiles,
            expectedDirectories: expectedDirectories,
            identities: &identities
        )
        return identities
    }

    static func inspectDirectory(
        descriptor: Int32,
        relativePath: String,
        expectedFiles: Set<String>,
        expectedDirectories: Set<String>,
        identities: inout [String: NodeIdentity]
    ) throws {
        // `dup` would share the directory-stream offset with `descriptor`, so
        // a second verification pass could begin at end-of-directory. Opening
        // `.` through the anchored descriptor creates an independent open-file
        // description while remaining inside the verified directory.
        let streamFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let duplicate = ".".withCString { component in
            Darwin.openat(descriptor, component, streamFlags)
        }
        guard duplicate >= 0 else {
            throw systemError("openat", path: relativePath)
        }
        guard let stream = Darwin.fdopendir(duplicate) else {
            let code = errno
            _ = Darwin.close(duplicate)
            throw RuntimeModelSnapshotError.systemCallFailed(
                operation: "fdopendir",
                path: relativePath,
                code: code
            )
        }
        defer { Darwin.closedir(stream) }

        while true {
            errno = 0
            guard let entry = Darwin.readdir(stream) else {
                if errno != 0 {
                    throw systemError("readdir", path: relativePath)
                }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            let path = relativePath.isEmpty ? name : relativePath + "/" + name

            var value = stat()
            let result = name.withCString { component in
                Darwin.fstatat(descriptor, component, &value, AT_SYMLINK_NOFOLLOW)
            }
            guard result == 0 else {
                throw systemError("fstatat", path: path)
            }

            switch value.st_mode & S_IFMT {
            case S_IFDIR:
                guard expectedDirectories.contains(path) else {
                    throw RuntimeModelSnapshotError.unexpectedSnapshotEntry(path)
                }
                try requirePermissions(value, expected: mode_t(0o700), path: path)
                let childFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                let child = name.withCString { component in
                    Darwin.openat(descriptor, component, childFlags)
                }
                guard child >= 0 else {
                    let code = errno
                    if code == ELOOP {
                        throw RuntimeModelSnapshotError.symbolicLink(path)
                    }
                    throw RuntimeModelSnapshotError.systemCallFailed(
                        operation: "openat",
                        path: path,
                        code: code
                    )
                }
                let ownedChild = OwnedFileDescriptor(child)
                let openedStatus = try status(of: child, path: path)
                guard NodeIdentity(openedStatus) == NodeIdentity(value) else {
                    throw RuntimeModelSnapshotError.snapshotIdentityChanged
                }
                identities[path] = NodeIdentity(value)
                try inspectDirectory(
                    descriptor: ownedChild.rawValue,
                    relativePath: path,
                    expectedFiles: expectedFiles,
                    expectedDirectories: expectedDirectories,
                    identities: &identities
                )
            case S_IFREG:
                guard expectedFiles.contains(path) else {
                    throw RuntimeModelSnapshotError.unexpectedSnapshotEntry(path)
                }
                guard value.st_nlink == 1 else {
                    throw RuntimeModelSnapshotError.hardLinkedFile(path)
                }
                try requirePermissions(value, expected: mode_t(0o600), path: path)
                identities[path] = NodeIdentity(value)
            case S_IFLNK:
                throw RuntimeModelSnapshotError.symbolicLink(path)
            default:
                throw RuntimeModelSnapshotError.nonRegularFile(path)
            }
        }
    }

    static func directoryPaths(
        for files: [RuntimeModelContentBinding.File]
    ) -> Set<String> {
        var result = Set<String>()
        for file in files {
            let components = file.path.split(separator: "/").map(String.init)
            guard components.count > 1 else { continue }
            var path = ""
            for component in components.dropLast() {
                path = path.isEmpty ? component : path + "/" + component
                result.insert(path)
            }
        }
        return result
    }

    static func safeComponents(for path: String) throws -> [String] {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw RuntimeModelSnapshotError.unsafeRelativePath(path)
        }
        return components
    }

    static func validatedRegularFileState(
        descriptor: Int32,
        path: String,
        expectedSize: Int64,
        requirePrivatePermissions: Bool
    ) throws -> StableFileState {
        let value = try status(of: descriptor, path: path)
        guard value.st_mode & S_IFMT == S_IFREG else {
            if value.st_mode & S_IFMT == S_IFLNK {
                throw RuntimeModelSnapshotError.symbolicLink(path)
            }
            throw RuntimeModelSnapshotError.nonRegularFile(path)
        }
        guard value.st_nlink == 1 else {
            throw RuntimeModelSnapshotError.hardLinkedFile(path)
        }
        guard value.st_size == expectedSize else {
            throw RuntimeModelSnapshotError.sizeMismatch(
                path: path,
                expected: expectedSize,
                actual: value.st_size
            )
        }
        if requirePrivatePermissions {
            try requirePermissions(value, expected: mode_t(0o600), path: path)
        }
        return StableFileState(value)
    }

    static func requireDirectory(_ value: stat, path: String) throws {
        guard value.st_mode & S_IFMT == S_IFDIR else {
            if value.st_mode & S_IFMT == S_IFLNK {
                throw RuntimeModelSnapshotError.symbolicLink(path)
            }
            throw RuntimeModelSnapshotError.nonDirectory(path)
        }
    }

    static func requirePermissions(
        _ value: stat,
        expected: mode_t,
        path: String
    ) throws {
        guard value.st_mode & mode_t(0o777) == expected else {
            throw RuntimeModelSnapshotError.invalidPrivatePermissions(path)
        }
    }

    static func identity(of descriptor: Int32, path: String) throws -> NodeIdentity {
        NodeIdentity(try status(of: descriptor, path: path))
    }

    static func status(of descriptor: Int32, path: String) throws -> stat {
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0 else {
            throw systemError("fstat", path: path)
        }
        return value
    }

    static func copyAndHash(
        source: Int32,
        destination: Int32,
        path: String
    ) throws -> (sha256: String, byteCount: Int64) {
        guard Darwin.lseek(source, 0, SEEK_SET) >= 0 else {
            throw systemError("lseek", path: path)
        }
        var hasher = SHA256()
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)

        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(source, bytes.baseAddress, bytes.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw systemError("read", path: path)
            }
            if count == 0 { break }
            let integerCount = Int(count)
            let data = Data(buffer[0..<integerCount])
            hasher.update(data: data)
            try writeAll(
                data,
                to: destination,
                path: path
            )
            total += Int64(integerCount)
        }
        return (hex(hasher.finalize()), total)
    }

    static func hashFile(
        descriptor: Int32,
        path: String
    ) throws -> (sha256: String, byteCount: Int64) {
        guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw systemError("lseek", path: path)
        }
        var hasher = SHA256()
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)

        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw systemError("read", path: path)
            }
            if count == 0 { break }
            let integerCount = Int(count)
            hasher.update(data: Data(buffer[0..<integerCount]))
            total += Int64(integerCount)
        }
        return (hex(hasher.finalize()), total)
    }

    static func writeAll(_ data: Data, to descriptor: Int32, path: String) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw systemError("write", path: path)
                }
                guard count > 0 else {
                    throw RuntimeModelSnapshotError.systemCallFailed(
                        operation: "write",
                        path: path,
                        code: EIO
                    )
                }
                offset += count
            }
        }
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    static func systemError(_ operation: String, path: String) -> RuntimeModelSnapshotError {
        .systemCallFailed(operation: operation, path: path, code: errno)
    }
}
