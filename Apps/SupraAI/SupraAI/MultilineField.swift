import AppKit
import SwiftUI

/// Deterministic top-to-bottom Tab order for AppKit-backed fields hosted in
/// SwiftUI. The window's auto-recalculated key-view loop follows hosting-view
/// geometry, which does NOT reliably match the visual form order, so forms that
/// care register each entry field with an explicit order. Native controls outside
/// the chain keep their normal key-loop behavior after the first/last field.
@MainActor
final class SupraFocusChain {
    private struct Entry {
        weak var view: NSView?
        let order: Int
        let identifier: String?
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var installedInitialFocus = false
    var onFocusChange: ((String?) -> Void)?

    func register(_ view: NSView, at order: Int, identifier: String? = nil) {
        entries[ObjectIdentifier(view)] = Entry(view: view, order: order, identifier: identifier)
        // The window pointer is nil until the view lands in the hierarchy —
        // finish the window-level setup on the next runloop turn.
        DispatchQueue.main.async { [weak self] in self?.installInitialFocusIfPossible() }
    }

    func unregister(_ view: NSView) {
        entries.removeValue(forKey: ObjectIdentifier(view))
    }

    @discardableResult
    func focusNext(after view: NSView) -> Bool {
        focus(from: view, offset: 1)
    }

    @discardableResult
    func focusPrevious(before view: NSView) -> Bool {
        focus(from: view, offset: -1)
    }

    func noteFocused(_ view: NSView) {
        onFocusChange?(entry(for: view)?.identifier)
    }

    func noteFirstRegisteredControl() {
        onFocusChange?(orderedEntries().first?.identifier)
    }

    private func focus(from view: NSView, offset: Int) -> Bool {
        let ordered = orderedEntries()
        guard let current = ordered.firstIndex(where: { $0.view === view }) else { return false }
        let nextIndex = current + offset
        guard ordered.indices.contains(nextIndex) else { return false }
        guard let window = view.window ?? ordered[nextIndex].view.window else { return false }
        let didFocus = window.makeFirstResponder(ordered[nextIndex].view)
        if didFocus {
            onFocusChange?(ordered[nextIndex].identifier)
        }
        return didFocus
    }

    private func orderedEntries() -> [(view: NSView, order: Int, identifier: String?)] {
        entries = entries.filter { $0.value.view != nil }
        return entries.values.compactMap { entry in
            guard let view = entry.view else { return nil }
            return (view, entry.order, entry.identifier)
        }
        .sorted { lhs, rhs in
            if lhs.order == rhs.order {
                return ObjectIdentifier(lhs.view).hashValue < ObjectIdentifier(rhs.view).hashValue
            }
            return lhs.order < rhs.order
        }
    }

    private func entry(for view: NSView) -> Entry? {
        entries = entries.filter { $0.value.view != nil }
        return entries[ObjectIdentifier(view)]
    }

