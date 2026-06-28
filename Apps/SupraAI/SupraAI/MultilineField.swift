import AppKit
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

/// A captioned, full-width, left-aligned bordered single-line field — the unified
/// style for prose-form text entry. A bare `TextField` row in a grouped form is
/// right-aligned and reads as an unlabeled value; this keeps the label visible and the
/// text flowing naturally from the left. Shared across Settings, Edit Matter, and
/// drafting (spec §9.3).
struct LabeledTextField: View {
    let label: String
    @Binding var text: String
    var prompt: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            LeadingTextField(text: $text, placeholder: prompt ?? "")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        }
    }
}

/// An AppKit-backed single-line text field that stays LEFT-aligned even inside a
/// grouped `Form`, where SwiftUI's `TextField` is unavoidably forced to trailing
/// alignment. Borderless/transparent so the SwiftUI wrapper draws the box.
struct LeadingTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.alignment = .left
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .preferredFont(forTextStyle: .body)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
        nsView.placeholderString = placeholder
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
