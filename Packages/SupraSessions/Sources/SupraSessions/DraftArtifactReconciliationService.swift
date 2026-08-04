import Darwin
import Foundation
import SupraDocuments
import SupraStore

public struct DraftArtifactReconciliationSummary: Sendable, Equatable {
    public var finalizedCount: Int
    public var abortedCount: Int
    public var recoveryRequiredCount: Int
    public var removedTemporaryFileCount: Int

    public init(
        finalizedCount: Int = 0,
        abortedCount: Int = 0,
        recoveryRequiredCount: Int = 0,
        removedTemporaryFileCount: Int = 0
    ) {
        self.finalizedCount = finalizedCount
        self.abortedCount = abortedCount
        self.recoveryRequiredCount = recoveryRequiredCount
        self.removedTemporaryFileCount = removedTemporaryFileCount
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
            let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try fileManager.removeItem(at: entry)
            removed += 1
        }
        if removed > 0 {
            try fileWriter.synchronizeParentDirectory(of: publicURL)
        }
        return removed
    }

    private enum RegularFileState {
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
        return url.standardizedFileURL == expected
    }

    private enum ReconciliationError: Error {
        case artifactMismatch
        case artifactChangedDuringInspection
        case invalidFormat
    }
}
