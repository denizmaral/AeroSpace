import Common
import os
import Synchronization

/// Counts accessibility calls. Every AX call is an IPC round trip that also wakes up the main thread of the target app,
/// so AX calls are the main performance and energy cost of AeroSpace (in AeroSpace itself and in other apps).
///
/// The counts are logged per refresh session at the debug level (zero cost unless the log is streamed):
///
///     log stream --level debug --predicate 'subsystem == "bobko.aerospace" && category == "perf"'
enum AxStats {
    struct Counters: Sendable, Equatable {
        var reads: Int = 0
        var writes: Int = 0

        static func - (lhs: Counters, rhs: Counters) -> Counters {
            Counters(reads: lhs.reads - rhs.reads, writes: lhs.writes - rhs.writes)
        }
    }

    private static let counters = Mutex(Counters())

    static func recordRead() { counters.withLock { $0.reads += 1 } }
    static func recordWrite() { counters.withLock { $0.writes += 1 } }
    static var snapshot: Counters { counters.withLock { $0 } }
}

let perfLogger = Logger(subsystem: aeroSpaceAppId, category: "perf")

/// Logs the number of AX calls and the duration of a refresh session
struct SessionPerfLog {
    private let name: String
    private let start = ContinuousClock.now
    private let startCounters = AxStats.snapshot

    init(_ name: String) { self.name = name }

    func finish() {
        let ax = AxStats.snapshot - startCounters
        let duration = ContinuousClock.now - start
        perfLogger.debug("session=\(name, privacy: .public) axReads=\(ax.reads) axWrites=\(ax.writes) ms=\(duration.milliseconds)")
    }
}

extension Duration {
    var milliseconds: Int64 { components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000 }
}
