import SwiftUI
import AppKit
import SublineCore

// MARK: - Look

/// Subline's look comes from FaceID, an app by the same author: black blocks with round continuous corners, white
/// text, controls drawn by the app rather than by macOS (so they look the same on every macOS version). The brand
/// color is the white of the capsules in the app icon; around the blocks is graphite.
enum Brand {
    /// The marks of the icon: white with a cool tint. Main buttons, switches that are on.
    static let mark = Color(red: 0.96, green: 0.96, blue: 0.98)
}

enum Palette {
    /// Around the blocks.
    static let window = Color(red: 0.094, green: 0.094, blue: 0.106)
    /// The blocks: subtitles, video, inspector, sheets.
    static let block = Color.black
    /// Cards inside a block.
    static let card = Color.white.opacity(0.07)
    /// Lines between the rows of a card.
    static let separator = Color.white.opacity(0.08)
    /// Fields, tracks, round buttons.
    static let fill = Color.white.opacity(0.12)
    static let secondary = Color.white.opacity(0.55)
    /// Quiet labels (units, sizes, the file summary): about 5:1 on black, above the 4.5:1 of WCAG AA.
    static let tertiary = Color.white.opacity(0.5)
    /// Placeholders of text fields: drawn by the app, the system ones are too faint on black.
    static let placeholder = Color.white.opacity(0.45)
    /// Something needs a look: a missing font, a download that retries.
    static let attention = Color.orange
    static let danger = Color(red: 1, green: 0.42, blue: 0.4)
}

enum Metrics {
    static let blockRadius: CGFloat = 20
    static let cardRadius: CGFloat = 14
    /// Padding inside every block: the space under the content is the same in all of them.
    static let inset: CGFloat = 12
    /// Between the blocks and around them.
    static let gap: CGFloat = 8
    static let rowHeight: CGFloat = 34
}

// MARK: - Motion

enum Motion {
    /// Content changes as in the island of FaceID: quick, with a little overshoot.
    static let island = Animation.spring(response: 0.42, dampingFraction: 0.74)
    static let quick = Animation.spring(response: 0.22, dampingFraction: 0.85)
    /// Settling back after a drag past the frame edge.
    static let settle = Animation.spring(response: 0.4, dampingFraction: 1)

    /// With Reduce Motion, movement becomes a short cross-fade.
    static func animation(_ base: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : base
    }
}

/// New content appears out of a blur, growing from the top, as in the island of FaceID.
struct RevealTransition: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .blur(radius: (1 - progress) * 10)
            .scaleEffect(0.85 + 0.15 * progress, anchor: .top)
    }
}

extension AnyTransition {
    static func reveal(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .modifier(active: RevealTransition(progress: 0), identity: RevealTransition(progress: 1))
    }
}

extension View {
    /// The symbol bounces when `value` changes (macOS 14 and later).
    @ViewBuilder
    func bounce<V: Equatable>(on value: V) -> some View {
        if #available(macOS 14.0, *) {
            symbolEffect(.bounce, value: value)
        } else {
            self
        }
    }
}

/// A tap on the trackpad, felt when a finger rests on it.
enum Haptics {
    /// A switch was flipped, a segment chosen, the text stuck to the middle of the frame.
    static func tap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    static func success() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}

// MARK: - Surfaces

extension View {
    /// A black block with round continuous corners; what scrolls inside stays within them.
    ///
    /// The black stays inside the block. By default SwiftUI stretches a background into the safe area it touches; the
    /// blocks touch the titlebar's, so the stretch lay over the top bar, invisible under the clip but still taking the
    /// clicks, and «Открыть», «Экспорт» and the style switch only moved the window.
    func block(radius: CGFloat = Metrics.blockRadius) -> some View {
        background(Palette.block, ignoresSafeAreaEdges: [])
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// A card inside a block.
    func card(radius: CGFloat = Metrics.cardRadius) -> some View {
        background(Palette.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    /// What scrolls up fades out under the top edge instead of being cut off.
    func softTopEdge(_ height: CGFloat = 10) -> some View {
        mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: height)
                Color.black
            }
        }
    }
}

/// The line between the rows of a card.
struct Separator: View {
    var leading: CGFloat = 12

    var body: some View {
        Rectangle()
            .fill(Palette.separator)
            .frame(height: 1)
            .padding(.leading, leading)
    }
}

/// The name of a group of controls, above its card. A reset button follows it when the group is changed in the
/// current scope.
struct SectionTitle: View {
    let title: String
    var onReset: (() -> Void)?

    init(_ title: String, onReset: (() -> Void)? = nil) {
        self.title = title
        self.onReset = onReset
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)
            if let onReset {
                ResetButton(action: onReset)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .frame(height: 22)
    }
}

