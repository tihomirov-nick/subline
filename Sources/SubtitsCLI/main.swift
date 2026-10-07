import Foundation
import CoreGraphics
import ImageIO
import CoreText
import SubtitsCore

// Development tool: runs the subtitle pipeline without the UI.
//
//   subtits-cli probe <media>
//   subtits-cli transcribe <media> --model <ggml.bin> [--lang ru] [--greedy] [--vad] [--out transcript.json]
//   subtits-cli cues <transcript.json> [--preset 0] [--size 1080x1920] [--case original]
//   subtits-cli render <transcript.json> --out frame.png [--preset 0] [--size 1080x1920] [--time 3.5] [--background frame.jpg]
//   subtits-cli export <media> <transcript.json> --out out.mp4 [--format mp4H264|mp4HEVC|movProRes|overlayProRes4444|srt] [--preset 0]
//   subtits-cli fonts [family]

setvbuf(stdout, nil, _IOLBF, 0)

var arguments = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return value
}

func flag(_ name: String) -> Bool {
    guard let index = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: index)
    return true
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func loadTranscript(_ path: String) -> Transcript {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let data = FileManager.default.contents(atPath: path),
          let transcript = try? decoder.decode(Transcript.self, from: data) else { fail("cannot read transcript \(path)") }
    return transcript
}

func presetFromOptions() -> SubtitlePreset {
    var preset = SubtitlePreset.builtIn[Int(option("--preset") ?? "0") ?? 0]
    if let mode = option("--case"), let value = TextCaseMode(rawValue: mode) { preset.caseMode = value }
    if let family = option("--font") { preset.fontFamily = family }
    if let face = option("--face") { preset.fontFace = face }
    if let size = option("--font-size"), let value = Double(size) { preset.fontSize = value }
    if let lines = option("--lines"), let value = Int(lines) { preset.maxLines = value }
    if let words = option("--words"), let value = Int(words) { preset.maxWordsPerCue = value }
    if let y = option("--y"), let value = Double(y) { preset.positionY = value }
    if let box = option("--box"), let value = BoxMode(rawValue: box) { preset.boxMode = value }
    if flag("--shadow") { preset.shadowEnabled = true }
    return preset
}

func sizeFromOptions(default size: CGSize = CGSize(width: 1080, height: 1920)) -> CGSize {
    guard let text = option("--size") else { return size }
    let parts = text.split(separator: "x").compactMap { Double($0) }
    guard parts.count == 2 else { fail("bad --size") }
    return CGSize(width: parts[0], height: parts[1])
}

