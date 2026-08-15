import Foundation
import XCTest

final class ArchitectureUXDrPackage01Tests: XCTestCase {
    func testDecisionFreezesFourteenPackageBaselineThresholdsAndNoChangeOutcome() throws {
        let decision = try String(contentsOf: repositoryRoot.appendingPathComponent("Docs/Architecture/Remediation/Optional-Architecture-Decisions.yml"), encoding: .utf8)
        XCTAssertTrue(decision.contains("id: DR-PACKAGE-01"))
        XCTAssertTrue(decision.contains("baseline_package_count: 14"))
        XCTAssertTrue(decision.contains("clean_build_wall_time_reduction_percent: 15"))
        XCTAssertTrue(decision.contains("changed_target_rebuild_wall_time_reduction_percent: 20"))
        XCTAssertTrue(decision.contains("pilot_outcome: no_pilot"))
        XCTAssertTrue(decision.contains("disposition: no_change"))
        XCTAssertTrue(decision.contains("Disk size alone is not evidence"))

        let packages = try FileManager.default.contentsOfDirectory(
            at: repositoryRoot.appendingPathComponent("Packages"),
            includingPropertiesForKeys: nil
        ).filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Package.swift").path) }
        XCTAssertEqual(packages.count, 14)
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
