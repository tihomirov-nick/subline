import SwiftUI
import AppKit
import SubtitsCore

// MARK: - Motion

/// Springs used across the app. Critically damped (no overshoot) by default; with Reduce Motion the
/// movement is replaced by a short cross-fade.
enum Motion {
    static let standard = Animation.spring(response: 0.35, dampingFraction: 1)
    static let quick = Animation.spring(response: 0.22, dampingFraction: 1)
    /// Settling back after a drag past the frame edge.
    static let settle = Animation.spring(response: 0.4, dampingFraction: 1)

    static func animation(_ base: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : base
    }
}

/// Glass surfaces appear as a material arriving (scale + blur), not as a plain fade.
private struct MaterializeModifier: ViewModifier {
    let progress: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(0.94 + 0.06 * progress)
            .blur(radius: (1 - progress) * 6)
            .opacity(progress)
    }
}

extension AnyTransition {
    static func materialize(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .modifier(active: MaterializeModifier(progress: 0), identity: MaterializeModifier(progress: 1))
    }
}

/// Progressive resistance past a boundary (Apple's rubber-band function).
func rubberBand(_ overshoot: CGFloat, dimension: CGFloat, constant: CGFloat = 0.55) -> CGFloat {
    guard dimension > 0 else { return 0 }
    return (overshoot * dimension * constant) / (dimension + constant * abs(overshoot))
}

// MARK: - Colors

extension RGBAColor {
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent), a: Double(ns.alphaComponent))
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}

// MARK: - Inspector building blocks

/// A group of the inspector: a title above a grouped card. A group that can be switched off shows its
/// switch as the first row of the card (as in iOS Settings) and the rest of the card only while it is on.
struct InspectorSection<Content: View>: View {
    let title: String
    var isOn: Binding<Bool>?
    /// Content that brings its own cards (tiles) goes under the title without a card around it.
    var plain: Bool
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, isOn: Binding<Bool>? = nil, plain: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.isOn = isOn
        self.plain = plain
        self.content = content()
    }

    var body: some View {
        Group {
            if let isOn {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Toggle("", isOn: isOn.animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion)))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 40)
                    if isOn.wrappedValue {
                        Rectangle()
                            .fill(Color.hairline)
                            .frame(height: 1)
                            .padding(.leading, 12)
                        VStack(alignment: .leading, spacing: 10) {
                            content
                        }
                        .padding(12)
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    SectionHeader(title)
                    if plain {
                        content
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            content
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
    }
}

/// Label on the left, control on the right.
struct PropertyRow<Control: View>: View {
    let label: String
    @ViewBuilder var control: Control

    init(_ label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12.5))
                .lineLimit(1)
            Spacer(minLength: 8)
            control
        }
        .frame(minHeight: 24)
    }
}

/// Numeric capsule field with a stepper, in pixels (or another unit).
struct ValueField: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    var unit: String = "px"
    var fractionDigits = 0
    var width: CGFloat = 44
    @FocusState private var focused: Bool

    var body: some View {
        let clamped = Binding(
            get: { value },
            set: { value = min(max($0, range.lowerBound), range.upperBound) }
        )
        HStack(spacing: 4) {
            HStack(spacing: 3) {
                TextField("", value: clamped, format: .number.precision(.fractionLength(0...fractionDigits)).grouping(.never))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5).monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .frame(width: width)
                    .focused($focused)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(Color.quietFill))
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(focused ? 0.85 : 0), lineWidth: 1.5))
            Stepper("", value: clamped, in: range, step: step)
                .labelsHidden()
                .controlSize(.small)
        }
    }
}

/// Property with a numeric field and a slider underneath (for values tried by feel: size, width).
struct SliderProperty: View {
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    var unit: String = "px"
    var fractionDigits = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PropertyRow(label) {
                ValueField(value: $value, range: range, step: step, unit: unit, fractionDigits: fractionDigits)
            }
            Slider(value: Binding(
                get: { min(max(value, range.lowerBound), range.upperBound) },
                set: { newValue in
                    let stepped = step > 0 ? (newValue / step).rounded() * step : newValue
                    value = min(max(stepped, range.lowerBound), range.upperBound)
                }
            ), in: range)
            .controlSize(.small)
        }
    }
}

struct ColorProperty: View {
    let label: String
    @Binding var color: RGBAColor
    var supportsOpacity = false

    var body: some View {
        PropertyRow(label) {
            ColorPicker("", selection: Binding(get: { color.color }, set: { color = RGBAColor($0) }), supportsOpacity: supportsOpacity)
                .labelsHidden()
                .frame(width: 44)
        }
    }
}

