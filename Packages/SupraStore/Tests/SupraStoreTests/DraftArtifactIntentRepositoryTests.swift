import Foundation
@testable import SupraStore
import XCTest

final class DraftArtifactIntentRepositoryTests: XCTestCase {
    func testTDAI02FinalizationHashesInstalledBytesAndIsIdempotent() throws {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Synthetic artifact matter")
        let expected = Data("expected bytes".utf8)
        let intent = try store.draftArtifacts.prepareGenericIntent(
            matterID: matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Synthetic-draft.md",
            output: expected,
            id: "synthetic-artifact-intent"
        )

        XCTAssertThrowsError(
            try store.draftArtifacts.finalizeIntent(
                id: intent.id,
                installedOutput: Data("replaced bytes".utf8)
            )
        ) { error in
            XCTAssertEqual(error as? DraftArtifactIntentError, .installedArtifactMismatch)
        }
        XCTAssertTrue(try store.auditEvents.fetchEvents(matterID: matter.id).isEmpty)
        XCTAssertEqual(
            try store.draftArtifacts.intent(id: intent.id)?.status,
            DraftArtifactIntentStatus.prepared.rawValue
        )

        try store.draftArtifacts.finalizeIntent(id: intent.id, installedOutput: expected)
        try store.draftArtifacts.finalizeIntent(id: intent.id, installedOutput: expected)
        XCTAssertEqual(
            try store.auditEvents.fetchEvents(matterID: matter.id)
                .filter { $0.eventType == "draft_generated" }.count,
            1
        )
    }

    func testTDAI03OnlyPreparedIntentReservesFileName() throws {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Synthetic reservation matter")
        let output = Data("draft".utf8)
        let first = try store.draftArtifacts.prepareGenericIntent(
            matterID: matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Reusable.md",
            output: output,
            id: "first-reservation"
        )
        XCTAssertThrowsError(
            try store.draftArtifacts.prepareGenericIntent(
                matterID: matter.id,
                artifactKind: .customDescription,
                format: .markdown,
                fileName: "Reusable.md",
                output: output,
                id: "competing-reservation"
            )
        ) { error in
            XCTAssertEqual(error as? DraftArtifactIntentError, .fileNameReserved)
        }

        try store.draftArtifacts.abortIntent(id: first.id)
        let replacement = try store.draftArtifacts.prepareGenericIntent(
            matterID: matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Reusable.md",
            output: output,
            id: "replacement-reservation"
        )
        XCTAssertEqual(replacement.status, DraftArtifactIntentStatus.prepared.rawValue)
    }
}
