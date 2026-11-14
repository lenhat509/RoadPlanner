@testable import Waystage
import Foundation
import Testing

@Suite("AppConfiguration")
struct AppConfigurationTests {
    @Test("Reads keys from Info.plist values")
    func readsValues() {
        let configuration = AppConfiguration(
            info: [
                "WAYGoogleMapsAPIKey": "AIzaTestKey",
                "WAYGatewayBaseURL": "https://gateway.example.com",
                "WAYGatewayAppToken": "token",
            ],
            bundleIdentifier: "com.example.waystage"
        )
        #expect(configuration.googleMapsAPIKey == "AIzaTestKey")
        #expect(configuration.gatewayBaseURL?.host == "gateway.example.com")
        #expect(configuration.isGoogleConfigured)
        #expect(configuration.isGatewayConfigured)
    }

    @Test("Treats empty and unexpanded build variables as missing")
    func unresolvedValues() {
        let configuration = AppConfiguration(
            info: ["WAYGoogleMapsAPIKey": "$(GOOGLE_MAPS_API_KEY)", "WAYGatewayBaseURL": "  ", "WAYGatewayAppToken": ""],
            bundleIdentifier: "x"
        )
        #expect(configuration.googleMapsAPIKey == nil)
        #expect(configuration.gatewayBaseURL == nil)
        #expect(!configuration.isGoogleConfigured)
        #expect(!configuration.isGatewayConfigured)
    }

    @Test("Rejects non-HTTPS gateway URLs")
    func httpsOnly() {
        let configuration = AppConfiguration(info: ["WAYGatewayBaseURL": "http://gateway.example.com"], bundleIdentifier: "x")
        #expect(configuration.gatewayBaseURL == nil)
    }

    @Test("The shipped Info.plist declares every required key")
    func infoPlist() throws {
        let info = try #require(Bundle.main.infoDictionary)
        #expect(info["NSLocationWhenInUseUsageDescription"] is String)
        #expect((info["UIBackgroundModes"] as? [String])?.contains("location") == true)
        #expect((info["LSApplicationQueriesSchemes"] as? [String])?.contains("comgooglemaps") == true)
        #expect(info["ITSAppUsesNonExemptEncryption"] as? Bool == false)
        #expect(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy") != nil)
    }
}
