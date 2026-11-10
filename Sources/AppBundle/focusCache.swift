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
        // Not the window that MarSpace focused (its own focus arrives in macOS later): e.g. the window of an app that was
        // just launched, which its window rule may have moved to another workspace
        if let nativeFocused, nativeFocused != globalFocus.windowOrNil { countFocusChangeByMacOs() }
        _ = nativeFocused?.focusWindow()
        lastKnownNativeFocusedWindowId = nativeFocused?.windowId
    }
    (nativeFocused?.app as? MacApp)?.lastFocusedNativeWindowOpaqueId = nativeFocused?.windowId
}
