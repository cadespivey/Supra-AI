import CryptoKit
import Foundation

public struct ArchitecturePackageEdge: Hashable, Codable, Comparable, Sendable {
    public let source: String
    public let destination: String

    public init(source: String, destination: String) {
        self.source = source
        self.destination = destination
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.source != rhs.source {
            return lhs.source < rhs.source
        }
        return lhs.destination < rhs.destination
    }

    fileprivate var canonicalValue: String {
        "\(source)->\(destination)"
    }
}

public struct ArchitectureDependencyException: Equatable, Sendable {
    public let id: String
    public let edge: ArchitecturePackageEdge
    public let rationale: String

    public init(id: String, edge: ArchitecturePackageEdge, rationale: String) {
        self.id = id
        self.edge = edge
        self.rationale = rationale
    }
}

public struct ArchitecturePackageGraph: Equatable, Sendable {
    public let recordID: String
    public let wireID: String
    public let policyVersion: Int
    public let packageNames: Set<String>
    public let edges: Set<ArchitecturePackageEdge>

    public init(
        recordID: String,
        wireID: String,
        policyVersion: Int,
        packageNames: Set<String>,
        edges: Set<ArchitecturePackageEdge>
    ) {
        self.recordID = recordID
        self.wireID = wireID
        self.policyVersion = policyVersion
        self.packageNames = packageNames
        self.edges = edges
    }
}

public enum ArchitecturePolicyViolation: Equatable, Sendable {
    case unsupportedPolicyVersion(expected: Int, actual: Int)
    case packageInventoryMismatch(expected: [String], actual: [String])
    case missingRequiredEdge(ArchitecturePackageEdge)
    case undeclaredEdge(ArchitecturePackageEdge)
    case edgeReferencesUnknownPackage(ArchitecturePackageEdge)
    case dependencyCycle([String])
    case forbiddenCapabilityEdge(ArchitecturePackageEdge, capabilityOwner: String)
}

public struct RepositoryArchitectureReceipt: Equatable, Codable, Sendable {
    public let recordID: String
    public let wireID: String
    public let policyVersion: Int
    public let packageCount: Int
    public let edgeCount: Int
    public let approvedExceptionCount: Int
    public let graphSHA256: String

    public init(
        recordID: String,
        wireID: String,
        policyVersion: Int,
        packageCount: Int,
        edgeCount: Int,
        approvedExceptionCount: Int,
        graphSHA256: String
    ) {
        self.recordID = recordID
        self.wireID = wireID
        self.policyVersion = policyVersion
        self.packageCount = packageCount
        self.edgeCount = edgeCount
        self.approvedExceptionCount = approvedExceptionCount
        self.graphSHA256 = graphSHA256
    }
}

public struct RepositoryArchitectureAudit: Equatable, Sendable {
    public let violations: [ArchitecturePolicyViolation]
    public let receipt: RepositoryArchitectureReceipt?

    public var isApproved: Bool {
        violations.isEmpty && receipt != nil
    }

    public init(
        violations: [ArchitecturePolicyViolation],
        receipt: RepositoryArchitectureReceipt?
    ) {
        self.violations = violations
        self.receipt = receipt
    }
}

public enum RepositoryArchitecturePolicyError: Error, Equatable, LocalizedError {
    case packagesDirectoryMissing(String)
    case manifestUnreadable(package: String)
    case manifestPackageNameMissing(package: String)
    case manifestPackageNameMismatch(directory: String, declared: String)
    case malformedLocalDependencyDeclaration(package: String)
    case exceptionBudgetExceeded(allowed: Int, actual: Int)
    case duplicateExceptionID(String)
    case duplicateExceptionEdge(ArchitecturePackageEdge)
    case invalidExceptionEdge(ArchitecturePackageEdge)

