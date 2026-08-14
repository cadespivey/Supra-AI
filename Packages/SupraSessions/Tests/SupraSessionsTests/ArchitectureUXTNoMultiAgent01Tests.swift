import Foundation
import XCTest

/// Source-level release boundary shared by T-NO-MULTI-AGENT-01 and the caller-
/// ownership portion of T-RUNTIME-SCHED-01/T-RUNTIME-LIFECYCLE-01.
///
/// Expected RED: the no-agent standing guard is already true, but ordinary
/// feature files still own raw `RuntimeClientProtocol` data-plane calls and the
/// app composes `RuntimeSafetyClient` directly instead of one shared
/// `ModelExecutionCoordinator`/scoped permit boundary.
final class ArchitectureUXTNoMultiAgent01Tests: XCTestCase {
    func testReleaseCompositionContainsNoAgentIdentityRoleHandoffOrFramework() throws {
        // Standing guard: fixed typed feature steps are allowed; agent identity,
        // role registries, autonomous recursion, and agent frameworks are not.
        var sources = try productionSources()
        sources.append(SourceFile(
            relativePath: "T-NO-MULTI-AGENT-01-wire.swift",
            contents: "public enum T_NO_MULTI_AGENT_01_WIRE_731 { case fixedSequentialTask }"
        ))
        let bannedIdentifiers = [
            "AgentIdentity",
            "AgentRole",
            "AgentRegistry",
            "AgentHandoff",
            "AgentCoordinator",
            "AgentOrchestrator",
            "MultiAgent",
            "AutonomousAgent",
            "RecursiveAgent",
            "RolePromptRegistry",
        ]
        let bannedUIOrPersistencePhrases = [
            "agent_identity",
            "agent_role",
            "agent_handoff",
            "agent_registry",
            "multi-agent",
            "multi agent",
            "autonomous recursion",
        ]
        var violations: [String] = []
        for source in sources {
            let lowercased = source.contents.lowercased()
            for identifier in bannedIdentifiers where source.contents.contains(identifier) {
                violations.append("\(source.relativePath): banned identifier \(identifier)")
            }
            for phrase in bannedUIOrPersistencePhrases where lowercased.contains(phrase) {
                violations.append("\(source.relativePath): banned release phrase \(phrase)")
            }
        }

        for manifest in try dependencyManifests() {
            let lowercased = manifest.contents.lowercased()
            for dependency in [
                "langchain",
                "langgraph",
                "crewai",
                "autogen",
                "agent-framework",
                "agentframework",
            ] where lowercased.contains(dependency) {
                violations.append("\(manifest.relativePath): banned dependency \(dependency)")
            }
        }

        XCTAssertEqual(
            violations,
            [],
            "T-NO-MULTI-AGENT-01 release surface must remain one typed task/one GPU lane:\n"
                + violations.joined(separator: "\n")
        )
        let acceptedWire = try XCTUnwrap(sources.first {
            $0.contents.contains("T_NO_MULTI_AGENT_01_WIRE_731")
        })
        XCTAssertEqual(acceptedWire.relativePath, "T-NO-MULTI-AGENT-01-wire.swift")
        XCTAssertTrue(acceptedWire.contents.contains("T_NO_MULTI_AGENT_01_WIRE_731"))
        XCTAssertFalse(acceptedWire.contents.contains("DEFAULT-000"))
    }

    func testEveryOrdinaryRuntimeDataPlaneCallIsPermitOwnedOrExplicitlyAllowlisted() throws {
        let sources = try productionSources()
        let directCallTokens = [
            "runtimeClient.generate(",
            "runtimeClient.collectGeneratedText(",
            "runtimeClient.countTokens(",
            "runtimeClient.loadModel(",
            "runtimeClient.loadEmbeddingModel(",
            "runtimeClient.embedTexts(",
            "runtimeClient.unloadModel(",
            "runtimeClient.reloadCurrentModel(",
        ]
        let explicitAllowlist: Set<String> = [
            // Signed Release and hosted adversarial/XPC probes intentionally
            // exercise the low-level boundary rather than ordinary app work.
            // RuntimeClient is the transport and RuntimeSafetyClient is the
            // cancellation-quarantine layer immediately below the coordinator.
            "Packages/SupraRuntimeClient/Sources/SupraRuntimeClient/RuntimeClient.swift",
            "Packages/SupraRuntimeClient/Sources/SupraRuntimeClient/RuntimeClientProtocol.swift",
            "Packages/SupraRuntimeClient/Sources/SupraRuntimeClient/RuntimeSafetyClient.swift",
            "Packages/SupraSessions/Sources/SupraSessions/SignedReleaseSmokeRunner.swift",
            "Apps/SupraAI/SupraAI/RuntimeXPCIntegrationView.swift",
            // The composition root may construct the raw transport solely to
            // wrap it in RuntimeSafetyClient and the one shared coordinator.
            "Apps/SupraAI/SupraAI/AppEnvironment.swift",
        ]

        var violations: [String] = []
        for source in sources where !explicitAllowlist.contains(source.relativePath) {
            let isGatewayOwner = source.relativePath.hasSuffix("/ModelExecutionCoordinator.swift")
                || source.relativePath.hasSuffix("/ModelExecutionPermit.swift")
            if isGatewayOwner { continue }

            if source.contents.contains("RuntimeClientProtocol") {
                violations.append(
                    "\(source.relativePath): ordinary source still owns raw RuntimeClientProtocol"
                )
            }

            for (offset, line) in source.contents.components(separatedBy: .newlines).enumerated() {
                guard directCallTokens.contains(where: { line.contains($0) }) else { continue }
                violations.append(
                    "\(source.relativePath):\(offset + 1): \(line.trimmingCharacters(in: .whitespaces))"
                )
            }
        }

        let collector = try source(
            relativePath: "Packages/SupraSessions/Sources/SupraSessions/GenerationStreamCollector.swift"
        )
        if collector.contents.contains("extension RuntimeClientProtocol") {
            violations.append(
                "\(collector.relativePath): raw collectGeneratedText extension remains feature-callable"
            )
        }

        XCTAssertEqual(
            violations,
            [],
            "ordinary GenerateRequest/embedding/load/token work must be owned by a scoped coordinator permit:\n"
                + violations.joined(separator: "\n")
        )
    }

