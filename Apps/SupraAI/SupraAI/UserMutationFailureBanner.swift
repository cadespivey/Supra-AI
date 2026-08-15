import SupraSessions
import SwiftUI

/// A compact, content-safe failure presentation shared by mutation surfaces.
///
/// This view owns no workflow state. Feature views provide the exact retry and
/// correction closures so a failure can never escape its original matter,
/// folder, draft, version, or destination.
struct UserMutationFailureBanner: View {
    let failure: UserMutationFailure
    let retry: () -> Void
    let correct: (() -> Void)?

    @AccessibilityFocusState private var failureFocused: Bool
    @State private var showTechnicalDetails = false

    init(
        failure: UserMutationFailure,
        retry: @escaping () -> Void,
        correct: (() -> Void)? = nil
    ) {
        self.failure = failure
        self.retry = retry
        self.correct = correct
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.orange)
                .frame(width: 3)
                .accessibilityHidden(true)

            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Change not saved")
                    .font(.callout.weight(.semibold))
                Text(failure.userMessage)
                    .font(.supraCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let technicalDetails = failure.technicalDetails,
                   !technicalDetails.isEmpty {
                    DisclosureGroup("Technical Details", isExpanded: $showTechnicalDetails) {
                        Text(technicalDetails)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("mutation.failure.technicalDetails")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if failure.recoveryActions.contains(.retry) {
                Button("Retry") { retry() }
                    .buttonStyle(.ghost)
                    .accessibilityIdentifier(
                        "mutation.failure.retry.\(failure.operation.rawValue)"
                    )
            }
            if failure.recoveryActions.contains(.correctInput), let correct {
                Button("Correct") { correct() }
                    .buttonStyle(.ghost)
                    .accessibilityIdentifier(
                        "mutation.failure.correct.\(failure.operation.rawValue)"
                    )
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.orange.opacity(0.09),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mutation.failure.\(failure.operation.rawValue)")
        .accessibilityLabel("Change not saved")
        .accessibilityValue(failure.userMessage)
        .accessibilityFocused($failureFocused)
        .onAppear { failureFocused = true }
        .onChange(of: failure.userMessage) { _, _ in failureFocused = true }
    }
}
