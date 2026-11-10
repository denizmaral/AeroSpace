import Common
import os

/// Focus decisions: macOS focus taken over by a refresh session, focus-follows-mouse checks.
/// `log stream --predicate 'subsystem == "com.denizmaral.MarSpace" && category == "focus"'`
let focusLogger = Logger(subsystem: aeroSpaceAppId, category: "focus")
