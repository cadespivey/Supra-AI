import Foundation
import SupraCore
@testable import SupraRuntimeInterface
import XCTest

final class RuntimeXPCCodecTests: XCTestCase {
    func testGenerationEventRoundTripsThroughXPCCodec() throws {
        let generationID = GenerationID()
        let event = GenerationEvent(
            generationID: generationID,
            sequenceNumber: 4,
            timestamp: Date(),
            type: .token,
            tokenText: "hello",
            metrics: RuntimeMetrics(generatedTokenCount: 1)
        )

        let data = try RuntimeXPCCodec.encode(event)
        let decoded = try RuntimeXPCCodec.decode(GenerationEvent.self, from: data)

        XCTAssertEqual(decoded.generationID, generationID)
        XCTAssertEqual(decoded.sequenceNumber, 4)
        XCTAssertEqual(decoded.type, .token)
        XCTAssertEqual(decoded.tokenText, "hello")
        XCTAssertEqual(decoded.metrics?.generatedTokenCount, 1)
    }

    func testDefaultServiceNameMatchesAppXPCBundleIdentifier() {
        XCTAssertEqual(RuntimeXPCServiceNames.defaultServiceName, "ai.supra.SupraAI.SupraRuntimeService")
    }
}

