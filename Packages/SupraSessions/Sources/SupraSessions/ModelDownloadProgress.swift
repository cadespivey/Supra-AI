import Foundation

/// Byte-accurate snapshot of a managed model download, published on every
/// progress emission so the UI can fill its bar by percentage, show a live
/// MB/s rate, and caption the file being transferred.
public struct ModelDownloadProgress: Equatable, Sendable {
    /// Files fully downloaded and hash-verified (includes files reused from an
    /// interrupted earlier run).
    public var completedFiles: Int
    public var totalFiles: Int
    /// The most recently finished file — with up to four transfers in flight
    /// there is no single "current" file, so captions should read this as
    /// recent activity, not an exact position.
    public var currentFile: String
    /// Verified bytes on disk plus bytes reported for in-flight transfers.
    public var bytesReceived: Int64
    /// Sum of every manifest artifact's size; known before transfer starts.
    public var totalBytes: Int64
    /// Sliding-window transfer rate; nil until enough samples span the window.
    public var bytesPerSecond: Double?

    public init(
        completedFiles: Int,
        totalFiles: Int,
        currentFile: String,
        bytesReceived: Int64,
        totalBytes: Int64,
        bytesPerSecond: Double? = nil
    ) {
        self.completedFiles = completedFiles
        self.totalFiles = totalFiles
        self.currentFile = currentFile
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
    }

    /// Fill fraction for a determinate progress bar. Defensive about a zero
    /// total (never NaN, never a full bar for an unstarted download) and about
    /// over-reporting (clamps at 1).
    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(bytesReceived) / Double(totalBytes))
    }

    /// Human-readable rate in decimal megabytes per second ("12.3 MB/s"),
    /// the convention download UIs use; nil while the rate is unmeasured.
    public var speedText: String? {
        guard let bytesPerSecond else { return nil }
        return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
    }
}

/// Sliding-window byte-rate estimator behind the MB/s indicator. Pure value
/// logic over caller-supplied timestamps so tests drive it deterministically.
public struct DownloadRateTracker: Sendable {
    private var samples: [(time: TimeInterval, bytes: Int64)] = []
    private let window: TimeInterval
    private let minimumSpan: TimeInterval

    public init(window: TimeInterval = 4, minimumSpan: TimeInterval = 0.5) {
        self.window = window
        self.minimumSpan = minimumSpan
    }

    /// Records a cumulative byte count at a (monotonic) timestamp and returns
    /// the windowed average rate, or nil while the window is too thin to be
    /// meaningful. A cumulative count lower than the previous sample means a
    /// failed file restarted from zero under concurrency — the tracker resets
    /// rather than ever reporting a negative rate.
    public mutating func record(bytes: Int64, at time: TimeInterval) -> Double? {
        if let last = samples.last, bytes < last.bytes {
            samples.removeAll(keepingCapacity: true)
        }
        samples.append((time: time, bytes: bytes))
        samples.removeAll { time - $0.time > window }
        guard samples.count >= 2, let first = samples.first else { return nil }
        let span = time - first.time
        guard span >= minimumSpan else { return nil }
        return Double(bytes - first.bytes) / span
    }
}
