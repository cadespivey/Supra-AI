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

    public func download(for request: URLRequest, policy: RedirectPolicy) async throws -> PolicyHTTPDownload {
        let delegate = RedirectTaskDelegate(initialRequest: request, policy: policy)
        do {
            let (temporaryURL, response) = try await session.download(for: request, delegate: delegate)
            try delegate.throwIfRejected()
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

private final class RedirectTaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.supraai.networking", category: "redirect-policy")

    private let policy: RedirectPolicy
    private let lock = NSLock()
    private var currentRequest: URLRequest
    private var storedRedirects: [RedirectAuditHop] = []
    private var rejection: RedirectRejection?

    init(initialRequest: URLRequest, policy: RedirectPolicy) {
        self.currentRequest = initialRequest
        self.policy = policy
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
