import Darwin
import Foundation
import SupraDocuments
import SupraStore

public struct DraftArtifactReconciliationSummary: Sendable, Equatable {
    public var finalizedCount: Int
    public var abortedCount: Int
    public var recoveryRequiredCount: Int
    public var removedTemporaryFileCount: Int
    public var removedRollbackQuarantineCount: Int

    public init(
        finalizedCount: Int = 0,
        abortedCount: Int = 0,
        recoveryRequiredCount: Int = 0,
        removedTemporaryFileCount: Int = 0,
        removedRollbackQuarantineCount: Int = 0
    ) {
        self.finalizedCount = finalizedCount
        self.abortedCount = abortedCount
        self.recoveryRequiredCount = recoveryRequiredCount
        self.removedTemporaryFileCount = removedTemporaryFileCount
        self.removedRollbackQuarantineCount = removedRollbackQuarantineCount
    }
}

/// Resolves Store-owned publication intents left prepared across a process
/// boundary. It only removes exact hidden writer temporaries. A public path is
/// either finalized in place, left untouched for explicit recovery, or absent.
public final class DraftArtifactReconciliationService: @unchecked Sendable {
    private let store: SupraStore
    private let storage: DocumentStorage
    private let fileWriter: DurableFileWriter
    private let fileManager: FileManager

    public init(
        store: SupraStore,
        storage: DocumentStorage = .makeDefault(),
        fileWriter: DurableFileWriter = DurableFileWriter(),
        fileManager: FileManager = .default
    ) {
        self.store = store
        self.storage = storage
        self.fileWriter = fileWriter
        self.fileManager = fileManager
    }

    @discardableResult
    public func reconcilePendingIntents() throws -> DraftArtifactReconciliationSummary {
        var summary = DraftArtifactReconciliationSummary()
        for intent in try store.draftArtifacts.pendingIntents(limit: 2_000) {
            // Validate the Store-owned row before deriving a managed path or
            // mutating any filesystem entry named by that row.
            do {
                _ = try store.draftArtifacts.auditEventPreview(intentID: intent.id)
            } catch {
                try requireRecovery(intent.id)
                summary.recoveryRequiredCount += 1
                continue
            }
            let publicURL = storage.exportsDirectory(forMatterID: intent.matterID)
                .appendingPathComponent(intent.fileName, isDirectory: false)
            guard Self.isSafeManagedURL(
                publicURL,
                storage: storage,
                matterID: intent.matterID,
                fileName: intent.fileName
            ) else {
                try requireRecovery(intent.id)
                summary.recoveryRequiredCount += 1
                continue
            }

            do {
                let removed = try removeOwnedTemporaryFiles(for: intent, publicURL: publicURL)
                summary.removedTemporaryFileCount += removed
            } catch {
                try requireRecovery(intent.id)
                summary.recoveryRequiredCount += 1
                continue
            }

            do {
                switch try reconcileRollbackQuarantine(for: intent, publicURL: publicURL) {
                case .none:
                    break
                case .removedOwned:
                    try store.draftArtifacts.abortIntent(id: intent.id)
                    summary.removedRollbackQuarantineCount += 1
                    summary.abortedCount += 1
                    continue
                case .recoveryRequired:
                    try requireRecovery(intent.id)
                    summary.recoveryRequiredCount += 1
                    continue
                }
            } catch {
                try requireRecovery(intent.id)
                summary.recoveryRequiredCount += 1
                continue
            }

            switch Self.regularFileState(at: publicURL) {
            case .missing:
                try store.draftArtifacts.abortIntent(id: intent.id)
                summary.abortedCount += 1
            case .unsafeOrUnreadable:
                try requireRecovery(intent.id)
                summary.recoveryRequiredCount += 1
            case .regular:
                do {
                    let beforeValidation = try Data(contentsOf: publicURL, options: .mappedIfSafe)
                    guard beforeValidation.count == intent.outputByteSize,
                          DocumentStorage.sha256Hex(of: beforeValidation) == intent.outputSHA256 else {
                        throw ReconciliationError.artifactMismatch
                    }
                    try DocumentExportValidator.validate(
                        publicURL,
                        as: try Self.exportFormat(intent.format)
                    )
                    // Bind finalization to the bytes observed after format
                    // validation as well; replacement during inspection fails.
                    let installed = try Data(contentsOf: publicURL, options: .mappedIfSafe)
                    guard installed == beforeValidation else {
                        throw ReconciliationError.artifactChangedDuringInspection
                    }
                    try store.draftArtifacts.finalizeIntent(
                        id: intent.id,
                        installedOutput: installed
                    )
                    summary.finalizedCount += 1
                } catch {
                    try requireRecovery(intent.id)
                    summary.recoveryRequiredCount += 1
                }
            }
        }
        return summary
    }

    private func requireRecovery(_ id: String) throws {
        try store.draftArtifacts.markRecoveryRequired(id: id)
    }

