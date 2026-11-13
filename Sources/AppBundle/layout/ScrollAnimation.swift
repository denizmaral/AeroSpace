import AppKit
import Common

/// The screen of a scrolling workspace slides along the strip of columns (see ``Layout/scrolling``): the windows move
/// from where the previous offset put them to their new places in a fifth of a second, fast and then slower. A column
/// that leaves the screen slides off it, and waits in the corner of the screen then.
///
/// Only the positions change during a slide (moving a window costs the app much less than resizing it), and an app that
/// is busy skips steps: a frame that the app didn't take yet is replaced by the next one (see `MacApp.setAxFrame`). The
/// layouts of the sessions that follow (e.g. the complete refresh session after a command, the windows that moved) leave
/// a sliding window alone while they want it where the slide ends. One that wants it elsewhere takes it over
@MainActor
enum ScrollAnimation {
    struct Slide {
        let window: Window
        let from: CGPoint
        /// Where the slide ends
        let to: CGPoint
        let size: CGSize
        /// The top left corner of the window after the slide: `to`, or the corner of the screen for a column that slid
        /// off it
        let final: CGPoint
    }

    private static let duration: Duration = .milliseconds(220)
    private static var slides: [OpaqueWindowId: Slide] = [:]
    private static var task: Task<Void, Never>? = nil

    /// The window slides to where the layout wants it
    static func isSliding(_ window: Window, to final: CGPoint, size: CGSize) -> Bool {
        guard let slide = slides[window.windowId] else { return false }
        return slide.final == final && slide.size == size
    }

    /// The layout puts the window somewhere else
    static func stop(_ window: Window) {
        slides.removeValue(forKey: window.windowId)
    }

    static func start(_ newSlides: [Slide]) {
        // The windows of a slide that is under way and doesn't go on: where it was taking them
        for (id, slide) in slides where !newSlides.contains(where: { $0.window.windowId == id }) {
            slide.window.setAxFrame(slide.final, slide.size)
        }
        slides = Dictionary(newSlides.map { ($0.window.windowId, $0) }, uniquingKeysWith: { _, last in last })
        for slide in newSlides {
            slide.window.setAxFrame(slide.from, slide.size, readBack: false)
        }
        task?.cancel()
        task = Task.startUnstructured { @MainActor in
            let start = ContinuousClock.now
            while true {
                try? await Task.sleep(for: .milliseconds(16)) // A frame of the display
                if Task.isCancelled { return }
                let progress = min(1, (ContinuousClock.now - start) / duration)
                if progress >= 1 { break }
                let eased = 1 - pow(1 - progress, 3) // Ease out
                for slide in slides.values {
                    let point = CGPoint(x: slide.from.x + (slide.to.x - slide.from.x) * eased, y: slide.from.y + (slide.to.y - slide.from.y) * eased)
                    slide.window.setAxFrame(point, nil, readBack: false)
                }
            }
            let ended = slides.values
            slides = [:]
            for slide in ended {
                slide.window.setAxFrame(slide.final, slide.size) // Read back: what the window made of its tile
            }
        }
    }
}
