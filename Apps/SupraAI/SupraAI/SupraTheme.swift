import AppKit
import SwiftUI

// MARK: - Semantic type scale

/// A five-role type scale mirroring the system text styles Apple surfaces in Mail
/// on macOS — Title · Headline · Subheadline · Body · Caption. Prefer these over
/// ad-hoc `.system(size:)` so sizing stays consistent across views and tracks
/// Dynamic Type. On macOS these resolve to roughly: Title ≈ 17pt semibold,
/// Headline ≈ 13pt semibold, Subheadline ≈ 11pt, Body ≈ 13pt, Caption ≈ 10pt.
///
/// - `supraTitle`       screen / sheet titles
/// - `supraHeadline`    section and card headers
/// - `supraSubheadline` secondary lines beneath a title (pair with `.secondary`)
/// - `supraBody`        default UI text
/// - `supraCaption`     hints, metadata, footnotes (pair with `.secondary`)
extension Font {
    static let supraTitle = Font.title2.weight(.semibold)
    static let supraHeadline = Font.headline
    static let supraSubheadline = Font.subheadline
    static let supraBody = Font.body
    static let supraCaption = Font.caption
}

extension View {
    /// Long-form reading surfaces — assistant answers, rendered work product, and
    /// ScratchPad notes. One step above the UI base (14pt, matching Apple Mail's
    /// Body) with reading leading, and an optional capped measure so lines don't run
    /// too wide to scan. Pass `measure: nil` for content already inside a narrow
    /// column (e.g. a note row).
    func supraReadingBody(measure: CGFloat? = 640) -> some View {
        self
            .font(.system(size: 14))
            .lineSpacing(3)
            .frame(maxWidth: measure, alignment: .leading)
    }
}

// MARK: - Sheet & popover chrome

/// Uniform chrome for a centered sheet: a `supraTitle` header with a trailing ghost
/// Done button (Esc), a divider, the content, and an optional right-aligned footer
/// action row. Replaces the hand-rolled header/divider/footer each sheet grew on its
/// own, so every sheet reads as the same surface.
struct SupraSheetScaffold<Content: View, Footer: View>: View {
    private let title: String
    private let doneLabel: String
    private let onClose: () -> Void
    private let content: Content
    private let footer: Footer
    private let hasFooter: Bool

    init(
        _ title: String,
        doneLabel: String = "Done",
        onClose: @escaping () -> Void,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.doneLabel = doneLabel
        self.onClose = onClose
        self.content = content()
        self.footer = footer()
        self.hasFooter = true
    }

    init(
        _ title: String,
        doneLabel: String = "Done",
        onClose: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) where Footer == EmptyView {
        self.title = title
        self.doneLabel = doneLabel
        self.onClose = onClose
        self.content = content()
        self.footer = EmptyView()
        self.hasFooter = false
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.supraTitle).lineLimit(1)
                Spacer()
                Button(doneLabel, action: onClose)
                    .buttonStyle(.ghost)
                    .keyboardShortcut(.cancelAction)
                // With no footer there is no competing primary action, so Return
                // closes the sheet too (several pre-scaffold sheets bound Return).
                if !hasFooter {
                    Button("", action: onClose)
                        .keyboardShortcut(.defaultAction)
                        .hidden()
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
            }
            .padding()
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if hasFooter {
                Divider()
                // Callers own alignment (add a leading Spacer for a right-aligned row),
                // so footers with a leading secondary action still fit the frame.
                HStack(spacing: 8) {
                    footer
                }
                .padding(12)
            }
        }
    }
}

/// Closes transient chrome (the inspector slide-over) on Esc no matter which view
/// has focus. `onExitCommand` and `.keyboardShortcut(.cancelAction)` both need
/// responder-chain cooperation that an NSTextView-focused composer denies, so this
/// installs an NSEvent local monitor only while `isActive`.
private struct EscapeCloseModifier: ViewModifier {
    let isActive: Bool
    let action: () -> Void
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            // onAppear too: a host inside `if let` mounts with isActive already true,
            // and onChange only fires on changes after insertion.
            .onAppear { if isActive { install() } }
            .onChange(of: isActive) { _, active in
                active ? install() : remove()
            }
            .onDisappear { remove() }
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }   // Esc
            // A save panel, alert, or attached sheet owns Esc while it's up —
            // pass the event through so the DIALOG cancels, not the slide-over
            // beneath it (the case readers host fileExporters).
            if event.window is NSPanel || event.window?.attachedSheet != nil {
                return event
            }
            action()
            return nil
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

extension View {
    /// Esc runs `action` while `isActive`, regardless of focus.
    func closesOnEscape(when isActive: Bool, action: @escaping () -> Void) -> some View {
        modifier(EscapeCloseModifier(isActive: isActive, action: action))
    }
}