/// Segmented control with SF Symbols, sized for the inspector.
struct SymbolSegments<Value: Hashable>: View {
    @Binding var selection: Value
    let items: [(value: Value, symbol: String, help: String)]

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(items, id: \.value) { item in
                Image(systemName: item.symbol)
                    .help(item.help)
                    .tag(item.value)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

// MARK: - Font picker

extension Notification.Name {
    static let openFontLibrary = Notification.Name("SubtitsOpenFontLibrary")
}

/// Font family selector with search and live previews of the fonts.
struct FontFamilyPicker: View {
    @Binding var family: String
    let fontsVersion: Int
    @State private var isPresented = false
    @State private var search = ""

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack {
                Text(family)
                    .font(.custom(family, size: 15))
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 13)
            .frame(height: 34)
            .background(Capsule().fill(Color.quietFill))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .popover(isPresented: $isPresented, arrowEdge: .leading) {
            FontListPopover(family: $family, search: $search, isPresented: $isPresented, fontsVersion: fontsVersion)
        }
    }
}

private struct FontListPopover: View {
    @Binding var family: String
    @Binding var search: String
    @Binding var isPresented: Bool
    let fontsVersion: Int

    var body: some View {
        let appFamilies = FontLibrary.appFamilyNames
        let all = FontLibrary.allFamilyNames()
        let query = search.trimmingCharacters(in: .whitespaces)
        let filter: (String) -> Bool = { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
        VStack(spacing: 0) {
            SearchField(prompt: L("Поиск шрифта"), text: $search)
                .padding(10)
            Divider()
            List {
                if !appFamilies.filter(filter).isEmpty {
                    Section(L("Шрифты приложения")) {
                        ForEach(appFamilies.filter(filter), id: \.self) { row($0) }
                    }
                }
                Section(L("Шрифты macOS")) {
                    ForEach(all.filter { filter($0) && !appFamilies.contains($0) }, id: \.self) { row($0) }
                }
            }
            .listStyle(.sidebar)
            Divider()
            Button {
                isPresented = false
                NotificationCenter.default.post(name: .openFontLibrary, object: nil)
            } label: {
                Label(L("Скачать бесплатные шрифты…"), systemImage: "books.vertical")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
        .frame(width: 320, height: 460)
        .id(fontsVersion)
    }

    private func row(_ name: String) -> some View {
        Button {
            family = name
            isPresented = false
        } label: {
            HStack {
                Text(name)
                    .font(.custom(name, size: 15))
                    .lineLimit(1)
                Spacer()
                if !FontLibrary.supportsCyrillic(family: name) {
                    Text(L("лат."))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .help(L("В шрифте нет русских букв"))
                }
                if name == family {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Styles available in the selected font family.
struct FacePicker: View {
    let family: String
    @Binding var face: String
    let fontsVersion: Int

    var body: some View {
        let names = uniqueStyleNames(FontLibrary.faces(of: family))
        Picker("", selection: $face) {
            ForEach(names, id: \.self) { name in
                Text(name).tag(name)
            }
            if !names.contains(face) {
                Text(face).tag(face)
            }
        }
        .labelsHidden()
        .frame(width: 150)
        .id("\(family)-\(fontsVersion)")
    }

    private func uniqueStyleNames(_ faces: [FontFaceInfo]) -> [String] {
        var seen = Set<String>()
        return faces.map(\.styleName).filter { seen.insert($0).inserted }
    }
}

// MARK: - Time

/// Editable time value "m:ss.cc".
struct TimeField: View {
    let value: Double
    var tint: Color?
    var onBeginEditing: (() -> Void)?
    let onCommit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
            .frame(width: 54)
            .focused($focused)
            .onAppear { text = Self.format(value) }
            .onChange(of: value) { newValue in
                if !focused { text = Self.format(newValue) }
            }
            .onChange(of: focused) { isFocused in
                if isFocused { onBeginEditing?() } else { commit() }
            }
            .onSubmit { commit() }
    }

    private func commit() {
        if let parsed = parseTimecode(text), abs(parsed - value) > 0.0005 {
            onCommit(parsed)
        } else {
            text = Self.format(value)
        }
    }

    static func format(_ seconds: Double) -> String {
        let total = Int((max(0, seconds) * 100).rounded())
        return String(format: "%d:%02d.%02d", total / 6000, (total / 100) % 60, total % 100)
    }
}

/// Small rounded label.
struct Badge: View {
    let text: String
    var color: Color = .accentColor

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
    }
}

/// Search capsule with a magnifying glass and a clear button.
struct SearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("Очистить"))
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 30)
        .background(Capsule().fill(Color.quietFill))
    }
}
