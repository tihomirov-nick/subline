import XCTest
@testable import SublineCore

/// Words moved between subtitles, cuts and joins, typed and pasted text.
final class CueEditorTests: XCTestCase {
    /// "раз два наше" | "дело простое", as recognition cut them: the second subtitle starts after a pause.
    private let words = [
        Word(text: "раз", start: 0.0, end: 0.5),
        Word(text: "два", start: 0.6, end: 1.2),
        Word(text: "наше", start: 1.4, end: 2.0),
        Word(text: "дело", start: 3.0, end: 3.5),
        Word(text: "простое.", start: 3.6, end: 4.4),
    ]

    private func pair() -> [Cue] {
        [Cue(start: 0, end: 2.3, text: "раз два наше"), Cue(start: 3.0, end: 4.6, text: "дело простое.")]
    }

    // MARK: Typed and pasted text

    func testLineBreaksBecomeSpacesInOneLineText() {
        XCTAssertEqual(CueText.normalizedInput("наше\nдело\u{2028}тут\tвсё", allowsLineBreaks: false), "наше дело тут всё")
        XCTAssertEqual(CueText.normalizedInput("наше\r\nдело", allowsLineBreaks: false), "наше дело")
        XCTAssertEqual(CueText.normalizedInput("наше\r\nдело\u{2029}тут", allowsLineBreaks: true), "наше\nдело\nтут")
        XCTAssertEqual(CueText.normalizedInput("без переносов", allowsLineBreaks: false), "без переносов")
    }

    func testCaretOffsetGivesTheWordToSplitAt() {
        let text = "раз два три"
        XCTAssertEqual(CueText.wordIndex(atUTF16Offset: 0, in: text), 0)
        XCTAssertEqual(CueText.wordIndex(atUTF16Offset: 7, in: text), 2) // right after "два"
        XCTAssertEqual(CueText.wordIndex(atUTF16Offset: 8, in: text), 2) // before "три"
        XCTAssertEqual(CueText.wordIndex(atUTF16Offset: 6, in: text), 2) // inside "два": it stays in the first part
        XCTAssertEqual(CueText.wordIndex(atUTF16Offset: 99, in: text), 3)
    }

    func testSplitTextKeepsLineBreaksOfEachPart() {
        let (first, second) = CueText.split("раз два\nтри четыре", beforeWord: 3)
        XCTAssertEqual(first, "раз два\nтри")
        XCTAssertEqual(second, "четыре")
    }

    // MARK: Moving words

    func testLastWordMovesToNextAtTheMomentItIsSaid() {
        var cues = pair()
        XCTAssertTrue(CueEditor.moveLastWordToNext(&cues, at: 0, words: words))
        XCTAssertEqual(cues.map(\.text), ["раз два", "наше дело простое."])
        XCTAssertEqual(cues[0].end, 1.4, accuracy: 0.001)
        XCTAssertEqual(cues[1].start, 1.4, accuracy: 0.001, "the next subtitle shows the word while it sounds")
        XCTAssertEqual(cues[1].end, 4.6, accuracy: 0.001)
    }

    func testLastWordWithoutRecognizedTimesTakesItsShareOfTheText() {
        var cues = [Cue(start: 0, end: 3, text: "раз два наше"), Cue(start: 3, end: 5, text: "дело")]
        XCTAssertTrue(CueEditor.moveLastWordToNext(&cues, at: 0))
        // "раз два " is 8 of 13 characters (each word with its space).
        XCTAssertEqual(cues[0].end, 3.0 * 8 / 13, accuracy: 0.001)
        XCTAssertEqual(cues[1].start, cues[0].end, accuracy: 0.001)
        XCTAssertEqual(cues[1].text, "наше дело")
    }

    func testFirstWordMovesToPreviousThatLastsUntilItIsSaid() {
        var cues = pair()
        XCTAssertTrue(CueEditor.moveFirstWordToPrevious(&cues, at: 1, words: words))
        XCTAssertEqual(cues.map(\.text), ["раз два наше дело", "простое."])
        XCTAssertEqual(cues[0].end, 3.6, accuracy: 0.001)
        XCTAssertEqual(cues[1].start, 3.6, accuracy: 0.001)
    }

    func testMovingTheOnlyWordJoinsTheSubtitles() {
        var cues = [Cue(start: 0, end: 1, text: "раз"), Cue(start: 1.2, end: 3, text: "два три")]
        XCTAssertTrue(CueEditor.moveLastWordToNext(&cues, at: 0))
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "раз два три")
        XCTAssertEqual(cues[0].start, 0, accuracy: 0.001)

