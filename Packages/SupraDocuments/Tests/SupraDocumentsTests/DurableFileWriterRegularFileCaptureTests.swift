import Darwin
import Foundation
@testable import SupraDocuments
import XCTest

final class DurableFileWriterRegularFileCaptureTests: XCTestCase {
    // ACR-FILE-041. Expected runtime RED at 40a731a7's committed baseline:
    // relaunch identity capture accepts a FIFO as though it were an installed
    // regular artifact. Nonblocking keeper descriptors make the test immune to
    // an implementation that opens the FIFO for reading before checking mode.
    func testACRFILE041ManagedIdentityCaptureRejectsFIFOWithoutDeletingIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Supra-Regular-Capture-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent("matter-123", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let fifo = parent.appendingPathComponent("artifact.md")
        XCTAssertEqual(fifo.path.withCString { Darwin.mkfifo($0, S_IRUSR | S_IWUSR) }, 0)

        let reader = fifo.path.withCString {
            Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        }
        XCTAssertGreaterThanOrEqual(reader, 0)
        defer { if reader >= 0 { Darwin.close(reader) } }
        let writerKeeper = fifo.path.withCString {
            Darwin.open($0, O_WRONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        }
        XCTAssertGreaterThanOrEqual(writerKeeper, 0)
        defer { if writerKeeper >= 0 { Darwin.close(writerKeeper) } }

        var before = stat()
        XCTAssertEqual(fifo.path.withCString { Darwin.lstat($0, &before) }, 0)
        XCTAssertEqual(before.st_mode & S_IFMT, S_IFIFO)

        XCTAssertThrowsError(
            try DurableFileWriter().installedFileIdentity(
                at: fifo,
                containedIn: root
            )
        ) { error in
            XCTAssertEqual(
                error as? DurableFileWriter.WriterError,
                .fileIdentityInspectionFailed(EFTYPE)
            )
        }

        var after = stat()
        XCTAssertEqual(fifo.path.withCString { Darwin.lstat($0, &after) }, 0)
        XCTAssertEqual(after.st_mode & S_IFMT, S_IFIFO)
        XCTAssertEqual(after.st_dev, before.st_dev)
        XCTAssertEqual(after.st_ino, before.st_ino)
        XCTAssertEqual(after.st_gen, before.st_gen)
    }
}
