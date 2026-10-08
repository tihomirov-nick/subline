import SwiftUI
import AppKit
import SublineCore

/// Settings (⌘,): the interface language. It follows macOS; a separate one for Subline is chosen in System Settings.
struct SettingsView: View {
    var body: some View {
        VStack(spacing: 0) {
            Row(title: L("Язык интерфейса"),
                help: L("Subline берет первый язык из настроек macOS. Чтобы выбрать язык только для Subline, добавьте его в «Язык и регион» → «Приложения» и перезапустите Subline")) {
                Text(Localization.currentName)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
                Button(L("Изменить")) {
                    Self.openLanguageSettings()
                }
                .appButton(.secondary)
                .controlSize(.small)
            }
            .card()
        }
        .padding(Metrics.inset)
        .frame(width: 380)
        .background(Palette.block.ignoresSafeArea())
        .background(BlackWindow())
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    /// System Settings → General → Language & Region.
    static func openLanguageSettings() {
        let pane = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!
        if !NSWorkspace.shared.open(pane) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }
}

/// The settings window is black from the titlebar down, like the blocks of the main window.
private struct BlackWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            // SwiftUI sets up the settings window once more after it appears.
            DispatchQueue.main.async { [weak self] in self?.apply() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.apply() }
        }

        private func apply() {
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.backgroundColor = .black
        }
    }
}
