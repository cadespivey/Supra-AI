import Foundation
@testable import SupraSessions
import XCTest

/// Gating tests for the byte-accurate download progress value the Models module
/// renders (fill fraction + MB/s text).
///
/// EXPECTED RED (pre-implementation): `ModelDownloadProgress` does not exist, so
/// this suite fails to build — that compile failure is the observable RED state.
final class ModelDownloadProgressTests: XCTestCase {

    private func makeProgress(
        bytesReceived: Int64,
        totalBytes: Int64,
        bytesPerSecond: Double? = nil
    ) -> ModelDownloadProgress {
        ModelDownloadProgress(
            completedFiles: 1,
            totalFiles: 3,
            currentFile: "model.safetensors",
            bytesReceived: bytesReceived,
            totalBytes: totalBytes,
            bytesPerSecond: bytesPerSecond
        )
    }

    func testFractionCompleted() {
        // Unknown total (defensive; manifests always carry sizes) → empty bar,
        // never NaN and never a full bar for an unstarted download.
        XCTAssertEqual(makeProgress(bytesReceived: 0, totalBytes: 0).fractionCompleted, 0)
        XCTAssertEqual(makeProgress(bytesReceived: 500, totalBytes: 1000).fractionCompleted, 0.5)
        // Over-reporting (e.g. a re-verified file counted while a redownload is
        // in flight) clamps rather than overflowing the bar.
        XCTAssertEqual(makeProgress(bytesReceived: 1500, totalBytes: 1000).fractionCompleted, 1)
    }

    func testSpeedTextFormatsDecimalMegabytesPerSecond() {
        XCTAssertNil(makeProgress(bytesReceived: 0, totalBytes: 1, bytesPerSecond: nil).speedText)
        XCTAssertEqual(
            makeProgress(bytesReceived: 0, totalBytes: 1, bytesPerSecond: 12_345_678).speedText,
            "12.3 MB/s"
        )
        // Sub-megabyte rates keep one decimal instead of rounding to zero-ish noise.
        XCTAssertEqual(
            makeProgress(bytesReceived: 0, totalBytes: 1, bytesPerSecond: 400_000).speedText,
            "0.4 MB/s"
        )
        XCTAssertEqual(
            makeProgress(bytesReceived: 0, totalBytes: 1, bytesPerSecond: 0).speedText,
            "0.0 MB/s"
        )
    }
}
