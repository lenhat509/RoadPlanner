import Foundation
import Testing
@testable import TripModels

@Suite("TripRequest validation")
struct TripRequestTests {
    private let origin = Place(id: "o", name: "Origin", coordinate: GeoCoordinate(latitude: 37.77, longitude: -122.42))
    private let destination = Place(id: "d", name: "Destination", coordinate: GeoCoordinate(latitude: 40.71, longitude: -74.0))
    private let departure = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeRequest(
        mpg: Double = 30,
        arriveBy: Date? = nil,
        maxContinuous: TimeInterval? = nil,
        origin: Place? = nil
    ) -> TripRequest {
        var policy = DrivingPolicy.standard
        if let maxContinuous { policy.maxContinuousDriving = maxContinuous }
        return TripRequest(
            origin: origin ?? self.origin,
            destination: destination,
            departure: departure,
            arriveBy: arriveBy,
            vehicle: Vehicle(milesPerGallon: mpg),
            policy: policy,
            goal: .balanced
        )
    }

    @Test("A well-formed request has no validation errors")
    func validRequest() {
        #expect(makeRequest().validationErrors().isEmpty)
    }

    @Test("Default policy rests within the 2–3 hour window")
    func defaultRestWindow() {
        let policy = DrivingPolicy.standard
        #expect(policy.maxContinuousDriving <= 3 * 3_600)
        #expect(policy.maxContinuousDriving >= 2 * 3_600)
        #expect(policy.restStopDuration >= 10 * 60)
    }

    @Test("Rejects non-positive or absurd MPG", arguments: [0.0, -5.0, 250.0])
    func invalidMPG(mpg: Double) {
        #expect(makeRequest(mpg: mpg).validationErrors().contains(.invalidFuelEconomy))
    }

    @Test("Rejects an arrival deadline before departure")
    func deadlineBeforeDeparture() {
        let request = makeRequest(arriveBy: departure.addingTimeInterval(-60))
        #expect(request.validationErrors().contains(.deadlineBeforeDeparture))
    }

    @Test("Rejects identical origin and destination")
    func identicalEndpoints() {
        let request = makeRequest(origin: destination)
        #expect(request.validationErrors().contains(.originEqualsDestination))
    }

    @Test("Rejects rest intervals outside 30 minutes … 5 hours", arguments: [TimeInterval(10 * 60), TimeInterval(6 * 3_600)])
    func invalidRestInterval(interval: TimeInterval) {
        #expect(makeRequest(maxContinuous: interval).validationErrors().contains(.invalidRestInterval))
    }

    @Test("Rejects a minimum fuel level outside 5 % … 50 %", arguments: [0.0, 0.6])
    func invalidFuelReserve(fraction: Double) {
        var request = makeRequest()
        request.policy.fuelReserveFraction = fraction
        #expect(request.validationErrors().contains(.invalidFuelReserve))
    }

    @Test("Vehicle range accounts for tank size and MPG")
    func vehicleRange() {
        let vehicle = Vehicle(milesPerGallon: 30, tankCapacityGallons: 15)
        #expect(vehicle.fullTankRangeMiles == 450)
        #expect(abs(vehicle.gallons(forMeters: Units.metersPerMile * 30) - 1) < 1e-9)
    }

    @Test("Requests round-trip through JSON")
    func codableRoundTrip() throws {
        let request = makeRequest(arriveBy: departure.addingTimeInterval(86_400 * 4))
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(TripRequest.self, from: data)
        #expect(decoded == request)
    }
}

@Suite("LocalTime")
struct LocalTimeTests {
    @Test("Seconds from midnight")
    func secondsFromMidnight() {
        #expect(LocalTime(hour: 8, minute: 30).secondsFromMidnight == 30_600)
    }

    @Test("Clamps out-of-range components")
    func clamps() {
        let time = LocalTime(hour: 27, minute: -4)
        #expect(time.hour == 23)
        #expect(time.minute == 0)
    }

    @Test("Formats as a 24-hour clock string")
    func formatting() {
        #expect(LocalTime(hour: 7, minute: 5).description == "07:05")
    }
}
