import Foundation
import SupraSessions
import XCTest

/// T-WORK-CONTEXT-01. Every cross-surface handoff carries one explicit,
/// version-bound context. The destination may not rebuild it from the selected
/// matter, a current source set, or another process-global default.
///
/// Expected RED: the compact `WorkContext` exists for setup return, but there is
/// no typed `WorkHandoffRequest` / `WorkSurface` boundary covering the remaining
/// named workflows.
final class ArchitectureUXTWorkContext01Tests: XCTestCase {
    private enum Wire {
        static let matterID = "matter-713"
        static let sourceSetID = "source-719"
        static let sourceSetVersion = 7
        static let authorityPacketID = "packet-727"
        static let authorityPacketVersion = 11
        static let workProductID = "work-product-729"
        static let workProductVersion = 13
        static let checkpointID = "checkpoint-733"
        static let forbiddenDefault = "DEFAULT-000"
    }

    func testNamedHandoffsRoundTripOneExactNonDefaultContext() throws {
        let context = WorkContext(
            matterID: Wire.matterID,
            intent: .draftMotion,
            sourceSet: VersionedWorkReference(
                id: Wire.sourceSetID,
                version: Wire.sourceSetVersion
            ),
            authorityPacket: VersionedWorkReference(
                id: Wire.authorityPacketID,
                version: Wire.authorityPacketVersion
            ),
            workProduct: VersionedWorkReference(
                id: Wire.workProductID,
                version: Wire.workProductVersion
            ),
            returnDestination: .matterTask(
                matterID: Wire.matterID,
                intent: .draftMotion
            ),
            checkpointID: Wire.checkpointID
        )

        let routes: [(String, WorkSurface, WorkSurface)] = [
            ("documents-to-ask-739", .documents, .ask),
            ("chat-to-research-743", .chat, .research),
            ("research-to-authorities-751", .research, .authorities),
            ("authorities-to-new-work-757", .authorities, .newWorkProduct),
            ("quick-attachment-to-matter-761", .quickAttachment, .documents),
            ("saved-work-to-check-sources-769", .savedWork, .checkSources),
            ("public-records-to-matter-773", .publicRecords, .documents),
        ]
        let requests = routes.map { id, origin, destination in
            WorkHandoffRequest(
                id: id,
                origin: origin,
                destination: destination,
                context: context
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(requests)
        let decoded = try JSONDecoder().decode(
            [WorkHandoffRequest].self,
            from: data
        )

        XCTAssertEqual(decoded, requests)
        XCTAssertEqual(Set(decoded.map(\.id)).count, routes.count)
        XCTAssertEqual(decoded.map(\.origin), routes.map(\.1))
        XCTAssertEqual(decoded.map(\.destination), routes.map(\.2))
        for request in decoded {
            XCTAssertEqual(request.context.matterID, Wire.matterID, request.id)
            XCTAssertEqual(request.context.intent, .draftMotion, request.id)
            XCTAssertEqual(request.context.sourceSet?.id, Wire.sourceSetID, request.id)
            XCTAssertEqual(
                request.context.sourceSet?.version,
                Wire.sourceSetVersion,
                request.id
            )
            XCTAssertEqual(
                request.context.authorityPacket?.id,
                Wire.authorityPacketID,
                request.id
            )
            XCTAssertEqual(
                request.context.authorityPacket?.version,
                Wire.authorityPacketVersion,
                request.id
            )
            XCTAssertEqual(request.context.workProduct?.id, Wire.workProductID, request.id)
            XCTAssertEqual(
                request.context.workProduct?.version,
                Wire.workProductVersion,
                request.id
            )
            XCTAssertEqual(request.context.checkpointID, Wire.checkpointID, request.id)
        }

        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        for exactWire in [
            Wire.matterID,
            Wire.sourceSetID,
            String(Wire.sourceSetVersion),
            Wire.authorityPacketID,
            String(Wire.authorityPacketVersion),
            Wire.workProductID,
            String(Wire.workProductVersion),
            Wire.checkpointID,
        ] {
            XCTAssertTrue(encoded.contains(exactWire), exactWire)
        }
        XCTAssertFalse(encoded.contains(Wire.forbiddenDefault))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("current matter"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("default route"))
    }

    func testUnknownSurfaceAndMissingIdentityFailClosed() throws {
        XCTAssertNil(WorkSurface(rawValue: "DEFAULT-000"))

        let malformed = #"{"id":"","origin":"documents","destination":"ask","context":{}}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                WorkHandoffRequest.self,
                from: Data(malformed.utf8)
            )
        )
    }
}