/// One line of a card: the name on the left, the control on the right. What it does is in the tooltip.
struct Row<Control: View>: View {
    let title: String
    var help: String?
    /// The value is changed in the current scope: the name is bold and a reset button follows it.
    var changed = false
    var onReset: (() -> Void)?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12.5, weight: changed ? .semibold : .medium))
                .lineLimit(1)
            if changed, let onReset {
                ResetButton(action: onReset)
            }
            Spacer(minLength: 6)
            control
                // Fields, swatches and sliders of the row are named after it for VoiceOver.
                .environment(\.rowTitle, title)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: Metrics.rowHeight)
        .contentShape(Rectangle())
        .help(help ?? "")
    }
}

extension EnvironmentValues {
    /// The name of the row a control sits in: its label for VoiceOver.
    var rowTitle: String {
        get { self[RowTitleKey.self] }
        set { self[RowTitleKey.self] = newValue }
    }
}

private struct RowTitleKey: EnvironmentKey {
    static let defaultValue = ""
}

/// A tooltip without its shortcut, for VoiceOver: "Скрыть стиль (⌥⌘I)" is read as "Скрыть стиль".
func spokenText(_ help: String) -> String {
    guard help.hasSuffix(")"), let open = help.range(of: " (", options: .backwards) else { return help }
    let inside = help[open.upperBound...].dropLast()
    let shortcut = inside.contains { "⌘⌥⇧⌃←→↑↓".contains($0) } || inside == L("пробел")
    return shortcut ? String(help[..<open.lowerBound]) : help
}

/// A highlight under a row that reacts to clicks anywhere in it.
private struct RowHover: View {
    let hovering: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.white.opacity(hovering ? 0.05 : 0))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
    }
}

/// A row whose value is chosen from a menu: a click anywhere in the row opens it, under the value.
struct MenuRow: View {
    let title: String
    var help: String?
    var changed = false
    var onReset: (() -> Void)?
    let value: String
    let entries: () -> [MenuEntry]
    @State private var anchor = MenuAnchor()
    @State private var hovering = false

    var body: some View {
        Row(title: title, help: help, changed: changed, onReset: onReset) {
            HStack(spacing: 4) {
                Text(value)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
            }
            .foregroundStyle(Color.white.opacity(hovering ? 1 : 0.65))
            .background(AnchorView(anchor: anchor))
        }
        .background(RowHover(hovering: hovering))
        .onTapGesture { anchor.show(entries()) }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityHint(help ?? "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { anchor.show(entries()) }
    }
}

/// A row with a switch: a click anywhere in the row flips it.
struct SwitchRow: View {
    let title: String
    var help: String?
    @Binding var isOn: Bool
    @State private var hovering = false

    var body: some View {
        Row(title: title, help: help) {
            Switch(isOn: $isOn)
        }
        .background(RowHover(hovering: hovering))
        .onTapGesture {
            isOn.toggle()
            Haptics.tap()
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        // VoiceOver: one switch named after the row.
        .accessibilityRepresentation {
            Toggle(title, isOn: $isOn)
                .accessibilityHint(help ?? "")
        }
    }
}

/// A row with a color: a click anywhere in the row opens the color panel for it.
struct ColorRow: View {
    let title: String
    var changed = false
    var onReset: (() -> Void)?
    @Binding var color: Color
    var opacity = true
    @State private var owner = UUID()
    @State private var hovering = false

    var body: some View {
        Row(title: title, changed: changed, onReset: onReset) {
            ColorSwatch(color: $color, opacity: opacity, owner: owner)
        }
        .background(RowHover(hovering: hovering))
        .onTapGesture { ColorSwatch.open(owner: owner, color: $color, opacity: opacity) }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityElement(children: .contain)
    }
}

/// A small round button that brings back the shared value.
struct ResetButton: View {
    var help = L("Вернуть общее значение")
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Palette.fill))
                // A larger target than the circle: a click next to it counts.
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.85))
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Buttons

/// Capsule buttons drawn by the app. They sink when pressed, spring back with a little bounce and grow slightly
/// under the pointer, like the buttons of FaceID.
struct AppButtonStyle: ButtonStyle {
    enum Kind {
        /// The main action: a filled white capsule, like the marks of the icon.
        case primary
        /// Everything else: a translucent capsule.
        case secondary
        /// Deleting: a red-tinted capsule.
        case destructive
    }

    var kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        AppButtonBody(kind: kind, configuration: configuration)
    }
}

