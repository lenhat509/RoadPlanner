// Shared by the app and the UI tests (compiled into both targets).

/// Launch arguments understood by the app (used by UI tests and demos).
enum LaunchArgument {
    /// Offline sandbox: simulated Google backend, simulated GPS that drives the route.
    static let uiTestSandbox = "-UITestSandbox"
    /// Clears saved trips and preferences before launch (sandbox only).
    static let resetState = "-ResetState"
    /// Accept the driving safety notice automatically (screenshot runs).
    static let skipSafetyNotice = "-SkipSafetyNotice"
}
