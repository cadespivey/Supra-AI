import Foundation

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

    /// `true` when the persisted bookmark resolved as stale (folder moved/renamed).
    /// The host should re-mint and re-persist a fresh `.withSecurityScope` bookmark.
    let isStale: Bool

    /// Whether the app currently holds security-scoped access to the directory.
    var hasAccess: Bool { accessedURL != nil }

    init(bookmarkData: Data?) {
        guard let bookmarkData else {
            accessedURL = nil
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
            isStale = stale
            return
        }
        accessedURL = url
        isStale = stale
    }

    /// A plain bookmark for the model directory, valid only while this access is
    /// held and both processes are running. Returns `nil` when no access is held.
    func makeTransferableBookmark() -> Data? {
        guard let accessedURL else { return nil }
        return try? accessedURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// A fresh `.withSecurityScope` bookmark for re-persisting when the stored one
    /// went stale. Returns `nil` when no access is held.
    func makePersistentBookmark() -> Data? {
        guard let accessedURL else { return nil }
        return try? accessedURL.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func release() {
        accessedURL?.stopAccessingSecurityScopedResource()
    }
}