private struct AppButtonBody: View {
    let kind: AppButtonStyle.Kind
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let pressed = configuration.isPressed
        let grows = hovering && isEnabled && !reduceMotion
        configuration.label
            .font(.system(size: fontSize, weight: kind == .primary ? .semibold : .medium))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, padding.h)
            .padding(.vertical, padding.v)
            .background(Capsule().fill(background(pressed: pressed)))
            .focusRing(Capsule())
            // A mini button is drawn smaller than it takes clicks: at least 24 pt high.
            .frame(minHeight: controlSize == .mini ? 24 : nil)
            .contentShape(Rectangle())
            .scaleEffect(pressed && !reduceMotion ? 0.92 : (grows ? 1.03 : 1))
            .brightness(pressed && kind == .primary ? -0.08 : 0)
            .opacity(isEnabled ? 1 : 0.4)
            // In quickly, back out with a little bounce, like iOS buttons.
            .animation(pressed ? .spring(response: 0.18, dampingFraction: 0.8) : .spring(response: 0.35, dampingFraction: 0.5),
                       value: pressed)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
            .onHover { hovering = $0 }
    }

    private var fontSize: CGFloat {
        switch controlSize {
        case .mini: 11
        case .small: 12
        case .large: 14
        default: 13
        }
    }

    private var padding: (h: CGFloat, v: CGFloat) {
        switch controlSize {
        case .mini: (9, 3.5)
        case .small: (12, 5)
        case .large: (20, 9)
        default: (15, 6.5)
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: .black
        case .secondary: .white
        case .destructive: Palette.danger
        }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary: Brand.mark.opacity(pressed ? 0.8 : (hovering ? 0.92 : 1))
        case .secondary: Color.white.opacity(pressed ? 0.24 : (hovering ? 0.2 : 0.14))
        case .destructive: Color.red.opacity(pressed ? 0.3 : (hovering ? 0.24 : 0.18))
        }
    }
}

extension View {
    func appButton(_ kind: AppButtonStyle.Kind = .secondary) -> some View {
        buttonStyle(AppButtonStyle(kind: kind))
    }
}

/// Sinks when pressed, springs back with a little bounce. With the keyboard focus it gets the focus ring.
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.94
    var ring = AnyShape(Capsule())

    init(scale: CGFloat = 0.94) {
        self.scale = scale
    }

    init<S: Shape>(scale: CGFloat = 0.94, ring: S) {
        self.scale = scale
        self.ring = AnyShape(ring)
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .focusRing(ring)
            .scaleEffect(configuration.isPressed ? scale : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(configuration.isPressed ? .spring(response: 0.18, dampingFraction: 0.8)
                                               : .spring(response: 0.35, dampingFraction: 0.45),
                       value: configuration.isPressed)
    }
}

// MARK: - Keyboard focus

extension View {
    /// The system focus ring around `shape` while this button has the keyboard focus (keyboard navigation turned on in
    /// System Settings). The button then takes Space from the player.
    func focusRing<S: Shape>(_ shape: S) -> some View {
        modifier(FocusRing(shape: AnyShape(shape), takesSpace: true, takesArrows: false))
    }

    /// A control set with the arrows (a slider, a stepper, the scrubber): it takes the keyboard focus with keyboard
    /// navigation, shows the focus ring, and ← ↓ step down, → ↑ step up.
    func keyboardAdjustable<S: Shape>(ring shape: S = Capsule(), arrows: @escaping (Int) -> Void) -> some View {
        modifier(KeyboardAdjustable(shape: AnyShape(shape), step: arrows))
    }
}

private struct FocusRing: ViewModifier {
    let shape: AnyShape
    let takesSpace: Bool
    let takesArrows: Bool
    @Environment(\.isFocused) private var isFocused
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .overlay {
                shape
                    .stroke(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2.5)
                    .padding(-2.5)
                    .opacity(isFocused ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .onChange(of: isFocused) { focused in
                KeyboardFocus.set(id, focused: focused, space: takesSpace, arrows: takesArrows)
            }
            .onDisappear { KeyboardFocus.set(id, focused: false, space: false, arrows: false) }
    }
}

private struct KeyboardAdjustable: ViewModifier {
    let shape: AnyShape
    let step: (Int) -> Void

    func body(content: Content) -> some View {
        content
            .modifier(FocusRing(shape: shape, takesSpace: false, takesArrows: true))
            // Like the controls of macOS: in the Tab order only with keyboard navigation, a click does not take focus.
            .focusable(NSApp?.isFullKeyboardAccessEnabled ?? false)
            .onMoveCommand { direction in
                switch direction {
                case .left, .down: step(-1)
                case .right, .up: step(1)
                @unknown default: break
                }
            }
    }
}

/// The face of a round button with an SF Symbol.
struct IconLabel: View {
    let symbol: String
    var size: CGFloat = 26
    /// A quiet circle under the symbol; without it the circle shows only under the pointer.
    var filled = true
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: (size * 0.42).rounded(), weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(fill))
            // The whole square around the circle takes the click, at least 24 × 24 pt.
            .frame(minWidth: 24, minHeight: 24)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.35)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var fill: Color {
        Color.white.opacity(hovering && isEnabled ? (filled ? 0.18 : 0.12) : (filled ? 0.12 : 0))
    }
}

/// A round button with an SF Symbol; what it does is in the tooltip.
struct IconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 26
    var filled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            IconLabel(symbol: symbol, size: size, filled: filled)
        }
        .buttonStyle(PressStyle(scale: 0.88))
        .help(help)
        .accessibilityLabel(spokenText(help))
    }
}