    public var errorDescription: String? {
        switch self {
        case let .packagesDirectoryMissing(path):
            return "Packages directory is missing at \(path)"
        case let .manifestUnreadable(package):
            return "Package manifest is unreadable for \(package)"
        case let .manifestPackageNameMissing(package):
            return "Package manifest has no top-level name for \(package)"
        case let .manifestPackageNameMismatch(directory, declared):
            return "Package directory \(directory) declares \(declared)"
        case let .malformedLocalDependencyDeclaration(package):
            return "Package \(package) has a local dependency declaration the policy cannot parse"
        case let .exceptionBudgetExceeded(allowed, actual):
            return "Architecture exception budget is \(allowed), received \(actual)"
        case let .duplicateExceptionID(id):
            return "Architecture exception ID is duplicated: \(id)"
        case let .duplicateExceptionEdge(edge):
            return "Architecture exception edge is duplicated: \(edge.canonicalValue)"
        case let .invalidExceptionEdge(edge):
            return "Architecture exception is not a reviewed test-harness edge: \(edge.canonicalValue)"
        }
    }
}

/// The reviewed local-package dependency contract. `SupraTestKit` is not part
/// of the app product, so its seven high-level dependencies are explicit test
/// harness exceptions. Every other local edge is part of the ordinary graph.
public struct RepositoryArchitecturePolicy: Sendable {
    public static let current = RepositoryArchitecturePolicy(
        policyVersion: 8,
        packageNames: currentPackageNames,
        requiredEdges: currentRequiredEdges,
        approvedExceptions: currentApprovedExceptions,
        exceptionBudget: 7
    )

    public let policyVersion: Int
    public let packageNames: Set<String>
    public let requiredEdges: Set<ArchitecturePackageEdge>
    public let approvedExceptions: [ArchitectureDependencyException]
    public let exceptionBudget: Int

    public init(
        policyVersion: Int,
        packageNames: Set<String>,
        requiredEdges: Set<ArchitecturePackageEdge>,
        approvedExceptions: [ArchitectureDependencyException],
        exceptionBudget: Int
    ) {
        self.policyVersion = policyVersion
        self.packageNames = packageNames
        self.requiredEdges = requiredEdges
        self.approvedExceptions = approvedExceptions
        self.exceptionBudget = exceptionBudget
    }

