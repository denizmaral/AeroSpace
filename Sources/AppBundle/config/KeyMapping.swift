import Common
import HotKey

/// The names of the keys in the shortcuts (e.g. `alt-h` in messages and in `aerospace` commands): by the key layout of
/// the preset
struct KeyMapping: Withable, Equatable, Sendable {
    enum Preset: String, CaseIterable, Sendable {
        case qwerty, dvorak, colemak
    }

    var preset: Preset = .qwerty

    init(preset: Preset = .qwerty) {
        self.preset = preset
    }
}
