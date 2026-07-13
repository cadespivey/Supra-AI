import Foundation

/// Exact-origin policy applied to every redirect proposed by `URLSession`.
///
/// Public policies are HTTPS-only. `NetworkPolicyServiceProtocol` has an internal trusted
/// constructor for an initial URL it has already validated; this keeps synthetic loopback
/// integration tests possible without creating a production HTTP escape hatch.
public struct RedirectPolicy: Sendable {
    public static let maximumPermittedHops = 5

    public struct AllowedOrigin: Hashable, Sendable {
        fileprivate let origin: Origin
        public let service: String
        public let credentialOwner: String?

        public init(url: URL, service: String, credentialOwner: String?) throws {
            self.origin = try Origin(url: url, requiresHTTPS: true)
            self.service = service
            self.credentialOwner = credentialOwner
        }

        fileprivate init(
            trustedURL url: URL,
            service: String,
            credentialOwner: String?,
            requiresHTTPS: Bool
        ) throws {
            self.origin = try Origin(url: url, requiresHTTPS: requiresHTTPS)
            self.service = service
            self.credentialOwner = credentialOwner
        }
    }

    public struct CrossOriginRule: Hashable, Sendable {
        fileprivate let source: Origin
        fileprivate let destination: Origin
        public let service: String

        public init(
            from source: URL,
            to destination: URL,
            service: String
        ) throws {
            self.source = try Origin(url: source, requiresHTTPS: true)
            self.destination = try Origin(url: destination, requiresHTTPS: true)
            self.service = service
        }

        fileprivate init(
            trustedSource source: URL,
            destination: URL,
            service: String,
            requiresHTTPS: Bool
        ) throws {
            self.source = try Origin(url: source, requiresHTTPS: requiresHTTPS)
            self.destination = try Origin(url: destination, requiresHTTPS: requiresHTTPS)
            self.service = service
        }
    }

    public let initialService: String
    public let maximumHops: Int

    private let initialOrigin: Origin
    private let origins: [Origin: AllowedOrigin]
    private let crossOriginRules: Set<CrossOriginRule>
    private let requiresHTTPS: Bool

    public init(
        initialURL: URL,
        service: String,
        credentialOwner: String? = nil,
        additionalOrigins: [AllowedOrigin] = [],
        crossOriginRules: [CrossOriginRule] = [],
        maximumHops: Int = 5
    ) throws {
        try self.init(
            trustedInitialURL: initialURL,
            service: service,
            credentialOwner: credentialOwner,
            additionalOrigins: additionalOrigins,
            crossOriginRules: crossOriginRules,
            maximumHops: maximumHops,
            requiresHTTPS: true
        )
    }

    init(
        trustedInitialURL initialURL: URL,
        service: String,
        credentialOwner: String? = nil,
        additionalOrigins: [AllowedOrigin] = [],
        crossOriginRules: [CrossOriginRule] = [],
        maximumHops: Int = 5,
        requiresHTTPS: Bool = false
    ) throws {
        guard (0...Self.maximumPermittedHops).contains(maximumHops),
              !service.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NetworkPolicyError.invalidURL
        }
        let initial = try AllowedOrigin(
            trustedURL: initialURL,
            service: service,
            credentialOwner: credentialOwner,
            requiresHTTPS: requiresHTTPS
        )
        var configuredOrigins: [Origin: AllowedOrigin] = [:]
        for origin in additionalOrigins {
            configuredOrigins[origin.origin] = origin
        }
        configuredOrigins[initial.origin] = initial

