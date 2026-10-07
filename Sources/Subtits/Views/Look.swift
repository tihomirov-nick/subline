import SwiftUI
import AppKit

// MARK: - Look

/// The look of Apple's 2026 systems (iOS 27, macOS 27): controls float above the content in Liquid Glass,
/// the content sits on grouped cards, controls are capsules and nested corners are concentric.
/// macOS 26 and later draw the glass themselves; older systems get a material with a light edge instead.
enum Look {
    /// Liquid Glass is drawn by the system. SUBTITS_LEGACY_GLASS=1 shows the look of older systems (for checks).
    static let liquidGlass: Bool = {
        if #available(macOS 26.0, *) {
            return ProcessInfo.processInfo.environment["SUBTITS_LEGACY_GLASS"] == nil
        }
        return false
    }()

    /// Grouped cards: inspector, sidebar, sheets.
    static let cardRadius: CGFloat = 14
    /// Rows and tiles inside lists and cards.
    static let innerRadius: CGFloat = 10
    /// The video frame.
    static let frameRadius: CGFloat = 12
}

// MARK: - Colors

extension Color {
    /// Background of panels that hold grouped cards (the inspector, sheets).
    static let groupedBackground = Color(nsColor: .adaptive(
        light: NSColor(srgbRed: 0.949, green: 0.949, blue: 0.965, alpha: 1),
        dark: NSColor(srgbRed: 0.106, green: 0.106, blue: 0.114, alpha: 1)))
    /// A card on the grouped background.
    static let card = Color(nsColor: .adaptive(
        light: .white,
        dark: NSColor(srgbRed: 0.173, green: 0.173, blue: 0.18, alpha: 1)))
    /// The raised thumb of a segmented control.
    static let segmentThumb = Color(nsColor: .adaptive(light: .white, dark: NSColor(white: 0.37, alpha: 1)))
    /// Fields, chips and tracks. Translucent, so it reads on cards, glass and materials alike.
    static let quietFill = Color.primary.opacity(0.07)
    /// Separators inside cards.
    static let hairline = Color.primary.opacity(0.09)
}

extension NSColor {
    static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }
}

// MARK: - Surfaces

private struct CardModifier: ViewModifier {
    var radius: CGFloat
    var fill: Color
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.background {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            shape.fill(fill)
                .overlay(shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.35 : 0.05), lineWidth: 1))
        }
    }
}

extension View {
    /// A grouped card, as in the inset grouped lists of iOS.
    func card(radius: CGFloat = Look.cardRadius, fill: Color = .card) -> some View {
        modifier(CardModifier(radius: radius, fill: fill))
    }

    /// A control surface floating above the content: Liquid Glass, or a material with a light edge
    /// and a soft shadow on older systems.
    @ViewBuilder
    func glassSurface<S: InsettableShape>(_ shape: S) -> some View {
        if #available(macOS 26.0, *), Look.liquidGlass {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.13), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
        }
    }
}

// MARK: - Scrolling under bars

/// A scrolling area with a header (and a footer) pinned over it. With Liquid Glass the content scrolls
/// under them behind the soft edge effect of system bars; older systems stack them with hairlines.
struct BarredScroll<Header: View, Content: View, Footer: View>: View {
    let header: Header
    let content: Content
    let footer: Footer
    private let hasFooter: Bool

    init(@ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.header = header()
        self.content = content()
        self.footer = footer()
        hasFooter = true
    }

    var body: some View {
        if #available(macOS 26.0, *), Look.liquidGlass {
            // A legacy scroller (mouse attached) would keep a strip of width under the bars but stay invisible.
            ScrollView {
                content
            }
            .scrollIndicators(.never)
            .safeAreaBar(edge: .top) { header }
            .safeAreaBar(edge: .bottom) { footer }
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        } else {
            VStack(spacing: 0) {
                header
                Rectangle()
                    .fill(Color.hairline)
                    .frame(height: 1)
                ScrollView {
                    content
                }
                if hasFooter {
                    Rectangle()
                        .fill(Color.hairline)
                        .frame(height: 1)
                    footer
                }
            }
        }
    }
}

