import XCTest
@testable import SublineCore

/// "1 line" means one line: built subtitles fit it, a break typed into one-line text is a space, and a subtitle that
/// is longer than the line says so and can be cut where both halves fit.
final class LineFitTests: XCTestCase {
    private let canvas = CGSize(width: 1080, height: 1920)

    /// The built-in "Reels / Shorts — 1 строка" preset.
    private var oneLine: SubtitlePreset {
        let preset = SubtitlePreset.builtIn[1]
        XCTAssertEqual(preset.maxLines, 1)
        return preset
    }

    private func sentenceWords(_ text: String) -> [Word] {
        text.split(separator: " ").enumerated().map { index, word in
            Word(text: String(word), start: Double(index) * 0.4, end: Double(index) * 0.4 + 0.35)
        }
    }

    private let speech = "Сегодня покажу, как быстро сделать красивые субтитры для любого видео, даже если вы никогда раньше этим не занимались и не знаете, с чего начать работу."

    func testShortTextFitsOneLine() {
        let renderer = CueRenderer(preset: oneLine, canvas: canvas)
        let fit = renderer.fit(Cue(start: 0, end: 1, text: "наше дело"))
        XCTAssertEqual(fit, LineFit(lines: 1, maxLines: 1))
        XCTAssertFalse(fit.overflows)
    }

    func testBreakInOneLineTextIsASpace() {
        let renderer = CueRenderer(preset: oneLine, canvas: canvas)
        XCTAssertEqual(renderer.fit(Cue(start: 0, end: 1, text: "наше\nдело")).lines, 1)
        // A style with two lines keeps the break typed by hand.
        var twoLines = oneLine
        twoLines.maxLines = 2
        XCTAssertEqual(CueRenderer(preset: twoLines, canvas: canvas).fit(Cue(start: 0, end: 1, text: "наше\nдело")).lines, 2)
    }

    func testLongTextSaysItDoesNotFitAndSplitsIntoFittingHalves() throws {
        let renderer = CueRenderer(preset: oneLine, canvas: canvas)
        // Words are added until the text takes two lines: one word too many for the line, as after a word pasted by hand.
        var text = ""
        for word in speech.split(separator: " ") {
            text += (text.isEmpty ? "" : " ") + word
            if renderer.fit(Cue(start: 0, end: 3, text: text)).lines >= 2 { break }
        }
        let cue = Cue(start: 0, end: 3, text: text)
        let fit = renderer.fit(cue)
        XCTAssertEqual(fit, LineFit(lines: 2, maxLines: 1), text)
        XCTAssertTrue(fit.overflows)
        let k = try XCTUnwrap(renderer.splitPoint(cue))
        var cues = [cue]
        XCTAssertTrue(CueEditor.split(&cues, at: 0, beforeWord: k))
        for part in cues {
            XCTAssertFalse(renderer.fit(part).overflows, "\(part.text) still takes \(renderer.fit(part).lines) lines")
        }
    }

    func testSplitPointPrefersTheEndOfAClause() {
        let renderer = CueRenderer(preset: oneLine, canvas: canvas)
        let cue = Cue(start: 0, end: 3, text: "Привет, это наши субтитры")
        let k = renderer.splitPoint(cue)
        XCTAssertEqual(k, 1, "after «Привет,»")
    }

    /// Recognition cuts subtitles that the renderer draws on one line, with capitals and with highlight plates too.
    func testBuiltSubtitlesFitOneLineWithCapitalsAndPlates() {
        for variant in 0..<3 {
            var preset = oneLine
            preset.maxWordsPerCue = 0
            if variant >= 1 { preset.uppercase = true }
            if variant == 2 { preset.highlightEnabled = true }
            let style = LayoutStyle(preset: preset, canvas: canvas)
            let cues = CueBuilder.build(words: sentenceWords(speech), style: style)
            XCTAssertGreaterThan(cues.count, 3)
            let renderer = CueRenderer(preset: preset, canvas: canvas)
            for cue in cues {
                XCTAssertFalse(renderer.fit(cue).overflows, "variant \(variant): «\(cue.text)» takes \(renderer.fit(cue).lines) lines")
            }
        }
    }
}
