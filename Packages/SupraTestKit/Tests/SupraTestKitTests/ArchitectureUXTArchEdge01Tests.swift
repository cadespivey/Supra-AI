import Foundation
@testable import SupraTestKit
import XCTest

/// T-ARCH-EDGE-01 owns the fixed local-package dependency graph. It proves
/// that graph changes are reviewed as policy changes rather than silently
/// broadening a package's capabilities.
final class ArchitectureUXTArchEdge01Tests: XCTestCase {
    private let recordID = "record-713"
    private let wireID = "T_ARCH_EDGE_01_WIRE_731"
    private let policyVersion = 8

    func testRepositoryGraphMatchesTheVersionEightPolicyAndExactInventory() throws {
        // Expected RED: RepositoryArchitecturePolicy and its manifest-backed
        // audit receipt do not exist yet.
        let policy = RepositoryArchitecturePolicy.current
        let graph = try policy.loadGraph(
            repositoryRoot: repoRoot(),
            recordID: recordID,
            wireID: wireID,
            policyVersion: policyVersion
        )
        let audit = policy.audit(graph)

        XCTAssertTrue(audit.isApproved, "current repository graph must be approved: \(audit.violations)")
        XCTAssertEqual(graph.packageNames, Self.expectedPackageNames)
        XCTAssertEqual(graph.edges, Self.expectedEdges)
        XCTAssertEqual(graph.packageNames.count, 14)
        XCTAssertEqual(graph.edges.count, 36)
        XCTAssertEqual(policy.approvedExceptions.map(\.edge), Self.expectedExceptionEdges)
        XCTAssertEqual(policy.approvedExceptions.count, 7)

        let receipt = try XCTUnwrap(audit.receipt)
        XCTAssertEqual(receipt.recordID, recordID)
        XCTAssertEqual(receipt.wireID, wireID)
        XCTAssertEqual(receipt.policyVersion, policyVersion)
        XCTAssertEqual(receipt.packageCount, 14)
        XCTAssertEqual(receipt.edgeCount, 36)
        XCTAssertEqual(receipt.approvedExceptionCount, 7)
        XCTAssertEqual(
            receipt.graphSHA256,
            "4a1cce833b7b78357dc02562c32bd9481f6f37f6c671b216c4a76e632e75dcb2"
        )

        let exactReceiptElement = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        XCTAssertTrue(exactReceiptElement.contains(recordID))
        XCTAssertTrue(exactReceiptElement.contains(wireID))
        XCTAssertTrue(exactReceiptElement.contains("\"policyVersion\":8"))
        XCTAssertFalse(exactReceiptElement.contains("DEFAULT-000"))
    }

    func testInventoryAndRequiredEdgesFailClosedInsteadOfSilentlyChangingPolicy() throws {
        // Expected RED: there is no typed package-inventory or missing-edge
        // failure owned by one repository architecture policy.
        let policy = RepositoryArchitecturePolicy.current
        let graph = try loadCurrentGraph(policy)
        let unexpectedPackage = "SupraExperimental8"
        let missingEdge = ArchitecturePackageEdge(source: "SupraSessions", destination: "SupraCore")

        let drifted = ArchitecturePackageGraph(
            recordID: graph.recordID,
            wireID: graph.wireID,
            policyVersion: graph.policyVersion,
            packageNames: graph.packageNames.union([unexpectedPackage]),
            edges: graph.edges.subtracting([missingEdge])
        )
        let audit = policy.audit(drifted)

        XCTAssertFalse(audit.isApproved)
        XCTAssertNil(audit.receipt)
        XCTAssertTrue(
            audit.violations.contains(
                .packageInventoryMismatch(
                    expected: Self.expectedPackageNames.sorted(),
                    actual: Self.expectedPackageNames.union([unexpectedPackage]).sorted()
                )
            )
        )
        XCTAssertTrue(audit.violations.contains(.missingRequiredEdge(missingEdge)))
        XCTAssertFalse(String(describing: audit.violations).contains("DEFAULT-000"))
    }