        self.initialService = service
        self.maximumHops = maximumHops
        self.initialOrigin = initial.origin
        self.origins = configuredOrigins
        self.crossOriginRules = Set(crossOriginRules)
        self.requiresHTTPS = requiresHTTPS
    }

    /// Returns the only redirect request the caller may follow. Credential-bearing headers
    /// are rebuilt from the current request and are retained only for an explicitly scoped
    /// same-owner route.
    public func requestForRedirect(
        from currentRequest: URLRequest,
        response: HTTPURLResponse,
        proposedRequest: URLRequest,
        hopCount: Int
    ) throws -> URLRequest {
        let sourceURL = currentRequest.url ?? response.url
        let destinationURL = proposedRequest.url
        guard let sourceURL, let destinationURL else {
            throw rejection(
                reason: .invalidDestination,
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                statusCode: response.statusCode,
                hopCount: hopCount
            )
        }
        guard hopCount <= maximumHops else {
            throw rejection(
                reason: .hopLimitExceeded(maximum: maximumHops),
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                statusCode: response.statusCode,
                hopCount: hopCount
            )
        }
        guard Self.redirectStatusCodes.contains(response.statusCode) else {
            throw rejection(
                reason: .unexpectedStatus(response.statusCode),
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                statusCode: response.statusCode,
                hopCount: hopCount
            )
        }

        let sourceOrigin: Origin
        let destinationOrigin: Origin
        do {
            sourceOrigin = try Origin(url: sourceURL, requiresHTTPS: requiresHTTPS)
            destinationOrigin = try Origin(url: destinationURL, requiresHTTPS: requiresHTTPS)
        } catch NetworkPolicyError.insecureScheme(let scheme) {
            throw rejection(
                reason: .insecureScheme(scheme),
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                statusCode: response.statusCode,
                hopCount: hopCount
            )
        } catch NetworkPolicyError.embeddedCredentials {
            throw rejection(
                reason: .embeddedCredentials,
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                statusCode: response.statusCode,
                hopCount: hopCount
            )
        } catch {
            throw rejection(
                reason: .invalidDestination,
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                statusCode: response.statusCode,
                hopCount: hopCount
            )
        }

        guard let sourceConfiguration = origins[sourceOrigin],
              let destinationConfiguration = origins[destinationOrigin] else {
            throw rejection(
                reason: .originNotAllowed,
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                statusCode: response.statusCode,
                hopCount: hopCount
            )
        }

        let preservesCredentials: Bool
        if sourceOrigin == destinationOrigin {
            preservesCredentials = Self.hasSameCredentialOwner(
                sourceConfiguration,
                destinationConfiguration
            )
        } else {
            guard let route = crossOriginRules.first(where: {
                $0.source == sourceOrigin && $0.destination == destinationOrigin
            }) else {
                throw rejection(
                    reason: .crossOriginRouteNotAllowed,
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    statusCode: response.statusCode,
                    hopCount: hopCount
                )
            }
            guard route.service == destinationConfiguration.service else {
                throw rejection(
                    reason: .crossOriginRouteNotAllowed,
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    statusCode: response.statusCode,
                    hopCount: hopCount
                )
            }
            preservesCredentials = false
        }

        var rebuilt = proposedRequest
        Self.removeCredentialHeaders(from: &rebuilt)
        if preservesCredentials {
            for (name, value) in currentRequest.allHTTPHeaderFields ?? [:]
            where Self.isCredentialHeader(name) {
                rebuilt.setValue(value, forHTTPHeaderField: name)
            }
        }
        return rebuilt
    }

    /// Hugging Face downloads are token-free. The exact host inventory is deliberately
    /// explicit. A live smoke on 2026-07-13 observed the Hub redirecting a small public LFS
    /// object to `us.aws.cdn.hf.co`; every unobserved origin remains denied and must be added
    /// only with a new captured redirect and regression test.
    public static func huggingFace(initialURL: URL, maximumHops: Int = 5) throws -> RedirectPolicy {
        let hub = URL(string: "https://huggingface.co")!
        guard try Origin(url: initialURL, requiresHTTPS: true) == Origin(url: hub, requiresHTTPS: true) else {
            throw NetworkPolicyError.hostNotAllowed(initialURL.host?.lowercased() ?? "")
        }
        let cdnURLs = [
            "https://us.aws.cdn.hf.co"
        ].compactMap(URL.init(string:))
        let origins = try cdnURLs.map {
            try AllowedOrigin(url: $0, service: "hugging-face-download", credentialOwner: nil)
        }
        let rules = try cdnURLs.map {
            try CrossOriginRule(
                from: hub,
                to: $0,
                service: "hugging-face-download"
            )
        }
        return try RedirectPolicy(
            initialURL: initialURL,
            service: "hugging-face-hub",
            credentialOwner: nil,
            additionalOrigins: origins,
            crossOriginRules: rules,
            maximumHops: maximumHops
        )
    }

    static let credentialHeaderNames: Set<String> = [
        "authorization",
        "proxy-authorization",
        "cookie",
        "cookie2",
        "x-api-key",
        "api-key",
        "apikey",
        "x-auth-token",
        "x-access-token",
        "ocp-apim-subscription-key"
    ]

    static func containsCredentialHeaders(_ request: URLRequest) -> Bool {
        (request.allHTTPHeaderFields ?? [:]).keys.contains(where: isCredentialHeader)
    }

    static func redactedURL(_ url: URL?) -> URL? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static let redirectStatusCodes: Set<Int> = [301, 302, 303, 307, 308]

    private static func hasSameCredentialOwner(_ source: AllowedOrigin, _ destination: AllowedOrigin) -> Bool {
        guard let owner = source.credentialOwner else { return false }
        return owner == destination.credentialOwner
    }

    private static func isCredentialHeader(_ name: String) -> Bool {
        credentialHeaderNames.contains(name.lowercased())
    }

    private static func removeCredentialHeaders(from request: inout URLRequest) {
        for name in Array(request.allHTTPHeaderFields?.keys ?? Dictionary<String, String>().keys)
        where isCredentialHeader(name) {
            request.setValue(nil, forHTTPHeaderField: name)
        }
        // Also clear canonical spellings in case Foundation's header dictionary omitted one.
        for name in credentialHeaderNames {
            request.setValue(nil, forHTTPHeaderField: name)
        }
    }

    private func rejection(
        reason: RedirectRejection.Reason,
        sourceURL: URL?,
        destinationURL: URL?,
        statusCode: Int,
        hopCount: Int
    ) -> NetworkPolicyError {
        .redirectRejected(
            RedirectRejection(
                reason: reason,
                sourceURL: Self.redactedURL(sourceURL),
                destinationURL: Self.redactedURL(destinationURL),
                statusCode: statusCode,
                hopCount: hopCount
            )
        )
    }
}