    private func removeOwnedTemporaryFiles(
        for intent: DraftArtifactIntentRecord,
        publicURL: URL
    ) throws -> Int {
        let directory = publicURL.deletingLastPathComponent()
        let prefix = ".\(intent.fileName).supra-tmp-"
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: []
            )
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return 0
        }
        var removed = 0
        for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
            let suffix = String(entry.lastPathComponent.dropFirst(prefix.count))
            guard let identifier = UUID(uuidString: suffix),
                  identifier.uuidString.caseInsensitiveCompare(suffix) == .orderedSame else {
                continue
            }
            let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ReconciliationError.unsafeOwnedTemporary
            }
            try fileManager.removeItem(at: entry)
            removed += 1
        }
        if removed > 0 {
            try fileWriter.synchronizeParentDirectory(of: publicURL)
        }
        return removed
    }

    private enum RollbackReconciliation {
        case none
        case removedOwned
        case recoveryRequired
    }

    private func reconcileRollbackQuarantine(
        for intent: DraftArtifactIntentRecord,
        publicURL: URL
    ) throws -> RollbackReconciliation {
        let directory = publicURL.deletingLastPathComponent()
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: []
            )
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .none
        }
        let candidates = entries.filter {
            Self.isExactRollbackQuarantineName(
                $0.lastPathComponent,
                fileName: intent.fileName
            )
        }
        guard !candidates.isEmpty else { return .none }
        guard candidates.count == 1,
              Self.regularFileState(at: publicURL) == .missing else {
            return .recoveryRequired
        }
        let candidate = candidates[0]
        let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            return .recoveryRequired
        }
        let beforeValidation = try Data(contentsOf: candidate, options: .mappedIfSafe)
        guard beforeValidation.count == intent.outputByteSize,
              DocumentStorage.sha256Hex(of: beforeValidation) == intent.outputSHA256 else {
            return .recoveryRequired
        }
        do {
            try DocumentExportValidator.validate(
                candidate,
                as: try Self.exportFormat(intent.format)
            )
        } catch {
            return .recoveryRequired
        }
        let afterValidation = try Data(contentsOf: candidate, options: .mappedIfSafe)
        guard afterValidation == beforeValidation else { return .recoveryRequired }
        try fileManager.removeItem(at: candidate)
        try fileWriter.synchronizeParentDirectory(of: publicURL)
        return .removedOwned
    }

    private static func isExactRollbackQuarantineName(
        _ candidate: String,
        fileName: String
    ) -> Bool {
        let prefix = ".supra-draft-rollback-"
        guard candidate.hasPrefix(prefix) else { return false }
        let remainder = String(candidate.dropFirst(prefix.count))
        guard remainder.count > 37 else { return false }
        let identifierText = String(remainder.prefix(36))
        let separatorIndex = remainder.index(remainder.startIndex, offsetBy: 36)
        guard remainder[separatorIndex] == "-",
              String(remainder.dropFirst(37)) == fileName,
              let identifier = UUID(uuidString: identifierText),
              identifier.uuidString.caseInsensitiveCompare(identifierText) == .orderedSame else {
            return false
        }
        return true
    }

    private enum RegularFileState: Equatable {
        case missing
        case regular
        case unsafeOrUnreadable
    }

    private static func regularFileState(at url: URL) -> RegularFileState {
        var information = stat()
        let result = url.path.withCString { lstat($0, &information) }
        guard result == 0 else {
            return errno == ENOENT ? .missing : .unsafeOrUnreadable
        }
        return information.st_mode & S_IFMT == S_IFREG ? .regular : .unsafeOrUnreadable
    }

    private static func exportFormat(_ rawValue: String) throws -> DocumentExportFormat {
        switch DraftArtifactIntentFormat(rawValue: rawValue) {
        case .docx:
            return .docx
        case .markdown:
            return .markdown
        case nil:
            throw ReconciliationError.invalidFormat
        }
    }

    private static func isSafeManagedURL(
        _ url: URL,
        storage: DocumentStorage,
        matterID: String,
        fileName: String
    ) -> Bool {
        guard !matterID.isEmpty,
              !matterID.contains("/"),
              !matterID.contains("\\"),
              !fileName.isEmpty,
              fileName == URL(fileURLWithPath: fileName).lastPathComponent,
              !fileName.contains("/"),
              !fileName.contains("\\") else {
            return false
        }
        let expected = storage.exportsDirectory(forMatterID: matterID)
            .appendingPathComponent(fileName, isDirectory: false)
            .standardizedFileURL
        guard url.standardizedFileURL == expected else { return false }
        return safeManagedParents(
            root: storage.root.standardizedFileURL,
            parent: expected.deletingLastPathComponent()
        )
    }

    private static func safeManagedParents(root: URL, parent: URL) -> Bool {
        let rootPath = root.path
        let parentPath = parent.path
        guard parentPath == rootPath || parentPath.hasPrefix(rootPath + "/") else { return false }
        let relative = String(parentPath.dropFirst(rootPath.count))
            .split(separator: "/")
            .map(String.init)
        var candidate = root
        for component in [""] + relative {
            if !component.isEmpty {
                candidate.appendPathComponent(component, isDirectory: true)
            }
            var information = stat()
            let result = candidate.path.withCString { lstat($0, &information) }
            if result != 0 {
                if errno == ENOENT { continue }
                return false
            }
            guard information.st_mode & S_IFMT == S_IFDIR else { return false }
        }
        return true
    }

    private enum ReconciliationError: Error {
        case artifactMismatch
        case artifactChangedDuringInspection
        case invalidFormat
        case unsafeOwnedTemporary
    }
}
