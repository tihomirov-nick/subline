import AppKit

/// Keys and clicks of the main window. Space, the arrows and ⌫ control the player and the list anywhere except while
/// typing text or while one of the app's own controls has the keyboard focus. Typing ends with Esc, with Return in a
/// one-line field and with a click outside the field (what was typed stays), so Space plays the video again right after.
///
/// The Playback and Subtitles menus show these keys as their shortcuts. A plain key in a menu would take it from every
/// text field, so the keys never reach the menus from the keyboard: in the player they run the command here, anywhere
/// else they go straight to the window (the text, a focused button or slider, a sheet).
@MainActor
final class KeyboardController {
    enum Command: Equatable {
        case togglePlay
        case stepFrames(Int)
        case jumpSeconds(Double)
        case previousCue
        case nextCue
        case escape
        /// ⌫ or ⌦: the selected subtitles (or the one under the playhead) go.
        case delete
        /// ⌘A outside the text: every subtitle is selected.
        case selectAll
    }

    private var keyMonitor: Any?
    private var mouseMonitor: Any?

    func install(_ handler: @escaping (Command) -> Bool) {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let consumed = MainActor.assumeIsolated { Self.consumes(event, handler) }
            return consumed ? nil : event
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            MainActor.assumeIsolated { Self.endTypingIfOutside(event) }
            return event
        }
    }

    /// True when the key is used up here.
    static func consumes(_ event: NSEvent, _ handler: (Command) -> Bool) -> Bool {
        if endsTyping(event) { return true }
        guard let command = command(for: event) else { return false }
        if isPlayerContext(event, for: command) {
            return handler(command)
        }
        // A key the menus show as a shortcut, pressed in text, in a sheet or on a focused control: it goes to the window
        // itself, the menu shortcut must not take it.
        if command.isMenuKey, let window = event.window {
            window.sendEvent(event)
            return true
        }
        return false
    }

    /// The main window itself: sheets, panels (alerts, the color panel) and popovers keep their own keys.
    private static func isMainWindow(_ window: NSWindow?) -> Bool {
        guard let window, !window.isSheet, window.attachedSheet == nil, !(window is NSPanel),
              window.className.contains("Popover") == false else { return false }
        return true
    }

    private static func isPlayerContext(_ event: NSEvent, for command: Command) -> Bool {
        guard let window = event.window, window.isKeyWindow, isMainWindow(window) else { return false }
        // Typing in a text field: the keys belong to the text.
        if window.firstResponder is NSText { return false }
        // A focused button takes Space, a focused slider or stepper takes the arrows.
        switch command {
        case .togglePlay where KeyboardFocus.takesSpace: return false
        case .stepFrames, .jumpSeconds, .previousCue, .nextCue:
            if KeyboardFocus.takesArrows { return false }
        default: break
        }
        return true
    }

    /// The view text is typed into: the text field of a field editor, or a text view of its own.
    static func typingView(in window: NSWindow) -> NSView? {
        guard let text = window.firstResponder as? NSTextView, text.isEditable else { return nil }
        if text.isFieldEditor, let field = text.delegate as? NSView { return field }
        return text
    }

    private static func endsTyping(_ event: NSEvent) -> Bool {
        guard let window = event.window, window.isKeyWindow else { return false }
        return endTyping(keyCode: event.keyCode, modifiers: event.modifierFlags, in: window)
    }

    /// Esc ends typing and keeps the text. Return in a one-line field reaches the field first (it commits the value),
    /// then typing ends. The subtitle text handles Return itself. True when the key is used up.
    static func endTyping(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, in window: NSWindow) -> Bool {
        guard isMainWindow(window), let text = window.firstResponder as? NSTextView, text.isEditable,
              !text.hasMarkedText() else { return false }
        guard modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        switch keyCode {
        case 53: // Esc
            window.makeFirstResponder(nil)
            return true
        case 36, 76: // Return, Enter
            if text.isFieldEditor {
                DispatchQueue.main.async {
                    if window.firstResponder === text { window.makeFirstResponder(nil) }
                }
            }
            return false
        default:
            return false
        }
    }

    private static func endTypingIfOutside(_ event: NSEvent) {
        guard let window = event.window else { return }
        endTyping(click: event.locationInWindow, in: window)
    }

    /// A click anywhere outside the field being typed in ends typing; the click then does what it does.
    @discardableResult
    static func endTyping(click point: NSPoint, in window: NSWindow) -> Bool {
        guard isMainWindow(window), let view = typingView(in: window) else { return false }
        guard !view.convert(view.bounds, to: nil).contains(point) else { return false }
        window.makeFirstResponder(nil)
        return true
    }

    static func command(for event: NSEvent) -> Command? {
        command(keyCode: event.keyCode, modifiers: event.modifierFlags)
    }

    static func command(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Command? {
        let flags = modifiers.intersection([.command, .control, .option, .shift])
        if flags == .command { return keyCode == 0 ? .selectAll : nil }   // ⌘A
        guard flags.isEmpty || flags == .shift else { return nil }
        let shift = flags == .shift
        switch keyCode {
        case 49: return shift ? nil : .togglePlay                       // Space
        case 123: return shift ? .jumpSeconds(-1) : .stepFrames(-1)     // ←
        case 124: return shift ? .jumpSeconds(1) : .stepFrames(1)       // →
        case 126: return shift ? nil : .previousCue                     // ↑
        case 125: return shift ? nil : .nextCue                         // ↓
        case 53: return shift ? nil : .escape                           // Esc
        case 51, 117: return shift ? nil : .delete                      // ⌫, ⌦
        default: return nil
        }
    }
}

extension KeyboardController.Command {
    /// Plain keys that are also shortcuts of menu items.
    var isMenuKey: Bool {
        switch self {
        case .togglePlay, .stepFrames, .jumpSeconds, .previousCue, .nextCue, .delete: return true
        case .escape, .selectAll: return false
        }
    }
}

/// Which of the app's own controls has the keyboard focus (Tab with keyboard navigation turned on): a button takes
/// Space, a slider or a stepper takes the arrows. The controls report it themselves (`trackKeyboardFocus`).
@MainActor
enum KeyboardFocus {
    private(set) static var spaceTakers = Set<UUID>()
    private(set) static var arrowTakers = Set<UUID>()

    static var takesSpace: Bool { !spaceTakers.isEmpty }
    static var takesArrows: Bool { !arrowTakers.isEmpty }

    static func set(_ id: UUID, focused: Bool, space: Bool, arrows: Bool) {
        if focused && space { spaceTakers.insert(id) } else { spaceTakers.remove(id) }
        if focused && arrows { arrowTakers.insert(id) } else { arrowTakers.remove(id) }
    }
}
