// Renders the app icon into Resources/AppIcon.icns
// Usage: swift scripts/make_icon.swift
//
// Two subtitle lines drawn as dashes and dots, "— — •" over "• —", centered like captions, in the
// Liquid Glass manner of macOS 26–27: a graphite body lit from above with a glass rim, and white marks
// that float above it and catch the light along their top edge.
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Subline.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let space = CGColorSpace(name: CGColorSpace.sRGB)!

/// Apple-style continuous corners (superellipse).
func squircle(_ rect: CGRect, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / exponent)
        let y = rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / exponent)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// Linear or radial gradient from (location, r, g, b, a) stops.
func gradient(_ stops: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)]) -> CGGradient {
    let colors = stops.map { CGColor(colorSpace: space, components: [$0.1, $0.2, $0.3, $0.4])! }
    return CGGradient(colorsSpace: space, colors: colors as CFArray, locations: stops.map { $0.0 })!
}

enum Mark { case dash, dot }

func render(size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(body)

    // Body with a soft shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(gray: 0.04, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    // Deep graphite to black, lit from above.
    ctx.drawLinearGradient(gradient([(0, 0.20, 0.20, 0.23, 1), (0.55, 0.07, 0.07, 0.08, 1), (1, 0.02, 0.02, 0.025, 1)]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Soft glow behind the captions.
    ctx.drawRadialGradient(gradient([(0, 1, 1, 1, 0.07), (1, 1, 1, 1, 0)]),
                           startCenter: CGPoint(x: 512, y: 560), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 560), endRadius: 430, options: [])
    // Glass rim: bright along the top, faint along the bottom.
    ctx.addPath(squircle(body.insetBy(dx: 2, dy: 2)))
    ctx.setLineWidth(4)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, 1, 1, 1, 0.42), (0.35, 1, 1, 1, 0.06), (0.7, 1, 1, 1, 0.03), (1, 1, 1, 1, 0.14)]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // Captions: two lines of dashes and dots, "— — •" over "• —".
    let thickness: CGFloat = 84
    let dash: CGFloat = 216
    let gap: CGFloat = 58
    let lineGap: CGFloat = 70
    let rows: [[Mark]] = [[.dash, .dash, .dot], [.dot, .dash]]
    func width(_ row: [Mark]) -> CGFloat {
        row.map { $0 == .dash ? dash : thickness }.reduce(0, +) + CGFloat(row.count - 1) * gap
    }
    var marks: [CGRect] = []
    let blockHeight = CGFloat(rows.count) * thickness + CGFloat(rows.count - 1) * lineGap
    var top = body.midY + blockHeight / 2
    for row in rows {
        var x = body.midX - width(row) / 2
        for mark in row {
            let length = mark == .dash ? dash : thickness
            marks.append(CGRect(x: x, y: top - thickness, width: length, height: thickness))
            x += length + gap
        }
        top -= thickness + lineGap
    }

    for rect in marks {
        let pill = CGPath(roundedRect: rect, cornerWidth: thickness / 2, cornerHeight: thickness / 2, transform: nil)
        // Depth: the mark floats above the body.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: CGColor(gray: 0, alpha: 0.7))
        ctx.addPath(pill)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(pill)
        ctx.clip()
        // Volume: white at the top, a cool grey at the bottom.
        ctx.drawLinearGradient(gradient([(0, 1, 1, 1, 1), (0.6, 0.95, 0.95, 0.97, 1), (1, 0.80, 0.81, 0.86, 1)]),
                               start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        // Specular highlight along the top edge: the part that catches the light.
        let highlight = CGPath(roundedRect: rect.insetBy(dx: 10, dy: 8).offsetBy(dx: 0, dy: 4),
                               cornerWidth: (thickness - 16) / 2, cornerHeight: (thickness - 16) / 2, transform: nil)
        ctx.addPath(highlight)
        ctx.clip()
        ctx.drawLinearGradient(gradient([(0, 1, 1, 1, 0.95), (0.45, 1, 1, 1, 0), (1, 1, 1, 1, 0)]),
                               start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        ctx.restoreGState()

        // Crisp inner edge: light on top, a darker line at the bottom.
        ctx.saveGState()
        ctx.addPath(pill)
        ctx.clip()
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), cornerWidth: thickness / 2 - 1.5, cornerHeight: thickness / 2 - 1.5, transform: nil))
        ctx.setLineWidth(3)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(gradient([(0, 1, 1, 1, 0.9), (0.5, 1, 1, 1, 0), (1, 0.45, 0.47, 0.55, 0.55)]),
                               start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        ctx.restoreGState()
    }
    return ctx.makeImage()!
}


func png(size: Int) -> Data {
    NSBitmapImageRep(cgImage: render(size: size)).representation(using: .png, properties: [:])!
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in sizes {
    try png(size: size).write(to: iconset.appendingPathComponent("\(name).png"))
}
try png(size: 1024).write(to: root.appendingPathComponent("Resources/AppIcon-1024.png"))

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try process.run()
process.waitUntilExit()
print(process.terminationStatus == 0 ? "Resources/AppIcon.icns written" : "iconutil failed")
