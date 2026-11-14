// Shared by the app and the UI tests (compiled into both targets).

/// Launch arguments understood by the app (used by UI tests and demos).
enum LaunchArgument {
    /// Offline sandbox: simulated Google backend, simulated GPS that drives the route.
    static let uiTestSandbox = "-UITestSandbox"
    /// Clears saved trips and preferences before launch (sandbox only).
    static let resetState = "-ResetState"
    /// Accept the driving safety notice automatically (screenshot runs).
    static let skipSafetyNotice = "-SkipSafetyNotice"
    /// Force dark appearance (screenshot runs).
    static let darkMode = "-DarkMode"
    /// Simulated car drives a short way into each leg and parks, so drive mode holds still for a
    /// capture (screenshot runs); otherwise it drives very fast so tests reach stops quickly.
    static let screenshotPace = "-ScreenshotPace"
    /// Plays the launch intro in the sandbox and holds its last scene a few seconds, so a
    /// screenshot can capture it (UI tests otherwise skip the intro).
    static let showIntro = "-ShowIntro"
    /// Asks for the terms agreement in the sandbox (UI tests otherwise skip it).
    static let showTerms = "-ShowTerms"
}