    public func loadGraph(
        repositoryRoot: URL,
        recordID: String,
        wireID: String,
        policyVersion: Int
    ) throws -> ArchitecturePackageGraph {
        let packagesURL = repositoryRoot.appendingPathComponent("Packages", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: packagesURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw RepositoryArchitecturePolicyError.packagesDirectoryMissing(packagesURL.path)
        }

        let entries = try FileManager.default.contentsOfDirectory(
            at: packagesURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let manifests = entries
            .map { ($0.lastPathComponent, $0.appendingPathComponent("Package.swift")) }
            .filter { FileManager.default.fileExists(atPath: $0.1.path) }
            .sorted { $0.0 < $1.0 }

        var discoveredPackages = Set<String>()
        var discoveredEdges = Set<ArchitecturePackageEdge>()
        for (directoryName, manifestURL) in manifests {
            guard let source = try? String(contentsOf: manifestURL, encoding: .utf8) else {
                throw RepositoryArchitecturePolicyError.manifestUnreadable(package: directoryName)
            }
            let declaredName = try parseDeclaredPackageName(source, package: directoryName)
            guard declaredName == directoryName else {
                throw RepositoryArchitecturePolicyError.manifestPackageNameMismatch(
                    directory: directoryName,
                    declared: declaredName
                )
            }
            discoveredPackages.insert(directoryName)
            for dependency in try parseLocalDependencies(source, package: directoryName) {
                discoveredEdges.insert(
                    ArchitecturePackageEdge(source: directoryName, destination: dependency)
                )
            }
        }

        return ArchitecturePackageGraph(
            recordID: recordID,
            wireID: wireID,
            policyVersion: policyVersion,
            packageNames: discoveredPackages,
            edges: discoveredEdges
        )
    }

    public func audit(_ graph: ArchitecturePackageGraph) -> RepositoryArchitectureAudit {
        var violations: [ArchitecturePolicyViolation] = []

        if graph.policyVersion != policyVersion {
            violations.append(
                .unsupportedPolicyVersion(expected: policyVersion, actual: graph.policyVersion)
            )
        }
        if graph.packageNames != packageNames {
            violations.append(
                .packageInventoryMismatch(
                    expected: packageNames.sorted(),
                    actual: graph.packageNames.sorted()
                )
            )
        }

        for edge in requiredEdges.subtracting(graph.edges).sorted() {
            violations.append(.missingRequiredEdge(edge))
        }
        for edge in graph.edges.subtracting(requiredEdges).sorted() {
            violations.append(.undeclaredEdge(edge))
        }
        for edge in graph.edges.sorted()
        where !graph.packageNames.contains(edge.source) || !graph.packageNames.contains(edge.destination) {
            violations.append(.edgeReferencesUnknownPackage(edge))
        }
        if let cycle = firstDependencyCycle(in: graph) {
            violations.append(.dependencyCycle(cycle))
        }
        for edge in graph.edges.sorted() {
            if let capabilityOwner = forbiddenCapabilityOwner(for: edge) {
                violations.append(
                    .forbiddenCapabilityEdge(edge, capabilityOwner: capabilityOwner)
                )
            }
        }

        guard violations.isEmpty else {
            return RepositoryArchitectureAudit(violations: violations, receipt: nil)
        }
        return RepositoryArchitectureAudit(
            violations: [],
            receipt: RepositoryArchitectureReceipt(
                recordID: graph.recordID,
                wireID: graph.wireID,
                policyVersion: graph.policyVersion,
                packageCount: graph.packageNames.count,
                edgeCount: graph.edges.count,
                approvedExceptionCount: approvedExceptions.count,
                graphSHA256: Self.graphSHA256(graph.edges)
            )
        )
    }

    public func validateExceptionSet(
        _ exceptions: [ArchitectureDependencyException]
    ) throws {
        guard exceptions.count <= exceptionBudget else {
            throw RepositoryArchitecturePolicyError.exceptionBudgetExceeded(
                allowed: exceptionBudget,
                actual: exceptions.count
            )
        }
        var ids = Set<String>()
        var edges = Set<ArchitecturePackageEdge>()
        for exception in exceptions {
            guard ids.insert(exception.id).inserted else {
                throw RepositoryArchitecturePolicyError.duplicateExceptionID(exception.id)
            }
            guard edges.insert(exception.edge).inserted else {
                throw RepositoryArchitecturePolicyError.duplicateExceptionEdge(exception.edge)
            }
            guard requiredEdges.contains(exception.edge),
                  exception.edge.source == "SupraTestKit",
                  exception.edge.destination != "SupraCore"
            else {
                throw RepositoryArchitecturePolicyError.invalidExceptionEdge(exception.edge)
            }
        }
    }

    private func parseDeclaredPackageName(
        _ source: String,
        package: String
    ) throws -> String {
        let pattern = #"let\s+package\s*=\s*Package\s*\(\s*name\s*:\s*"([A-Za-z0-9_-]+)""#
        guard let match = firstCapture(pattern: pattern, in: source) else {
            throw RepositoryArchitecturePolicyError.manifestPackageNameMissing(package: package)
        }
        return match
    }

    private func parseLocalDependencies(
        _ source: String,
        package: String
    ) throws -> [String] {
        let broadPattern = #"\.package\s*\([^\)]*path\s*:\s*"\.\./"#
        let exactPattern = #"\.package\s*\(\s*(?:name\s*:\s*"[^"]+"\s*,\s*)?path\s*:\s*"\.\./([A-Za-z0-9_-]+)"\s*\)"#
        let broadCount = matches(pattern: broadPattern, in: source).count
        let dependencies = captures(pattern: exactPattern, in: source)
        guard broadCount == dependencies.count else {
            throw RepositoryArchitecturePolicyError.malformedLocalDependencyDeclaration(
                package: package
            )
        }
        return dependencies
    }

    private func firstCapture(pattern: String, in value: String) -> String? {
        captures(pattern: pattern, in: value).first
    }

    private func captures(pattern: String, in value: String) -> [String] {
        return matches(pattern: pattern, in: value).compactMap { match in
            guard match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: value)
            else {
                return nil
            }
            return String(value[captureRange])
        }
    }

