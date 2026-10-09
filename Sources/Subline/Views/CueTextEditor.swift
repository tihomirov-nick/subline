import SwiftUI
import AppKit
import SublineCore

/// The text of a subtitle in the list, typed right in place. An AppKit text view, so every key does what the list
/// needs: Return and Esc finish typing (the text stays), Tab goes on to the text of the next subtitle (⇧Tab: the
/// previous one), ⌥Return breaks the line where the style allows several lines, and a line break typed or pasted into
/// a one-line subtitle becomes a space.
struct CueTextEditor: NSViewRepresentable {
    let cueID: UUID
    let text: String
    let allowsLineBreaks: Bool
    /// Commands for the subtitle, added to the menu of the text (right click).
    var menuEntries: () -> [MenuEntry] = { [] }
    var onBegin: () -> Void = {}
    var onChange: (String) -> Void = { _ in }
    /// The caret moved (UTF-16 offset).
    var onCaret: (Int) -> Void = { _ in }
    var onEnd: () -> Void = {}
    /// Tab (true) or ⇧Tab (false); without it they finish typing.
    var onTab: ((Bool) -> Void)?
    /// Typing should move here (Tab from the subtitle before); `onFocusTaken` is called once the text has the keyboard.
    var focusRequested = false
    /// Where the caret goes when the text takes the keyboard (the place of a click); at the end when nil.
    var caretOnFocus: Int?
    var onFocusTaken: () -> Void = {}

    static let font = NSFont.systemFont(ofSize: 13.5)

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> CueTextView {
        let view = CueTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 18))
        view.cueID = cueID
        view.coordinator = context.coordinator
        view.delegate = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.usesFontPanel = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = Self.font
        view.textColor = .white
        view.insertionPointColor = .white
        view.typingAttributes = [.font: Self.font, .foregroundColor: NSColor.white]
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.focusRingType = .none
        view.string = text
        view.setAccessibilityLabel(L("Текст субтитра"))
        return view
    }

    func updateNSView(_ view: CueTextView, context: Context) {
        context.coordinator.parent = self
        view.cueID = cueID
        view.caretOnFocus = caretOnFocus
        if focusRequested { view.takeFocusWhenPossible() }
        guard view.string != text, !view.hasMarkedText() else { return }
        // The text changed outside (a word moved to a neighbour, undo): the caret stays as near as it can, and the undo
        // of typing starts over (its steps belong to the old text; the change itself is a step of the window).
        let selection = view.selectedRange()
        context.coordinator.forgetTyping()
        view.string = text
        let length = (text as NSString).length
        let location = min(selection.location, length)
        view.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CueTextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? max(nsView.frame.width, 120)
        return CGSize(width: width, height: Self.height(of: nsView.string, width: width))
    }

    @MainActor private static var heights: [String: CGFloat] = [:]

    /// The height of the text at this width (at least one line). Laying out the text takes a while and every layout
    /// pass of the list asks again, so the answers are kept.
    @MainActor static func height(of text: String, width: CGFloat) -> CGFloat {
        let key = "\(width)|\(text)"
        if let height = heights[key] { return height }
        if heights.count > 4000 { heights.removeAll(keepingCapacity: true) }
        let height = measureHeight(of: text, width: width)
        heights[key] = height
        return height
    }

    /// The character under a point of the text laid out at this width: where a click puts the caret.
    @MainActor static func characterIndex(in text: String, width: CGFloat, at point: CGPoint) -> Int {
        let length = (text as NSString).length
        guard length > 0 else { return 0 }
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let container = NSTextContainer(size: NSSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
        let index = layout.characterIndexForGlyph(at: glyph) + (fraction > 0.5 ? 1 : 0)
        return min(max(0, index), length)
    }

    private static func measureHeight(of text: String, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(string: text.isEmpty ? " " : text, attributes: [.font: font])
        let container = NSTextContainer(size: NSSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        var height = layout.usedRect(for: container).height
        if text.hasSuffix("\n") { height += layout.extraLineFragmentRect.height }
        return ceil(max(height, layout.defaultLineHeight(for: font)))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CueTextEditor
        /// Typing has its own undo while it lasts; afterwards the whole round is one step of the window (Правка текста).
        private let typingUndo = UndoManager()

        init(_ parent: CueTextEditor) {
            self.parent = parent
        }

        func began() {
            typingUndo.removeAllActions()
            parent.onBegin()
        }

        func forgetTyping() {
            typingUndo.removeAllActions()
        }

        func ended(_ view: NSTextView) {
            parent.onCaret(view.selectedRange().location)
            typingUndo.removeAllActions()
            parent.onEnd()
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.onChange(view.string)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? CueTextView, !view.isEnding,
                  view.window?.firstResponder === view else { return }
            parent.onCaret(view.selectedRange().location)
        }

        /// Pasted, dropped or typed text: line breaks the style does not allow become spaces, tabs too.
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard let replacement = replacementString else { return true }
            let clean = CueText.normalizedInput(replacement, allowsLineBreaks: parent.allowsLineBreaks)
            guard clean != replacement else { return true }
            textView.insertText(clean, replacementRange: range)
            return false
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
                // Tab goes on to the next subtitle, ⇧Tab to the previous one; the text is already in place.
                let forward = selector == #selector(NSResponder.insertTab(_:))
                if let onTab = parent.onTab {
                    onTab(forward)
                } else {
                    textView.window?.makeFirstResponder(nil)
                }
                return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:)):
                // Return confirms, Esc finishes too: the text is already in place.
                textView.window?.makeFirstResponder(nil)
                return true
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), #selector(NSResponder.insertLineBreak(_:)):
                // ⌥Return: a line break of its own, where the style has more than one line.
                if parent.allowsLineBreaks {
                    textView.insertText("\n", replacementRange: textView.selectedRange())
                } else {
                    NSSound.beep()
                }
                return true
            default:
                return false
            }
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            typingUndo
        }

        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            let entries = parent.menuEntries()
            guard !entries.isEmpty else { return menu }
            menu.insertItem(.separator(), at: 0)
            for item in MenuAnchor.items(entries).reversed() {
                menu.insertItem(item, at: 0)
            }
            return menu
        }
    }
}

/// The text view of a subtitle: it tells when typing starts and ends.
final class CueTextView: NSTextView {
    var cueID: UUID?
    weak var coordinator: CueTextEditor.Coordinator?
    /// Typing is ending: the caret is already kept, the selection that follows is not a move of it.
    private(set) var isEnding = false
    /// Typing moves here as soon as the view is in a window (a row of the list appears while it scrolls into view).
    private var wantsFocus = false
    /// Where the caret goes when the view takes the keyboard; at the end when nil.
    var caretOnFocus: Int?

    func takeFocusWhenPossible() {
        wantsFocus = true
        DispatchQueue.main.async { [weak self] in self?.takeFocusIfWanted() }
    }

    private func takeFocusIfWanted() {
        guard wantsFocus, let window else { return }
        wantsFocus = false
        if window.firstResponder !== self, window.makeFirstResponder(self) {
            // The caret where the click was, or at the end, ready to go on typing.
            let length = (string as NSString).length
            setSelectedRange(NSRange(location: min(caretOnFocus ?? length, length), length: 0))
        }
        coordinator?.parent.onFocusTaken()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if wantsFocus { DispatchQueue.main.async { [weak self] in self?.takeFocusIfWanted() } }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { coordinator?.began() }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            coordinator?.ended(self)
            // No grey selection left behind in the list.
            isEnding = true
            setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
            isEnding = false
        }
        return resigned
    }
}
