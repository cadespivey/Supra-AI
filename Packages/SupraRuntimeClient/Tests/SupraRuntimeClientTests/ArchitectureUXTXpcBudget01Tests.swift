import Foundation
import SupraCore
@testable import SupraRuntimeClient
import SupraRuntimeInterface
import XCTest

/// T-XPC-BUDGET-01 RED: neither the shared codec nor either side of the XPC
/// boundary accepts a byte budget. Oversized `Data` therefore reaches DTO
/// decoding instead of being rejected before a decoder can allocate from it.
final class ArchitectureUXTXpcBudget01Tests: XCTestCase {
    func testRequestEncodedBytesAdmitNAndRejectNPlusOneBeforeDecode() throws {
        var policy = RuntimeBudgetPolicy.production
        policy.maxEncodedRequestBytes = ArchitectureUXRuntimeBudgetWire.requestByteLimit

        ArchitectureUXDecodeProbe.reset()
        let acceptedData = ArchitectureUXRuntimeBudgetWire.jsonProbe(
            encodedByteCount: policy.maxEncodedRequestBytes,
            fill: "R",
            prefix: ArchitectureUXRuntimeBudgetWire.xpcBudget01
        )
        let accepted = try RuntimeXPCCodec.decodeRequest(
            ArchitectureUXDecodeProbe.self,
            from: acceptedData,
            policy: policy
        )

        XCTAssertEqual(acceptedData.count, ArchitectureUXRuntimeBudgetWire.requestByteLimit)
        XCTAssertEqual(ArchitectureUXDecodeProbe.decodeCount, 1)
        XCTAssertTrue(accepted.wire.hasPrefix(ArchitectureUXRuntimeBudgetWire.xpcBudget01))
        XCTAssertTrue(accepted.wire.contains(ArchitectureUXRuntimeBudgetWire.modelArtifactID))
        XCTAssertTrue(accepted.wire.contains(ArchitectureUXRuntimeBudgetWire.modelRevision))
        XCTAssertFalse(accepted.wire.contains(ArchitectureUXRuntimeBudgetWire.forbiddenDefault))

        ArchitectureUXDecodeProbe.reset()
        let rejectedData = ArchitectureUXRuntimeBudgetWire.jsonProbe(
            encodedByteCount: policy.maxEncodedRequestBytes + 1,
            fill: "X",
            prefix: ArchitectureUXRuntimeBudgetWire.xpcBudget01
        )
        assertArchitectureUXBudgetViolation(
            .encodedRequestBytes,
            limit: policy.maxEncodedRequestBytes,
            actual: policy.maxEncodedRequestBytes + 1
        ) {
            _ = try RuntimeXPCCodec.decodeRequest(
                ArchitectureUXDecodeProbe.self,
                from: rejectedData,
                policy: policy
            )
        }
        XCTAssertEqual(
            ArchitectureUXDecodeProbe.decodeCount,
            0,
            "N+1 bytes must be rejected before Decodable.init(from:) executes"
        )
    }

    func testResponseEncodedBytesAdmitNAndRejectNPlusOneBeforeDecode() throws {
        var policy = RuntimeBudgetPolicy.production
        policy.maxEncodedResponseBytes = ArchitectureUXRuntimeBudgetWire.responseByteLimit

        ArchitectureUXDecodeProbe.reset()
        let acceptedData = ArchitectureUXRuntimeBudgetWire.jsonProbe(
            encodedByteCount: policy.maxEncodedResponseBytes,
            fill: "S",
            prefix: ArchitectureUXRuntimeBudgetWire.xpcBudget01
        )
        let accepted = try RuntimeXPCCodec.decodeResponse(
            ArchitectureUXDecodeProbe.self,
            from: acceptedData,
            policy: policy
        )

        XCTAssertEqual(acceptedData.count, ArchitectureUXRuntimeBudgetWire.responseByteLimit)
        XCTAssertEqual(ArchitectureUXDecodeProbe.decodeCount, 1)
        XCTAssertTrue(accepted.wire.hasPrefix(ArchitectureUXRuntimeBudgetWire.xpcBudget01))
        XCTAssertTrue(accepted.wire.contains(ArchitectureUXRuntimeBudgetWire.modelArtifactID))
        XCTAssertTrue(accepted.wire.contains(ArchitectureUXRuntimeBudgetWire.modelRevision))
        XCTAssertFalse(accepted.wire.contains(ArchitectureUXRuntimeBudgetWire.forbiddenDefault))

        ArchitectureUXDecodeProbe.reset()
        let rejectedData = ArchitectureUXRuntimeBudgetWire.jsonProbe(
            encodedByteCount: policy.maxEncodedResponseBytes + 1,
            fill: "Y",
            prefix: ArchitectureUXRuntimeBudgetWire.xpcBudget01
        )
        assertArchitectureUXBudgetViolation(
            .encodedResponseBytes,
            limit: policy.maxEncodedResponseBytes,
            actual: policy.maxEncodedResponseBytes + 1
        ) {
            _ = try RuntimeXPCCodec.decodeResponse(
                ArchitectureUXDecodeProbe.self,
                from: rejectedData,
                policy: policy
            )
        }
        XCTAssertEqual(
            ArchitectureUXDecodeProbe.decodeCount,
            0,
            "N+1 response bytes must be rejected before Decodable.init(from:) executes"
        )
    }

