import SwiftUI
import AppKit
import SublineCore

/// Settings (⌘,): the interface language, the sound effects and the updates. The language follows macOS; a separate one
/// for Subline is chosen in System Settings.
struct SettingsView: View {
    @EnvironmentObject var updater: Updater
    @AppStorage(SoundEffects.enabledKey) private var soundEffects = true
    @AppStorage(MenuBarIcon.enabledKey) private var menuBarIcon = true

    var body: some View {
        VStack(spacing: 10) {
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
                Separator()
                Row(title: L("Звуковые эффекты"),
                    help: L("Короткие звуки macOS: распознавание, экспорт или загрузка модели началась, закончилась или не удалась, файл сохранен, стиль скопирован или вставлен, что-то добавлено или удалено. Громкость та же, что у звуков предупреждений, и звуков нет, если выключены звуковые эффекты интерфейса (Системные настройки, раздел «Звук»)")) {
                    Switch(isOn: $soundEffects)
                }
                Separator()
                Row(title: L("Значок в строке меню во время работы"),
                    help: L("Пока идет распознавание или экспорт, в строке меню виден значок Subline с ходом работы, в подсказке проценты. Щелчок по значку открывает окно")) {
                    Switch(isOn: $menuBarIcon)
                }
            }
            .card()
            VStack(spacing: 0) {
                Row(title: L("Проверять обновления"),
                    help: L("После запуска и раз в день Subline смотрит, нет ли новой версии на GitHub, и предлагает ее установить")) {
                    Switch(isOn: Binding(get: { updater.automaticChecks }, set: { updater.automaticChecks = $0 }))
                }
                Separator()
                // The version with the status under it: a reason can be long, the button stays.
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Версия %@", "\(updater.currentVersion)"))
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                        if !updater.statusText.isEmpty {
                            Text(updater.statusText)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Palette.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    Spacer(minLength: 6)
                    Button(L("Проверить сейчас")) {
                        updater.check(userInitiated: true)
                    }
                    .appButton(.secondary)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(updater.isBusy)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(minHeight: Metrics.rowHeight)
                .contentShape(Rectangle())
                .help(updater.statusHelp)
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
