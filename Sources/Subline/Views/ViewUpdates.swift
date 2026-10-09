import SwiftUI

// How the window keeps its redrawing to what changed. `AppModel` publishes every change of the work (a typed letter,
// a style value, the selection), and a view that watches it redraws on all of them. So the parts that cost the most do
// not watch it: a small parent that watches it gathers what the part shows into an Equatable value, and the part (made
// with `.equatable()`) redraws only when that value differs. The part keeps the model as a plain reference for its
// actions and bindings. What moves at its own pace has an object of its own, watched only by the views that show it:
// the playhead time (`PlaybackClock`), the subtitle under it (`PlayheadCue`), the subtitle image (`PreviewOverlay`).

/// Tests: how many times the main parts of the window drew themselves, by name. Counts only in debug builds and only
/// while `isCounting` is on; in release builds `hit` does nothing.
enum RenderCount {
    #if DEBUG
    @MainActor static var isCounting = false
    @MainActor static var counts: [String: Int] = [:]
    #endif

    @MainActor @inline(__always) static func hit(_ name: String) -> Int {
        #if DEBUG
        if isCounting { counts[name, default: 0] += 1 }
        #endif
        return 0
    }
}