extension BarredScroll where Footer == EmptyView {
    init(@ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content) {
        self.header = header()
        self.content = content()
        footer = EmptyView()
        hasFooter = false
    }
}

// MARK: - Buttons

extension View {
    /// Secondary actions: a glass capsule, or a bordered capsule on older systems.
    @ViewBuilder
    func glassButton() -> some View {
        if #available(macOS 26.0, *), Look.liquidGlass {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered).capsuleBorder()
        }
    }

    /// The main action of an area: tinted glass, or a filled capsule on older systems.
    @ViewBuilder
    func glassProminentButton() -> some View {
        if #available(macOS 26.0, *), Look.liquidGlass {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent).capsuleBorder()
        }
    }

    /// A round "more" menu (⋯): a glass circle, or a borderless menu on older systems.
    @ViewBuilder
    func circleMenu() -> some View {
        if #available(macOS 26.0, *), Look.liquidGlass {
            menuStyle(.button).buttonStyle(.glass).buttonBorderShape(.circle).menuIndicator(.hidden).fixedSize()
        } else {
            menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }

    @ViewBuilder
    func capsuleBorder() -> some View {
        if #available(macOS 14.0, *) {
            buttonBorderShape(.capsule)
        } else {
            self
        }
    }
}

/// Instant press feedback for custom buttons.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 1), value: configuration.isPressed)
    }
}

/// On/off capsule (text formatting): filled with the accent color while on.
struct ChipToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 11)
                .frame(height: 26)
                .foregroundStyle(configuration.isOn ? Color.white : Color.primary)
                .background(Capsule().fill(configuration.isOn ? Color.accentColor : Color.quietFill))
                .contentShape(Capsule())
                .animation(.easeOut(duration: 0.12), value: configuration.isOn)
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - Segmented control

/// Segmented control drawn like the system one of 2026: a quiet track and a raised thumb that slides to
/// the selected segment. Used where segments need two lines or their own help and enabled state.
struct SegmentedTrack<Value: Hashable, SegmentLabel: View>: View {
    @Binding var selection: Value
    let values: [Value]
    let radius: CGFloat
    let isEnabled: (Value) -> Bool
    let help: (Value) -> String
    let label: (Value, Bool) -> SegmentLabel
    @Namespace private var thumb
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(selection: Binding<Value>, values: [Value], radius: CGFloat = 8,
         isEnabled: @escaping (Value) -> Bool = { _ in true },
         help: @escaping (Value) -> String = { _ in "" },
         @ViewBuilder label: @escaping (Value, Bool) -> SegmentLabel) {
        _selection = selection
        self.values = values
        self.radius = radius
        self.isEnabled = isEnabled
        self.help = help
        self.label = label
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(values, id: \.self) { value in
                let selected = value == selection
                Button {
                    selection = value
                } label: {
                    label(value, selected)
                        .frame(maxWidth: .infinity)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: radius, style: .continuous)
                                    .fill(Color.segmentThumb)
                                    .shadow(color: .black.opacity(0.16), radius: 2.5, y: 1)
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .disabled(!isEnabled(value))
                .opacity(isEnabled(value) ? 1 : 0.38)
                .help(help(value))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: radius + 3, style: .continuous).fill(Color.quietFill))
        .animation(Motion.animation(Motion.quick, reduceMotion: reduceMotion), value: selection)
    }
}

/// The current value as plain text that opens a menu, like the pop-up rows of iOS Settings.
/// Hugs a short value and truncates a long one.
struct ValueMenu<Items: View>: View {
    let value: String
    @ViewBuilder var items: Items

    var body: some View {
        ViewThatFits(in: .horizontal) {
            menu.fixedSize()
            menu
        }
    }

    private var menu: some View {
        Menu {
            items
        } label: {
            Text(value)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
    }
}

// MARK: - Headings

/// Title above a grouped card.
struct SectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// SF Symbol on a colored rounded square, as in iOS Settings (sheet titles).
struct IconTile: View {
    let symbol: String
    var color: Color = .accentColor
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(color.gradient))
    }
}

/// Title of a sheet: icon tile, large title and a short explanation, with the main button on the right.
struct SheetHeader<Trailing: View>: View {
    let symbol: String
    let color: Color
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(symbol: symbol, color: color, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}
