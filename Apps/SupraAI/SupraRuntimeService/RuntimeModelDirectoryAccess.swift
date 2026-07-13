import Foundation

enum RuntimeModelDirectoryAccessError: LocalizedError {
    case bookmarkRequired
    case bookmarkInvalid(String)
    case bookmarkStale
    case bookmarkTargetMismatch
    case managedRootEscape
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
    private let closeLock = NSLock()
    private var isClosed = false

    init(bookmark: Data?, requestedPath: String, managedRootPath: String?) throws {
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

        self.url = canonicalResolved
        self.scopedURL = resolvedURL
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

    private static func canonicalDirectoryURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }
}
