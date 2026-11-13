import AppKit
import Common
import Synchronization

// Two fingers sideways on the trackpad move through the columns of a scrolling workspace (see Layout.scrolling), like the
// view of niri and Hyprland follows the fingers. Three fingers aren't seen by apps on macOS (only by the system, or by a
// private framework), so it's the scroll events of two fingers: a gesture that goes sideways over a monitor that shows
// a scrolling workspace is taken from the app under the mouse, every other one is left to it (scrolling up and down,
// sideways over a tiling workspace, a mouse wheel).
//
// The windows move by whole columns: a column per `ColumnScrollGesture.columnDistance` of the fingers, through the focus,
// like `focus left` and `focus right`. Moving windows along with every scroll event through the accessibility API would
// lag behind the fingers.
//
// The event tap runs on a thread of its own: the scroll events of every app pass through it, and the main thread may be
// busy. It reads what it needs (`TrackpadColumnScrolling.shared`) under a mutex, the main actor writes it after layouts.

/// The gesture of two fingers that the trackpad reports with scroll events: whether it's taken from the app, and how far
/// the screen moves along the columns. A pure state machine
struct ColumnScrollGesture: Sendable, Equatable {
    /// The fingers' distance (scroll points) for a column
    static let columnDistance: CGFloat = 110
    /// The fingers' distance after which it's clear whether the gesture goes sideways
    static let decisionDistance: CGFloat = 6
    /// A shorter gesture that is taken moves no column: the fingers only brushed the trackpad
    static let flickDistance: CGFloat = 30

    enum State: Sendable, Equatable {
        case idle
        /// Too short to tell the direction: the events go to the app meanwhile
        case undecided(dx: CGFloat, dy: CGFloat)
        /// Sideways: the gesture (and its momentum after the fingers left the trackpad) moves the columns
        case taken
        /// Left to the app, with its momentum
        case left
    }

    enum Phase: Sendable, Equatable {
        /// The fingers touch the trackpad (also the "may begin" phase)
        case began
        case changed
        /// The fingers left the trackpad, or the gesture was canceled
        case ended
        /// The scrolling goes on by itself after the fingers left
        case momentum
        /// Not a phase of a gesture: a mouse wheel
        case none
    }

    /// What becomes of a scroll event
    enum Verdict: Sendable, Equatable {
        /// The app gets it
        case pass
        /// The app doesn't get it
        case take
        /// The gesture is taken from now on: the app gets this event as the end of a canceled gesture (without its
        /// distance), it saw the beginning and must not wait for the rest (a scroll view, the back gesture of a browser)
        case cancelForApp
    }

    private(set) var state: State = .idle
    private var distance: CGFloat = 0
    /// The columns that the gesture moved so far
    private var moved = 0

    /// - Parameter isWanted: a gesture that begins now may move columns: over a scrolling workspace, from a trackpad, with
    ///   the modifiers of the settings
    /// - Parameter dx: the scrolling sideways, as apps get it (positive: the content follows fingers that go right)
    /// - Returns: what becomes of the event, and how many columns the screen moves (negative: to the left)
    mutating func handle(_ phase: Phase, dx: CGFloat, dy: CGFloat, isWanted: @autoclosure () -> Bool) -> (verdict: Verdict, columns: Int) {
        switch phase {
            case .none: return (.pass, 0)
            case .momentum: return (state == .taken ? .take : .pass, 0) // Its momentum doesn't reach the app, nor moves columns
            case .ended:
                if case .undecided = state { state = .left }
                guard state == .taken else { return (.pass, 0) }
                // A quick flick that didn't reach the distance of a column moves one: it was meant to
                let flick = moved == 0 && abs(distance) >= Self.flickDistance ? (distance > 0 ? -1 : 1) : 0
                return (.take, flick)
            case .began:
                state = isWanted() ? .undecided(dx: 0, dy: 0) : .left
                (distance, moved) = (0, 0)
            case .changed:
                if state == .idle { // The beginning was missed
                    state = isWanted() ? .undecided(dx: 0, dy: 0) : .left
                    (distance, moved) = (0, 0)
                }
        }
        switch state {
            case .idle, .left: return (.pass, 0)
            case .undecided(let sumX, let sumY):
                let (sumX, sumY) = (sumX + abs(dx), sumY + abs(dy))
                distance += dx
                if sumX + sumY < Self.decisionDistance {
                    state = .undecided(dx: sumX, dy: sumY)
                    return (.pass, 0)
                }
                state = sumX > sumY * 1.5 ? .taken : .left
                return state == .taken ? (.cancelForApp, step()) : (.pass, 0)
            case .taken:
                distance += dx
                return (.take, step())
        }
    }

    /// The fingers going right move the strip right: the columns on the left come in
    private mutating func step() -> Int {
        let columns = Int(distance / Self.columnDistance)
        distance -= CGFloat(columns) * Self.columnDistance
        moved += abs(columns)
        return -columns
    }
}

enum TrackpadColumnScrolling {
    /// What the event tap reads, on its thread
    struct Shared: Sendable {
        /// The monitors (top left origin) that show a scrolling workspace
        var screens: [Rect] = []
        /// Windows over the columns that keep their gestures: floating windows, the windows of MarSpace
        var excluded: [Rect] = []
        /// Exactly these modifiers are held during a gesture that moves columns: e.g. none, or Option
        var modifiers: CGEventFlags = []
        var gesture = ColumnScrollGesture()
    }

    static let shared = Mutex(Shared())

