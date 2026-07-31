import Foundation
import OSLog

public struct PolicyHTTPResponse: Sendable {
    public let data: Data
    public let response: URLResponse
    public let redirects: [RedirectAuditHop]
}

public struct PolicyHTTPDownload: Sendable {
    public let temporaryURL: URL
    public let response: URLResponse
    public let redirects: [RedirectAuditHop]
}

/// A per-task delegate is mandatory for every request. `URLSession`'s default redirect
/// behavior is never reachable through this abstraction.
public final class PolicyEnforcingURLSessionTransport: @unchecked Sendable {
    private let session: URLSession

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.session = URLSession(configuration: configuration)
    }

    /// Retains a caller's test protocol/configuration while replacing redirect behavior with
    /// the policy task delegate. This does not inherit the session's global redirect delegate.
    public init(session: URLSession) {
        self.session = session
    }

    public func data(for request: URLRequest, policy: RedirectPolicy) async throws -> PolicyHTTPResponse {
        let delegate = RedirectTaskDelegate(initialRequest: request, policy: policy)
        do {
            let (data, response) = try await session.data(for: request, delegate: delegate)
            try delegate.throwIfRejected()
            return PolicyHTTPResponse(data: data, response: response, redirects: delegate.redirects)
        } catch {
            try delegate.throwIfRejected()
            throw error
        }
    }

    /// `onBytes` receives the cumulative bytes written for this transfer,
    /// throttled to ~2 MB increments (URLSession's `didWriteData` fires per
    /// buffer — far too often to forward for multi-gigabyte model weights).
    /// Called on URLSession's delegate queue; callers hop executors themselves.
    ///
    /// Deliberately built on a classic `downloadTask(with:)` + `task.delegate`
    /// rather than the async `download(for:delegate:)` convenience: on macOS 27
    /// the convenience wrapper never delivers
    /// `URLSessionDownloadDelegate.didWriteData` to the per-task delegate
    /// (byte progress silently dies while the transfer proceeds) and traps in
    /// its own completion closure when the delegate rejects a redirect.
    /// `PolicyTransportDownloadTests` pins both behaviors.
    public func download(
        for request: URLRequest,
        policy: RedirectPolicy,
        onBytes: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> PolicyHTTPDownload {
        let delegate = RedirectTaskDelegate(initialRequest: request, policy: policy, onBytes: onBytes)
        let task = session.downloadTask(with: request)
        task.delegate = delegate
        do {
            let (temporaryURL, response) = try await delegate.completeDownload(driving: task)
            do {
                try delegate.throwIfRejected()
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw error
            }
            return PolicyHTTPDownload(
                temporaryURL: temporaryURL,
                response: response,
                redirects: delegate.redirects
            )
        } catch {
            try delegate.throwIfRejected()
            throw error
        }
    }
}