// MARK: - Switch, segments, tiles

/// A switch drawn by the app, as on iPhone: white when on, the knob stretches while pressed and slides with a spring.
struct Switch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
            Haptics.tap()
        } label: {
            EmptyView()
        }
        .buttonStyle(SwitchStyle(isOn: isOn))
        .accessibilityValue(isOn ? L("Вкл") : L("Выкл"))
    }

    private struct SwitchStyle: ButtonStyle {
        let isOn: Bool

        func makeBody(configuration: Configuration) -> some View {
            let pressed = configuration.isPressed
            Capsule()
                .fill(isOn ? Brand.mark : Color.white.opacity(0.22))
                .frame(width: 36, height: 21)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(isOn ? Color.black : Color.white)
                        .frame(width: pressed ? 22 : 17, height: 17)
                        .padding(2)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                }
                .contentShape(Capsule())
                .focusRing(Capsule())
                .animation(.spring(response: 0.3, dampingFraction: 0.68), value: isOn)
                .animation(.spring(response: 0.22, dampingFraction: 0.75), value: pressed)
        }
    }
}

/// One option of `Segments`: a short title or a symbol, and a tooltip.
struct SegmentItem<Value: Hashable> {
    let value: Value
    var title: String?
    var symbol: String?
    var help: String?
    var enabled = true

    init(_ value: Value, _ title: String, help: String? = nil, enabled: Bool = true) {
        self.value = value
        self.title = title
        self.help = help
        self.enabled = enabled
    }

    init(_ value: Value, symbol: String, help: String, enabled: Bool = true) {
        self.value = value
        self.symbol = symbol
        self.help = help
        self.enabled = enabled
    }
}

/// A choice drawn by the app: the white pill slides to the chosen option.
struct Segments<Value: Hashable>: View {
    @Binding var selection: Value
    let items: [SegmentItem<Value>]
    /// Equal options across the whole width; otherwise each one hugs its title.
    var fill = false
    var large = false
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.value) { item in
                let selected = selection == item.value
                Button {
                    guard selection != item.value else { return }
                    selection = item.value
                    Haptics.tap()
                } label: {
                    label(item, selected: selected)
                        .padding(.horizontal, fill ? 4 : (large ? 9 : 7))
                        .frame(maxWidth: fill ? .infinity : nil)
                        .frame(height: large ? 26 : 20)
                        .background {
                            if selected {
                                Capsule().fill(Color.white).matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        // The gaps around the pill take the click too: no dead edges between the options.
                        .padding(.vertical, 2)
                        .padding(.horizontal, 0.5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .disabled(!item.enabled)
                .opacity(item.enabled ? 1 : 0.35)
                .help(item.help ?? "")
                .accessibilityLabel(item.title ?? item.help ?? "")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 1.5)
        .background(Capsule().fill(Palette.fill))
        .animation(.spring(response: 0.32, dampingFraction: 0.75), value: selection)
    }

    @ViewBuilder
    private func label(_ item: SegmentItem<Value>, selected: Bool) -> some View {
        let color = selected ? Color.black : Color.white.opacity(0.8)
        if let symbol = item.symbol {
            Image(systemName: symbol)
                .font(.system(size: large ? 12.5 : 11, weight: .semibold))
                .foregroundStyle(color)
        } else {
            // Equal options keep one weight: a bolder chosen title would have to shrink to fit.
            Text(item.title ?? "")
                .font(.system(size: large ? 12 : 10.5, weight: fill ? .medium : (selected ? .semibold : .regular)))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: !fill, vertical: false)
        }
    }
}

/// An on/off feature as in Control Center: a wide pill with an icon circle (white when on) and the name on one line.
/// It sinks when pressed, the icon bounces and a ring spreads out when it changes, the trackpad taps. An orange dot
/// when it needs a look.
struct Tile: View {
    let symbol: String
    let title: String
    let on: Bool
    var attention = false
    var help = ""
    let action: () -> Void
    @State private var hovering = false
    @State private var rippleScale: CGFloat = 1
    @State private var rippleOpacity: Double = 0
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: symbol)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(on ? Color.black : Color.white)
                        .bounce(on: on)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(on ? Brand.mark : Color.white.opacity(0.16)))
                        .background {
                            // The ring that spreads out when the switch changes.
                            Circle()
                                .stroke(on ? Brand.mark : Color.white, lineWidth: 2)
                                .scaleEffect(rippleScale)
                                .opacity(rippleOpacity)
                        }
                    if attention {
                        Circle().fill(Palette.attention).frame(width: 9, height: 9)
                            .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                            .offset(x: 2, y: -2)
                            .accessibilityHidden(true)
                    }
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.white.opacity(hovering ? 0.13 : 0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(PressStyle(ring: RoundedRectangle(cornerRadius: 13, style: .continuous)))
        .onHover { hovering = $0 }
        .help(help)
        .onChange(of: on) { _ in
            ripple()
            Haptics.tap()
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: on)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(title)
        .accessibilityValue(on ? L("Вкл") : L("Выкл"))
        .accessibilityHint(help)
    }

    private func ripple() {
        guard !reduceMotion else { return }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            rippleScale = 1
            rippleOpacity = 0.8
        }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.45)) {
                rippleScale = 1.6
                rippleOpacity = 0
            }
        }
    }
}

