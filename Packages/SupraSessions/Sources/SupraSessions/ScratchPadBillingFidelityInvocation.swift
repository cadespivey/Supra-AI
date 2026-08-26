import Darwin
import Foundation

struct ScratchPadBillingFidelityDirectoryIdentity: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
}

public enum ScratchPadBillingFidelityReportWriter {
    static func rootIdentity(at rootURL: URL) throws -> ScratchPadBillingFidelityDirectoryIdentity {
        let descriptor = Darwin.open(
            rootURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw posixError() }
        defer { Darwin.close(descriptor) }
        return try identity(of: descriptor)
    }

    static func write(
        _ data: Data,
        rootURL: URL,
        expectedRootIdentity: ScratchPadBillingFidelityDirectoryIdentity,
        relativeParentComponents: [String],
        fileName: String,
        beforeFileCreation: () throws -> Void = {},
        afterFileCreation: () throws -> Void = {},
        afterDataWrite: () throws -> Void = {}
    ) throws {
        let rootFD = Darwin.open(
            rootURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootFD >= 0 else { throw posixError() }
        var directoryDescriptors = [rootFD]
        defer {
            for descriptor in directoryDescriptors.reversed() {
                _ = Darwin.close(descriptor)
            }
        }
        guard try identity(of: rootFD) == expectedRootIdentity else {
            throw posixError(code: ESTALE)
        }

        var directoryFD = rootFD
        for component in relativeParentComponents {
            let nextFD = component.withCString { name in
                Darwin.openat(
                    directoryFD,
                    name,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard nextFD >= 0 else { throw posixError() }
            directoryDescriptors.append(nextFD)
            directoryFD = nextFD
        }

        try beforeFileCreation()
        guard directoryChainMatches(
            rootURL: rootURL,
            expectedRootIdentity: expectedRootIdentity,
            components: relativeParentComponents,
            expectedDescriptors: directoryDescriptors
        ) else {
            throw posixError(code: ESTALE)
        }

        let fileFD = fileName.withCString { name in
            Darwin.openat(
                directoryFD,
                name,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard fileFD >= 0 else { throw posixError() }
        defer { Darwin.close(fileFD) }
        let expectedFileIdentity = try identity(of: fileFD)
        var shouldRemoveFile = true
        defer {
            if shouldRemoveFile {
                _ = Darwin.ftruncate(fileFD, 0)
                _ = Darwin.fsync(fileFD)
            }
        }

        try afterFileCreation()
        guard directoryChainMatches(
            rootURL: rootURL,
            expectedRootIdentity: expectedRootIdentity,
            components: relativeParentComponents,
            expectedDescriptors: directoryDescriptors
        ), leafMatches(
            expectedIdentity: expectedFileIdentity,
            directoryFD: directoryFD,
            fileName: fileName
        ) else {
            throw posixError(code: ESTALE)
        }

        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                guard let baseAddress = bytes.baseAddress else { break }
                let result = Darwin.write(
                    fileFD,
                    baseAddress.advanced(by: written),
                    bytes.count - written
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard result > 0 else { throw posixError(code: EIO) }
                written += result
            }
        }
        guard Darwin.fsync(fileFD) == 0 else { throw posixError() }
        try afterDataWrite()
        guard directoryChainMatches(
            rootURL: rootURL,
            expectedRootIdentity: expectedRootIdentity,
            components: relativeParentComponents,
            expectedDescriptors: directoryDescriptors
        ), leafMatches(
            expectedIdentity: expectedFileIdentity,
            directoryFD: directoryFD,
            fileName: fileName
        ) else {
            throw posixError(code: ESTALE)
        }
        shouldRemoveFile = false
    }

    private static func directoryChainMatches(
        rootURL: URL,
        expectedRootIdentity: ScratchPadBillingFidelityDirectoryIdentity,
        components: [String],
        expectedDescriptors: [Int32]
    ) -> Bool {
        guard expectedDescriptors.count == components.count + 1 else { return false }
        let verificationRootFD = Darwin.open(
            rootURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard verificationRootFD >= 0,
              let actualRootIdentity = try? identity(of: verificationRootFD),
              actualRootIdentity == expectedRootIdentity else {
            if verificationRootFD >= 0 { _ = Darwin.close(verificationRootFD) }
            return false
        }
        var verificationDescriptors = [verificationRootFD]
        defer {
            for descriptor in verificationDescriptors.reversed() {
                _ = Darwin.close(descriptor)
            }
        }

        var directoryFD = verificationRootFD
        for (index, component) in components.enumerated() {
            let nextFD = component.withCString { name in
                Darwin.openat(
                    directoryFD,
                    name,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard nextFD >= 0 else { return false }
            verificationDescriptors.append(nextFD)
            guard let actualIdentity = try? identity(of: nextFD),
                  let expectedIdentity = try? identity(of: expectedDescriptors[index + 1]),
                  actualIdentity == expectedIdentity else {
                return false
            }
            directoryFD = nextFD
        }
        return true
    }

    private static func leafMatches(
        expectedIdentity: ScratchPadBillingFidelityDirectoryIdentity,
        directoryFD: Int32,
        fileName: String
    ) -> Bool {
        var value = stat()
        let result = fileName.withCString { name in
            Darwin.fstatat(directoryFD, name, &value, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0,
              (value.st_mode & S_IFMT) == S_IFREG else {
            return false
        }
        return ScratchPadBillingFidelityDirectoryIdentity(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino)
        ) == expectedIdentity
    }

    private static func identity(
        of descriptor: Int32
    ) throws -> ScratchPadBillingFidelityDirectoryIdentity {
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0 else { throw posixError() }
        return ScratchPadBillingFidelityDirectoryIdentity(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino)
        )
    }

    private static func posixError(code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}

public struct ScratchPadBillingFidelityInvocation: Sendable, Equatable {
    public let outputURL: URL
    public let chatRepositoryID: String
    public let sourceCommitSHA: String
    private let temporaryRootURL: URL
    private let temporaryRootIdentity: ScratchPadBillingFidelityDirectoryIdentity
    private let relativeParentComponents: [String]
    private let outputFileName: String

    public static func resolve(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        compiledSourceCommitSHA: String? = Bundle.main.object(
            forInfoDictionaryKey: "SupraSourceCommitSHA"
        ) as? String
    ) throws -> Self {
        let outputPath = try uniqueValue(
            after: "-scratchPadBillingFidelityOutput",
            arguments: arguments
        )
        let repositoryID = try environmentValue(
            "SUPRA_BILLING_CHAT_REPOSITORY",
            environment: environment
        )
        let sourceCommitSHA = try environmentValue(
            "SUPRA_BILLING_SOURCE_SHA",
            environment: environment
        )
        guard sourceCommitSHA.count == 40,
              sourceCommitSHA.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw ScratchPadBillingFidelityInvocationError.invalidValue("SUPRA_BILLING_SOURCE_SHA")
        }
        guard let compiledSourceCommitSHA,
              compiledSourceCommitSHA.count == 40,
              compiledSourceCommitSHA.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw ScratchPadBillingFidelityInvocationError.invalidValue("SupraSourceCommitSHA")
        }
        guard sourceCommitSHA == compiledSourceCommitSHA else {
            throw ScratchPadBillingFidelityInvocationError.sourceCommitMismatch(
                requested: sourceCommitSHA,
                compiled: compiledSourceCommitSHA
            )
        }

        let outputURL = URL(fileURLWithPath: outputPath, isDirectory: false).standardizedFileURL
        let temporaryRoot = temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let outputParent = outputURL.deletingLastPathComponent().resolvingSymlinksInPath()
        guard outputParent.path == temporaryRoot.path
                || outputParent.path.hasPrefix(temporaryRoot.path + "/") else {
            throw ScratchPadBillingFidelityInvocationError.pathOutsideTemporaryContainer(outputURL.path)
        }
        var parentIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: outputParent.path, isDirectory: &parentIsDirectory),
              parentIsDirectory.boolValue else {
            throw ScratchPadBillingFidelityInvocationError.invalidValue("-scratchPadBillingFidelityOutput")
        }
        if FileManager.default.fileExists(atPath: outputURL.path) ||
            (try? FileManager.default.destinationOfSymbolicLink(atPath: outputURL.path)) != nil {
            throw ScratchPadBillingFidelityInvocationError.outputAlreadyExists(outputURL.path)
        }

        let relativeParentComponents: [String]
        if outputParent.path == temporaryRoot.path {
            relativeParentComponents = []
        } else {
            relativeParentComponents = outputParent.path
                .dropFirst(temporaryRoot.path.count + 1)
                .split(separator: "/")
                .map(String.init)
        }
        let rootIdentity = try ScratchPadBillingFidelityReportWriter.rootIdentity(at: temporaryRoot)
        return Self(
            outputURL: outputURL,
            chatRepositoryID: repositoryID,
            sourceCommitSHA: sourceCommitSHA,
            temporaryRootURL: temporaryRoot,
            temporaryRootIdentity: rootIdentity,
            relativeParentComponents: relativeParentComponents,
            outputFileName: outputURL.lastPathComponent
        )
    }

    public func writeReport(_ data: Data) throws {
        try ScratchPadBillingFidelityReportWriter.write(
            data,
            rootURL: temporaryRootURL,
            expectedRootIdentity: temporaryRootIdentity,
            relativeParentComponents: relativeParentComponents,
            fileName: outputFileName
        )
    }

    private static func uniqueValue(after flag: String, arguments: [String]) throws -> String {
        let matches = arguments.indices.filter { arguments[$0] == flag }
        guard matches.count == 1,
              let index = matches.first,
              arguments.indices.contains(index + 1) else {
            throw ScratchPadBillingFidelityInvocationError.invalidValue(flag)
        }
        let value = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw ScratchPadBillingFidelityInvocationError.invalidValue(flag)
        }
        return value
    }

    private static func environmentValue(
        _ key: String,
        environment: [String: String]
    ) throws -> String {
        guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            throw ScratchPadBillingFidelityInvocationError.invalidValue(key)
        }
        return value
    }
}

public enum ScratchPadBillingFidelityInvocationError: Error, LocalizedError, Equatable {
    case invalidValue(String)
    case sourceCommitMismatch(requested: String, compiled: String)
    case pathOutsideTemporaryContainer(String)
    case outputAlreadyExists(String)

    public var errorDescription: String? {
        switch self {
        case .invalidValue(let field):
            "ScratchPad billing fidelity invocation is missing or duplicates \(field)."
        case .sourceCommitMismatch(let requested, let compiled):
            "ScratchPad billing fidelity source mismatch: requested \(requested), signed build \(compiled)."
        case .pathOutsideTemporaryContainer(let path):
            "ScratchPad billing fidelity output is outside the app temporary container: \(path)"
        case .outputAlreadyExists(let path):
            "ScratchPad billing fidelity output already exists: \(path)"
        }
    }
}
