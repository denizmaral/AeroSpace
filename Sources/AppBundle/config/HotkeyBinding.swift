import AppKit
import Common
import Foundation
import HotKey

@MainActor private var hotkeys: [String: HotKey] = [:]
@MainActor var registeredHotkeys: [HotKey] { Array(hotkeys.values) }

/// While a shortcut is recorded in the settings window, MarSpace's shortcuts are off: they would take its keys. Also when the
/// config is applied meanwhile (an edit, a change of the keyboard layout, `reload-config`)
@MainActor private(set) var areHotkeysPaused = false

@MainActor func setHotkeysPaused(_ paused: Bool) {
    areHotkeysPaused = paused
    let bindings = activeMode.flatMap { config.modes[$0] }?.bindings ?? [:]
    for (binding, key) in hotkeys {
        key.isEnabled = !paused && bindings.keys.contains(binding)
    }
}

/// Unregisters the hotkeys of keys that aren't bound anymore. The others stay registered
@MainActor func removeHotkeys(notIn keys: Set<String>) {
    for (key, hotkey) in hotkeys where !keys.contains(key) {
        hotkey.isEnabled = false // Explicitly: a running hotkey handler may keep it alive
        hotkeys[key] = nil
    }
}

@MainActor func resetHotKeys() {
    // Explicitly unregister all hotkeys. We cannot always rely on destruction of the HotKey object to trigger
    // unregistration because we might be running inside a hotkey handler that is keeping its HotKey object alive.
    for (_, key) in hotkeys {
        key.isEnabled = false
    }
    hotkeys = [:]
}

extension HotKey {
    var isEnabled: Bool {
        get { !isPaused }
        set {
            if isEnabled != newValue {
                isPaused = !newValue
            }
        }
    }
}

@MainActor var activeMode: String? = mainModeId
@MainActor func activateMode_nonCancellable(_ targetMode: String?) async {
    let targetBindings = targetMode.flatMap { config.modes[$0] }?.bindings ?? [:]
    for binding in targetBindings.values where !hotkeys.keys.contains(binding.descriptionWithKeyCode) {
        hotkeys[binding.descriptionWithKeyCode] = HotKey(key: binding.keyCode, modifiers: binding.modifiers, keyDownHandler: {
            Task.startUnstructured {
                if let activeMode {
                    broadcastEvent(.bindingTriggered(
                        mode: activeMode,
                        binding: binding.descriptionWithKeyNotation,
                    ))
                    try await runLightSession(.hotkeyBinding, .checkServerIsEnabledOrDie()) { () throws in
                        _ = await config.modes[activeMode]?.bindings[binding.descriptionWithKeyCode]?.commands
                            .run(.defaultEnv, .emptyStdin)
                    }
                }
            }
        })
    }
    for (binding, key) in hotkeys {
        key.isEnabled = !areHotkeysPaused && targetBindings.keys.contains(binding)
    }
    let oldMode = activeMode
    activeMode = targetMode
    if oldMode != targetMode {
        broadcastEvent(.modeChanged(mode: targetMode))
        _ = await config.onModeChanged.run(.defaultEnv, .emptyStdin)
    }
}

struct HotkeyBinding: Equatable, Sendable {
    let modifiers: NSEvent.ModifierFlags
    let keyCode: Key
    let commands: Shell<any Command>
    let descriptionWithKeyCode: String
    let descriptionWithKeyNotation: String

    init(_ modifiers: NSEvent.ModifierFlags, _ keyCode: Key, _ commands: Shell<any Command>, descriptionWithKeyNotation: String) {
        self.modifiers = modifiers
        self.keyCode = keyCode
        self.commands = commands
        self.descriptionWithKeyCode = modifiers.isEmpty
            ? keyCode.toString()
            : modifiers.toString() + "-" + keyCode.toString()
        self.descriptionWithKeyNotation = descriptionWithKeyNotation
    }

    static func == (lhs: HotkeyBinding, rhs: HotkeyBinding) -> Bool {
        lhs.modifiers == rhs.modifiers &&
            lhs.keyCode == rhs.keyCode &&
            lhs.descriptionWithKeyCode == rhs.descriptionWithKeyCode &&
            lhs.commands.strictEquals(rhs.commands)
    }
}
