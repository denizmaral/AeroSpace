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
        let id = binding.descriptionWithKeyCode
        hotkeys[id] = HotKey(
            key: binding.keyCode,
            modifiers: binding.modifiers,
            keyDownHandler: {
                Task.startUnstructured {
                    if let activeMode {
                        broadcastEvent(.bindingTriggered(
                            mode: activeMode,
                            binding: binding.descriptionWithKeyNotation,
                        ))
                        try await runLightSession(.hotkeyBinding, .checkServerIsEnabledOrDie()) { () throws in
                            _ = await config.modes[activeMode]?.bindings[id]?.commands.run(.defaultEnv, .emptyStdin)
                        }
                        startHotkeyRepeat(id, binding.keyCode, binding.modifiers)
                    }
                }
            },
            keyUpHandler: { stopHotkeyRepeat(id) },
        )
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

// MARK: - Key repeat

/// The shortcut that repeats right now: one at a time, like the keys that type
@MainActor private var hotkeyRepeat: (id: String, task: Task<(), any Error>)? = nil

/// A shortcut that repeats while its keys are held (``HotkeyBinding/repeatsWhileHeld``, e.g. resizing) runs again and
/// again, with the key repeat delay and rate of macOS (System Settings › Keyboard). Hotkeys (Carbon) fire once per press
@MainActor
private func startHotkeyRepeat(_ id: String, _ key: Key, _ modifiers: NSEvent.ModifierFlags) {
    hotkeyRepeat?.task.cancel()
    hotkeyRepeat = nil
    let delay = NSEvent.keyRepeatDelay, interval = NSEvent.keyRepeatInterval
    // The key repeat of macOS is off: a very long interval
    guard repeatingBinding(id) != nil, delay < 5, interval < 2 else { return }
    let task = Task.startUnstructured { @MainActor in
        try await repeatWhileHeld(
            delay: .seconds(delay),
            interval: .seconds(interval),
            // The keys are asked, not only the release of the hotkey: an event that is missed must not repeat forever
            isHeld: { repeatingBinding(id) != nil && isHeld(key, modifiers) },
            action: {
                // Not canceled in the middle when the keys are released: a session of its own
                _ = await Task.startUnstructured { @MainActor in
                    guard let token: RunSessionGuard = .isServerEnabled else { return }
                    try await runLightSession(.hotkeyBinding, token) { () throws in
                        _ = await repeatingBinding(id)?.commands.run(.defaultEnv, .emptyStdin)
                    }
                }.result
            },
        )
    }
    hotkeyRepeat = (id, task)
}

@MainActor
private func stopHotkeyRepeat(_ id: String) {
    guard hotkeyRepeat?.id == id else { return }
    hotkeyRepeat?.task.cancel()
    hotkeyRepeat = nil
}

/// The binding of the keys in the active mode, if it repeats. Looked up every time: the mode or the settings may change
/// while the keys are held
@MainActor
private func repeatingBinding(_ id: String) -> HotkeyBinding? {
    guard !areHotkeysPaused, let binding = activeMode.flatMap({ config.modes[$0] })?.bindings[id], binding.repeatsWhileHeld else { return nil }
    return binding
}

private func isHeld(_ key: Key, _ modifiers: NSEvent.ModifierFlags) -> Bool {
    let held = NSEvent.ModifierFlags(rawValue: UInt(CGEventSource.flagsState(.combinedSessionState).rawValue))
    return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(key.carbonKeyCode)) && held.isSuperset(of: modifiers)
}

/// Runs `action` again and again while `isHeld`, like a key that types: after `delay`, then every `interval` (counted
/// from the end of the action: the actions never overlap). Canceled when the keys are released
@MainActor
func repeatWhileHeld(delay: Duration, interval: Duration, isHeld: @MainActor () -> Bool, action: @MainActor () async -> Void) async throws {
    try await Task.sleep(for: delay)
    while isHeld() {
        try checkCancellation()
        await action()
        try await Task.sleep(for: interval)
    }
}

struct HotkeyBinding: Equatable, Sendable {
    let modifiers: NSEvent.ModifierFlags
    let keyCode: Key
    let commands: Shell<any Command>
    let descriptionWithKeyCode: String
    let descriptionWithKeyNotation: String
    /// The commands run again and again while the keys are held. See ``startHotkeyRepeat(_:_:_:)``
    let repeatsWhileHeld: Bool

    init(
        _ modifiers: NSEvent.ModifierFlags,
        _ keyCode: Key,
        _ commands: Shell<any Command>,
        descriptionWithKeyNotation: String,
        repeatsWhileHeld: Bool = false,
    ) {
        self.modifiers = modifiers
        self.keyCode = keyCode
        self.commands = commands
        self.repeatsWhileHeld = repeatsWhileHeld
        self.descriptionWithKeyCode = modifiers.isEmpty
            ? keyCode.toString()
            : modifiers.toString() + "-" + keyCode.toString()
        self.descriptionWithKeyNotation = descriptionWithKeyNotation
    }

    static func == (lhs: HotkeyBinding, rhs: HotkeyBinding) -> Bool {
        lhs.modifiers == rhs.modifiers &&
            lhs.keyCode == rhs.keyCode &&
            lhs.descriptionWithKeyCode == rhs.descriptionWithKeyCode &&
            lhs.repeatsWhileHeld == rhs.repeatsWhileHeld &&
            lhs.commands.strictEquals(rhs.commands)
    }
}
