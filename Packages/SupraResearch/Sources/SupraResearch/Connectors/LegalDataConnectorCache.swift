import Foundation

/// Response cache seam for the government-data connectors.
public protocol LegalDataConnectorCache: Sendable {
    func get(key: String, now: Date) async throws -> LegalDataCacheEntry?
    func put(_ entry: LegalDataCacheEntry, key: String) async throws
    func removeExpired(now: Date) async throws
}

/// File-backed JSON cache. Each CONNECTOR constructs its own instance rooted
/// at `{cacheRoot}/{connectorName}/responses/` so the on-disk layout stays
/// per-connector while lookups stay flat by key. Corrupt, expired, or
/// hash-mismatched entries read as misses and are replaced on the next
/// successful fetch. Writes are atomic (temp file + move).
public actor FileLegalDataConnectorCache: LegalDataConnectorCache {
    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL) {
        self.directory = directory
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// Convenience root for a connector under the configured cache directory.
    public static func forConnector(
        named connectorName: String,
        configuration: LegalDataConnectorConfiguration
    ) -> FileLegalDataConnectorCache {
        FileLegalDataConnectorCache(
            directory: configuration.cacheDirectory
                .appendingPathComponent(connectorName, isDirectory: true)
                .appendingPathComponent("responses", isDirectory: true)
        )
    }

    /// `sha256(method + "\n" + absoluteURL + "\n" + canonicalParams)`. The URL
    /// is the final encoded URL; transient headers (User-Agent) are excluded.
    public static func cacheKey(method: String, url: URL, params: JSONValue) -> String {
        ConnectorHashing.sha256Hex(method + "\n" + url.absoluteString + "\n" + params.canonicalJSONString())
    }

    public func get(key: String, now: Date) async throws -> LegalDataCacheEntry? {
        let file = fileURL(for: key)
        guard let data = try? Data(contentsOf: file) else { return nil }
        guard let entry = try? decoder.decode(LegalDataCacheEntry.self, from: data) else {
            // Corrupt: ignore; it is replaced on the next successful fetch.
            return nil
        }
        if let expiresAt = entry.expiresAt, expiresAt <= now { return nil }
        guard let payload = entry.rawPayload,
              ConnectorHashing.sha256Hex(payload) == entry.payloadHash else {
            return nil
        }
        return entry
    }

    public func put(_ entry: LegalDataCacheEntry, key: String) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(entry)
        let file = fileURL(for: key)
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        try data.write(to: temporary, options: .atomic)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
    }

    public func removeExpired(now: Date) async throws {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let entry = try? decoder.decode(LegalDataCacheEntry.self, from: data) else { continue }
            if let expiresAt = entry.expiresAt, expiresAt <= now {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func fileURL(for key: String) -> URL {
        // Keys are SHA-256 hex — already filesystem-safe.
        let safe = key.filter { $0.isHexDigit }
        return directory.appendingPathComponent((safe.isEmpty ? "invalid" : safe) + ".json")
    }
}
