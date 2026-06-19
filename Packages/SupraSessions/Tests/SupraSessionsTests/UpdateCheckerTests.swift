import Foundation
@testable import SupraSessions
import SupraStore
import XCTest

final class UpdateCheckerTests: XCTestCase {
    private static let releaseJSON = """
    {
      "tag_name": "v1.2.0",
      "name": "Supra AI 1.2.0",
      "html_url": "https://github.com/cadespivey/Supra-AI/releases/tag/v1.2.0",
      "prerelease": false,
      "assets": [
        { "name": "SupraAI-1.2.0.zip",
          "browser_download_url": "https://github.com/cadespivey/Supra-AI/releases/download/v1.2.0/SupraAI-1.2.0.zip" },
        { "name": "SupraAI-1.2.0.dmg",
          "browser_download_url": "https://github.com/cadespivey/Supra-AI/releases/download/v1.2.0/SupraAI-1.2.0.dmg" }
      ]
    }
    """

    func testIsNewerComparesDottedVersions() {
        XCTAssertTrue(ReleaseUpdateChecker.isNewer("1.2.0", than: "1.1.0"))
        XCTAssertTrue(ReleaseUpdateChecker.isNewer("v1.10.0", than: "1.9.0"))
        XCTAssertFalse(ReleaseUpdateChecker.isNewer("1.1.0", than: "1.1.0"))
        XCTAssertFalse(ReleaseUpdateChecker.isNewer("1.1", than: "1.1.0"))
        XCTAssertFalse(ReleaseUpdateChecker.isNewer("1.0.9", than: "1.1.0"))
    }

    func testEvaluatePrefersDmgAssetForNewerRelease() throws {
        let release = try JSONDecoder().decode(GitHubRelease.self, from: Data(Self.releaseJSON.utf8))
        let update = try XCTUnwrap(ReleaseUpdateChecker.evaluate(release: release, currentVersion: "1.1.0"))
        XCTAssertEqual(update.version, "1.2.0")
        XCTAssertEqual(update.downloadURL?.lastPathComponent, "SupraAI-1.2.0.dmg")
        XCTAssertEqual(update.releaseURL.absoluteString, "https://github.com/cadespivey/Supra-AI/releases/tag/v1.2.0")
    }

    func testPrereleaseIsIgnored() throws {
        let json = #"{"tag_name":"v2.0.0","html_url":"https://x/r","prerelease":true,"assets":[]}"#
        let release = try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
        XCTAssertNil(ReleaseUpdateChecker.evaluate(release: release, currentVersion: "1.1.0"))
    }

    @MainActor
    func testControllerSurfacesNewerRelease() async throws {
        let controller = UpdateController(
            store: try makeStore(),
            currentVersion: "1.1.0",
            fetch: { _ in Data(Self.releaseJSON.utf8) }
        )
        await controller.checkNow()
        XCTAssertEqual(controller.available?.version, "1.2.0")
        XCTAssertNil(controller.statusMessage)
    }

    @MainActor
    func testControllerReportsUpToDate() async throws {
        let controller = UpdateController(
            store: try makeStore(),
            currentVersion: "1.2.0",
            fetch: { _ in Data(Self.releaseJSON.utf8) }
        )
        await controller.checkNow()
        XCTAssertNil(controller.available)
        XCTAssertEqual(controller.statusMessage, "You're on the latest version (1.2.0).")
    }

    @MainActor
    func testControllerSurfacesFetchError() async throws {
        struct Boom: Error {}
        let controller = UpdateController(
            store: try makeStore(),
            currentVersion: "1.1.0",
            fetch: { _ in throw Boom() }
        )
        await controller.checkNow()
        XCTAssertNil(controller.available)
        XCTAssertTrue(controller.statusMessage?.hasPrefix("Couldn't check for updates") ?? false)
    }

    private func makeStore() throws -> SupraStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateCheckerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try SupraStore(url: dir.appendingPathComponent("test.sqlite"))
    }
}