    /// Focuses the first registered field once the hosting window exists.
    /// Idempotent (latched) and safe to call from several triggers —
    /// register-time async AND the host view's `onAppear` — because the
    /// register-time call can fire before the window is attached on slower
    /// presentations, and `onAppear` is the reliable "window is ready" signal.
    func installInitialFocusIfPossible() {
        guard !installedInitialFocus else { return }
        guard let first = orderedEntries().first, let window = first.view.window else { return }
        installedInitialFocus = true
        window.initialFirstResponder = first.view
        // Never yank focus away from a registered field the user reached
        // first (a late-firing trigger must not steal it). The field editor of
        // an NSTextField is a descendant of the field, so cover both.
        let responder = window.firstResponder as? NSView
        let alreadyInChain = orderedEntries().contains { entry in
            responder === entry.view || responder?.isDescendant(of: entry.view) == true
        }
        guard !alreadyInChain else { return }
        if window.firstResponder !== first.view {
            window.makeFirstResponder(first.view)
        }
        onFocusChange?(first.identifier)
    }
}

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
    var focusChain: SupraFocusChain? = nil
    var focusOrder: Int = 0
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
                accessibilityID: accessibilityID,
                focusChain: focusChain,
                focusOrder: focusOrder
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
    var focusChain: SupraFocusChain? = nil
    var focusOrder: Int = 0

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
        context.coordinator.focusChain = focusChain
        focusChain?.register(textView, at: focusOrder, identifier: accessibilityID)

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
        context.coordinator.focusChain = focusChain
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        if let textView = scrollView.documentView as? NSTextView {
            coordinator.focusChain?.unregister(textView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, focusChain: focusChain) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        var focusChain: SupraFocusChain?

        init(text: Binding<String>, focusChain: SupraFocusChain?) {
            self.text = text
            self.focusChain = focusChain
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }

        func textDidBeginEditing(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            focusChain?.noteFocused(view)
        }

        /// Tab/Shift-Tab move focus like every other form field — these are
        /// prose fields in FORMS, not code editors, so a literal tab character
        /// has no value and trapping keyboard users in the field is worse.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSTextView.insertTab(_:)):
                if focusChain?.focusNext(after: textView) == true { return true }
                textView.window?.selectNextKeyView(nil)
                return true
            case #selector(NSTextView.insertBacktab(_:)):
                if focusChain?.focusPrevious(before: textView) == true { return true }
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
    var focusChain: SupraFocusChain? = nil
    var focusOrder: Int = 0
    var accessibilityID: String? = nil
    @State private var focused = false

    var body: some View {
        LeadingTextField(
            text: $text, placeholder: placeholder,
            onEditingChanged: { focused = $0 },
            focusChain: focusChain, focusOrder: focusOrder,
            accessibilityID: accessibilityID
        )
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

struct FocusChainSwitch: NSViewRepresentable {
    @Binding var isOn: Bool
    var focusChain: SupraFocusChain? = nil
    var focusOrder: Int = 0
    var accessibilityID: String? = nil
    var accessibilityLabelText: String = "Limit to a date range"

    func makeNSView(context: Context) -> NSSwitch {
        let control = ChainedSwitch()
        control.state = isOn ? .on : .off
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        control.focusChain = focusChain
        control.setAccessibilityIdentifier(accessibilityID)
        control.setAccessibilityLabel(accessibilityLabelText)
        focusChain?.register(control, at: focusOrder, identifier: accessibilityID)
        return control
    }

    func updateNSView(_ nsView: NSSwitch, context: Context) {
        nsView.state = isOn ? .on : .off
        nsView.setAccessibilityIdentifier(accessibilityID)
        context.coordinator.isOn = $isOn
        context.coordinator.focusChain = focusChain
        if let chained = nsView as? ChainedSwitch {
            chained.focusChain = focusChain
        }
    }

    static func dismantleNSView(_ nsView: NSSwitch, coordinator: Coordinator) {
        coordinator.focusChain?.unregister(nsView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isOn: $isOn, focusChain: focusChain)
    }

    final class Coordinator: NSObject {
        var isOn: Binding<Bool>
        var focusChain: SupraFocusChain?

        init(isOn: Binding<Bool>, focusChain: SupraFocusChain?) {
            self.isOn = isOn
            self.focusChain = focusChain
        }

        @objc func changed(_ sender: NSSwitch) {
            isOn.wrappedValue = sender.state == .on
        }
    }

    final class ChainedSwitch: NSSwitch {
        weak var focusChain: SupraFocusChain?

        override func keyDown(with event: NSEvent) {
            guard event.keyCode == 48 else {
                super.keyDown(with: event)
                return
            }
            // At a chain boundary (this is the last/first registered field),
            // hand off to the native key-view loop so Tab reaches the buttons
            // below instead of dead-ending on the toggle — mirroring the
            // text-field boundary behavior above.
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift) {
                if focusChain?.focusPrevious(before: self) == true { return }
                window?.selectPreviousKeyView(nil)
            } else {
                if focusChain?.focusNext(after: self) == true { return }
                window?.selectNextKeyView(nil)
            }
        }

        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted {
                focusChain?.noteFocused(self)
            }
            return accepted
        }
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
    var focusChain: SupraFocusChain? = nil
    var focusOrder: Int = 0
    var accessibilityID: String? = nil

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
        field.setAccessibilityIdentifier(accessibilityID)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.focusChain = focusChain
        focusChain?.register(field, at: focusOrder, identifier: accessibilityID)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
        nsView.placeholderString = placeholder
        nsView.setAccessibilityIdentifier(accessibilityID)
        context.coordinator.focusChain = focusChain
    }

    static func dismantleNSView(_ nsView: NSTextField, coordinator: Coordinator) {
        coordinator.focusChain?.unregister(nsView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onEditingChanged: onEditingChanged, focusChain: focusChain)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let text: Binding<String>
        private let onEditingChanged: ((Bool) -> Void)?
        var focusChain: SupraFocusChain?

        init(
            text: Binding<String>,
            onEditingChanged: ((Bool) -> Void)?,
            focusChain: SupraFocusChain?
        ) {
            self.text = text
            self.onEditingChanged = onEditingChanged
            self.focusChain = focusChain
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
        func controlTextDidBeginEditing(_ notification: Notification) {
            onEditingChanged?(true)
            guard let field = notification.object as? NSTextField else { return }
            focusChain?.noteFocused(field)
        }
        func controlTextDidEndEditing(_ notification: Notification) { onEditingChanged?(false) }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let focusChain else { return false }
            switch commandSelector {
            case #selector(NSTextView.insertTab(_:)):
                return focusChain.focusNext(after: control)
            case #selector(NSTextView.insertBacktab(_:)):
                return focusChain.focusPrevious(before: control)
            default:
                return false
            }
        }
    }
}