    private func matches(pattern: String, in value: String) -> [NSTextCheckingResult] {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators]
        ) else {
            return []
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.matches(in: value, range: range)
    }

    private func firstDependencyCycle(in graph: ArchitecturePackageGraph) -> [String]? {
        var adjacency: [String: [String]] = [:]
        for edge in graph.edges where graph.packageNames.contains(edge.destination) {
            adjacency[edge.source, default: []].append(edge.destination)
        }
        for source in adjacency.keys {
            adjacency[source]?.sort()
        }

        var visited = Set<String>()
        var active = Set<String>()
        var path: [String] = []

        func visit(_ package: String) -> [String]? {
            if active.contains(package),
               let cycleStart = path.firstIndex(of: package) {
                return Array(path[cycleStart...]) + [package]
            }
            if visited.contains(package) {
                return nil
            }
            visited.insert(package)
            active.insert(package)
            path.append(package)
            for dependency in adjacency[package] ?? [] {
                if let cycle = visit(dependency) {
                    return cycle
                }
            }
            _ = path.popLast()
            active.remove(package)
            return nil
        }

        for package in graph.packageNames.sorted() {
            if let cycle = visit(package) {
                return cycle
            }
        }
        return nil
    }

    private func forbiddenCapabilityOwner(
        for edge: ArchitecturePackageEdge
    ) -> String? {
        if edge.destination == "SupraStore",
           Self.persistenceIsolatedPackages.contains(edge.source) {
            return "SupraStore"
        }
        if edge.destination == "SupraNetworking",
           Self.networkIsolatedPackages.contains(edge.source) {
            return "SupraNetworking"
        }
        return nil
    }

    private static func graphSHA256(_ edges: Set<ArchitecturePackageEdge>) -> String {
        let canonical = edges.sorted().map(\.canonicalValue).joined(separator: "\n") + "\n"
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static let persistenceIsolatedPackages: Set<String> = [
        "SupraCore",
        "SupraDesignSystem",
        "SupraDiagnostics",
        "SupraDocuments",
        "SupraDrafting",
        "SupraDraftingCore",
        "SupraExports",
        "SupraNetworking",
        "SupraResearch",
        "SupraRuntimeClient",
        "SupraRuntimeInterface",
    ]

    private static let networkIsolatedPackages: Set<String> = [
        "SupraCore",
        "SupraDesignSystem",
        "SupraDiagnostics",
        "SupraDocuments",
        "SupraDrafting",
        "SupraDraftingCore",
        "SupraExports",
        "SupraRuntimeClient",
        "SupraRuntimeInterface",
    ]

    private static let currentPackageNames: Set<String> = [
        "SupraCore",
        "SupraDesignSystem",
        "SupraDiagnostics",
        "SupraDocuments",
        "SupraDrafting",
        "SupraDraftingCore",
        "SupraExports",
        "SupraNetworking",
        "SupraResearch",
        "SupraRuntimeClient",
        "SupraRuntimeInterface",
        "SupraSessions",
        "SupraStore",
        "SupraTestKit",
    ]

    private static let currentRequiredEdges: Set<ArchitecturePackageEdge> = [
        .init(source: "SupraDiagnostics", destination: "SupraCore"),
        .init(source: "SupraDiagnostics", destination: "SupraRuntimeInterface"),
        .init(source: "SupraDocuments", destination: "SupraCore"),
        .init(source: "SupraDocuments", destination: "SupraExports"),
        .init(source: "SupraDrafting", destination: "SupraCore"),
        .init(source: "SupraDrafting", destination: "SupraDraftingCore"),
        .init(source: "SupraDrafting", destination: "SupraExports"),
        .init(source: "SupraDraftingCore", destination: "SupraCore"),
        .init(source: "SupraExports", destination: "SupraDraftingCore"),
        .init(source: "SupraNetworking", destination: "SupraCore"),
        .init(source: "SupraResearch", destination: "SupraCore"),
        .init(source: "SupraResearch", destination: "SupraNetworking"),
        .init(source: "SupraRuntimeClient", destination: "SupraCore"),
        .init(source: "SupraRuntimeClient", destination: "SupraRuntimeInterface"),
        .init(source: "SupraRuntimeInterface", destination: "SupraCore"),
        .init(source: "SupraSessions", destination: "SupraCore"),
        .init(source: "SupraSessions", destination: "SupraDiagnostics"),
        .init(source: "SupraSessions", destination: "SupraDocuments"),
        .init(source: "SupraSessions", destination: "SupraDrafting"),
        .init(source: "SupraSessions", destination: "SupraDraftingCore"),
        .init(source: "SupraSessions", destination: "SupraExports"),
        .init(source: "SupraSessions", destination: "SupraNetworking"),
        .init(source: "SupraSessions", destination: "SupraResearch"),
        .init(source: "SupraSessions", destination: "SupraRuntimeClient"),
        .init(source: "SupraSessions", destination: "SupraRuntimeInterface"),
        .init(source: "SupraSessions", destination: "SupraStore"),
        .init(source: "SupraStore", destination: "SupraCore"),
        .init(source: "SupraStore", destination: "SupraDiagnostics"),
        .init(source: "SupraTestKit", destination: "SupraCore"),
        .init(source: "SupraTestKit", destination: "SupraDocuments"),
        .init(source: "SupraTestKit", destination: "SupraDrafting"),
        .init(source: "SupraTestKit", destination: "SupraDraftingCore"),
        .init(source: "SupraTestKit", destination: "SupraNetworking"),
        .init(source: "SupraTestKit", destination: "SupraResearch"),
        .init(source: "SupraTestKit", destination: "SupraSessions"),
        .init(source: "SupraTestKit", destination: "SupraStore"),
    ]

    private static let currentApprovedExceptions: [ArchitectureDependencyException] = [
        .init(
            id: "test-harness-documents",
            edge: .init(source: "SupraTestKit", destination: "SupraDocuments"),
            rationale: "The isolated fixture harness exercises document behavior."
        ),
        .init(
            id: "test-harness-drafting",
            edge: .init(source: "SupraTestKit", destination: "SupraDrafting"),
            rationale: "The isolated fixture harness exercises drafting behavior."
        ),
        .init(
            id: "test-harness-drafting-core",
            edge: .init(source: "SupraTestKit", destination: "SupraDraftingCore"),
            rationale: "The isolated fixture harness constructs drafting domain values."
        ),
        .init(
            id: "test-harness-networking",
            edge: .init(source: "SupraTestKit", destination: "SupraNetworking"),
            rationale: "The isolated fixture harness validates authorized transport behavior."
        ),
        .init(
            id: "test-harness-research",
            edge: .init(source: "SupraTestKit", destination: "SupraResearch"),
            rationale: "The isolated fixture harness exercises research behavior."
        ),
        .init(
            id: "test-harness-sessions",
            edge: .init(source: "SupraTestKit", destination: "SupraSessions"),
            rationale: "The isolated fixture harness exercises app-facing orchestration."
        ),
        .init(
            id: "test-harness-store",
            edge: .init(source: "SupraTestKit", destination: "SupraStore"),
            rationale: "The isolated fixture harness creates disposable stores."
        ),
    ]
}
