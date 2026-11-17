import GoogleMaps
import SwiftUI
import TripFeatures

@main
struct WaystageApp: App {
    @State private var environment: AppEnvironment
    /// The opening animation, once per launch (not in UI tests, which drive the app straight away).
    @State private var showsIntro: Bool
    /// "Before you start": until the current terms are agreed to.
    @State private var needsTerms: Bool

    init() {
        // Shared with the CarPlay scene; it also gives the Maps SDK its key.
        let environment = AppEnvironment.shared
        _environment = State(initialValue: environment)
        _showsIntro = State(initialValue: LaunchIntroView.isShown(in: environment.mode, arguments: ProcessInfo.processInfo.arguments))
        _needsTerms = State(initialValue: TermsAgreementView.isRequired(
            mode: environment.mode, arguments: ProcessInfo.processInfo.arguments, preferences: environment.dependencies.preferences.load()
        ))
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                // Under the intro, so the intro fades straight into it.
                if needsTerms {
                    TermsAgreementView(onAgree: agreeToTerms)
                        .transition(.opacity)
                        .zIndex(1)
                }
                if showsIntro {
                    LaunchIntroView(hold: LaunchIntroView.hold(arguments: ProcessInfo.processInfo.arguments)) { showsIntro = false }
                        .zIndex(2)
                }
            }
            .environment(environment)
            // Google Maps needs an API key; demo mode and UI tests use Apple Maps instead.
            .environment(\.mapProvider, environment.mode == .production ? .google : .apple)
            .fontDesign(.rounded)
            .tint(Theme.accent)
            // Screenshot runs can force dark mode to review the dark theme.
            .preferredColorScheme(ProcessInfo.processInfo.arguments.contains(LaunchArgument.darkMode) ? .dark : nil)
        }
    }

    private func agreeToTerms() {
        let store = environment.dependencies.preferences
        var preferences = store.load()
        TermsAgreement.accept(&preferences)
        store.save(preferences)
        withAnimation(.easeOut(duration: 0.25)) { needsTerms = false }
        // Google's Navigation SDK terms are shown at first use too (its policies require it).
        if let navigation = environment.navigation {
            Task { await navigation.requestTerms() }
        }
    }
}