    func testSevenReviewedHarnessExceptionsPassAndTheEighthIsRejected() throws {
        // Expected RED: the seven reviewed TestKit-only exceptions have no
        // explicit budget or typed N+1 rejection.
        let policy = RepositoryArchitecturePolicy.current
        XCTAssertNoThrow(try policy.validateExceptionSet(policy.approvedExceptions))

        let eighth = ArchitectureDependencyException(
            id: "record-713-exception-8",
            edge: ArchitecturePackageEdge(source: "SupraTestKit", destination: "SupraRuntimeClient"),
            rationale: "T_ARCH_EDGE_01_N_PLUS_1_8"
        )
        XCTAssertThrowsError(try policy.validateExceptionSet(policy.approvedExceptions + [eighth])) { error in
            XCTAssertEqual(
                error as? RepositoryArchitecturePolicyError,
                .exceptionBudgetExceeded(allowed: 7, actual: 8)
            )
        }
        XCTAssertFalse(eighth.rationale.contains("DEFAULT-000"))
    }

    func testCycleAndForbiddenCapabilityEdgesAreReportedWithExactOwners() throws {
        // Expected RED: cycles and forbidden database/network capability edges
        // are not evaluated together against the declared package graph.
        let policy = RepositoryArchitecturePolicy.current
        let graph = try loadCurrentGraph(policy)
        let cycleEdge = ArchitecturePackageEdge(source: "SupraCore", destination: "SupraSessions")
        let databaseEdge = ArchitecturePackageEdge(source: "SupraDocuments", destination: "SupraStore")
        let networkingDatabaseEdge = ArchitecturePackageEdge(
            source: "SupraNetworking",
            destination: "SupraStore"
        )
        let networkEdge = ArchitecturePackageEdge(source: "SupraDocuments", destination: "SupraNetworking")
        let drifted = ArchitecturePackageGraph(
            recordID: graph.recordID,
            wireID: graph.wireID,
            policyVersion: graph.policyVersion,
            packageNames: graph.packageNames,
            edges: graph.edges.union([cycleEdge, databaseEdge, networkingDatabaseEdge, networkEdge])
        )

        let audit = policy.audit(drifted)

        XCTAssertFalse(audit.isApproved)
        XCTAssertNil(audit.receipt)
        XCTAssertTrue(audit.violations.contains(.dependencyCycle(["SupraCore", "SupraSessions", "SupraCore"])))
        XCTAssertTrue(
            audit.violations.contains(
                .forbiddenCapabilityEdge(databaseEdge, capabilityOwner: "SupraStore")
            )
        )
        XCTAssertTrue(
            audit.violations.contains(
                .forbiddenCapabilityEdge(networkingDatabaseEdge, capabilityOwner: "SupraStore")
            )
        )
        XCTAssertTrue(
            audit.violations.contains(
                .forbiddenCapabilityEdge(networkEdge, capabilityOwner: "SupraNetworking")
            )
        )
        XCTAssertFalse(String(describing: audit.violations).contains("DEFAULT-000"))
    }

    func testUnknownVersionNineCannotReuseTheVersionEightReceipt() throws {
        // Expected RED: graph receipts are not yet bound to a fail-closed
        // versioned policy identity.
        let policy = RepositoryArchitecturePolicy.current
        let graph = try loadCurrentGraph(policy)
        let versionNine = ArchitecturePackageGraph(
            recordID: graph.recordID,
            wireID: graph.wireID,
            policyVersion: 9,
            packageNames: graph.packageNames,
            edges: graph.edges
        )

        let audit = policy.audit(versionNine)

        XCTAssertFalse(audit.isApproved)
        XCTAssertNil(audit.receipt)
        XCTAssertTrue(
            audit.violations.contains(
                .unsupportedPolicyVersion(expected: 8, actual: 9)
            )
        )
        XCTAssertFalse(String(describing: audit.violations).contains("DEFAULT-000"))
    }

    private func loadCurrentGraph(
        _ policy: RepositoryArchitecturePolicy
    ) throws -> ArchitecturePackageGraph {
        try policy.loadGraph(
            repositoryRoot: repoRoot(),
            recordID: recordID,
            wireID: wireID,
            policyVersion: policyVersion
        )
    }

    private func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    private static let expectedPackageNames: Set<String> = [
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

    private static let expectedEdges: Set<ArchitecturePackageEdge> = [
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

    private static let expectedExceptionEdges: [ArchitecturePackageEdge] = [
        .init(source: "SupraTestKit", destination: "SupraDocuments"),
        .init(source: "SupraTestKit", destination: "SupraDrafting"),
        .init(source: "SupraTestKit", destination: "SupraDraftingCore"),
        .init(source: "SupraTestKit", destination: "SupraNetworking"),
        .init(source: "SupraTestKit", destination: "SupraResearch"),
        .init(source: "SupraTestKit", destination: "SupraSessions"),
        .init(source: "SupraTestKit", destination: "SupraStore"),
    ]
}