/// Tiles two in a row.
struct TileGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            content
        }
    }
}

// MARK: - Numbers

/// A number in a capsule with − and + on the sides (they repeat while held), in pixels or another unit.
struct ValueField: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    var unit: String = "px"
    var fractionDigits = 0
    var width: CGFloat = 38
    @FocusState private var focused: Bool
    @Environment(\.rowTitle) private var rowTitle

    var body: some View {
        HStack(spacing: 0) {
            StepButton(symbol: "minus", title: rowTitle, atLimit: value <= range.lowerBound,
                       action: { set(value - step) }, arrows: { set(value + Double($0) * step) })
            HStack(spacing: 2) {
                TextField("", value: Binding(get: { value }, set: { set($0) }),
                          format: .number.precision(.fractionLength(0...fractionDigits)).grouping(.never))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5).monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .frame(width: width)
                    .focused($focused)
                    .accessibilityLabel(rowTitle)
                    .accessibilityValue(unit.isEmpty ? "" : unit)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.tertiary)
                        .fixedSize()
                        .accessibilityHidden(true)
                }
            }
            .frame(maxHeight: .infinity)
            // A click on the unit or next to the number starts typing too.
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
            StepButton(symbol: "plus", title: rowTitle, atLimit: value >= range.upperBound,
                       action: { set(value + step) }, arrows: { set(value + Double($0) * step) })
        }
        .frame(height: 24)
        .background(Capsule().fill(Palette.fill))
        .overlay(Capsule().strokeBorder(Color.white.opacity(focused ? 0.4 : 0), lineWidth: 1))
        .animation(.easeOut(duration: 0.12), value: focused)
    }

    private func set(_ newValue: Double) {
        let clamped = min(max(newValue, range.lowerBound), range.upperBound)
        let scale = pow(10, Double(fractionDigits))
        let rounded = (clamped * scale).rounded() / scale
        if rounded != value { value = rounded }
    }
}

/// − or + of a `ValueField`: steps once on press, then repeats while held. With keyboard navigation it takes the
/// focus, and the arrows step the value (← ↓ down, → ↑ up).
private struct StepButton: View {
    let symbol: String
    var title = ""
    let atLimit: Bool
    let action: () -> Void
    var arrows: (Int) -> Void = { _ in }
    @StateObject private var repeater = Repeater()
    @State private var pressed = false
    @Environment(\.isEnabled) private var isEnabled

    private var label: String {
        if title.isEmpty { return symbol == "plus" ? L("Больше") : L("Меньше") }
        return symbol == "plus" ? L("Увеличить «%@»", title) : L("Уменьшить «%@»", title)
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(Color.white.opacity(!isEnabled || atLimit ? 0.25 : (pressed ? 1 : 0.7)))
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .scaleEffect(pressed ? 0.75 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: pressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard isEnabled, !pressed else { return }
                        pressed = true
                        action()
                        repeater.start(action)
                    }
                    .onEnded { _ in
                        pressed = false
                        repeater.stop()
                    }
            )
            .onDisappear { repeater.stop() }
            .keyboardAdjustable(ring: Circle(), arrows: arrows)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

@MainActor
private final class Repeater: ObservableObject {
    private var timer: Timer?

    func start(_ action: @escaping () -> Void) {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.timer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { _ in
                    MainActor.assumeIsolated { action() }
                }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

/// A slider drawn by the app: a white fill on a quiet track and a white knob that grows while dragged. With few
/// steps the trackpad taps on each one.
struct AppSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 0
    var tapsOnSteps = false
    /// For VoiceOver: what the slider sets, and how its value reads (the number when nil).
    var label = ""
    var valueText: String?
    @State private var dragging = false
    @State private var hovering = false

    var body: some View {
        GeometryReader { geometry in
            let knob: CGFloat = 16
            let width = max(1, geometry.size.width - knob)
            let span = max(range.upperBound - range.lowerBound, .ulpOfOne)
            let fraction = CGFloat((min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span)
            let track: CGFloat = dragging || hovering ? 6 : 4
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.14))
                    .frame(height: track)
                Capsule()
                    .fill(Brand.mark)
                    .frame(width: knob / 2 + width * fraction, height: track)
                Circle()
                    .fill(Color.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.4), radius: 2.5, y: 1)
                    .scaleEffect(dragging ? 1.18 : 1)
                    .offset(x: width * fraction)
            }
            .frame(height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        dragging = true
                        set(Double(min(max(0, (gesture.location.x - knob / 2) / width), 1)) * span + range.lowerBound)
                    }
                    .onEnded { _ in dragging = false }
            )
            .onHover { hovering = $0 }
        }
        .frame(height: 18)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: dragging)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .keyboardAdjustable(ring: RoundedRectangle(cornerRadius: 9, style: .continuous)) { direction in
            set(value + Double(direction) * keyStep)
        }
        // VoiceOver sees a real slider: its name, its value, and adjusting with the VO keys.
        .accessibilityRepresentation {
            Slider(value: Binding(get: { value }, set: { set($0) }), in: range, step: keyStep) {
                Text(label)
            }
            .accessibilityValue(valueText ?? "\(Int(value.rounded()))")
        }
    }

    /// One press of an arrow: the step, or a twentieth of the range.
    private var keyStep: Double {
        step > 0 ? step : (range.upperBound - range.lowerBound) / 20
    }

    private func set(_ newValue: Double) {
        var result = min(max(newValue, range.lowerBound), range.upperBound)
        if step > 0 {
            result = min(max(((result - range.lowerBound) / step).rounded() * step + range.lowerBound, range.lowerBound), range.upperBound)
        }
        guard result != value else { return }
        value = result
        if tapsOnSteps { Haptics.tap() }
    }
}

