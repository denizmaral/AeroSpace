import Common

@MainActor private var lastKnownNativeFocusedWindowId: OpaqueWindowId? = nil

/// The data should flow (from nativeFocused to focused) and
///                      (from nativeFocused to lastKnownNativeFocusedWindowId)
/// Alternative names: takeFocusFromMacOs, syncFocusFromMacOs
@MainActor func updateFocusCache(_ nativeFocused: Window?) {
    if nativeFocused?.parent is MacosPopupWindowsContainer {
        return
    }
    if nativeFocused?.windowId != lastKnownNativeFocusedWindowId {
        let event = refreshSessionEvent?.description ?? "none"
        focusLogger.info("takes over the macOS focus \(nativeFocused?.windowId.description ?? "nil", privacy: .public) (was \(lastKnownNativeFocusedWindowId?.description ?? "nil", privacy: .public)), session \(event, privacy: .public)")
        _ = nativeFocused?.focusWindow()
        lastKnownNativeFocusedWindowId = nativeFocused?.windowId
    }
    nativeFocused?.macAppUnsafe.lastFocusedNativeWindowOpaqueId = nativeFocused?.windowId
}
