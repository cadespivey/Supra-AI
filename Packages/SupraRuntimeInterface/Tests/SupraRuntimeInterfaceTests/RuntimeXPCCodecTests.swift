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

    func testLoadModelRequestRoundTripsModelBookmark() throws {
        let modelID = ModelID()
        let bookmark = Data([0x01, 0x02, 0x03, 0x04])
        let identity = ModelDirectoryIdentity(deviceID: 12, inode: 34)
        let request = LoadModelRequest(
            modelID: modelID,
            modelPath: "/models/local",
            displayName: "Local",
            modelBookmark: bookmark,
            managedRootPath: "/models",
            modelDirectoryIdentity: identity
        )

        let data = try RuntimeXPCCodec.encode(request)
        let decoded = try RuntimeXPCCodec.decode(LoadModelRequest.self, from: data)

        XCTAssertEqual(decoded.modelID, modelID)
        XCTAssertEqual(decoded.modelPath, "/models/local")
        XCTAssertEqual(decoded.modelBookmark, bookmark)
        XCTAssertEqual(decoded.managedRootPath, "/models")
        XCTAssertEqual(decoded.modelDirectoryIdentity, identity)
    }

    func testLoadModelRequestDefaultsBookmarkToNil() throws {
        let request = LoadModelRequest(modelID: ModelID(), modelPath: "/m", displayName: "M")
        let decoded = try RuntimeXPCCodec.decode(LoadModelRequest.self, from: try RuntimeXPCCodec.encode(request))
        XCTAssertNil(decoded.modelBookmark)
        XCTAssertNil(decoded.managedRootPath)
        XCTAssertNil(decoded.modelDirectoryIdentity)
    }

    func testEmbeddingLoadRequestRoundTripsDirectoryIdentity() throws {
        let identity = ModelDirectoryIdentity(deviceID: 56, inode: 78)
        let request = LoadEmbeddingModelRequest(
            embeddingModelID: DocumentEmbeddingModelID(),
            modelPath: "/models/embedding",
            displayName: "Embedding",
            modelBookmark: Data([0xAA]),
            managedRootPath: "/models",
            modelDirectoryIdentity: identity
        )

        let decoded = try RuntimeXPCCodec.decode(
            LoadEmbeddingModelRequest.self,
            from: RuntimeXPCCodec.encode(request)
        )
        XCTAssertEqual(decoded.modelDirectoryIdentity, identity)
    }

    func testDefaultServiceNameMatchesAppXPCBundleIdentifier() {
        XCTAssertEqual(RuntimeXPCServiceNames.defaultServiceName, "ai.supra.SupraAI.SupraRuntimeService")
    }
}