// MARK: - Colors

/// A color as a round swatch; a click opens the macOS color panel for it.
struct ColorSwatch: View {
    @Binding var color: Color
    var opacity = true
    /// The row the swatch sits in opens the same panel (ColorRow).
    var owner: UUID?
    @State private var ownID = UUID()
    @State private var hovering = false
    @Environment(\.rowTitle) private var rowTitle

    private var id: UUID { owner ?? ownID }

    /// Opens the macOS color panel for a color.
    static func open(owner: UUID, color: Binding<Color>, opacity: Bool) {
        ColorPanelBridge.shared.open(owner: owner, color: NSColor(color.wrappedValue), opacity: opacity) { picked in
            color.wrappedValue = Color(nsColor: picked)
        }
    }

    var body: some View {
        Button {
            Self.open(owner: id, color: $color, opacity: opacity)
        } label: {
            Circle()
                .fill(color)
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.28), lineWidth: 1))
                .padding(2)
                .overlay(Circle().strokeBorder(Color.white.opacity(hovering ? 0.7 : 0), lineWidth: 1.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.88))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onDisappear { ColorPanelBridge.shared.release(owner: id) }
        .help(L("Выбрать цвет"))
        .accessibilityLabel(rowTitle.isEmpty ? L("Цвет") : rowTitle)
        .accessibilityValue(RGBAColor(color).spokenName)
        .accessibilityHint(L("Открывает палитру цветов"))
    }
}

/// Connects the shared macOS color panel to the swatch that opened it last.
@MainActor
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var owner: UUID?
    private var apply: ((NSColor) -> Void)?

    func open(owner: UUID, color: NSColor, opacity: Bool, apply: @escaping (NSColor) -> Void) {
        let panel = NSColorPanel.shared
        self.apply = nil
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.showsAlpha = opacity
        panel.isContinuous = true
        panel.color = color
        self.owner = owner
        self.apply = apply
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.orderFront(nil)
    }

    func release(owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil
        apply = nil
        NSColorPanel.shared.setTarget(nil)
        NSColorPanel.shared.setAction(nil)
    }

    @objc private func changed(_ sender: NSColorPanel) {
        apply?(sender.color)
    }
}

// MARK: - Menus

/// One line of a menu opened by a button drawn by the app (the menu itself is the system one).
struct MenuEntry {
    enum Kind { case item, separator, header }

    var kind: Kind = .item
    var title = ""
    var checked = false
    var enabled = true
    var children: [MenuEntry] = []
    var action: (() -> Void)?

    static func item(_ title: String, checked: Bool = false, enabled: Bool = true, action: @escaping () -> Void) -> MenuEntry {
        MenuEntry(title: title, checked: checked, enabled: enabled, action: action)
    }

    static func submenu(_ title: String, enabled: Bool = true, _ children: [MenuEntry]) -> MenuEntry {
        MenuEntry(title: title, enabled: enabled && !children.isEmpty, children: children)
    }

    static func header(_ title: String) -> MenuEntry {
        MenuEntry(kind: .header, title: title)
    }

    static let separator = MenuEntry(kind: .separator)
}

/// A button that opens a system menu under itself. The menu is built when it opens, so it always shows the current
/// state.
struct MenuButton<Label: View>: View {
    let entries: () -> [MenuEntry]
    @ViewBuilder var label: Label
    @State private var anchor = MenuAnchor()

    var body: some View {
        Button {
            anchor.show(entries())
        } label: {
            label
        }
        .background(AnchorView(anchor: anchor))
    }
}

/// A round button with ⋯ (or another symbol) that opens a menu.
struct MenuIconButton: View {
    var symbol = "ellipsis"
    let help: String
    var size: CGFloat = 26
    var filled = true
    let entries: () -> [MenuEntry]

