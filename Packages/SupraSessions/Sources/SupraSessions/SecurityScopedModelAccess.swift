import Foundation
import SupraRuntimeInterface

/// Holds the app's own security-scoped access to a model directory long enough
/// to mint a plain, transferable bookmark to hand to the runtime service.
///
/// The app persists a `.withSecurityScope` bookmark per model (so it can reopen
/// the folder across launches). That bookmark is cryptographically bound to the
/// app's code-signing identity, so it cannot be resolved by the differently
/// signed runtime service. Instead the app resolves it, starts accessing it, and
/// mints a PLAIN bookmark whose embedded sandbox extension transfers read access
/// to the (still sandboxed) service — see Docs/Architecture/RuntimeFileAccess.md.
struct SecurityScopedModelAccess {
    private let accessedURL: URL?
    private let shouldStopAccessing: Bool

    /// `true` when the persisted bookmark resolved as stale (folder moved,
    /// renamed, or replaced). The host must fail closed and require re-selection.
    let isStale: Bool

    /// Whether this host can mint a bookmark for the directory. In the sandboxed
    /// app this means scoped access is active; unsandboxed test hosts use a plain
    /// bookmark and rely on the service to reject missing transferred authority.
    var hasAccess: Bool { accessedURL != nil }

    init(bookmarkData: Data?) {
        guard let bookmarkData else {
            accessedURL = nil
            shouldStopAccessing = false
            isStale = false
            return
        }
        var stale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ),
            url.startAccessingSecurityScopedResource()
        else {
            accessedURL = nil
            shouldStopAccessing = false
            isStale = stale
            return
        }
        accessedURL = url
        shouldStopAccessing = true
        isStale = stale
    }

    /// Opens an app-owned model directory through the same scoped-to-plain
    /// transfer used for user-selected folders. A plain bookmark minted without
    /// an actively held scope does not carry authority to the XPC sandbox.
    init(url: URL) {
        guard let bookmarkData = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            // ScopedBookmarksAgent is unavailable to unsandboxed SwiftPM and
            // command-line hosts. Preserve a plain-bookmark test path; a real
            // sandboxed XPC service still rejects it unless authority transfers.
            accessedURL = url
            shouldStopAccessing = false
            isStale = false
            return
        }

        var stale = false
        let resolvedURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        if let resolvedURL, resolvedURL.startAccessingSecurityScopedResource() {
            accessedURL = resolvedURL
            shouldStopAccessing = true
        } else {
            // Unsandboxed package/command-line hosts legitimately return false
            // from startAccessing. They can still mint a plain bookmark; the XPC
            // service remains the fail-closed authority and will reject it if it
            // carries no usable extension in a sandboxed production launch.
            accessedURL = url
            shouldStopAccessing = false
        }
        isStale = stale
    }

    /// Mints a plain bookmark and pins the exact directory object it authorized.
    /// Identity is sampled on both sides of bookmark creation; replacement during
    /// that window fails closed instead of pairing an old bookmark with a new inode.
    func makeTransferableAuthorization() -> (
        bookmark: Data,
        directoryIdentity: ModelDirectoryIdentity
    )? {
        guard !isStale,
              let accessedURL,
              let identityBefore = ModelDirectoryIdentity(url: accessedURL),
              let bookmark = try? accessedURL.bookmarkData(
                  options: [],
                  includingResourceValuesForKeys: nil,
                  relativeTo: nil
              ),
              let identityAfter = ModelDirectoryIdentity(url: accessedURL),
              identityAfter == identityBefore else {
            return nil
        }
        return (bookmark, identityBefore)
    }

    func release() {
        if shouldStopAccessing {
            accessedURL?.stopAccessingSecurityScopedResource()
        }
    }
}
