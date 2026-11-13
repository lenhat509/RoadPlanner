import Foundation
import Testing
@testable import Cadence

@Suite("AppConfiguration")
struct AppConfigurationTests {
    @Test("Reads keys from Info.plist values")
    func readsValues() {
        let configuration = AppConfiguration(
            info: [
                "CADGoogleMapsAPIKey": "AIzaTestKey",
                "CADGatewayBaseURL": "https://gateway.example.com",
                "CADGatewayAppToken": "token",
            ],
            bundleIdentifier: "com.example.cadence"
        )
        #expect(configuration.googleMapsAPIKey == "AIzaTestKey")
        #expect(configuration.gatewayBaseURL?.host == "gateway.example.com")
        #expect(configuration.isGoogleConfigured)
        #expect(configuration.isGatewayConfigured)
    }

    @Test("Treats empty and unexpanded build variables as missing")
    func unresolvedValues() {
        let configuration = AppConfiguration(
            info: ["CADGoogleMapsAPIKey": "$(GOOGLE_MAPS_API_KEY)", "CADGatewayBaseURL": "  ", "CADGatewayAppToken": ""],
            bundleIdentifier: "x"
        )
        #expect(configuration.googleMapsAPIKey == nil)
        #expect(configuration.gatewayBaseURL == nil)
        #expect(!configuration.isGoogleConfigured)
        #expect(!configuration.isGatewayConfigured)
    }

    @Test("Rejects non-HTTPS gateway URLs")
    func httpsOnly() {
        let configuration = AppConfiguration(info: ["CADGatewayBaseURL": "http://gateway.example.com"], bundleIdentifier: "x")
        #expect(configuration.gatewayBaseURL == nil)
    }

    @Test("The shipped Info.plist declares every required key")
    func infoPlist() throws {
        let info = try #require(Bundle.main.infoDictionary)
        #expect(info["NSLocationWhenInUseUsageDescription"] as? String != nil)
        #expect((info["UIBackgroundModes"] as? [String])?.contains("location") == true)
        #expect((info["LSApplicationQueriesSchemes"] as? [String])?.contains("comgooglemaps") == true)
        #expect(info["ITSAppUsesNonExemptEncryption"] as? Bool == false)
        #expect(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy") != nil)
    }
}
