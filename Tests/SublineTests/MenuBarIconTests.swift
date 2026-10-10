import XCTest
import AppKit
import SwiftUI
@testable import Subline
@testable import SublineCore

/// The icon in the menu bar: as big as the menu bar's own icons, standing still, with the check mark and the exclamation
/// mark inside the plate, and the menu of the family standard. Drawn offscreen; no status item is made (the tests keep the
/// icon switched off), so nothing appears in the menu bar.
@MainActor
final class MenuBarIconTests: XCTestCase {
    override func setUp() async throws {
        TestEnvironment.setUp()
    }

    // MARK: Size and drawing

    func testTheGlyphIsAsBigAsTheMenuBarsOwnIcons() {
        // The menu bar's own icons (Wi-Fi, Control Center) are about 16 pt high and at most 20 wide, in an image 22 pt
        // high. The badge is 1.4 times as wide as high, so at 16 pt it would be 22.4 wide: it is 20 wide and 14 high, in
        // the middle of the image, and half a point is left beside it, like in every app of the family.
        XCTAssertEqual(WorkGlyph.size.height, 22)
        XCTAssertLessThanOrEqual(WorkGlyph.size.height, NSStatusBar.system.thickness, "the image fits the menu bar")
        XCTAssertEqual(WorkGlyph.size, NSSize(width: 21, height: 22))
        XCTAssertEqual(WorkGlyph.plate, NSRect(x: 0.5, y: 4, width: 20, height: 14))
        XCTAssertLessThanOrEqual(WorkGlyph.plate.height, 16, "no higher than the system icons")
        XCTAssertLessThanOrEqual(WorkGlyph.plate.width, 20, "no wider than the system icons")
        XCTAssertEqual(WorkGlyph.plate.width / WorkGlyph.plate.height, 1.4, accuracy: 0.03, "the badge's proportions")
        XCTAssertEqual(WorkGlyph.plate.midY, WorkGlyph.size.height / 2, "the plate is in the middle of the image")
        for face in [WorkGlyph.Face.working, .success, .failure] {
            let image = WorkGlyph.image(face)
            XCTAssertEqual(image.size, WorkGlyph.size)
            XCTAssertTrue(image.isTemplate, "the menu bar tints a template image itself")
        }
        XCTAssertTrue(WorkGlyph.image(.working) === WorkGlyph.image(.working), "a face that comes back is not drawn again")
    }

    func testNothingTouchesTheEdgeOfThePlateOrOfTheImage() throws {
        // 8 pixels to the point. The capsules, the check mark and the exclamation mark are cut out of the plate; each
        // cut-out stays 1.75 pt (14 px) away from the plate's edge, so none of them is clipped, and the plate itself
        // stays inside the image with its margin: half a point at the sides, 4 pt above and below.
        let scale = 8
        let clearance = 14
        let side = Int(WorkGlyph.plate.minX * CGFloat(scale)), vertical = Int(WorkGlyph.plate.minY * CGFloat(scale))
        let expected: [WorkGlyph.Face: Int] = [.working: 4, .success: 1, .failure: 2]
        for (face, cuts) in expected {
            let alpha = try alphaRows(face, scale: scale)
            let height = alpha.count, width = alpha[0].count
            XCTAssertEqual(width, Int(WorkGlyph.size.width) * scale)
            XCTAssertEqual(height, Int(WorkGlyph.size.height) * scale)
            // The plate: where the image is more than half opaque.
            let solid = box(of: alpha.map { $0.map { $0 > 0.5 } })
            XCTAssertLessThanOrEqual(abs(solid.minX - side), 1, "\(face): half a point at the left")
            XCTAssertLessThanOrEqual(abs(solid.maxX - (width - side - 1)), 1, "\(face): half a point at the right")
            XCTAssertLessThanOrEqual(abs(solid.minY - vertical), 1, "\(face): 4 pt above")
            XCTAssertLessThanOrEqual(abs(solid.maxY - (height - vertical - 1)), 1, "\(face): 4 pt below")
            // Everything round the plate is clear.
            var dirty = 0
            for y in 0..<height {
                for x in 0..<width where (x < side || x >= width - side || y < vertical || y >= height - vertical) && alpha[y][x] > 0.01 {
                    dirty += 1
                }
            }
            XCTAssertEqual(dirty, 0, "\(face): the margin of the image is clear")
            // The clear parts that the corner of the image does not reach are the cut-outs.
            let parts = components(alpha.map { $0.map { $0 <= 0.5 } })
            let holes = parts.filter { part in !part.contains { $0.x == 0 && $0.y == 0 } }
            XCTAssertEqual(holes.count, cuts, "\(face): the number of cut-outs")
            for hole in holes {
                var mask = Array(repeating: Array(repeating: false, count: width), count: height)
                for cell in hole { mask[cell.y][cell.x] = true }
                let cut = box(of: mask)
                XCTAssertGreaterThanOrEqual(cut.minX - solid.minX, clearance, "\(face): a cut-out too close to the left edge")
                XCTAssertGreaterThanOrEqual(solid.maxX - cut.maxX, clearance, "\(face): a cut-out too close to the right edge")
                XCTAssertGreaterThanOrEqual(cut.minY - solid.minY, clearance, "\(face): a cut-out too close to the top edge")
                XCTAssertGreaterThanOrEqual(solid.maxY - cut.maxY, clearance, "\(face): a cut-out too close to the bottom edge")
            }
        }
    }