    func testAppComposesOneSharedCoordinatorAndNoSecondGenerativeWorker() throws {
        let appEnvironment = try source(relativePath: "Apps/SupraAI/SupraAI/AppEnvironment.swift")
        XCTAssertTrue(
            appEnvironment.contents.contains(
                "private let modelExecutionCoordinator: ModelExecutionCoordinator"
            ),
            "AppEnvironment must retain exactly one process-wide GPU admission owner"
        )
        XCTAssertEqual(
            occurrences(of: "ModelExecutionCoordinator(", in: appEnvironment.contents),
            1,
            "release composition must construct exactly one coordinator"
        )
        XCTAssertTrue(
            appEnvironment.contents.contains("RuntimeSafetyClient(base: baseRuntimeClient)"),
            "the coordinator must preserve the neutral cancellation-quarantine facade"
        )
        XCTAssertTrue(
            appEnvironment.contents.contains("runtimeClient: modelExecutionCoordinator"),
            "ordinary feature composition must receive the shared coordinator, not the raw client"
        )

        let modelLibrary = try source(
            relativePath: "Packages/SupraSessions/Sources/SupraSessions/ModelLibrary.swift"
        )
        XCTAssertFalse(
            modelLibrary.contents.contains("public var isRuntimeGenerating: () -> Bool"),
            "speculative prewarm must be queued/coalesced, not race a controller-local status heuristic"
        )
        XCTAssertTrue(
            modelLibrary.contents.contains("ModelExecutionOperation.prewarm"),
            "model prewarm must use the same typed physical lane"
        )
    }

    func testCoordinatorPublicContractNamesOneLaneAndFourPriorityClasses() throws {
        let coordinatorFiles = try productionSources().filter {
            $0.relativePath.hasSuffix("/ModelExecutionCoordinator.swift")
                || $0.relativePath.hasSuffix("/ModelExecutionPermit.swift")
        }
        let joined = coordinatorFiles.map(\.contents).joined(separator: "\n")

        XCTAssertEqual(
            occurrences(of: "actor ModelExecutionCoordinator", in: joined),
            1,
            "there must be one neutral coordinator actor, not a workflow/agent worker registry"
        )
        for contract in [
            "case foregroundInteractive",
            "case userInitiatedBatch",
            "case backgroundMaintenance",
            "case speculative",
            "maximumQueuedTasks",
            "agingIntervalTicks",
            "yieldAtSafeBoundary",
            "RuntimeSafetyClient",
            "ModelExecutionPermit",
        ] {
            XCTAssertTrue(joined.contains(contract), "missing runtime contract: \(contract)")
        }
        for forbidden in [
            "AgentIdentity",
            "AgentRole",
            "AgentHandoff",
            "concurrentGenerativeWorkers",
        ] {
            XCTAssertFalse(joined.contains(forbidden), "coordinator is not an agent system: \(forbidden)")
        }
    }

    private struct SourceFile {
        let relativePath: String
        let contents: String
    }

    private func productionSources() throws -> [SourceFile] {
        let roots = [
            repositoryRoot.appendingPathComponent("Packages", isDirectory: true),
            repositoryRoot.appendingPathComponent("Apps/SupraAI/SupraAI", isDirectory: true),
        ]
        var result: [SourceFile] = []
        for root in roots {
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ))
            for case let fileURL as URL in enumerator {
                let path = fileURL.path
                guard path.hasSuffix(".swift"),
                      path.contains("/Sources/") || path.contains("/Apps/SupraAI/SupraAI/")
                else { continue }
                result.append(try source(url: fileURL))
            }
        }
        return result.sorted { $0.relativePath < $1.relativePath }
    }

    private func dependencyManifests() throws -> [SourceFile] {
        let packageRoot = repositoryRoot.appendingPathComponent("Packages", isDirectory: true)
        let packageNames = try FileManager.default.contentsOfDirectory(
            at: packageRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var manifests = try packageNames.compactMap { directory -> SourceFile? in
            let manifest = directory.appendingPathComponent("Package.swift")
            guard FileManager.default.fileExists(atPath: manifest.path) else { return nil }
            return try source(url: manifest)
        }
        manifests.append(try source(relativePath: "Apps/SupraAI/SupraAI.xcodeproj/project.pbxproj"))
        return manifests
    }

    private func source(relativePath: String) throws -> SourceFile {
        try source(url: repositoryRoot.appendingPathComponent(relativePath))
    }

    private func source(url: URL) throws -> SourceFile {
        let contents = try String(contentsOf: url, encoding: .utf8)
        let prefix = repositoryRoot.path + "/"
        let relative = url.path.hasPrefix(prefix)
            ? String(url.path.dropFirst(prefix.count))
            : url.lastPathComponent
        return SourceFile(relativePath: relative, contents: contents)
    }

    private var repositoryRoot: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
    }
}