    /// Created once, read by the callback on the thread of the tap (to enable it again after macOS disabled it)
    nonisolated(unsafe) fileprivate static var tap: CFMachPort? = nil

    /// Starts the event tap, disabled until a monitor shows a scrolling workspace (see ``update()``)
    @MainActor
    static func start() {
        guard !isUnitTest, unsafe tap == nil else { return }
        let mask = CGEventMask(1) << CGEventMask(CGEventType.scrollWheel.rawValue)
        guard let port = unsafe CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: scrollEventTapCallback,
            userInfo: nil,
        ) else {
            perfLogger.error("Can't create the event tap for the trackpad: no accessibility permission?")
            return
        }
        unsafe tap = port
        CGEvent.tapEnable(tap: port, enable: false)
        let thread = Thread {
            guard let port = unsafe TrackpadColumnScrolling.tap,
                  let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            else { return }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopRun()
        }
        thread.name = "MarSpace trackpad scrolling"
        thread.qualityOfService = .userInteractive
        thread.start()
        update()
    }

    /// After every layout: which monitors show a scrolling workspace. The tap is enabled only while one does, the scroll
    /// events of the other workspaces don't go through MarSpace. Nothing is taken while MarSpace is disabled, or while a
    /// window in macOS fullscreen has the focus (its own Space is shown: a column that got the focus would leave it)
    @MainActor
    static func update() {
        guard let port = unsafe tap else { return }
        let isFullscreenShown = globalFocus.windowOrNil?.parent is MacosFullscreenWindowsContainer
        let workspaces = config.trackpadScrollsColumns && TrayMenuModel.shared.isEnabled && !isFullscreenShown
            ? globalUnsortedMonitorInfos.map(\.visibleWorkspace).filter { $0.rootTilingContainer.layout == .scrolling }
            : []
        let screens = workspaces.map(\.workspaceMonitorInfo.rect)
        // Not the windows of MarSpace that let the mouse through: the focus border covers the focused column
        let excluded = workspaces.flatMap { $0.floatingWindows.compactMap(\.observedFrame) } +
            NSApp.windows.filter { $0.isVisible && !$0.ignoresMouseEvents }.map(\.frame.withYAxisFlipped)
        let modifiers = config.trackpadScrollModifiers
        let changed = shared.withLock { shared in
            defer { (shared.screens, shared.excluded, shared.modifiers) = (screens, excluded, modifiers) }
            return shared.screens.isEmpty != screens.isEmpty
        }
        if changed { CGEvent.tapEnable(tap: port, enable: !screens.isEmpty) }
    }

    /// On the thread of the tap
    fileprivate static func handle(_ event: CGEvent) -> (verdict: ColumnScrollGesture.Verdict, columns: Int) {
        let scrollPhase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        let phase: ColumnScrollGesture.Phase = switch (scrollPhase, momentumPhase) {
            case (_, 1...): .momentum
            case (1, _), (128, _): .began // kCGScrollPhaseBegan, kCGScrollPhaseMayBegin
            case (2, _): .changed
            case (4, _), (8, _): .ended // kCGScrollPhaseEnded, kCGScrollPhaseCancelled
            default: .none
        }
        let dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        let dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let location = event.location
        let modifiers = event.flags.intersection([.maskAlternate, .maskCommand, .maskControl, .maskShift])
        return shared.withLock { shared in
            shared.gesture.handle(phase, dx: dx, dy: dy, isWanted: isContinuous && modifiers == shared.modifiers &&
                shared.screens.contains { $0.contains(location) } && !shared.excluded.contains { $0.contains(location) })
        }
    }

    /// The columns of the workspace under the mouse move: its most recent window and the windows next to it, like `focus`
    @MainActor
    fileprivate static func moveColumns(_ columns: Int, at location: CGPoint) async {
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        try? await runLightSession(.trackpadScroll, token) {
            let root = location.monitorApproximation.visibleWorkspace.rootTilingContainer
            guard root.layout == .scrolling else { return }
            guard case .cmd(let focus) = Action.focus(columns < 0 ? .left : .right).command else { return }
            for _ in 0 ..< abs(columns) {
                guard let window = root.mostRecentWindowRecursive else { return }
                _ = await focus.run(CmdEnv.defaultEnv.withWindowId(window.windowId), .emptyStdin)
            }
        }
    }
}

private func scrollEventTapCallback(
    _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    _: UnsafeMutableRawPointer?,
) -> Unmanaged<CGEvent>? {
    switch type {
        case .scrollWheel:
            let (verdict, columns) = TrackpadColumnScrolling.handle(event)
            if columns != 0 {
                let location = event.location
                Task.startUnstructured { @MainActor in await TrackpadColumnScrolling.moveColumns(columns, at: location) }
            }
            switch verdict {
                case .pass: return unsafe Unmanaged.passUnretained(event)
                case .take: return nil
                case .cancelForApp:
                    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 8) // kCGScrollPhaseCancelled
                    for field: CGEventField in [
                        .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2,
                        .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2,
                    ] {
                        event.setDoubleValueField(field, value: 0)
                    }
                    event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
                    event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 0)
                    return unsafe Unmanaged.passUnretained(event)
            }
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS disables a tap that was too slow. It's enabled again if a monitor still shows a scrolling workspace
            let isWanted = TrackpadColumnScrolling.shared.withLock { !$0.screens.isEmpty }
            if isWanted, let tap = unsafe TrackpadColumnScrolling.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return unsafe Unmanaged.passUnretained(event)
        default:
            return unsafe Unmanaged.passUnretained(event)
    }
}