    func testTheCapsulesAreAsThickAsTheProportionsSay() {
        // The icon's proportions (lines 9 thicknesses wide) at the size of the plate: 1.5 pt thick, 13.5 pt wide lines.
        let marks = WorkGlyph.marks
        XCTAssertEqual(marks.count, 4)
        let thickness: CGFloat = 1.5
        for line in [[marks[0], marks[1]], [marks[2], marks[3]]] {
            XCTAssertEqual(line[0].y, line[1].y)
            let width = (line[1].x1 + thickness / 2) - (line[0].x0 - thickness / 2)
            XCTAssertEqual(width, 13.5, accuracy: 0.001, "both lines are 9 thicknesses wide")
            XCTAssertEqual((line[0].x0 + line[1].x1) / 2, WorkGlyph.plate.midX, accuracy: 0.001, "the lines are in the middle")
        }
        XCTAssertEqual(marks[2].y - marks[0].y, 2.5, "the lines are 2.5 pt apart, the plate's middle between them")
        XCTAssertEqual((marks[0].y + marks[2].y) / 2, WorkGlyph.plate.midY)
        // The edges of the lines lie on whole pixels at 2x (a point is 2 pixels), so the lines are crisp on Retina.
        for mark in [marks[0], marks[2]] {
            XCTAssertEqual(((mark.y - thickness / 2) * 2).truncatingRemainder(dividingBy: 1), 0, accuracy: 0.001)
            XCTAssertEqual(((mark.y + thickness / 2) * 2).truncatingRemainder(dividingBy: 1), 0, accuracy: 0.001)
        }
    }

    // MARK: It stands still

    func testTheIconStandsStillWhileTheWorkGoes() {
        let icon = MenuBarIcon()
        XCTAssertNil(icon.face)
        for progress in [nil, 0, 0.4, 1] as [Double?] {
            icon.show(Activity(kind: .transcribing, title: "", progress: progress))
            XCTAssertEqual(icon.face, .working, "recognition does not type its lines in, whatever the progress")
            icon.show(Activity(kind: .exporting, title: "", progress: progress))
            XCTAssertEqual(icon.face, .working, "export does not fill its lines, whatever the progress")
        }
        icon.show(Activity(kind: .opening, title: "", progress: nil))
        XCTAssertNil(icon.face, "opening a file is no reason for the icon")
        icon.show(nil)
        XCTAssertNil(icon.face)
    }

    // MARK: The menu

