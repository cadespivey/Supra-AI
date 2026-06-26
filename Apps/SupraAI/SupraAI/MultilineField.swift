import SwiftUI

/// A bordered, auto-growing multi-line text field for prose entry in forms.
///
/// Backed by `TextEditor` (not `TextField(axis: .vertical)`, which on macOS commits —
/// and reselects — on the Return key instead of inserting a newline), so Return
/// inserts a line break the way users expect when typing instructions, style notes,
/// or "one per line" lists. It starts at `minLines` (≈3) and grows to fit the text
/// entered. A placeholder overlay stands in for the prompt `TextEditor` lacks.
struct MultilineField: View {
    let placeholder: String
    @Binding var text: String
    /// The collapsed height, in lines of body text. The field grows beyond this to
    /// fit longer input.
    var minLines: Int = 3

    @State private var contentHeight: CGFloat = 0

    private static let lineHeight: CGFloat = 17
    private static let horizontalInset: CGFloat = 6
    private static let verticalInset: CGFloat = 8
    private var minHeight: CGFloat { CGFloat(minLines) * Self.lineHeight + Self.verticalInset * 2 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // An invisible mirror of the content, laid out at the editor's text width;
            // its intrinsic height drives the editor's frame so the field grows to fit.
            Text(text.isEmpty ? placeholder : text)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Self.horizontalInset)
                .padding(.vertical, Self.verticalInset)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: HeightKey.self, value: geometry.size.height)
                })
                .hidden()

            if text.isEmpty {
                Text(placeholder)
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, Self.horizontalInset)
                    .padding(.vertical, Self.verticalInset)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                // Offsets `NSTextView`'s built-in ~5pt inset so the editor's text lines
                // up with the placeholder/sizer above.
                .padding(.horizontal, Self.horizontalInset - 5)
                .frame(height: max(minHeight, contentHeight))
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
        .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
    }
}

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