        var back = [Cue(start: 0, end: 1, text: "раз два"), Cue(start: 1.2, end: 3, text: "три")]
        XCTAssertTrue(CueEditor.moveFirstWordToPrevious(&back, at: 1))
        XCTAssertEqual(back.map(\.text), ["раз два три"])
        XCTAssertEqual(back[0].end, 3, accuracy: 0.001)
    }

    func testNoNeighbourNoMove() {
        var cues = pair()
        XCTAssertFalse(CueEditor.moveFirstWordToPrevious(&cues, at: 0))
        XCTAssertFalse(CueEditor.moveLastWordToNext(&cues, at: 1))
        XCTAssertEqual(cues.map(\.text), pair().map(\.text))
        XCTAssertEqual(cues.map(\.end), pair().map(\.end))
    }

    func testWordStylesTravelWithTheirWords() {
        var bold = StyleOverride()
        bold.fontFace = "Black"
        var red = StyleOverride()
        red.textColor = RGBAColor(r: 1, g: 0, b: 0)
        var cues = pair()
        cues[0].wordStyles = [2: bold]   // "наше"
        cues[1].wordStyles = [0: red]    // "дело"
        CueEditor.moveLastWordToNext(&cues, at: 0, words: words)
        XCTAssertNil(cues[0].wordStyles)
        XCTAssertEqual(cues[1].wordStyles?[0], bold)
        XCTAssertEqual(cues[1].wordStyles?[1], red)
        CueEditor.moveFirstWordToPrevious(&cues, at: 1, words: words)
        XCTAssertEqual(cues[0].wordStyles?[2], bold)
        XCTAssertEqual(cues[1].wordStyles?[0], red)
    }

    // MARK: Cutting and joining

    func testSplitBeforeAWordCutsWhenItIsSaid() {
        var cues = [Cue(start: 0, end: 4.6, text: "раз два наше дело простое.", groupID: UUID())]
        XCTAssertTrue(CueEditor.split(&cues, at: 0, beforeWord: 3, words: words))
        XCTAssertEqual(cues.map(\.text), ["раз два наше", "дело простое."])
        XCTAssertEqual(cues[0].end, 3.0, accuracy: 0.001)
        XCTAssertEqual(cues[1].start, 3.0, accuracy: 0.001)
        XCTAssertEqual(cues[1].end, 4.6, accuracy: 0.001)
        XCTAssertEqual(cues[1].groupID, cues[0].groupID, "the second part stays in the group")
        XCTAssertNotEqual(cues[1].id, cues[0].id)
    }

    func testSplitAtThePlayheadUsesThatMoment() {
        var cues = [Cue(start: 0, end: 4.6, text: "раз два наше дело простое.")]
        let k = CueEditor.wordIndex(at: 2.9, in: cues[0], words: words)
        XCTAssertEqual(k, 3, "the word that starts closest to the playhead")
        XCTAssertTrue(CueEditor.split(&cues, at: 0, beforeWord: k!, time: 2.9, words: words))
        XCTAssertEqual(cues[0].end, 2.9, accuracy: 0.001)
        XCTAssertEqual(cues[1].start, 2.9, accuracy: 0.001)
    }

    func testSplitRefusesToLeaveAnEmptyPart() {
        var cues = [Cue(start: 0, end: 2, text: "раз два")]
        XCTAssertFalse(CueEditor.split(&cues, at: 0, beforeWord: 0))
        XCTAssertFalse(CueEditor.split(&cues, at: 0, beforeWord: 2))
        XCTAssertEqual(cues.count, 1)
    }

    func testMergeJoinsTextTimeAndStyles() {
        var red = StyleOverride()
        red.textColor = RGBAColor(r: 1, g: 0, b: 0)
        var cues = pair()
        cues[1].wordStyles = [1: red]
        XCTAssertTrue(CueEditor.mergeWithNext(&cues, at: 0))
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "раз два наше дело простое.")
        XCTAssertEqual(cues[0].end, 4.6, accuracy: 0.001)
        XCTAssertEqual(cues[0].wordStyles?[4], red)
    }

    func testEditedWordsStillFindTheirTimes() {
        // "наше" was typed by hand after "два": the other words keep their recognized times.
        let cue = Cue(start: 0, end: 2.3, text: "раз два наше")
        let edited = [Word(text: "раз", start: 0, end: 0.5), Word(text: "два,", start: 0.6, end: 1.2)]
        let times = CueEditor.timings(of: cue, words: edited)
        XCTAssertEqual(times[1]?.end, 1.2)
        XCTAssertNil(times[2])
        XCTAssertEqual(CueEditor.boundary(of: cue, beforeWord: 2, words: edited), 1.2, accuracy: 0.001)
    }
}