    func testTheMenuOfTheIconFollowsTheFamilyStandard() throws {
        let icon = MenuBarIcon()
        var stopped = 0
        icon.stopWork = { stopped += 1 }
        func titles() -> [String] { icon.makeMenu().items.map { $0.isSeparatorItem ? "—" : $0.title } }
        let tail = [L("Настройки…"), L("Проверить обновления…"), L("О приложении «Subline»"), "—", L("Завершить Subline")]

        XCTAssertEqual(titles(), tail, "with no work there is nothing to stop")
        icon.show(Activity(kind: .transcribing, title: "", progress: 0.3))
        XCTAssertEqual(titles(), [L("Остановить распознавание"), "—"] + tail)
        icon.show(Activity(kind: .exporting, title: "", progress: 0.3))
        XCTAssertEqual(titles(), [L("Остановить экспорт"), "—"] + tail)

        let menu = icon.makeMenu()
        let settings = try XCTUnwrap(menu.items.first { $0.title == L("Настройки…") })
        XCTAssertEqual(settings.keyEquivalent, ",")
        XCTAssertEqual(settings.keyEquivalentModifierMask, .command)
        let quit = try XCTUnwrap(menu.items.first { $0.title == L("Завершить Subline") })
        XCTAssertEqual(quit.keyEquivalent, "q")
        XCTAssertEqual(quit.keyEquivalentModifierMask, .command)
        XCTAssertTrue(menu.items.allSatisfy { $0.isSeparatorItem || ($0.target === icon && $0.action != nil) },
                      "every item goes to the icon, which asks the model")

        // «Остановить» stops the work through the model.
        let stop = try XCTUnwrap(menu.items.first)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(stop.action), to: stop.target, from: stop))
        XCTAssertEqual(stopped, 1)
    }

    // MARK: Settings

    /// Settings in the order of the standard, their language row and the restart that follows a new language, with the
    /// icon, drawn into one picture: SUBLINE_TEST_RENDERS/settings-and-icon.png.
    func testSheetOfSettingsAndTheIcon() throws {
        // The language is read from and written to two defaults domains of the test's own, the switches of Settings
        // are read from the first of them (every one is on while nothing is saved): the app's own settings stay as they are.
        let updater = AppModel().updater
        let calmSuite = "MenuBarIconTests.calm", pendingSuite = "MenuBarIconTests.pending"
        let calmDefaults = try XCTUnwrap(UserDefaults(suiteName: calmSuite))
        let pendingDefaults = try XCTUnwrap(UserDefaults(suiteName: pendingSuite))
        for name in [calmSuite, pendingSuite] { UserDefaults.standard.removePersistentDomain(forName: name) }
        defer { for name in [calmSuite, pendingSuite] { UserDefaults.standard.removePersistentDomain(forName: name) } }
        let system = InterfaceLanguage.language(for: InterfaceLanguage.systemLanguages)

        // «Как в системе», and the language the Mac gives: nothing to restart.
        let calm = LanguageSource(defaults: calmDefaults, domain: calmSuite, running: system)
        XCTAssertEqual(calm.saved, .system)
        XCTAssertFalse(calm.needsRestart)
        // English chosen while Russian runs: the restart row shows.
        InterfaceLanguage.save(.english, in: pendingDefaults, domain: pendingSuite)
        let pending = LanguageSource(defaults: pendingDefaults, domain: pendingSuite, running: "ru")
        XCTAssertEqual(pending.saved, .english)
        XCTAssertTrue(pending.needsRestart)

        let icon = NSImage(contentsOf: TestEnvironment.root.appendingPathComponent("Resources/AppIcon-1024.png"))
        let sheet = VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .top, spacing: 28) {
                caption("Настройки: язык «Как в системе»",
                        SettingsView(language: calm).environmentObject(updater).defaultAppStorage(calmDefaults))
                caption("Выбран English, нужен перезапуск",
                        SettingsView(language: pending).environmentObject(updater).defaultAppStorage(calmDefaults))
                if let icon {
                    caption("Иконка приложения", Image(nsImage: icon).resizable().interpolation(.high).frame(width: 300, height: 300))
                }
            }
            HStack(alignment: .top, spacing: 36) {
                ForEach([("working", WorkGlyph.Face.working), ("success", .success), ("failure", .failure)], id: \.0) { name, face in
                    self.glyphColumn(name, face)
                }
            }
        }
        .padding(28)
        .frame(width: 1180, height: 700, alignment: .topLeading)
        .background(Color(white: 0.45))
        try TestEnvironment.render(sheet, size: CGSize(width: 1180, height: 700), name: "settings-and-icon.png")
    }

    // MARK: Pictures

    private func caption<V: View>(_ text: String, _ content: V) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            content
        }
    }

    /// One face: 8 times as large with the plate and the image outlined, and in a menu bar, dark and light, at its size.
    private func glyphColumn(_ name: String, _ face: WorkGlyph.Face) -> some View {
        let zoom = zoomed(face, scale: 8, white: true)
        return VStack(alignment: .leading, spacing: 10) {
            Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            Image(nsImage: zoom)
                .interpolation(.none)
                .frame(width: WorkGlyph.size.width * 8, height: WorkGlyph.size.height * 8)
                .background(Color.black)
                .overlay(Rectangle().strokeBorder(Color.red.opacity(0.7), lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    Rectangle().strokeBorder(Color.green.opacity(0.7), lineWidth: 1)
                        .frame(width: WorkGlyph.plate.width * 8, height: WorkGlyph.plate.height * 8)
                        .offset(x: WorkGlyph.plate.minX * 8, y: WorkGlyph.plate.minY * 8)
                }
            HStack(spacing: 0) {
                strip(face, dark: true)
                strip(face, dark: false)
            }
        }
    }

    /// The menu bar at its real height with the icon in it (a status item is the image and the margins of the menu bar).
    private func strip(_ face: WorkGlyph.Face, dark: Bool) -> some View {
        HStack(spacing: 0) {
            Image(nsImage: WorkGlyph.image(face))
                .renderingMode(.template)
                .foregroundStyle(dark ? Color.white : Color.black)
                .padding(.horizontal, 6)
        }
        .frame(width: 116, height: 24)
        .background(dark ? Color(white: 0.12) : Color(white: 0.92))
    }

    // MARK: Pixels

    /// The face drawn as the menu bar draws it, at `scale` pixels per point: the alpha of every pixel, row by row from
    /// the top.
    private func alphaRows(_ face: WorkGlyph.Face, scale: Int) throws -> [[Double]] {
        let rep = try bitmap(face, scale: scale)
        return (0..<rep.pixelsHigh).map { y in (0..<rep.pixelsWide).map { x in Double(rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) } }
    }

    private func bitmap(_ face: WorkGlyph.Face, scale: Int) throws -> NSBitmapImageRep {
        let image = WorkGlyph.image(face)
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width) * scale,
                                                 pixelsHigh: Int(image.size.height) * scale, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = image.size
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// The face enlarged, painted white (or black) the way the menu bar tints a template image.
    private func zoomed(_ face: WorkGlyph.Face, scale: Int, white: Bool) -> NSImage {
        guard let rep = try? bitmap(face, scale: scale) else { return NSImage() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (white ? NSColor.white : NSColor.black).set()
        NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh).fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        image.addRepresentation(rep)
        return image
    }

    /// The smallest box round the true cells.
    private func box(of mask: [[Bool]]) -> (minX: Int, maxX: Int, minY: Int, maxY: Int) {
        var result = (minX: Int.max, maxX: Int.min, minY: Int.max, maxY: Int.min)
        for (y, row) in mask.enumerated() {
            for (x, on) in row.enumerated() where on {
                result = (min(result.minX, x), max(result.maxX, x), min(result.minY, y), max(result.maxY, y))
            }
        }
        return result
    }

    /// The groups of neighbouring true cells (4-connected).
    private func components(_ mask: [[Bool]]) -> [[(x: Int, y: Int)]] {
        let height = mask.count, width = mask[0].count
        var seen = Array(repeating: Array(repeating: false, count: width), count: height)
        var groups: [[(x: Int, y: Int)]] = []
        for y in 0..<height {
            for x in 0..<width where mask[y][x] && !seen[y][x] {
                var stack = [(x: x, y: y)], cells: [(x: Int, y: Int)] = []
                seen[y][x] = true
                while let cell = stack.popLast() {
                    cells.append(cell)
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let (nx, ny) = (cell.x + dx, cell.y + dy)
                        if nx >= 0, ny >= 0, nx < width, ny < height, mask[ny][nx], !seen[ny][nx] {
                            seen[ny][nx] = true
                            stack.append((x: nx, y: ny))
                        }
                    }
                }
                groups.append(cells)
            }
        }
        return groups
    }
}
