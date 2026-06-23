import SwiftUI

/// A bordered multi-line text field for prose entry in forms.
///
/// Unlike `TextField(axis: .vertical)` — which on macOS commits (and reselects) on
/// the Return key instead of inserting a newline — this is backed by `TextEditor`,
/// so Return inserts a line break the way users expect when typing instructions,
/// style notes, or citation rules. A placeholder overlay stands in for the
/// `TextField` prompt the editor doesn't natively provide.
struct MultilineField: View {
    let placeholder: String
    @Binding var text: String
    var minHeight: CGFloat = 72

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .frame(minHeight: minHeight)
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor))
            )
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
    }
}