func run() async {
    FontLibrary.registerAppFonts()
    guard let command = arguments.first else { fail("usage: subtits-cli <probe|transcribe|cues|render|export|fonts> ...") }
    arguments.removeFirst()

    do {
        switch command {
        case "probe":
            let info = try await FFmpeg.probe(URL(fileURLWithPath: arguments[0]))
            print(info)
            print(info.summary)

        case "transcribe":
            let modelPath = option("--model") ?? ModelCatalog.recommended.localURL.path
            let language = option("--lang") ?? "ru"
            let outPath = option("--out")
            let prompt = option("--prompt") ?? ""
            let greedy = flag("--greedy")
            let vad = flag("--vad")
            let noDTW = flag("--no-dtw")
            if !flag("--verbose") { WhisperEngine.setLoggingEnabled(false) }
            let url = URL(fileURLWithPath: arguments[0])
            let info = try await FFmpeg.probe(url)
            guard info.hasAudio else { throw MediaError.noAudio }
            let work = AppPaths.makeTempDir("cli")
            defer { try? FileManager.default.removeItem(at: work) }
            var clock = Date()
            let samples = try await FFmpeg.extractAudioSamples(from: url, workDir: work, duration: info.duration)
            print(String(format: "audio: %d samples (%.1f s) in %.2f s", samples.count, Double(samples.count) / 16000, Date().timeIntervalSince(clock)))
            clock = Date()
            var options = WhisperOptions(modelPath: modelPath, language: language, prompt: prompt, beamSearch: !greedy, dtw: !noDTW)
            if vad { options.vadModelPath = AppPaths.vadModelURL?.path }
            var lastPrinted = -1
            let result = try WhisperEngine.transcribe(samples: samples, options: options, progress: { p in
                let percent = Int(p * 100)
                if percent / 10 != lastPrinted / 10 { print("progress \(percent)%"); lastPrinted = percent }
            })
            let elapsed = Date().timeIntervalSince(clock)
            print(String(format: "whisper %@: %.2f s (%.1fx realtime), language=%@", WhisperEngine.version, elapsed, info.duration / max(elapsed, 0.01), result.language))
            for segment in result.segments {
                print(String(format: "[%6.2f → %6.2f] %@", segment.start, segment.end, segment.text))
                print("    " + segment.words.map { String(format: "%@(%.2f-%.2f)", $0.text, $0.start, $0.end) }.joined(separator: " "))
            }
            let transcript = Transcript(language: result.language, modelName: URL(fileURLWithPath: modelPath).lastPathComponent,
                                        duration: info.duration, segments: result.segments)
            if let outPath {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(transcript).write(to: URL(fileURLWithPath: outPath))
                print("saved \(outPath)")
            }

        case "cues":
            let preset = presetFromOptions()
            let size = sizeFromOptions()
            let transcript = loadTranscript(arguments[0])
            let style = LayoutStyle(preset: preset, canvas: size)
            print("font: \(style.resolvedFamily) fallback=\(style.fontIsFallback) size=\(CTFontGetSizeCompat(style)) maxLineWidth=\(Int(style.maxLineWidth))")
            let cues = CueBuilder.build(words: transcript.words, style: style, mediaDuration: transcript.duration)
            let renderer = CueRenderer(preset: preset, canvas: size)
            for cue in cues {
                let lines = renderer.displayLines(cue)
                print(String(format: "%@ → %@  ", formatTimecode(cue.start), formatTimecode(cue.end)) + lines.joined(separator: " | "))
            }

        case "render":
            let preset = presetFromOptions()
            let size = sizeFromOptions()
            guard let outPath = option("--out") else { fail("--out required") }
            let time = Double(option("--time") ?? "") ?? -1
            let background = option("--background")
            let text = option("--text")
            let style = LayoutStyle(preset: preset, canvas: size)
            let renderer = CueRenderer(preset: preset, canvas: size)
            var cue = Cue(start: 0, end: 1, text: text ?? "Пример субтитров в выбранном стиле")
            if text == nil, let path = arguments.first {
                let transcript = loadTranscript(path)
                let cues = CueBuilder.build(words: transcript.words, style: style, mediaDuration: transcript.duration)
                cue = (time >= 0 ? cues.cue(at: time) : cues.first) ?? cue
            }
            // Optional word styles for testing: --word "1:color=ffd60a,size=110,slant=12,highlight=ff2d55,font=Playfair Display,face=Bold Italic,upper"
            if let spec = option("--word") {
                var styles: [Int: StyleOverride] = [:]
                for entry in spec.split(separator: ";") {
                    let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
                    guard parts.count == 2, let index = Int(parts[0]) else { continue }
                    var o = StyleOverride()
                    for item in parts[1].split(separator: ",") {
                        let kv = item.split(separator: "=", maxSplits: 1).map(String.init)
                        switch kv[0] {
                        case "color": o.textColor = hexColor(kv[1])
                        case "size": o.fontSize = Double(kv[1])
                        case "slant": o.slant = Double(kv[1])
                        case "highlight": o.highlightEnabled = true; o.highlightColor = hexColor(kv[1])
                        case "font": o.fontFamily = kv[1]
                        case "face": o.fontFace = kv[1]
                        case "upper": o.uppercase = true
                        default: break
                        }
                    }
                    styles[index] = o
                }
                cue.wordStyles = styles
            }
            guard let context = CueRenderer.makeContext(canvas: size, pixelSize: size) else { fail("context") }
            if let background, let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: background) as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                context.saveGState()
                context.translateBy(x: 0, y: size.height)
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(origin: .zero, size: size))
                context.restoreGState()
            } else {
                context.setFillColor(CGColor(red: 0.25, green: 0.35, blue: 0.45, alpha: 1))
                context.fill(CGRect(origin: .zero, size: size))
            }
            print("lines: \(renderer.displayLines(cue))")
            if let layout = renderer.layout(cue) {
                renderer.draw(layout, in: context)
            }
            try CueRenderer.writePNG(context.makeImage()!, to: URL(fileURLWithPath: outPath))
            print("saved \(outPath)")

        case "export":
            let preset = presetFromOptions()
            guard let outPath = option("--out") else { fail("--out required") }
            let format = ExportFormat(rawValue: option("--format") ?? "mp4H264") ?? .mp4H264
            let media = URL(fileURLWithPath: arguments[0])
            let transcript = loadTranscript(arguments[1])
            let info = try await FFmpeg.probe(media)
            print(info.summary)
            let style = LayoutStyle(preset: preset, canvas: info.size)
            let cues = CueBuilder.build(words: transcript.words, style: style, mediaDuration: info.duration)
            if format == .srt {
                try Exporter.srt(cues: cues, renderer: CueRenderer(preset: preset, canvas: info.size)).write(toFile: outPath, atomically: true, encoding: .utf8)
                print("saved \(outPath)")
                return
            }
            let clock = Date()
            var lastStage = ""
            var lastPercent = -1
            try await Exporter.exportVideo(info: info, cues: cues, preset: preset, format: format, output: URL(fileURLWithPath: outPath)) { stage, value in
                let percent = Int(value * 100)
                if stage != lastStage || percent / 10 != lastPercent / 10 {
                    print("\(stage) \(percent)%")
                    lastStage = stage
                    lastPercent = percent
                }
            }
            print(String(format: "saved %@ in %.1f s", outPath, Date().timeIntervalSince(clock)))

        case "check-catalog":
            // Verifies that every downloadable file of the font catalog exists.
            var failures = 0
            for font in FontCatalog.fonts {
                for item in font.downloads {
                    var request = URLRequest(url: item.url)
                    request.httpMethod = "HEAD"
                    let (_, response) = try await URLSession.shared.data(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if status != 200 {
                        failures += 1
                        print("FAIL \(status) \(font.id) \(item.name) \(item.url)")
                    }
                }
            }
            print("checked \(FontCatalog.fonts.count) fonts, failures: \(failures)")

        case "warmup":
            let clock = Date()
            WhisperEngine.warmUp()
            print(String(format: "warm-up: %.2f s", Date().timeIntervalSince(clock)))

        case "fonts":
            if let family = arguments.first {
                for face in FontLibrary.faces(of: family) {
                    print("\(face.styleName)\t\(face.postScriptName)\tweight=\(face.weight)\titalic=\(face.isItalic)")
                }
            } else {
                print("app fonts: \(FontLibrary.appFamilyNames)")
                print("all: \(FontLibrary.allFamilyNames().count) families")
            }

        default:
            fail("unknown command \(command)")
        }
    } catch {
        fail("error: \(error.localizedDescription)")
    }
}

func CTFontGetSizeCompat(_ style: LayoutStyle) -> Int { Int(CTFontGetSize(style.font)) }

func hexColor(_ hex: String) -> RGBAColor {
    let value = UInt32(hex, radix: 16) ?? 0xFFFFFF
    return RGBAColor(r: Double((value >> 16) & 0xFF) / 255, g: Double((value >> 8) & 0xFF) / 255, b: Double(value & 0xFF) / 255)
}

let semaphore = DispatchSemaphore(value: 0)
Task {
    await run()
    semaphore.signal()
}
semaphore.wait()