private final class RedirectTaskDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.supraai.networking", category: "redirect-policy")
    /// Forwarding threshold for byte-progress callbacks.
    private static let byteReportStride: Int64 = 2_000_000

    private let policy: RedirectPolicy
    private let onBytes: (@Sendable (Int64) -> Void)?
    private let lock = NSLock()
    private var currentRequest: URLRequest
    private var storedRedirects: [RedirectAuditHop] = []
    private var rejection: RedirectRejection?
    private var lastReportedBytes: Int64 = 0
    private var downloadContinuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var movedTemporaryURL: URL?
    private var fileMoveError: Error?

    init(
        initialRequest: URLRequest,
        policy: RedirectPolicy,
        onBytes: (@Sendable (Int64) -> Void)? = nil
    ) {
        self.currentRequest = initialRequest
        self.policy = policy
        self.onBytes = onBytes
    }

    /// Resumes `task.resume()` wrapped in a continuation so the transport can
    /// await a classic download task. Cancellation of the surrounding Swift
    /// task cancels the URL session task, which then completes with
    /// `URLError.cancelled` through `didCompleteWithError`.
    func completeDownload(driving task: URLSessionDownloadTask) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                downloadContinuation = continuation
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// The system deletes `location` the moment this method returns, so the
    /// file must move to a caller-owned path synchronously here.
    func urlSession(
        _: URLSession,
        downloadTask _: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let stable = FileManager.default.temporaryDirectory.appendingPathComponent(
            "policy-download-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        do {
            try FileManager.default.moveItem(at: location, to: stable)
            lock.lock()
            movedTemporaryURL = stable
            lock.unlock()
        } catch {
            lock.lock()
            fileMoveError = error
            lock.unlock()
        }
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = downloadContinuation
        downloadContinuation = nil
        let movedURL = movedTemporaryURL
        let moveError = fileMoveError
        lock.unlock()
        // Data-task flows (`data(for:)`) share this delegate but never set a
        // continuation; their completion is owned by the async convenience.
        guard let continuation else { return }
        if let error {
            if let movedURL { try? FileManager.default.removeItem(at: movedURL) }
            continuation.resume(throwing: error)
        } else if let moveError {
            continuation.resume(throwing: moveError)
        } else if let movedURL, let response = task.response {
            continuation.resume(returning: (movedURL, response))
        } else {
            // Completed with neither a file nor an error: the shape a rejected
            // redirect leaves behind (the 302 became the final response). The
            // transport's throwIfRejected() turns this into the policy error;
            // anything else is a genuinely malformed exchange.
            continuation.resume(throwing: URLError(.badServerResponse))
        }
    }

    func urlSession(
        _: URLSession,
        downloadTask _: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite _: Int64
    ) {
        guard let onBytes else { return }
        lock.lock()
        let shouldReport = totalBytesWritten - lastReportedBytes >= Self.byteReportStride
        if shouldReport { lastReportedBytes = totalBytesWritten }
        lock.unlock()
        if shouldReport { onBytes(totalBytesWritten) }
    }

    var redirects: [RedirectAuditHop] {
        lock.lock()
        defer { lock.unlock() }
        return storedRedirects
    }

    func throwIfRejected() throws {
        lock.lock()
        let stored = rejection
        lock.unlock()
        if let stored {
            throw NetworkPolicyError.redirectRejected(stored)
        }
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        lock.lock()
        let sourceRequest = currentRequest
        let hopCount = storedRedirects.count + 1
        lock.unlock()

        do {
            let approved = try policy.requestForRedirect(
                from: sourceRequest,
                response: response,
                proposedRequest: request,
                hopCount: hopCount
            )
            let sourceURL = RedirectPolicy.redactedURL(sourceRequest.url)
            let destinationURL = RedirectPolicy.redactedURL(approved.url)
            guard let sourceURL, let destinationURL else {
                lock.lock()
                rejection = RedirectRejection(
                    reason: .invalidDestination,
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    statusCode: response.statusCode,
                    hopCount: hopCount,
                    allowedHops: storedRedirects
                )
                lock.unlock()
                Self.logger.error("Blocked redirect hop \(hopCount, privacy: .public): invalid redacted destination")
                completionHandler(nil)
                return
            }
            let hop = RedirectAuditHop(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                statusCode: response.statusCode,
                hopCount: hopCount,
                method: approved.httpMethod ?? "GET"
            )
            lock.lock()
            storedRedirects.append(hop)
            currentRequest = approved
            lock.unlock()
            Self.logger.info(
                "Allowed redirect hop \(hopCount, privacy: .public): \(Self.endpoint(sourceURL), privacy: .public) -> \(Self.endpoint(destinationURL), privacy: .public)"
            )
            completionHandler(approved)
        } catch NetworkPolicyError.redirectRejected(let violation) {
            lock.lock()
            let enriched = RedirectRejection(
                reason: violation.reason,
                sourceURL: violation.sourceURL,
                destinationURL: violation.destinationURL,
                statusCode: violation.statusCode,
                hopCount: violation.hopCount,
                allowedHops: storedRedirects
            )
            rejection = enriched
            lock.unlock()
            Self.logger.error(
                "Blocked redirect hop \(hopCount, privacy: .public): \(Self.endpoint(enriched.destinationURL), privacy: .public); reason=\(String(describing: enriched.reason), privacy: .public)"
            )
            completionHandler(nil)
        } catch {
            lock.lock()
            rejection = RedirectRejection(
                reason: .invalidDestination,
                sourceURL: RedirectPolicy.redactedURL(sourceRequest.url),
                destinationURL: RedirectPolicy.redactedURL(request.url),
                statusCode: response.statusCode,
                hopCount: hopCount,
                allowedHops: storedRedirects
            )
            lock.unlock()
            Self.logger.error("Blocked redirect hop \(hopCount, privacy: .public): invalid destination")
            completionHandler(nil)
        }
    }

    private static func endpoint(_ url: URL?) -> String {
        guard let url else { return "invalid-url" }
        return url.absoluteString
    }
}
