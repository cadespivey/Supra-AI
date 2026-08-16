import Foundation
import XCTest

/// Guards the distinction between sanitizer evidence and the production XPC
/// resource envelope. Instrumentation may change resident-memory accounting;
/// it must not silently relax or claim the uninstrumented 256 MiB gate.
final class RuntimeXPCSanitizerQualificationTests: XCTestCase {
    func testSanitizerGateUsesAnExplicitNonProductionResourceProfile() throws {
        let script = try source("Scripts/run-runtime-sanitizer.sh")
        let hostedTest = try source(
            "Apps/SupraAI/SupraAIUITests/RuntimeXPCIntegrationTests.swift"
        )
        let hostedView = try source(
            "Apps/SupraAI/SupraAI/RuntimeXPCIntegrationView.swift"
        )

        XCTAssertTrue(
            script.contains(
                "RuntimeXPCIntegrationTests/testSanitizedHostedBoundaryLifecycle"
            ),
            "Expected RED: sanitizer builds still select the production resource-envelope test"
        )
        XCTAssertTrue(
            script.contains(
                #"OTHER_LDFLAGS=$(inherited) -fsanitize=undefined"#
            ),
            "Expected RED: Xcode instruments MLX C++ for UBSAN but does not link its runtime into the XPC executable"
        )
        XCTAssertTrue(
            hostedTest.contains("func testSanitizedHostedBoundaryLifecycle()"),
            "the hosted suite needs an explicit sanitizer lifecycle entry point"
        )
        XCTAssertTrue(
            hostedTest.contains("-runtimeXPCQualificationProfile"),
            "the UI runner must tell the DEBUG-only app surface which evidence it is collecting"
        )
        XCTAssertTrue(
            hostedView.contains("residentGrowthMiB <= 256"),
            "the ordinary hosted gate must retain the production 256 MiB ceiling"
        )
        XCTAssertTrue(
            hostedView.contains(
                "production 256 MiB envelope not evaluated under sanitizer instrumentation"
            ),
            "instrumented RSS must be reported without being mislabeled as production evidence"
        )
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private var repositoryRoot: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root
    }
}
