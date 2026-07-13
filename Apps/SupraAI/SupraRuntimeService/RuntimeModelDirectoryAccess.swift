import Foundation
import SupraRuntimeInterface

enum RuntimeModelDirectoryAccessError: LocalizedError {
    case bookmarkRequired
    case bookmarkInvalid(String)
    case bookmarkStale
    case bookmarkTargetMismatch
    case managedRootEscape
    case modelDirectoryIdentityRequired
    case modelDirectoryIdentityMismatch
    case modelDirectoryMissing(String)

    var errorDescription: String? {
        switch self {
        case .bookmarkRequired:
            "A transferable model-folder bookmark is required."
        case let .bookmarkInvalid(detail):
            "The model-folder bookmark is invalid: \(detail)"
        case .bookmarkStale:
            "The model-folder bookmark is stale. Re-select or re-download the model."
        case .bookmarkTargetMismatch:
            "The bookmarked model folder does not match the requested path."
        case .managedRootEscape:
            "The managed model path escapes its authorized root."
        case .modelDirectoryIdentityRequired:
            "A managed model-folder filesystem identity is required."
        case .modelDirectoryIdentityMismatch:
            "The model folder was replaced after it was authorized."
        case let .modelDirectoryMissing(path):
            "The model directory does not exist: \(path)"
        }
    }
}

/// Owns a transferable bookmark's security scope for one complete model load.
/// Raw paths never grant authority: the bookmark target is canonicalized, matched
/// to the request, and (for managed downloads) constrained to its canonical root.
final class RuntimeModelDirectoryAccess: @unchecked Sendable {
    let url: URL

    private let scopedURL: URL
    private let authorizedIdentity: ModelDirectoryIdentity
    private let closeLock = NSLock()
    private var isClosed = false

    init(
        bookmark: Data?,
        requestedPath: String,
        managedRootPath: String?,
        expectedIdentity: ModelDirectoryIdentity?
    ) throws {
        guard let bookmark, !bookmark.isEmpty else {
            throw RuntimeModelDirectoryAccessError.bookmarkRequired
        }

        var isStale = false
        let resolvedURL: URL
        do {
            resolvedURL = try URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw RuntimeModelDirectoryAccessError.bookmarkInvalid(error.localizedDescription)
        }
        guard resolvedURL.startAccessingSecurityScopedResource() else {
            throw RuntimeModelDirectoryAccessError.bookmarkInvalid(
                "the sandbox extension could not be activated"
            )
        }
        var retainScope = false
        defer {
            if !retainScope {
                resolvedURL.stopAccessingSecurityScopedResource()
            }
        }

        let canonicalResolved = Self.canonicalDirectoryURL(resolvedURL)
        let canonicalRequested = Self.canonicalDirectoryURL(
            URL(fileURLWithPath: requestedPath, isDirectory: true)
        )
        guard canonicalResolved.path == canonicalRequested.path else {
            throw isStale
                ? RuntimeModelDirectoryAccessError.bookmarkStale
                : RuntimeModelDirectoryAccessError.bookmarkTargetMismatch
        }

        if let managedRootPath {
            let root = Self.canonicalDirectoryURL(
                URL(fileURLWithPath: managedRootPath, isDirectory: true)
            ).path
            let candidate = canonicalResolved.path
            guard candidate != root, candidate.hasPrefix(root + "/") else {
                throw RuntimeModelDirectoryAccessError.managedRootEscape
            }
            guard expectedIdentity != nil else {
                throw RuntimeModelDirectoryAccessError.modelDirectoryIdentityRequired
            }
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: canonicalResolved.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            if isStale {
                throw RuntimeModelDirectoryAccessError.bookmarkStale
            }
            throw RuntimeModelDirectoryAccessError.modelDirectoryMissing(canonicalResolved.path)
        }

        guard let resolvedIdentity = ModelDirectoryIdentity(url: canonicalResolved) else {
            throw RuntimeModelDirectoryAccessError.modelDirectoryMissing(canonicalResolved.path)
        }
        if let expectedIdentity {
            guard resolvedIdentity == expectedIdentity else {
                throw RuntimeModelDirectoryAccessError.modelDirectoryIdentityMismatch
            }
        } else if isStale {
            // Cross-signer bookmark resolution reports valid authorities as stale.
            // Only a matching app-pinned filesystem identity can make that
            // advisory stale result acceptable.
            throw RuntimeModelDirectoryAccessError.bookmarkStale
        }

        self.url = canonicalResolved
        self.scopedURL = resolvedURL
        self.authorizedIdentity = resolvedIdentity
        retainScope = true
    }

    deinit {
        close()
    }

    func close() {
        closeLock.lock()
        guard !isClosed else {
            closeLock.unlock()
            return
        }
        isClosed = true
        closeLock.unlock()
        scopedURL.stopAccessingSecurityScopedResource()
    }

    /// Rechecks the directory entry immediately before a loaded container is
    /// committed. This closes the delete/recreate window across an async load;
    /// it is intentionally an identity check, not a content hash.
    func validateIdentity() throws {
        guard let currentIdentity = ModelDirectoryIdentity(url: url),
              currentIdentity == authorizedIdentity else {
            throw RuntimeModelDirectoryAccessError.modelDirectoryIdentityMismatch
        }
    }

    private static func canonicalDirectoryURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }
}
