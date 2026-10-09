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
                    help: L("Subline берёт первый подходящий язык из настроек macOS. Чтобы выбрать язык только для Subline, добавьте Subline в список «Приложения» в разделе «Язык и регион» и перезапустите приложение")) {
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
                SwitchRow(title: L("Звуковые эффекты"),
                          help: L("Subline коротко звучит в начале и в конце распознавания, экспорта и загрузки модели, при ошибках и после мелких действий, например при сохранении SRT или удалении субтитра. Громкость та же, что у звуков предупреждений. Если в Системных настройках, в разделе «Звук», выключены звуковые эффекты интерфейса, звуков нет"),
                          isOn: $soundEffects)
                Separator()
                SwitchRow(title: L("Значок в строке меню во время работы"),
                          help: L("Пока идёт распознавание или экспорт, значок Subline в строке меню показывает ход работы, а проценты видны в его подсказке. Щелчок по значку открывает окно"),
                          isOn: $menuBarIcon)
            }
            .card()
            VStack(spacing: 0) {
                SwitchRow(title: L("Проверять обновления"),
                          help: L("После запуска и раз в день Subline смотрит, не вышла ли новая версия, и предлагает её поставить"),
                          isOn: Binding(get: { updater.automaticChecks }, set: { updater.automaticChecks = $0 }))
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
