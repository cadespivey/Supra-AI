import Foundation
import SupraRuntimeInterface
import XCTest

/// T-STREAM-BUFFER-01 RED: the host retains every event for retained generations
/// and the client forwards every token event directly. There is no byte-bounded
/// replay/UI/persistence buffer, deterministic reconnect dedupe, coalescing
/// window, or one-shot exact terminal join shared by completion and cancellation.
final class ArchitectureUXTStreamBuffer01Tests: XCTestCase {
    private let forbiddenDefault = "DEFAULT-000"

    func testBoundedCoalescingProducesExactOutputAcrossEveryTerminalPath() throws {
        let completion = try run(.completion)
        let cancellation = try run(.cancellation)
        let reconnect = try run(.reconnect)
        let terminalFlush = try run(.terminalFlush)
        let receipts = [completion, cancellation, reconnect, terminalFlush]
        let expected = Data(ArchitectureUXRuntimeBudgetWire.streamBuffer.utf8)

        for receipt in receipts {
            XCTAssertEqual(receipt.wireID, "T_STREAM_BUFFER_01_WIRE_731")
            XCTAssertEqual(receipt.modelArtifactID, "model-wire-713")
            XCTAssertEqual(receipt.modelRevision, "rev-7")
            XCTAssertEqual(receipt.finalOutputUTF8, expected)
            XCTAssertEqual(
                receipt.coalescedUIChunks.joined(),
                ArchitectureUXRuntimeBudgetWire.streamBuffer
            )
            XCTAssertEqual(join(receipt.persistenceBatches), expected)
            XCTAssertLessThanOrEqual(receipt.retainedReplayEventCount, 3)
            XCTAssertLessThanOrEqual(receipt.retainedReplayEncodedBytes, 733)
            XCTAssertLessThanOrEqual(receipt.maximumUIChunkUTF8Bytes, 19)
            XCTAssertLessThanOrEqual(receipt.maximumPersistenceBatchUTF8Bytes, 23)
            XCTAssertLessThan(
                receipt.coalescedUIChunks.count,
                tokenChunks.count,
                "the 7 ms / 19-byte non-default policy must coalesce at least one adjacent pair"
            )
            XCTAssertFalse(
                String(decoding: receipt.finalOutputUTF8, as: UTF8.self)
                    .contains(forbiddenDefault)
            )
        }

        XCTAssertEqual(completion.finalOutputUTF8, cancellation.finalOutputUTF8)
        XCTAssertEqual(completion.finalOutputUTF8, reconnect.finalOutputUTF8)
        XCTAssertEqual(completion.finalOutputUTF8, terminalFlush.finalOutputUTF8)
        XCTAssertEqual(completion.terminalEventType, .generationCompleted)
        XCTAssertEqual(cancellation.terminalEventType, .generationCancelled)
        XCTAssertEqual(reconnect.terminalEventType, .generationCompleted)
        XCTAssertEqual(terminalFlush.terminalEventType, .generationCompleted)
    }

    func testReplayEventCountAdmitsNAndCompactsNPlusOneToTerminalMetadataPlusTail() throws {
        var buffer = RuntimeGenerationStreamBuffer(policy: streamPolicy())
        let events = streamEvents(terminalType: .generationCompleted)
        for event in events.prefix(3) {
            try buffer.ingest(event)
        }
        let atN = buffer.snapshot
        XCTAssertEqual(atN.retainedReplayEventCount, 3)

        try buffer.ingest(events[3])
        let afterNPlusOne = buffer.snapshot
        XCTAssertEqual(afterNPlusOne.retainedReplayEventCount, 3)
        XCTAssertFalse(afterNPlusOne.retainedSequenceNumbers.contains(events[0].sequenceNumber))
        XCTAssertEqual(afterNPlusOne.retainedSequenceNumbers, [2, 3, 4])
        XCTAssertLessThanOrEqual(afterNPlusOne.retainedReplayEncodedBytes, 733)
        XCTAssertFalse(
            ArchitectureUXRuntimeBudgetWire.streamBuffer
                .contains(forbiddenDefault)
        )
    }