    var body: some View {
        MenuButton(entries: entries) {
            IconLabel(symbol: symbol, size: size, filled: filled)
        }
        .buttonStyle(PressStyle(scale: 0.88))
        .help(help)
        .accessibilityLabel(spokenText(help))
    }
}

/// The main action with a menu of variants: the left part runs it, the chevron opens the menu.
struct SplitButton: View {
    let title: String
    let help: String
    let menuHelp: String
    /// Looks unavailable but still takes the click, so the action can say why it cannot run.
    var dimmed = false
    let action: () -> Void
    let entries: () -> [MenuEntry]
    @Environment(\.isEnabled) private var environmentEnabled
    @State private var hovering = false

    private var isEnabled: Bool { environmentEnabled && !dimmed }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .padding(.leading, 15)
                    .padding(.trailing, 10)
                    .frame(height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SplitPartStyle())
            .help(help)
            .accessibilityLabel(title)
            .accessibilityHint(spokenText(help))
            Rectangle()
                .fill(Color.black.opacity(0.15))
                .frame(width: 1, height: 16)
                .accessibilityHidden(true)
            MenuButton(entries: entries) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9.5, weight: .bold))
                    .frame(width: 26, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SplitPartStyle())
            .help(menuHelp)
            .accessibilityLabel(menuHelp)
        }
        .foregroundStyle(.black)
        .background(Capsule().fill(Brand.mark.opacity(hovering && isEnabled ? 0.92 : 1)))
        .clipShape(Capsule())
        .scaleEffect(hovering && isEnabled ? 1.03 : 1)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
    }

    private struct SplitPartStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                // Inside the capsule (it clips what sticks out): the ring is drawn inset.
                .focusRing(RoundedRectangle(cornerRadius: 12, style: .continuous).inset(by: 5))
                .background(Color.black.opacity(configuration.isPressed ? 0.12 : 0))
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .animation(configuration.isPressed ? .spring(response: 0.18, dampingFraction: 0.8)
                                                   : .spring(response: 0.35, dampingFraction: 0.5),
                           value: configuration.isPressed)
        }
    }
}

/// Where a menu opens: an invisible AppKit view behind the button.
@MainActor
final class MenuAnchor {
    weak var view: NSView?

    func show(_ entries: [MenuEntry]) {
        guard let view else { return }
        let menu = Self.menu(entries)
        let point = NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4)
        menu.popUp(positioning: nil, at: point, in: view)
    }

    private static func menu(_ entries: [MenuEntry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items(entries) { menu.addItem(item) }
        return menu
    }

    /// Menu items for the entries (also added to the menu of a text field).
    static func items(_ entries: [MenuEntry]) -> [NSMenuItem] {
        entries.map { entry in
            switch entry.kind {
            case .separator:
                return .separator()
            case .header:
                if #available(macOS 14.0, *) {
                    return .sectionHeader(title: entry.title)
                }
                let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                return item
            case .item:
                let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                if !entry.children.isEmpty {
                    item.submenu = Self.menu(entry.children)
                } else if let action = entry.action {
                    let target = MenuTarget(action, enabled: entry.enabled)
                    item.target = target
                    item.action = #selector(MenuTarget.run)
                    // The menu item does not keep its target.
                    item.representedObject = target
                }
                item.state = entry.checked ? .on : .off
                item.isEnabled = entry.enabled
                return item
            }
        }
    }
}

private final class MenuTarget: NSObject, NSMenuItemValidation {
    let action: () -> Void
    let enabled: Bool

    init(_ action: @escaping () -> Void, enabled: Bool) {
        self.action = action
        self.enabled = enabled
    }

    @objc func run() {
        action()
    }

    /// Menus that enable their items by themselves (the menu of a text field) keep the entry's state.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        enabled
    }
}

private struct AnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

// MARK: - Fields

/// Text field in a quiet capsule, outlined while typing.
struct CapsuleField: View {
    let prompt: String
    @Binding var text: String
    var symbol: String?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.secondary)
            }
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focused)
                // A placeholder of our own: the system one is too faint on black.
                .overlay(alignment: .leading) {
                    if text.isEmpty {
                        Text(prompt)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.placeholder)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityLabel(prompt)
            if !text.isEmpty && symbol == "magnifyingglass" {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.secondary)
                }
                .buttonStyle(PressStyle(scale: 0.85))
                .help(L("Очистить"))
                .accessibilityLabel(L("Очистить"))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Capsule().fill(Palette.fill))
        .overlay(Capsule().strokeBorder(Color.white.opacity(focused ? 0.4 : 0), lineWidth: 1))
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}

/// Search capsule with a magnifying glass and a clear button.
struct SearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        CapsuleField(prompt: prompt, text: $text, symbol: "magnifyingglass")
    }
}

/// A small rounded label.
struct Badge: View {
    let text: String
    var color: Color = .white

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.16)))
    }
}

