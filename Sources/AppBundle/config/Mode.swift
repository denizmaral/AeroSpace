import Common
import HotKey

struct Mode: Withable, Equatable, Sendable {
    var bindings: [String: HotkeyBinding]
}
