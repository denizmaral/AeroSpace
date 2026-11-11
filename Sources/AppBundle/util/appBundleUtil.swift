import AppKit
import Common
import Foundation
import os

let signposter = OSSignposter(subsystem: aeroSpaceAppId, category: .pointsOfInterest)

let myPid = NSRunningApplication.current.processIdentifier
let lockScreenAppBundleId = "com.apple.loginwindow"

func interceptTermination(_ _signal: Int32) {
    signal(_signal, { (signal: Int32) in
        check(Thread.current.isMainThread)
        Task.startUnstructured { @MainActor in
            runTerminationHandlerOnce()
            exit(signal)
        }
    } as sig_t)
}

@MainActor
func initTerminationHandler() {
    unsafe _terminationHandler = AppServerTerminationHandler()
    // `kill`, e.g. by a script that restarts MarSpace: quit like the menu does (the default action of SIGTERM ends the
    // process right away, with the windows of the workspaces that aren't shown still in the corner of the screen)
    signal(SIGTERM, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    source.setEventHandler { MainActor.assumeIsolated { NSApplication.shared.terminate(nil) } }
    source.resume()
    sigtermSource = source
}

@MainActor private var sigtermSource: (any DispatchSourceSignal)? = nil // Kept alive

@MainActor var didRunTerminationHandler = false

/// Puts the windows back on screen before MarSpace quits, however it quits: "Quit" in the menu, ⌘Q or the Dock while the
/// settings window is open, logging out, `kill`. Only once: "Quit" runs it and then terminates the app, which runs it again
@MainActor
func runTerminationHandlerOnce() {
    if didRunTerminationHandler { return }
    didRunTerminationHandler = true
    terminationHandler?.beforeTermination()
}

private struct AppServerTerminationHandler: TerminationHandler {
    @MainActor
    func beforeTermination() {
        // Make all windows fullscreen before Quit
        // It may be invoked when something went wrong (e.g. some windows are unbound), that's why it's not allowed to
        // use `.parent` call in here
        let monitors = globalUnsortedMonitorInfos.map { MonitorRects(rect: $0.rect, visibleRect: $0.visibleRect, isMain: $0.isMain) }
        let done = DispatchGroup()
        for window in MacWindow.allWindowsMap.values {
            let floatingSize = window.lastFloatingSize
            window.macApp.setAxFrameForTermination(window.windowId, done) { rect in
                frameForTermination(window: rect, floatingSize: floatingSize, monitors)
            }
        }
        // The apps are asked at the same time, each one on its thread, the windows of an app one by one. An app that
        // doesn't answer doesn't hold up the quit (logging out, a restart of MarSpace): its windows stay where they are
        _ = done.wait(timeout: .now() + terminationTimeout)
        if isDebug {
            let semaphore = DispatchSemaphore(value: 0)
            // Use Task.detached to avoid inheriting @MainActor.
            // If @MainActor was inherited, it would cause a deadlock
            Task.detached {
                await toggleReleaseServerIfDebug(.on)
                semaphore.signal()
            }
            semaphore.wait()
        }
    }
}

private let terminationTimeout: DispatchTimeInterval = .seconds(2)

struct MonitorRects: Sendable {
    let rect: Rect
    let visibleRect: Rect
    let isMain: Bool
}

/// The frame of a window when MarSpace quits: in the middle of the monitor that it's on (the nearest one for a window in
/// the corner of a workspace that isn't shown), with the size that it had as a floating window, or filling the monitor.
///
/// - Parameter window: where the window is now. nil if it's unknown: the main monitor
/// - Returns: nil if there is no monitor
func frameForTermination(window: Rect?, floatingSize: CGSize?, _ monitors: [MonitorRects]) -> (topLeft: CGPoint, size: CGSize)? {
    let nearest = window.flatMap { window in
        monitors.min { window.center.distance(toOuterFrame: $0.rect) < window.center.distance(toOuterFrame: $1.rect) }
    }
    guard let visible = (nearest ?? monitors.first(where: \.isMain) ?? monitors.first)?.visibleRect else { return nil }
    let size = floatingSize ?? CGSize(width: visible.width, height: visible.height)
    let topLeft = CGPoint(
        x: visible.topLeftX + max(0, (visible.width - size.width) / 2),
        y: visible.topLeftY + max(0, (visible.height - size.height) / 2),
    )
    return (topLeft, size)
}

@MainActor
func terminateApp() -> Never {
    NSApplication.shared.terminate(nil)
    die("Unreachable code")
}

extension String {
    func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(self, forType: .string)
    }
}

func - (a: CGPoint, b: CGPoint) -> CGPoint {
    CGPoint(x: a.x - b.x, y: a.y - b.y)
}

func + (a: CGPoint, b: CGPoint) -> CGPoint {
    CGPoint(x: a.x + b.x, y: a.y + b.y)
}

extension CGPoint: Withable {}

extension CGPoint {
    func distance(toOuterFrame rect: Rect) -> CGFloat {
        // Subtract 1 from maxX/maxY because the right/bottom bounds are
        // exclusive.
        let dx = max(rect.minX - x, 0, x - (rect.maxX - 1))
        let dy = max(rect.minY - y, 0, y - (rect.maxY - 1))
        return CGPoint(x: dx, y: dy).vectorLength
    }

    func coerce(in rect: Rect) -> CGPoint? {
        guard let xRange = rect.minX.until(incl: rect.maxX - 1) else { return nil }
        guard let yRange = rect.minY.until(incl: rect.maxY - 1) else { return nil }
        return CGPoint(x: x.coerce(in: xRange), y: y.coerce(in: yRange))
    }

    func addingXOffset(_ offset: CGFloat) -> CGPoint { CGPoint(x: x + offset, y: y) }
    func addingYOffset(_ offset: CGFloat) -> CGPoint { CGPoint(x: x, y: y + offset) }
    func addingOffset(_ orientation: Orientation, _ offset: CGFloat) -> CGPoint { orientation == .h ? addingXOffset(offset) : addingYOffset(offset) }

    func getProjection(_ orientation: Orientation) -> Double { orientation == .h ? x : y }

    var vectorLength: CGFloat { sqrt(x * x + y * y) }

    var monitorApproximation: MonitorInfo { globalUnsortedMonitorInfos.minByOrDie { distance(toOuterFrame: $0.rect) } }
}

extension CGFloat {
    func div(_ denominator: Int) -> CGFloat? {
        denominator == 0 ? nil : self / CGFloat(denominator)
    }

    func coerce(in range: ClosedRange<CGFloat>) -> CGFloat {
        switch true {
            case self > range.upperBound: range.upperBound
            case self < range.lowerBound: range.lowerBound
            default: self
        }
    }
}

#if DEBUG
    let isDebug = true
#else
    let isDebug = false
#endif

@inlinable
func checkCancellation(_ cm: CancellationMode = .cancellable) throws(CancellationError) {
    if cm == .cancellable && Task.isCancelled {
        throw CancellationError()
    }
}

public enum CancellationMode: Equatable, Sendable {
    case cancellable
    case nonCancellable
}
