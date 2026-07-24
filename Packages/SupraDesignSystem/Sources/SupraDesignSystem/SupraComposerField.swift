import AppKit
import SwiftUI

// MARK: - Key routing

/// What a composer does with a routed key command.
public enum SupraComposerKeyAction: Equatable, Sendable {
    /// Fire the composer's primary action (send the chat / save the note).
    case primaryAction
    /// Insert a line break at the caret.
    case insertLineBreak
    /// Not the composer's business — let the text system handle it.
    case passthrough
}

/// The single source of truth for composer Return-key semantics, kept pure so the
/// contract is unit-testable: plain Return (or keypad Enter — its `.numericPad`/
/// `.function` flags are not user modifiers) ALWAYS resolves to the primary action.
/// No composer state — attachments, tags, sibling chips — participates here, which
/// is exactly what makes the send behavior state-proof. Shift-Return and the native
/// line-break selectors (Option-Return, Ctrl-Return) insert a line break.
/// ⌘-Return passes through: the send button's `keyboardShortcut` owns it, and
/// routing it here too would double-fire the send.
public enum SupraComposerKeyRouter {
    public static func action(
        for selector: Selector,
        modifiers: NSEvent.ModifierFlags
    ) -> SupraComposerKeyAction {
        switch selector {
        case #selector(NSStandardKeyBindingResponding.insertNewline(_:)):
            if modifiers.contains(.command) { return .passthrough }
            if modifiers.contains(.shift) { return .insertLineBreak }
            return .primaryAction
        case #selector(NSStandardKeyBindingResponding.insertNewlineIgnoringFieldEditor(_:)),
             #selector(NSStandardKeyBindingResponding.insertLineBreak(_:)):
            return .insertLineBreak
        default:
            return .passthrough
        }
    }
}

/// The view layer's hooks into composer key handling. `primary` is the send/save
/// action. The Bool handlers back transient UI (autocomplete menus): return true to
/// consume the key, false for the default text-view behavior.
public struct SupraComposerKeyHandlers {
    public var primary: () -> Void
    public var tab: () -> Bool
    public var backtab: () -> Bool
    public var moveUp: () -> Bool
    public var moveDown: () -> Bool
    public var cancel: () -> Bool

    public init(
        primary: @escaping () -> Void = {},
        tab: @escaping () -> Bool = { false },
        backtab: @escaping () -> Bool = { false },
        moveUp: @escaping () -> Bool = { false },
        moveDown: @escaping () -> Bool = { false },
        cancel: @escaping () -> Bool = { false }
    ) {
        self.primary = primary
        self.tab = tab
        self.backtab = backtab
        self.moveUp = moveUp
        self.moveDown = moveDown
        self.cancel = cancel
    }
}

// MARK: - Editor core

/// The AppKit heart of `SupraComposerField`: an `NSTextView` whose key commands are
/// routed at the first-responder level via `textView(_:doCommandBy:)`. Unlike
/// SwiftUI's `.onKeyPress`, this path cannot be detached by hierarchy churn around
/// the field (attachment chips appearing, staged-file bars, tag suggestions), so
/// Return keeps sending no matter what the surrounding UI is doing — the exact
/// failure this component replaces. Factored out of the representable so tests can
/// drive the real delegate wiring headlessly.
@MainActor
public final class SupraComposerEditorCore: NSObject, NSTextViewDelegate {
    public let textView: NSTextView
    public var handlers = SupraComposerKeyHandlers()
    /// Modifier flags for the key event being interpreted. Injectable so tests can
    /// simulate Shift-Return without synthesizing window events.
    public var modifierFlagsProvider: () -> NSEvent.ModifierFlags = {
        NSApp.currentEvent?.modifierFlags ?? []
    }
    public var onTextChange: ((String) -> Void)?
    public var onFocusChange: ((Bool) -> Void)?

    public override init() {
        let view = ComposerTextView()
        view.font = .preferredFont(forTextStyle: .body)
        view.isRichText = false
        view.isEditable = true
        view.isSelectable = true
        view.drawsBackground = false
        view.focusRingType = .none
        view.allowsUndo = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        textView = view
        super.init()
        view.delegate = self
        view.focusSink = { [weak self] focused in self?.onFocusChange?(focused) }
    }

    public func textDidChange(_ notification: Notification) {
        onTextChange?(textView.string)
    }

