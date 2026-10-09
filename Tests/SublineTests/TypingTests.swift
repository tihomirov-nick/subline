import XCTest
import AppKit
@testable import Subline
@testable import SublineCore

/// Typing in the text of a subtitle: how it ends, what a pasted line break becomes, which commands act on it.
@MainActor
final class TypingTests: XCTestCase {
    override func setUp() async throws {
        TestEnvironment.setUp()
    }

    /// A window that is never shown, with a field being typed in and room to click next to it.
    private func typingWindow() -> (NSWindow, NSTextView) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let text = NSTextView(frame: CGRect(x: 20, y: 100, width: 200, height: 40))
        content.addSubview(text)
        window.contentView = content
        XCTAssertTrue(window.makeFirstResponder(text))
        return (window, text)
    }

    func testEscEndsTypingAndKeepsTheText() {
        let (window, text) = typingWindow()
        text.string = "наше"
        XCTAssertTrue(KeyboardController.endTyping(keyCode: 53, modifiers: [], in: window))
        XCTAssertFalse(window.firstResponder is NSText, "Space goes to the player again")
        XCTAssertEqual(text.string, "наше")
        window.close()
    }

    func testEscWithModifiersOrInASheetIsLeftAlone() {
        let (window, _) = typingWindow()
        XCTAssertFalse(KeyboardController.endTyping(keyCode: 53, modifiers: [.command], in: window))
        XCTAssertFalse(KeyboardController.endTyping(keyCode: 49, modifiers: [], in: window), "Space types a space while typing")
        XCTAssertTrue(window.firstResponder is NSText)
        window.close()
    }

    func testClickOutsideEndsTypingClickInsideDoesNot() {
        let (window, _) = typingWindow()
        XCTAssertFalse(KeyboardController.endTyping(click: NSPoint(x: 60, y: 120), in: window), "a click into the text")
        XCTAssertTrue(window.firstResponder is NSText)
        XCTAssertTrue(KeyboardController.endTyping(click: NSPoint(x: 300, y: 30), in: window), "a click next to it")
        XCTAssertFalse(window.firstResponder is NSText)
        window.close()
    }

    // MARK: The subtitle text field

    private func editor(allowsLineBreaks: Bool, changes: @escaping (String) -> Void = { _ in }) -> (CueTextEditor.Coordinator, CueTextView) {
        let editor = CueTextEditor(cueID: UUID(), text: "", allowsLineBreaks: allowsLineBreaks, onChange: changes)
        let coordinator = editor.makeCoordinator()
        let view = CueTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        view.coordinator = coordinator
        view.delegate = coordinator
        return (coordinator, view)
    }

    func testPastedLineBreakBecomesASpaceInOneLineText() {
        var typed = ""
        let (coordinator, view) = editor(allowsLineBreaks: false) { typed = $0 }
        view.insertText("раз два ", replacementRange: NSRange(location: 0, length: 0))
        view.insertText("наше\n", replacementRange: view.selectedRange())
        XCTAssertEqual(view.string, "раз два наше ")
        XCTAssertEqual(typed, "раз два наше ")
        // A private pasteboard: the clipboard of the Mac stays as it is.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("subline-tests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("дело\r\nпростое", forType: .string)
        XCTAssertTrue(view.readSelection(from: pasteboard, type: .string))
        XCTAssertEqual(view.string, "раз два наше дело простое")
        pasteboard.releaseGlobally()
        _ = coordinator
    }

    func testReturnFinishesOptionReturnBreaksOnlyWhereAllowed() {
        let (oneLine, oneLineView) = editor(allowsLineBreaks: false)
        XCTAssertTrue(oneLine.textView(oneLineView, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertTrue(oneLine.textView(oneLineView, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertTrue(oneLine.textView(oneLineView, doCommandBy: #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))))
        XCTAssertEqual(oneLineView.string, "", "no line break in a one-line subtitle")

        let (twoLines, twoLinesView) = editor(allowsLineBreaks: true)
        twoLinesView.insertText("раз", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(twoLines.textView(twoLinesView, doCommandBy: #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))))
        XCTAssertEqual(twoLinesView.string, "раз\n")
        XCTAssertFalse(twoLines.textView(twoLinesView, doCommandBy: #selector(NSResponder.moveLeft(_:))))
    }

    func testTextMenuGetsTheSubtitleCommands() {
        var moved = false
        let editor = CueTextEditor(cueID: UUID(), text: "раз", allowsLineBreaks: false, menuEntries: {
            [.item(L("Перенести последнее слово в следующий субтитр")) { moved = true },
             .item(L("Объединить со следующим"), enabled: false) {}]
        })
        let coordinator = editor.makeCoordinator()
        let view = CueTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: nil, keyEquivalent: "")
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let result = coordinator.textView(view, menu: menu, for: event, at: 0)
        XCTAssertEqual(result?.items.first?.title, L("Перенести последнее слово в следующий субтитр"))
        XCTAssertEqual(result?.items.last?.title, "Copy")
        menu.update()
        XCTAssertFalse(menu.items[1].isEnabled, "a disabled command stays disabled in a menu that enables items itself")
        let first = menu.items[0]
        _ = (first.target as? NSObject)?.perform(first.action)
        XCTAssertTrue(moved)
    }

    func testEditorHeightGrowsWithTheText() {
        let one = CueTextEditor.height(of: "наше", width: 200)
        let three = CueTextEditor.height(of: "раз\nдва\nтри", width: 200)
        XCTAssertGreaterThan(one, 10)
        XCTAssertGreaterThan(three, one * 2.5)
    }
}
