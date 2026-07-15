import Foundation
@testable import SupraSessions
import XCTest

/// Gating tests for the download speed tracker backing the Models module's
/// MB/s indicator.
///
/// EXPECTED RED (pre-implementation): `DownloadRateTracker` does not exist, so
/// this suite fails to build — that compile failure is the observable RED state
/// for a not-yet-existing type (runtime-red is impossible for absent symbols).
final class DownloadRateTrackerTests: XCTestCase {

    func testNoSpeedUntilWindowSpansSamples() {
        var tracker = DownloadRateTracker()
        // A single sample has no elapsed span to divide over.
        XCTAssertNil(tracker.record(bytes: 0, at: 100.0))
        // A second sample only 0.1s later is below the 0.5s minimum span.
        XCTAssertNil(tracker.record(bytes: 1_000_000, at: 100.1))
    }

    func testSteadySpeedAveragesOverWindow() {
        var tracker = DownloadRateTracker()
        _ = tracker.record(bytes: 0, at: 100.0)
        // 10 MB every second — steady 10 MB/s.
        var speed: Double?
        for second in 1...5 {
            speed = tracker.record(
                bytes: Int64(second) * 10_000_000,
                at: 100.0 + Double(second)
            )
        }
        let unwrapped = try! XCTUnwrap(speed)
        XCTAssertEqual(unwrapped, 10_000_000, accuracy: 500_000)

        // The window slides: after a burst of faster samples the average tracks
        // the recent rate, not the all-time mean.
        var recent: Double?
        for second in 6...12 {
            recent = tracker.record(
                bytes: 50_000_000 + Int64(second - 5) * 20_000_000,
                at: 100.0 + Double(second)
            )
        }
        XCTAssertEqual(try! XCTUnwrap(recent), 20_000_000, accuracy: 1_000_000)
    }

    func testStallDecaysToZero() {
        var tracker = DownloadRateTracker()
        _ = tracker.record(bytes: 0, at: 100.0)
        _ = tracker.record(bytes: 10_000_000, at: 101.0)
        // No new bytes for a stretch — the indicator must read 0, not stay stuck
        // at the last healthy rate and not go nil (the download is still active).
        var speed: Double?
        for second in 2...8 {
            speed = tracker.record(bytes: 10_000_000, at: 100.0 + Double(second))
        }
        XCTAssertEqual(try! XCTUnwrap(speed), 0, accuracy: 0.001)
    }

    func testByteRegressionResetsWithoutNegativeSpeed() {
        var tracker = DownloadRateTracker()
        _ = tracker.record(bytes: 0, at: 100.0)
        _ = tracker.record(bytes: 30_000_000, at: 101.0)
        // A failed file restarts from zero for that artifact, so the aggregate
        // can go backwards. The tracker must reset rather than report a negative
        // rate; whatever it reports next must be >= 0 (nil is also acceptable).
        let after = tracker.record(bytes: 5_000_000, at: 102.0)
        if let after {
            XCTAssertGreaterThanOrEqual(after, 0)
        }
        let recovered = tracker.record(bytes: 15_000_000, at: 103.0)
        if let recovered {
            XCTAssertGreaterThanOrEqual(recovered, 0)
        }
    }
}
