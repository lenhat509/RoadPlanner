@testable import Waystage
import CoreLocation
import Foundation
import Testing
import TripFeatures
import TripModels

@MainActor
@Suite("Platform adapters")
struct PlatformAdapterTests {
    @Test("Maps CoreLocation authorization states", arguments: [
        (CLAuthorizationStatus.notDetermined, LocationAuthorization.notDetermined),
        (.authorizedWhenInUse, .authorized),
        (.authorizedAlways, .authorized),
        (.denied, .denied),
        (.restricted, .denied),
    ])
    func authorization(status: CLAuthorizationStatus, expected: LocationAuthorization) {
        #expect(CoreLocationProvider.map(status) == expected)
    }

    @Test("Converts CLLocation to a navigation sample")
    func sampleConversion() {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 36.1, longitude: -115.1),
            altitude: 600, horizontalAccuracy: 8, verticalAccuracy: 5, course: 90, speed: 29, timestamp: timestamp
        )
        let sample = CoreLocationProvider.sample(from: location)
        #expect(sample.coordinate == GeoCoordinate(latitude: 36.1, longitude: -115.1))
        #expect(sample.horizontalAccuracy == 8)
        #expect(sample.speed == 29)
        #expect(sample.course == 90)
        #expect(sample.timestamp == timestamp)
    }

    @Test("Speech announcer can speak and stop without crashing")
    func speech() {
        let speech = SpeechAnnouncer()
        speech.speak("In half a mile, take the exit.")
        speech.stopSpeaking()
    }
}
