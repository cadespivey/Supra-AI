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
    /// Accessibility identifier applied to the underlying text view (so XCUITest can
    /// find it as a `textView`). The SwiftUI `.accessibilityIdentifier` modifier lands
    /// on the host group, not the AppKit text view, so it's threaded explicitly.
    var accessibilityID: String? = nil

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

            // AppKit-backed so the text origin is exact: zeroing the text container's
            // line-fragment padding makes the insertion point, typed glyphs, AND the
            // placeholder all start at the same inset (SwiftUI's `TextEditor` leaves a
            // ~5pt glyph padding the empty cursor doesn't share, so they misaligned).
            MultilineTextEditor(
                text: $text,
                inset: CGSize(width: Self.horizontalInset, height: Self.verticalInset),
                accessibilityID: accessibilityID
            )
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

/// A transparent, non-scrolling `NSTextView` for `MultilineField`. The SwiftUI box
/// draws the border/background and the frame drives height (so it never scrolls);
/// this exists only to control the text container insets exactly — `textContainerInset`
/// supplies the padding and `lineFragmentPadding = 0` removes the glyph offset, so the
/// cursor, typed text, and the placeholder overlay all share one origin.
private struct MultilineTextEditor: NSViewRepresentable {
    @Binding var text: String
    var inset: CGSize
    var accessibilityID: String?

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .preferredFont(forTextStyle: .body)
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.focusRingType = .none
        textView.allowsUndo = true
        textView.textContainerInset = inset
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.setAccessibilityIdentifier(accessibilityID)

        // An enclosing scroll view top-anchors the document text within the (taller)
        // min-height frame; scrollers stay off because the SwiftUI frame grows to fit.
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text { textView.string = text }
        textView.textContainerInset = inset
        textView.setAccessibilityIdentifier(accessibilityID)
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }

        /// Tab/Shift-Tab move focus like every other form field — these are
        /// prose fields in FORMS, not code editors, so a literal tab character
        /// has no value and trapping keyboard users in the field is worse.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSTextView.insertTab(_:)):
                textView.window?.selectNextKeyView(nil)
                return true
            case #selector(NSTextView.insertBacktab(_:)):
                textView.window?.selectPreviousKeyView(nil)
                return true
            default:
                return false
            }
        }
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
/// The `.supraField()` surface for GROUPED `Form` rows, where SwiftUI's
/// `TextField` is unavoidably forced to trailing alignment and renders its
/// label inside the row. AppKit-backed (like `LabeledTextField`) so text stays
/// leading; carries the same box + focus accent as `.supraField()`.
struct BoxedLeadingTextField: View {
    let placeholder: String
    @Binding var text: String
    @State private var focused = false

    var body: some View {
        LeadingTextField(text: $text, placeholder: placeholder, onEditingChanged: { focused = $0 })
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        focused ? Color.accentColor.opacity(0.7) : Color(nsColor: .separatorColor),
                        lineWidth: focused ? 1.5 : 1
                    )
            )
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}

struct LabeledTextField: View {
    let label: String
    @Binding var text: String
    var prompt: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
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
    var onEditingChanged: ((Bool) -> Void)? = nil

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

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, onEditingChanged: onEditingChanged) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let text: Binding<String>
        private let onEditingChanged: ((Bool) -> Void)?
        init(text: Binding<String>, onEditingChanged: ((Bool) -> Void)?) {
            self.text = text
            self.onEditingChanged = onEditingChanged
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
        func controlTextDidBeginEditing(_ notification: Notification) { onEditingChanged?(true) }
        func controlTextDidEndEditing(_ notification: Notification) { onEditingChanged?(false) }
    }
}