/// Right-edge inspector slide-over chrome (locked spec §8.1): resizable leading
/// edge, separator + shadow, slides in from the trailing edge, Esc closes. One
/// shared panel chrome for the document preview and the authority reader.
struct SlideOverPanel<Content: View>: View {
    @Binding var width: CGFloat
    var minWidth: CGFloat = 560
    var maxWidth: CGFloat = 1100
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            PreviewResizeHandle(width: $width, minWidth: minWidth, maxWidth: maxWidth)
            content()
                .frame(width: width)
        }
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 10, x: -3, y: 0)
        .transition(.move(edge: .trailing))
        // Restore the Escape-to-close that a sheet/inspector gives for free.
        .onExitCommand { onClose() }
    }
}

/// Uniform chrome for an anchored popover: a `supraTitle` heading over the content,
/// standard padding, and a fixed width — matching the generation-settings popover
/// that set the pattern.
struct SupraPopoverFrame<Content: View>: View {
    private let title: String
    private let width: CGFloat
    private let content: Content

    init(_ title: String, width: CGFloat = 320, @ViewBuilder content: () -> Content) {
        self.title = title
        self.width = width
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.supraTitle)
            content
        }
        .padding()
        .frame(width: width)
    }
}

// MARK: - Text-field chrome

/// THE standard single-line input surface, matching `MultilineField`'s box:
/// `textBackgroundColor` fill + `separatorColor` hairline, radius 6, and an
/// accent border while focused. Fields styled `.plain` or left on the macOS
/// default disappear into window backgrounds (especially in dark mode) —
/// every form field should read as a field at a glance. A ViewModifier (not a
/// TextFieldStyle) because `_body(configuration:)` trips Swift 6 region
/// isolation when handing the field to a stateful chrome view.
private struct SupraFieldModifier: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .focused($focused)
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

extension View {
    /// Apply to every single-line `TextField` in forms, sheets, and toolbars.
    func supraField() -> some View {
        modifier(SupraFieldModifier())
    }
}

/// Claude-style chrome primitives: "ghost" buttons (no outline, text/icon on the
/// surface, a soft shade only on hover) and a `hoverShade` modifier for rows and
/// icon buttons. The wash is ~10% of the foreground, adapting to light/dark. Reserve
/// `.ghostAccent` for the single primary action per view; `.ghostDanger` for
/// destructive ones.
struct GhostButtonStyle: ButtonStyle {
    enum Role { case standard, danger, accent }
    var role: Role = .standard

    func makeBody(configuration: Configuration) -> some View {
        GhostButtonBody(configuration: configuration, role: role)
    }
}

private struct GhostButtonBody: View {
    @Environment(\.isEnabled) private var isEnabled
    let configuration: ButtonStyleConfiguration
    let role: GhostButtonStyle.Role
    @State private var hovering = false

    private var tint: Color {
        switch role {
        case .standard: return .primary
        case .danger: return .red
        case .accent: return .accentColor
        }
    }

    private var fill: Color {
        guard isEnabled else { return role == .accent ? tint.opacity(0.08) : .clear }
        if configuration.isPressed { return tint.opacity(role == .standard ? 0.16 : 0.22) }
        if role == .accent { return tint.opacity(hovering ? 0.20 : 0.12) }
        if hovering { return tint.opacity(role == .standard ? 0.10 : 0.14) }
        return .clear
    }

    var body: some View {
        configuration.label
            .foregroundStyle(role == .standard ? Color.primary : tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = isEnabled && $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension ButtonStyle where Self == GhostButtonStyle {
    static var ghost: GhostButtonStyle { .init(role: .standard) }
    static var ghostDanger: GhostButtonStyle { .init(role: .danger) }
    static var ghostAccent: GhostButtonStyle { .init(role: .accent) }
}

/// Fills the background with a soft hover wash — for selectable rows and flat icon
/// buttons that aren't `Button`s with `GhostButtonStyle`.
private struct HoverShadeModifier: ViewModifier {
    var cornerRadius: CGFloat = 8
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.10) : .clear)
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    func hoverShade(cornerRadius: CGFloat = 8) -> some View {
        modifier(HoverShadeModifier(cornerRadius: cornerRadius))
    }
}

/// A ghost segmented control: a row of text segments, the selected one gently filled,
/// the rest shading on hover. Replaces `Picker(.segmented)` in the chrome (no boxed
/// outline). Each segment carries an optional accessibility identifier (`""` = none).
struct GhostSegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let segments: [(value: Value, label: String, id: String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments, id: \.value) { segment in
                GhostSegment(label: segment.label, isSelected: selection == segment.value, accessibilityID: segment.id) {
                    selection = segment.value
                }
            }
        }
    }
}

private struct GhostSegment: View {
    let label: String
    let isSelected: Bool
    let accessibilityID: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityID)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.08) : (hovering ? Color.primary.opacity(0.10) : .clear))
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
