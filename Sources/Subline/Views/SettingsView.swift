import SwiftUI
import AppKit
import SublineCore

/// Settings (⌘,), in the order of the family standard: the main ones (the interface language, opening at login, the sound
/// effects, the menu bar icon), then the updates. The language is the app's own `AppleLanguages`, the setting System
/// Settings writes too (InterfaceLanguage), and a new one takes effect after a restart.
struct SettingsView: View {
    @EnvironmentObject var updater: Updater
    @AppStorage(SoundEffects.enabledKey) private var soundEffects = true
    @AppStorage(MenuBarIcon.enabledKey) private var menuBarIcon = true
    private let language: LanguageSource

    init(language: LanguageSource = LanguageSource()) {
        self.language = language
    }

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 0) {
                LanguageRows(source: language)
                Separator()
                LoginItemRows()
                Separator()
                SwitchRow(title: L("Звуковые эффекты"),
                          help: L("Subline коротко звучит в начале и в конце распознавания, экспорта и загрузки модели, при ошибках и после мелких действий, например при сохранении SRT или удалении субтитра. Громкость та же, что у звуков предупреждений. Если в Системных настройках, в разделе «Звук», выключены звуковые эффекты интерфейса, звуков нет"),
                          isOn: $soundEffects)
                Separator()
                SwitchRow(title: L("Значок в строке меню во время работы"),
                          help: L("Пока идёт распознавание или экспорт, в строке меню стоит значок Subline, а проценты видны в его подсказке. Щелчок по значку выводит окно вперёд, правый щелчок открывает меню, в котором можно остановить работу"),
                          isOn: $menuBarIcon)
            }
            .card()
            VStack(spacing: 0) {
                SwitchRow(title: L("Проверять обновления"),
                          help: L("Subline смотрит, нет ли новой версии, при запуске, раз в три часа и после пробуждения Mac"),
                          isOn: Binding(get: { updater.automaticChecks }, set: { updater.automaticChecks = $0 }))
                Separator()
                SwitchRow(title: L("Обновлять автоматически"),
                          help: L("Новая версия скачивается и ставится сама, когда Subline ничем не занят. Пока идёт распознавание, экспорт или загрузка модели, играет видео или вы правите текст субтитра, обновление ждёт. Если выключить, Subline будет только предлагать обновиться"),
                          isOn: Binding(get: { updater.automaticInstall }, set: { updater.automaticInstall = $0 }))
                    .disabled(!updater.automaticChecks)
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
}

// MARK: - Interface language

/// Where the language is read from and written to, and the language this launch speaks. The app's own by default; the
/// tests point it at a defaults domain of their own, so nothing of the test process's is touched.
struct LanguageSource {
    var defaults: UserDefaults = .standard
    var domain: String? = Bundle.main.bundleIdentifier
    /// "ru" or "en": what the interface shows now (`Localization.current`).
    var running: String = Localization.current

    var saved: InterfaceLanguage {
        InterfaceLanguage.saved(in: defaults, domain: domain)
    }

    /// Whether the next launch will speak another language than this one.
    var needsRestart: Bool {
        InterfaceLanguage.needsRestart(running: running, in: defaults, domain: domain)
    }

    func save(_ choice: InterfaceLanguage) {
        InterfaceLanguage.save(choice, in: defaults, domain: domain)
    }
}

extension InterfaceLanguage {
    /// A language is named in its own language, so anyone finds theirs.
    var title: String {
        switch self {
        case .system: return L("Как в системе")
        case .russian: return "Русский"
        case .english: return "English"
        }
    }
}

/// The interface language: «Как в системе», «Русский» or «English». The choice is read again when Settings open and when
/// the user comes back to Subline, since System Settings writes the same setting. A language other than the one this
/// launch speaks offers a restart under the row.
private struct LanguageRows: View {
    let source: LanguageSource
    @State private var choice: InterfaceLanguage
    @State private var needsRestart: Bool

    init(source: LanguageSource) {
        self.source = source
        _choice = State(initialValue: source.saved)
        _needsRestart = State(initialValue: source.needsRestart)
    }

    var body: some View {
        MenuRow(title: L("Язык интерфейса"),
                help: L("При варианте «Как в системе» Subline берёт первый подходящий язык из списка в Системных настройках, раздел «Язык и регион». Новый язык включится после перезапуска"),
                value: choice.title) {
            [.item(InterfaceLanguage.system.title, checked: choice == .system) { select(.system) },
             .separator,
             .item(InterfaceLanguage.russian.title, checked: choice == .russian) { select(.russian) },
             .item(InterfaceLanguage.english.title, checked: choice == .english) { select(.english) }]
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        if needsRestart {
            Separator()
            RestartRow()
        }
    }

    private func select(_ language: InterfaceLanguage) {
        source.save(language)
        refresh()
    }

    private func refresh() {
        choice = source.saved
        needsRestart = source.needsRestart
    }
}

/// «Язык сменится после перезапуска» with the button that restarts Subline. Not while the app is busy: a restart would
/// break what it is doing (the same test the updater uses before it restarts the app).
private struct RestartRow: View {
    @EnvironmentObject var updater: Updater

    var body: some View {
        // The Russian note and button take 314 of the row's 332 pt: the gap between them is the only slack, and it stays
        // one piece (a stack's spacing next to a Spacer would add to it).
        HStack(spacing: 0) {
            Text(L("Язык сменится после перезапуска"))
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 10)
            // Whether the app is busy is not published: the button looks again every second while the row shows.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let busy = updater.appIsBusy()
                Button(L("Перезапустить")) { restart() }
                    .appButton(.secondary)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(busy)
                    .help(busy ? L("Пока идёт распознавание, экспорт или загрузка модели, играет видео или вы правите текст субтитра, Subline не перезапускается") : "")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(minHeight: Metrics.rowHeight)
        .contentShape(Rectangle())
    }

    private func restart() {
        guard !updater.appIsBusy() else { return }
        InterfaceLanguage.relaunch()
    }
}

// MARK: - Opening at login

/// Opening at login (Updater.LoginItem), and the way to System Settings when it is switched off there: only the user can
/// switch it on again in Login Items.
private struct LoginItemRows: View {
    @ObservedObject private var loginItem = Updater.LoginItem.shared
    @State private var needsApproval = false

    var body: some View {
        SwitchRow(title: L("Запускать при входе"),
                  help: L("При входе в систему Subline запускается без окна и значка в Dock, чтобы вовремя ставить обновления. Окно появится, когда вы откроете Subline"),
                  isOn: Binding(get: { loginItem.isEnabled }, set: {
                      loginItem.set($0)
                      needsApproval = loginItem.needsApproval
                  }))
            .onAppear(perform: refresh)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        if needsApproval {
            Separator()
            // The text above and the button under it: both do not fit in a line of the 380 pt window in Russian. The text may
            // wrap, so a longer translation is not cut off either.
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Выключено в Системных настройках"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("Открыть «Объекты входа»")) { loginItem.openSystemSettings() }
                    .appButton(.secondary)
                    .controlSize(.small)
                    .fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(minHeight: Metrics.rowHeight)
            .contentShape(Rectangle())
            .help(L("Запуск при входе выключен в Системных настройках, в разделе «Объекты входа». Включить его снова можно только там"))
        }
    }

    /// Read again when Settings open and when the user comes back to Subline: System Settings may have changed it.
    private func refresh() {
        loginItem.refresh()
        needsApproval = loginItem.needsApproval
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