public struct RedirectAuditHop: Equatable, Sendable {
    public let sourceURL: URL
    public let destinationURL: URL
    public let statusCode: Int
    public let hopCount: Int
    public let method: String
}

public struct RedirectRejection: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case invalidDestination
        case insecureScheme(String?)
        case embeddedCredentials
        case originNotAllowed
        case crossOriginRouteNotAllowed
        case unexpectedStatus(Int)
        case hopLimitExceeded(maximum: Int)
    }

    public let reason: Reason
    public let sourceURL: URL?
    public let destinationURL: URL?
    public let statusCode: Int
    public let hopCount: Int
    public let allowedHops: [RedirectAuditHop]

    public init(
        reason: Reason,
        sourceURL: URL?,
        destinationURL: URL?,
        statusCode: Int,
        hopCount: Int,
        allowedHops: [RedirectAuditHop] = []
    ) {
        self.reason = reason
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.statusCode = statusCode
        self.hopCount = hopCount
        self.allowedHops = allowedHops
    }
}

private struct Origin: Hashable, Sendable {
    let scheme: String
    let host: String
    let port: Int?

    init(url: URL, requiresHTTPS: Bool) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw NetworkPolicyError.invalidURL
        }
        guard let scheme = components.scheme?.lowercased(),
              !scheme.isEmpty,
              !requiresHTTPS || scheme == "https" else {
            throw NetworkPolicyError.insecureScheme(components.scheme)
        }
        guard let host = components.host?.lowercased(), !host.isEmpty else {
            throw NetworkPolicyError.missingHost
        }
        guard components.user == nil, components.password == nil else {
            throw NetworkPolicyError.embeddedCredentials
        }
        self.scheme = scheme
        self.host = host
        self.port = components.port
    }
}
