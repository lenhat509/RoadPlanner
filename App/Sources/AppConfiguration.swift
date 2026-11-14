import Foundation

/// Build-time configuration injected through `Config/*.xcconfig` → `Info.plist`.
struct AppConfiguration: Equatable {
    var googleMapsAPIKey: String?
    var gatewayBaseURL: URL?
    var gatewayAppToken: String?
    var bundleIdentifier: String

    init(info: [String: Any], bundleIdentifier: String) {
        googleMapsAPIKey = Self.resolved(info["WAYGoogleMapsAPIKey"])
        gatewayBaseURL = Self.resolved(info["WAYGatewayBaseURL"])
            .flatMap(URL.init(string:))
            .flatMap { $0.scheme == "https" && $0.host != nil ? $0 : nil }
        gatewayAppToken = Self.resolved(info["WAYGatewayAppToken"])
        self.bundleIdentifier = bundleIdentifier
    }

    static func load(bundle: Bundle = .main) -> AppConfiguration {
        AppConfiguration(info: bundle.infoDictionary ?? [:], bundleIdentifier: bundle.bundleIdentifier ?? "com.example.waystage")
    }

    /// Treats empty values and unexpanded build variables (`$(VAR)`) as missing.
    static func resolved(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.hasPrefix("$(") ? nil : trimmed
    }

    var isGoogleConfigured: Bool { googleMapsAPIKey != nil }
    var isGatewayConfigured: Bool { gatewayBaseURL != nil && gatewayAppToken != nil }
}
