import AppKit

/// Player keys (Space, arrows) that work anywhere in the main window except while typing text.
@MainActor
final class KeyboardController {
    enum Command: Equatable {
        case togglePlay
        case stepFrames(Int)
        case jumpSeconds(Double)
        case previousCue
        case nextCue
        case escape
    }

    private var monitor: Any?

    func install(_ handler: @escaping (Command) -> Bool) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let command = Self.command(for: event), Self.isPlayerContext(event) else { return false }
                return handler(command)
            }
            return consumed ? nil : event
        }
    }

    private static func isPlayerContext(_ event: NSEvent) -> Bool {
        guard let window = event.window, window.isKeyWindow, window.attachedSheet == nil,
              !(window is NSPanel), window.className.contains("Popover") == false else { return false }
        // Typing in a text field: the keys belong to the text.
        if window.firstResponder is NSText { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        return modifiers.isEmpty
    }

    private static func command(for event: NSEvent) -> Command? {
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 49: return .togglePlay                              // Space
        case 123: return shift ? .jumpSeconds(-1) : .stepFrames(-1) // ←
        case 124: return shift ? .jumpSeconds(1) : .stepFrames(1)   // →
        case 126: return .previousCue                            // ↑
        case 125: return .nextCue                                // ↓
        case 53: return .escape                                  // Esc
        default: return nil
        }
    }
}
