import AppKit
import Common

@MainActor
var appForTests: (any AbstractApp)? = nil

@MainActor
private var focusedApp: (any AbstractApp)? {
    get async throws {
        if isUnitTest {
            return appForTests
        } else {
            check(appForTests == nil)
            return switch RunningApps.frontmost {
                case let frontmost?: try await MacApp.getOrRegister(frontmost)
                case nil: nil
            }
        }
    }
}

@MainActor
func getNativeFocusedWindow(_ cm: CancellationMode) async throws -> Window? {
    try await focusedApp?.getFocusedWindow(cm)
}
