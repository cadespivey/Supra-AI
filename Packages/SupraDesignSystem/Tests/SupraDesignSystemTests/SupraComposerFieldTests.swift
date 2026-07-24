import AppKit
@testable import SupraDesignSystem
import XCTest

/// Gating tests for the shared composer key routing that replaces the per-view
/// SwiftUI `.onKeyPress(.return)` closures in the chat and ScratchPad composers.
/// Those closures are bypassed when the hierarchy around the focused field changes
/// (attachment chips, staged files, tag state), letting Return fall through to
/// `TextField(axis: .vertical)`'s macOS default — commit-and-reselect — instead of
/// sending. Routing at the AppKit first-responder level is immune to that.
///
/// Expected RED (all tests): `SupraComposerKeyRouter` and `SupraComposerEditorCore`
/// do not exist yet — the file fails to compile, and the Return-always-sends
/// contract is enforced nowhere.
@MainActor
final class SupraComposerFieldTests: XCTestCase {

    // MARK: - Router (pure selector/modifier routing)

    // Expected RED: router type absent. Plain Return must resolve to the primary
    // action — no composer state may downgrade it.
    func testPlainReturnRoutesToPrimaryAction() {
        XCTAssertEqual(
            SupraComposerKeyRouter.action(
                for: #selector(NSStandardKeyBindingResponding.insertNewline(_:)),
                modifiers: []
            ),
            .primaryAction
        )
    }

    // Expected RED: router type absent. Keypad Enter carries .numericPad/.function
    // flags; those are not user "modifiers" and must not suppress the send.
    func testKeypadEnterFlagsStillRouteToPrimaryAction() {
        XCTAssertEqual(
            SupraComposerKeyRouter.action(
                for: #selector(NSStandardKeyBindingResponding.insertNewline(_:)),
                modifiers: [.numericPad, .function]
            ),
            .primaryAction
        )
    }

    // Expected RED: router type absent. Shift-Return is the one Return chord that
    // means "line break", per the app-wide composer convention.
    func testShiftReturnRoutesToLineBreak() {
        XCTAssertEqual(
            SupraComposerKeyRouter.action(
                for: #selector(NSStandardKeyBindingResponding.insertNewline(_:)),
                modifiers: [.shift]
            ),
            .insertLineBreak
        )
    }

    // Expected RED: router type absent. The native line-break selectors
    // (Option-Return, Ctrl-Return) stay line breaks.
    func testNativeLineBreakSelectorsRouteToLineBreak() {
        XCTAssertEqual(
            SupraComposerKeyRouter.action(
                for: #selector(NSStandardKeyBindingResponding.insertNewlineIgnoringFieldEditor(_:)),
                modifiers: []
            ),
            .insertLineBreak
        )
        XCTAssertEqual(
            SupraComposerKeyRouter.action(
                for: #selector(NSStandardKeyBindingResponding.insertLineBreak(_:)),
                modifiers: [.control]
            ),
            .insertLineBreak
        )
    }

    // Expected RED: router type absent. ⌘-Return is the send button's
    // keyboardShortcut; if it ever reaches the text system the router must pass it
    // through rather than fire the primary action a second time.
    func testCommandReturnPassesThrough() {
        XCTAssertEqual(
            SupraComposerKeyRouter.action(
                for: #selector(NSStandardKeyBindingResponding.insertNewline(_:)),
                modifiers: [.command]
            ),
            .passthrough
        )
    }

    // Expected RED: router type absent. Unrelated editing selectors are none of the
    // composer's business.
    func testUnrelatedSelectorPassesThrough() {
        XCTAssertEqual(
            SupraComposerKeyRouter.action(
                for: #selector(NSStandardKeyBindingResponding.moveLeft(_:)),
                modifiers: []
            ),
            .passthrough
        )
    }

    // MARK: - Editor core (headless NSTextView through the real delegate wiring)

    private func makeCore(
        modifiers: NSEvent.ModifierFlags = [],
        primary: @escaping () -> Void
    ) -> SupraComposerEditorCore {
        let core = SupraComposerEditorCore()
        core.handlers.primary = primary
        core.modifierFlagsProvider = { modifiers }
        return core
    }

