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
    /// Deterministic process-boundary seam used to prove pathname replacement
    /// after the initial no-follow regular-file check fails closed.
    var publicArtifactInspectionCheckpoint: (URL) throws -> Void = { _ in }
    /// Deterministic final-removal seam. Cleanup must recheck the inspected
    /// inode after this checkpoint and use a nonrecursive unlink.
    var cleanupPreUnlinkCheckpoint: (URL) throws -> Void = { _ in }
    /// Deterministic format-validation seam used to prove a validator result
    /// cannot be detached from the bytes that reconciliation later finalizes or
    /// removes. Production uses the complete format-aware validator.
    var artifactFormatValidator: (Data, DocumentExportFormat) throws -> Void = {
        try DocumentExportValidator.validate($0, as: $1)
    }

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
                case .removedOwnedRecoveryRequired:
                    try requireRecovery(intent.id)
                    summary.removedRollbackQuarantineCount += 1
                    summary.recoveryRequiredCount += 1
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
                    guard let inspectedIdentity = try fileWriter.installedFileIdentity(
                        at: publicURL,
                        containedIn: storage.root
                    ) else {
                        throw ReconciliationError.artifactChangedDuringInspection
                    }
                    try publicArtifactInspectionCheckpoint(publicURL)
                    let installed = try fileWriter.durablyValidatedInstalledFileData(
                        matching: inspectedIdentity,
                        at: publicURL,
                        containedIn: storage.root,
                        expectedByteCount: intent.outputByteSize
                    ) { candidate in
                        guard candidate.count == intent.outputByteSize,
                              DocumentStorage.sha256Hex(of: candidate) == intent.outputSHA256 else {
                            throw ReconciliationError.artifactMismatch
                        }
                        try artifactFormatValidator(
                            candidate,
                            try Self.exportFormat(intent.format)
                        )
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
            guard Self.regularFileState(at: entry) == .regular,
                  let inspectedIdentity = try fileWriter.installedFileIdentity(
                      at: entry,
                      containedIn: storage.root
                  ) else {
                throw ReconciliationError.unsafeOwnedTemporary
            }
            try cleanupPreUnlinkCheckpoint(entry)
            guard Self.regularFileState(at: entry) == .regular,
                  try fileWriter.unlinkFile(
                      matching: inspectedIdentity,
                      at: entry,
                      containedIn: storage.root,
                      maximumByteCount: intent.outputByteSize,
                      contentValidator: { _ in }
                  ) else {
                throw ReconciliationError.unsafeOwnedTemporary
            }
            removed += 1
        }
        return removed
    }

    private enum RollbackReconciliation {
        case none
        case removedOwned
        case removedOwnedRecoveryRequired
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
        guard Self.regularFileState(at: candidate) == .regular,
              let inspectedIdentity = try fileWriter.installedFileIdentity(
                  at: candidate,
                  containedIn: storage.root
              ) else {
            return .recoveryRequired
        }
        try cleanupPreUnlinkCheckpoint(candidate)
        guard Self.regularFileState(at: publicURL) == .missing else {
            return .recoveryRequired
        }
        let removed = try fileWriter.unlinkFile(
            matching: inspectedIdentity,
            at: candidate,
            containedIn: storage.root,
            expectedByteCount: intent.outputByteSize,
            contentValidator: { candidateData in
                guard candidateData.count == intent.outputByteSize,
                      DocumentStorage.sha256Hex(of: candidateData) == intent.outputSHA256 else {
                    throw ReconciliationError.artifactMismatch
                }
                try artifactFormatValidator(
                    candidateData,
                    try Self.exportFormat(intent.format)
                )
            }
        )
        guard removed else { return .recoveryRequired }
        guard Self.regularFileState(at: publicURL) == .missing else {
            // The writer has already unlinked and synchronized the exact
            // rollback source. A public survivor still requires recovery, but
            // the durable quarantine removal remains an accurate summary fact.
            return .removedOwnedRecoveryRequired
        }
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
