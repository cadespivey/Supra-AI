import SupraSessions
import SwiftUI

/// Shared indicator for managed model downloads: a determinate bar filled by
/// byte fraction, a percent · speed · files caption, and (where the hosting
/// surface allows aborting) a ghost-danger Cancel affordance. Used by the
/// Models pane, the download sheet, the embedding setup section, and onboarding
/// so every download in the app reads identically.
struct DownloadProgressRow: View {
    let progress: ModelDownloadProgress
    /// Shown above the bar when the surface doesn't already name the download.
    var title: String?
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let title {
                Text(title)
                    .font(.supraCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 10) {
                ProgressView(value: progress.fractionCompleted)
                if let onCancel {
                    Button("Cancel", role: .cancel, action: onCancel)
                        .buttonStyle(.ghostDanger)
                }
            }
            Text(caption)
                .font(.supraCaption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var caption: String {
        var parts = ["\(Int((progress.fractionCompleted * 100).rounded()))%"]
        if let speed = progress.speedText { parts.append(speed) }
        parts.append("\(progress.completedFiles)/\(progress.totalFiles) files")
        var text = parts.joined(separator: " · ")
        // The most recently finished file (transfers run 4-wide, so this is
        // recent activity rather than a single in-flight position).
        if !progress.currentFile.isEmpty { text += " — \(progress.currentFile)" }
        return text
    }
}