    func testClientUsesOneBufferAndTerminalJoinDoesNotCopyTheFullStringPerToken() throws {
        let client = try ArchitectureUXRuntimeBudgetWire.source(
            "Packages/SupraRuntimeClient/Sources/SupraRuntimeClient/RuntimeClient.swift"
        )
        let buffer = try ArchitectureUXRuntimeBudgetWire.source(
            "Packages/SupraRuntimeClient/Sources/SupraRuntimeClient/RuntimeGenerationStreamBuffer.swift"
        )
        let hostReplay = try ArchitectureUXRuntimeBudgetWire.source(
            "Apps/SupraAI/SupraRuntimeService/GenerationEventBuffer.swift"
        )

        XCTAssertTrue(client.contains("RuntimeGenerationStreamBuffer"))
        XCTAssertTrue(client.contains("terminalFlush"))
        XCTAssertTrue(buffer.contains("tokenSegments.append("))
        XCTAssertTrue(buffer.contains("tokenSegments.joined()"))
        XCTAssertFalse(buffer.contains("finalOutput +="))
        XCTAssertTrue(hostReplay.contains("RuntimeStreamBufferPolicy"))
        XCTAssertTrue(hostReplay.contains("compactReplayIfNeeded"))
        XCTAssertTrue(hostReplay.contains("retainedReplayEncodedBytes"))
        XCTAssertFalse(client.contains(forbiddenDefault))
        XCTAssertFalse(buffer.contains(forbiddenDefault))
        XCTAssertFalse(hostReplay.contains(forbiddenDefault))
    }

    private enum Path {
        case completion
        case cancellation
        case reconnect
        case terminalFlush
    }

    private var tokenChunks: [String] {
        ["T_STREAM_", "BUFFER_01_", "WIRE_731|", "model-wire-713|", "rev-7"]
    }

    private func streamPolicy() -> RuntimeStreamBufferPolicy {
        RuntimeStreamBufferPolicy(
            wireID: "T_STREAM_BUFFER_01_WIRE_731",
            modelArtifactID: "model-wire-713",
            modelRevision: "rev-7",
            maxReplayEventCount: 3,
            maxReplayEncodedBytes: 733,
            maxUIChunkUTF8Bytes: 19,
            maxPersistenceBatchUTF8Bytes: 23,
            coalescingWindow: .milliseconds(7),
            coalescingUTF8Bytes: 19
        )
    }

    private func run(_ path: Path) throws -> RuntimeStreamFlushReceipt {
        var buffer = RuntimeGenerationStreamBuffer(policy: streamPolicy())
        switch path {
        case .completion:
            for event in streamEvents(terminalType: .generationCompleted) {
                try buffer.ingest(event)
            }
            return try buffer.flush(.completion)

        case .cancellation:
            for event in streamEvents(terminalType: .generationCancelled) {
                try buffer.ingest(event)
            }
            return try buffer.flush(.cancellation)

        case .reconnect:
            let events = streamEvents(terminalType: .generationCompleted)
            for event in events.prefix(3) {
                try buffer.ingest(event)
            }
            try buffer.ingestReplay(Array(events.dropFirst(2)))
            return try buffer.flush(.reconnect)

        case .terminalFlush:
            for event in streamEvents(terminalType: .generationCompleted).dropLast() {
                try buffer.ingest(event)
            }
            return try buffer.flush(.terminal(.generationCompleted))
        }
    }

    private func streamEvents(terminalType: GenerationEventType) -> [GenerationEvent] {
        let base = Date(timeIntervalSince1970: 1_947_731_000)
        var events = [
            architectureUXEvent(
                sequence: 1,
                type: .token,
                token: tokenChunks[0],
                timestamp: base
            ),
            architectureUXEvent(
                sequence: 2,
                type: .token,
                token: tokenChunks[1],
                timestamp: base.addingTimeInterval(0.006)
            ),
            architectureUXEvent(
                sequence: 3,
                type: .token,
                token: tokenChunks[2],
                timestamp: base.addingTimeInterval(0.014)
            ),
            architectureUXEvent(
                sequence: 4,
                type: .token,
                token: tokenChunks[3],
                timestamp: base.addingTimeInterval(0.021)
            ),
            architectureUXEvent(
                sequence: 5,
                type: .token,
                token: tokenChunks[4],
                timestamp: base.addingTimeInterval(0.029)
            ),
        ]
        events.append(
            architectureUXEvent(
                sequence: 6,
                type: terminalType,
                message: terminalType == .generationCancelled ? "cancelled-wire-743" : nil,
                timestamp: base.addingTimeInterval(0.031)
            )
        )
        return events
    }

    private func join(_ batches: [Data]) -> Data {
        batches.reduce(into: Data()) { result, batch in
            result.append(batch)
        }
    }
}