/// A thin progress line; without a value a short piece runs along it.
struct ProgressLine: View {
    var value: Double?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                if let value {
                    Capsule()
                        .fill(Brand.mark)
                        .frame(width: max(4, geometry.size.width * CGFloat(min(1, max(0, value)))))
                } else {
                    RunningPiece()
                }
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.2), value: value)
        .accessibilityRepresentation {
            if let value {
                ProgressView(value: min(1, max(0, value)))
            } else {
                ProgressView()
            }
        }
    }
}

/// The piece that runs along a progress line without a value. Core Animation moves it outside the app, so it costs
/// nothing per frame; a SwiftUI animation would redraw the whole window every frame and take a tenth of a core away
/// from long work.
private struct RunningPiece: NSViewRepresentable {
    func makeNSView(context: Context) -> PieceView {
        PieceView()
    }

    func updateNSView(_ view: PieceView, context: Context) {}

    final class PieceView: NSView {
        private let piece = CALayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            piece.backgroundColor = NSColor(Brand.mark).cgColor
            layer?.addSublayer(piece)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override func layout() {
            super.layout()
            layer?.cornerRadius = bounds.height / 2
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            piece.frame = CGRect(x: 0, y: 0, width: bounds.width * 0.3, height: bounds.height)
            piece.cornerRadius = bounds.height / 2
            CATransaction.commit()
            run()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            run()
        }

        /// From just outside the left end to just outside the right end in 1.4 s, again and again.
        private func run() {
            piece.removeAllAnimations()
            guard window != nil, bounds.width > 0 else { return }
            let width = piece.bounds.width
            let slide = CABasicAnimation(keyPath: "position.x")
            slide.fromValue = -width / 2
            slide.toValue = bounds.width + width / 2
            slide.duration = 1.4
            slide.repeatCount = .infinity
            piece.add(slide, forKey: "run")
        }
    }
}

// MARK: - Window

/// Empty parts of the top bar move the window; a double click zooms it (or does what is set in System Settings).
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": window.miniaturize(nil)
                case "None": break
                default: window.zoom(nil)
                }
            } else {
                window.performDrag(with: event)
            }
        }
    }
}

/// Closing the main window quits Subline. Subtitles and edits are saved by themselves, but running recognition or
/// export would be lost, so the red button and ⌘W ask first while one runs.
@MainActor
final class WindowCloseGuard: NSObject {
    static let shared = WindowCloseGuard()
    /// True when the window may close now (the app asks about running work and stops it).
    var mayClose: () -> Bool = { true }

    func guardCloseButton(of window: NSWindow) {
        guard let button = window.standardWindowButton(.closeButton), button.target !== self else { return }
        button.target = self
        button.action = #selector(closeClicked(_:))
    }

    @objc private func closeClicked(_ sender: NSButton) {
        guard let window = sender.window else { return }
        close(window)
    }

    private func close(_ window: NSWindow) {
        guard mayClose() else { return }
        window.close()
    }

    /// ⌘W: the main window through the question, any other window as usual.
    func closeKeyWindow() {
        guard let window = NSApp.keyWindow else { return }
        if window.standardWindowButton(.closeButton)?.target === self {
            close(window)
        } else {
            window.performClose(nil)
        }
    }
}

/// How the window's own controls sit: the height of the titlebar (the traffic lights are in its middle) and where
/// they end.
struct WindowChrome: Equatable {
    var titlebarHeight: CGFloat = 40
    var controlsEnd: CGFloat = 72
    var fullScreen = false
}

/// Sets up the main window: no title, a compact titlebar for the top bar, the graphite background.
struct WindowConfigurator: NSViewRepresentable {
    @Binding var chrome: WindowChrome

    func makeNSView(context: Context) -> NSView {
        let view = ConfigView()
        view.onChange = { chrome in
            DispatchQueue.main.async {
                if self.chrome != chrome { self.chrome = chrome }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ConfigView: NSView {
        var onChange: ((WindowChrome) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            guard let window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            if window.toolbar == nil {
                window.toolbar = NSToolbar(identifier: "SublineMain")
            }
            window.toolbarStyle = .unifiedCompact
            window.backgroundColor = NSColor(Palette.window)
            report()
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                         NSWindow.didResizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                })
            }
        }

        private func report() {
            guard let window else { return }
            // The window's buttons can be made anew (full screen): the close button is guarded each time.
            WindowCloseGuard.shared.guardCloseButton(of: window)
            var chrome = WindowChrome()
            chrome.fullScreen = window.styleMask.contains(.fullScreen)
            let titlebar = window.frame.height - window.contentLayoutRect.height
            if titlebar > 20 { chrome.titlebarHeight = titlebar }
            if let zoom = window.standardWindowButton(.zoomButton) {
                chrome.controlsEnd = zoom.convert(zoom.bounds, to: nil).maxX
            }
            onChange?(chrome)
        }
    }
}