    public func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch SupraComposerKeyRouter.action(for: commandSelector, modifiers: modifierFlagsProvider()) {
        case .primaryAction:
            handlers.primary()
            return true
        case .insertLineBreak:
            // Direct call, not doCommand(by:), so the delegate isn't re-entered.
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        case .passthrough:
            break
        }
        switch commandSelector {
        case #selector(NSStandardKeyBindingResponding.insertTab(_:)):
            if handlers.tab() { return true }
            // Composers are form neighbors, not code editors: Tab moves focus and
            // never types a literal tab into the draft.
            textView.window?.selectNextKeyView(nil)
            return true
        case #selector(NSStandardKeyBindingResponding.insertBacktab(_:)):
            if handlers.backtab() { return true }
            textView.window?.selectPreviousKeyView(nil)
            return true
        case #selector(NSStandardKeyBindingResponding.moveDown(_:)):
            return handlers.moveDown()
        case #selector(NSStandardKeyBindingResponding.moveUp(_:)):
            return handlers.moveUp()
        case #selector(NSStandardKeyBindingResponding.cancelOperation(_:)):
            return handlers.cancel()
        default:
            return false
        }
    }

    /// Reports first-responder transitions so the SwiftUI focus binding stays true
    /// to AppKit (textDidBeginEditing only fires on the first change, too late for
    /// focus-driven UI like the ScratchPad suggestion dropdown).
    final class ComposerTextView: NSTextView {
        var focusSink: ((Bool) -> Void)?

        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { focusSink?(true) }
            return accepted
        }

        override func resignFirstResponder() -> Bool {
            let accepted = super.resignFirstResponder()
            if accepted { focusSink?(false) }
            return accepted
        }
    }
}

// MARK: - SwiftUI field

/// The shared chat/ScratchPad composer input: an auto-growing, plain-text,
/// AppKit-backed field whose Return key ALWAYS fires `onPrimaryAction` (send),
/// with Shift-Return inserting a line break — regardless of attachments, tags, or
/// any other surrounding UI state. Grows from `lineRange.lowerBound` lines up to
/// `lineRange.upperBound`, then scrolls. The caller draws the box chrome.
public struct SupraComposerField: View {
    private let placeholder: String
    @Binding private var text: String
    @Binding private var isFocused: Bool
    private let lineRange: ClosedRange<Int>
    private let accessibilityID: String?
    private let handlers: SupraComposerKeyHandlers

    @Environment(\.isEnabled) private var isEnabled
    @State private var contentHeight: CGFloat = 0

    private static let lineHeight: CGFloat = 17

    public init(
        _ placeholder: String,
        text: Binding<String>,
        isFocused: Binding<Bool>,
        lineRange: ClosedRange<Int> = 1...6,
        accessibilityID: String? = nil,
        onPrimaryAction: @escaping () -> Void,
        onTab: @escaping () -> Bool = { false },
        onMoveUp: @escaping () -> Bool = { false },
        onMoveDown: @escaping () -> Bool = { false },
        onCancel: @escaping () -> Bool = { false }
    ) {
        self.placeholder = placeholder
        self._text = text
        self._isFocused = isFocused
        self.lineRange = lineRange
        self.accessibilityID = accessibilityID
        self.handlers = SupraComposerKeyHandlers(
            primary: onPrimaryAction,
            tab: onTab,
            moveUp: onMoveUp,
            moveDown: onMoveDown,
            cancel: onCancel
        )
    }

    private var minHeight: CGFloat { CGFloat(lineRange.lowerBound) * Self.lineHeight }
    private var maxHeight: CGFloat { CGFloat(lineRange.upperBound) * Self.lineHeight }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            // Invisible mirror of the content at the editor's width; its measured
            // height drives the editor frame (same approach as MultilineField).
            Text(text.isEmpty ? " " : text)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: ComposerHeightKey.self, value: geometry.size.height)
                })
                .hidden()

            if text.isEmpty {
                Text(placeholder)
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .allowsHitTesting(false)
            }

            ComposerEditor(
                text: $text,
                isFocused: $isFocused,
                isEnabled: isEnabled,
                accessibilityID: accessibilityID,
                handlers: handlers,
                scrolls: contentHeight > maxHeight
            )
            .frame(height: min(max(minHeight, contentHeight), maxHeight))
        }
        .onPreferenceChange(ComposerHeightKey.self) { contentHeight = $0 }
    }
}

private struct ComposerHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ComposerEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var isEnabled: Bool
    var accessibilityID: String?
    var handlers: SupraComposerKeyHandlers
    var scrolls: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        let core = SupraComposerEditorCore()
        /// Guards the focus binding against feedback while a programmatic
        /// first-responder change from updateNSView is in flight.
        var settingFocus = false
    }

    func makeNSView(context: Context) -> NSScrollView {
        let core = context.coordinator.core
        core.textView.string = text
        core.textView.setAccessibilityIdentifier(accessibilityID)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.documentView = core.textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let core = coordinator.core
        // Rebind closures every update so they capture the latest SwiftUI state.
        core.handlers = handlers
        core.onTextChange = { text = $0 }
        core.onFocusChange = { focused in
            guard !coordinator.settingFocus else { return }
            if isFocused != focused { isFocused = focused }
        }

        if core.textView.string != text { core.textView.string = text }
        core.textView.isEditable = isEnabled
        core.textView.isSelectable = true
        core.textView.setAccessibilityIdentifier(accessibilityID)
        scrollView.hasVerticalScroller = scrolls

        if isFocused, isEnabled, let window = core.textView.window,
           window.firstResponder !== core.textView {
            coordinator.settingFocus = true
            DispatchQueue.main.async {
                window.makeFirstResponder(core.textView)
                coordinator.settingFocus = false
            }
        }
    }
}