    func testClientAndHostUseDirectionalBudgetedCodecEntryPoints() throws {
        let client = try ArchitectureUXRuntimeBudgetWire.source(
            "Packages/SupraRuntimeClient/Sources/SupraRuntimeClient/RuntimeClient.swift"
        )
        let host = try ArchitectureUXRuntimeBudgetWire.source(
            "Apps/SupraAI/SupraRuntimeService/SupraRuntimeService.swift"
        )

        XCTAssertTrue(client.contains("RuntimeXPCCodec.decodeResponse("))
        XCTAssertTrue(host.contains("RuntimeXPCCodec.decodeRequest("))
        XCTAssertFalse(client.contains(ArchitectureUXRuntimeBudgetWire.forbiddenDefault))
        XCTAssertFalse(host.contains(ArchitectureUXRuntimeBudgetWire.forbiddenDefault))
    }
}

enum ArchitectureUXRuntimeBudgetWire {
    static let forbiddenDefault = "DEFAULT-000"
    static let xpcBudget01 = "T_XPC_BUDGET_01_WIRE_731|model-wire-713|rev-7"
    static let xpcBudget02 = "T_XPC_BUDGET_02_WIRE_731|model-wire-713|rev-7"
    static let xpcBudget03 = "T_XPC_BUDGET_03_WIRE_731|model-wire-713|rev-7"
    static let xpcBudget04 = "T_XPC_BUDGET_04_WIRE_731|model-wire-713|rev-7"
    static let xpcBudget05 = "T_XPC_BUDGET_05_WIRE_731|model-wire-713|rev-7"
    static let xpcBudget06 = "T_XPC_BUDGET_06_WIRE_731|model-wire-713|rev-7"
    static let runtimeKV = "T_RUNTIME_KV_01_WIRE_731|model-wire-713|rev-7"
    static let runtimeSwitch = "T_RUNTIME_SWITCH_01_WIRE_731|model-wire-713|rev-7"
    static let streamBuffer = "T_STREAM_BUFFER_01_WIRE_731|model-wire-713|rev-7"
    static let modelArtifactID = "model-wire-713"
    static let modelRevision = "rev-7"
    static let requestByteLimit = 313
    static let responseByteLimit = 347
    static let modelID = ModelID(UUID(uuidString: "d4b6281a-c00a-4f3d-8e17-731000000001")!)
    static let replacementModelID = ModelID(UUID(uuidString: "d4b6281a-c00a-4f3d-8e17-731000000002")!)
    static let embeddingModelID = DocumentEmbeddingModelID(
        UUID(uuidString: "d4b6281a-c00a-4f3d-8e17-731000000003")!
    )
    static let generationID = GenerationID(
        UUID(uuidString: "d4b6281a-c00a-4f3d-8e17-731000000004")!
    )
    static let modelFingerprint = String(repeating: "a", count: 63) + "7"
    static let replacementFingerprint = String(repeating: "b", count: 63) + "9"

    static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url
    }()

    static func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    static func exactASCII(prefix: String, utf8Bytes: Int, fill: Character = "Q") -> String {
        precondition(prefix.utf8.count <= utf8Bytes)
        return prefix + String(repeating: fill, count: utf8Bytes - prefix.utf8.count)
    }

    static func jsonProbe(encodedByteCount: Int, fill: Character, prefix: String) -> Data {
        let envelopeBytes = #"{"wire":""}"#.utf8.count
        precondition(encodedByteCount >= envelopeBytes + prefix.utf8.count)
        let value = exactASCII(
            prefix: prefix,
            utf8Bytes: encodedByteCount - envelopeBytes,
            fill: fill
        )
        let data = Data(#"{"wire":"\#(value)"}"#.utf8)
        precondition(data.count == encodedByteCount)
        precondition(!value.contains(forbiddenDefault))
        return data
    }
}

private final class ArchitectureUXDecodeProbe: Decodable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedDecodeCount = 0

    let wire: String

    static var decodeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedDecodeCount
    }

    static func reset() {
        lock.lock()
        storedDecodeCount = 0
        lock.unlock()
    }

    init(from decoder: any Decoder) throws {
        Self.lock.lock()
        Self.storedDecodeCount += 1
        Self.lock.unlock()

        let container = try decoder.container(keyedBy: CodingKeys.self)
        wire = try container.decode(String.self, forKey: .wire)
    }

    private enum CodingKeys: String, CodingKey {
        case wire
    }
}

func assertArchitectureUXBudgetViolation(
    _ dimension: RuntimeBudgetDimension,
    limit: Int,
    actual: Int,
    file: StaticString = #filePath,
    line: UInt = #line,
    operation: () throws -> Void
) {
    do {
        try operation()
        XCTFail(
            "Expected \(dimension.rawValue) N+1 budget rejection.",
            file: file,
            line: line
        )
    } catch let violation as RuntimeBudgetViolation {
        XCTAssertEqual(violation.dimension, dimension, file: file, line: line)
        XCTAssertEqual(violation.limit, limit, file: file, line: line)
        XCTAssertEqual(violation.actual, actual, file: file, line: line)
        XCTAssertFalse(
            String(describing: violation).contains(ArchitectureUXRuntimeBudgetWire.forbiddenDefault),
            file: file,
            line: line
        )
    } catch {
        XCTFail("Expected RuntimeBudgetViolation, got \(error).", file: file, line: line)
    }
}