    // Expected RED: core type absent. This is the bug's exact contract: with text
    // present, Return fires the primary action exactly once, the text is untouched,
    // and the field does NOT commit-and-reselect (no select-all highlight).
    func testReturnFiresPrimaryActionOnceAndDoesNotReselect() {
        var sends = 0
        let core = makeCore { sends += 1 }
        core.textView.string = "hello with attachment staged"
        core.textView.setSelectedRange(NSRange(location: 5, length: 0))

        core.textView.doCommand(by: #selector(NSStandardKeyBindingResponding.insertNewline(_:)))

        XCTAssertEqual(sends, 1, "plain Return must fire the primary action (send)")
        XCTAssertEqual(core.textView.string, "hello with attachment staged",
                       "send must not mutate the draft text")
        XCTAssertEqual(core.textView.selectedRange().length, 0,
                       "Return must not select-all (the commit-and-reselect symptom)")
    }

    // Expected RED: core type absent. Shift-Return inserts a line break and must
    // NOT send.
    func testShiftReturnInsertsLineBreakWithoutSending() {
        var sends = 0
        let core = makeCore(modifiers: [.shift]) { sends += 1 }
        core.textView.string = "hello"
        core.textView.setSelectedRange(NSRange(location: 5, length: 0))

        core.textView.doCommand(by: #selector(NSStandardKeyBindingResponding.insertNewline(_:)))

        XCTAssertEqual(sends, 0, "Shift-Return must not send")
        XCTAssertEqual(core.textView.string, "hello\n",
                       "Shift-Return must insert a line break at the caret")
    }

    // Expected RED: core type absent. While an autocomplete menu is open the view
    // layer consumes Escape; when it declines, the default cancel behavior stands.
    func testEscapeConsultsCancelHandler() {
        var consulted = 0
        let core = makeCore { XCTFail("escape must never send") }
        core.handlers.cancel = { consulted += 1; return true }
        core.textView.doCommand(by: #selector(NSStandardKeyBindingResponding.cancelOperation(_:)))
        XCTAssertEqual(consulted, 1)
    }

    // Expected RED: core type absent. Tab is consumed by the view layer when it
    // accepts a suggestion; otherwise it must never type a literal tab into the
    // draft (composers move focus, they don't indent).
    func testTabConsultsHandlerAndNeverInsertsTabCharacter() {
        var consulted = 0
        let core = makeCore { XCTFail("tab must never send") }
        core.handlers.tab = { consulted += 1; return true }
        core.textView.string = "hello"
        core.textView.doCommand(by: #selector(NSStandardKeyBindingResponding.insertTab(_:)))

        core.handlers.tab = { consulted += 1; return false }
        core.textView.doCommand(by: #selector(NSStandardKeyBindingResponding.insertTab(_:)))

        XCTAssertEqual(consulted, 2, "both tab presses consult the handler")
        XCTAssertFalse(core.textView.string.contains("\t"),
                       "a composer never inserts a literal tab character")
    }

    // Expected RED: core type absent. Arrow keys consult the menu-navigation
    // handlers; when declined (menu closed) the caret moves normally.
    func testArrowKeysConsultMenuNavigationHandlers() {
        var moves: [String] = []
        let core = makeCore { XCTFail("arrows must never send") }
        core.handlers.moveDown = { moves.append("down"); return true }
        core.handlers.moveUp = { moves.append("up"); return true }
        core.textView.string = "line one\nline two"
        core.textView.setSelectedRange(NSRange(location: 0, length: 0))

        core.textView.doCommand(by: #selector(NSStandardKeyBindingResponding.moveDown(_:)))
        core.textView.doCommand(by: #selector(NSStandardKeyBindingResponding.moveUp(_:)))
        XCTAssertEqual(moves, ["down", "up"])

        core.handlers.moveDown = { moves.append("declined"); return false }
        core.textView.doCommand(by: #selector(NSStandardKeyBindingResponding.moveDown(_:)))
        XCTAssertEqual(core.textView.selectedRange().location, 9,
                       "declined arrow falls through to normal caret movement")
    }

    // Expected RED: core type absent. Edits inside the text view propagate out
    // through the change callback so the SwiftUI binding stays in sync.
    func testTypingSyncsTextThroughChangeCallback() {
        var observed: [String] = []
        let core = makeCore { XCTFail("typing must never send") }
        core.onTextChange = { observed.append($0) }
        core.textView.insertText("draft", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(observed.last, "draft")
    }
}
