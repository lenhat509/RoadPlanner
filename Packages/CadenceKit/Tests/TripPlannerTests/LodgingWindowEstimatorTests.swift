import Foundation
import Testing
import TripModels
@testable import TripPlanner

@Suite("LodgingWindowEstimator")
struct LodgingWindowEstimatorTests {
    private let estimator = LodgingWindowEstimator()

    @Test("A single-day trip needs no lodging")
    func singleDay() {
        let windows = estimator.windows(routeDuration: 6 * 3_600, departure: Fixture.departure, utcOffset: Fixture.utcOffset, policy: .standard)
        #expect(windows.isEmpty)
    }

    @Test("A two-day trip has one window ending near the daily limit")
    func twoDays() throws {
        let windows = estimator.windows(routeDuration: 15 * 3_600, departure: Fixture.departure, utcOffset: Fixture.utcOffset, policy: .standard)
        #expect(windows.count == 1)
        let window = try #require(windows.first)
        #expect(window.routeTimeRange.contains(10 * 3_600 - 60))
        #expect(window.dayIndex == 0)
    }

    @Test("A cross-country trip has one window per night, in order")
    func crossCountry() {
        let windows = estimator.windows(routeDuration: 42 * 3_600, departure: Fixture.departure, utcOffset: Fixture.utcOffset, policy: .standard)
        #expect(windows.count == 4)
        #expect(windows.map(\.dayIndex) == [0, 1, 2, 3])
        for (previous, next) in zip(windows, windows.dropFirst()) {
            #expect(previous.routeTimeRange.lowerBound < next.routeTimeRange.lowerBound)
            #expect(previous.checkIn < next.checkIn)
        }
        #expect(windows.allSatisfy { $0.routeTimeRange.upperBound <= 42 * 3_600 })
    }

    @Test("A late departure ends the first day early")
    func lateDeparture() throws {
        let lateStart = Fixture.departure.addingTimeInterval(11 * 3_600) // 19:00 local
        let windows = estimator.windows(routeDuration: 10 * 3_600, departure: lateStart, utcOffset: Fixture.utcOffset, policy: .standard)
        let first = try #require(windows.first)
        #expect(first.routeTimeRange.upperBound < 5 * 3_600)
    }
}
