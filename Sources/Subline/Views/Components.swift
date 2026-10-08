import SwiftUI
import AppKit
import SublineCore

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

func colorBinding(_ binding: Binding<RGBAColor>) -> Binding<Color> {
    Binding(get: { binding.wrappedValue.color }, set: { binding.wrappedValue = RGBAColor($0) })
}

// MARK: - Font picker

extension Notification.Name {
    static let openFontLibrary = Notification.Name("SublineOpenFontLibrary")
}

/// The font family as a capsule written in that font; a click opens the list of fonts with search.
/// An orange dot when the font needs a look (the reason is in the tooltip).
struct FontFamilyPicker: View {
    @Binding var family: String
    let fontsVersion: Int
    var warning: String?
    @State private var isPresented = false
    @State private var search = ""
    @State private var hovering = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(family)
                    .font(.custom(family, size: 15))
                    .lineLimit(1)
                if warning != nil {
                    Circle()
                        .fill(Palette.attention)
                        .frame(width: 7, height: 7)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Palette.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Capsule().fill(Color.white.opacity(hovering ? 0.16 : 0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle(scale: 0.97))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(warning ?? L("Выбрать шрифт"))
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
        let query = search.trimmingCharacters(in: .whitespaces)
        let matches: (String) -> Bool = { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
        let own = appFamilies.filter(matches)
        let system = FontLibrary.allFamilyNames().filter { matches($0) && !appFamilies.contains($0) }
        VStack(spacing: 0) {
            SearchField(prompt: L("Поиск шрифта"), text: $search)
                .padding(10)
            Separator(leading: 0)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if !own.isEmpty {
                        SectionTitle(L("Шрифты приложения"))
                            .padding(.top, 6)
                        ForEach(own, id: \.self) { row($0) }
                    }
                    if !system.isEmpty {
                        SectionTitle(L("Шрифты macOS"))
                            .padding(.top, 10)
                        ForEach(system, id: \.self) { row($0) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            Separator(leading: 0)
            Button {
                isPresented = false
                NotificationCenter.default.post(name: .openFontLibrary, object: nil)
            } label: {
                Label(L("Скачать бесплатные шрифты"), systemImage: "books.vertical")
            }
            .appButton(.secondary)
            .controlSize(.small)
            .padding(10)
        }
        .frame(width: 300, height: 440)
        .environment(\.colorScheme, .dark)
        .id(fontsVersion)
    }

    private func row(_ name: String) -> some View {
        FontRow(name: name, selected: name == family) {
            family = name
            isPresented = false
        }
    }
}

private struct FontRow: View {
    let name: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(name)
                    .font(.custom(name, size: 15))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !FontLibrary.supportsCyrillic(family: name) {
                    Badge(text: L("Латиница"), color: .white.opacity(0.6))
                        .help(L("В шрифте нет русских букв"))
                }
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(hovering ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Time

/// Editable time value "m:ss.cc".
struct TimeField: View {
    let value: Double
    var highlighted = false
    var onBeginEditing: (() -> Void)?
    let onCommit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(highlighted ? Color.white : Palette.secondary)
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
