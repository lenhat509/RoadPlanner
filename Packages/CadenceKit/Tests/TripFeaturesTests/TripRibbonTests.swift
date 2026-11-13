import Foundation
import Testing
import TripModels
import TripSandbox
@testable import TripFeatures

@MainActor
@Suite("Trip ribbon and greeting")
struct TripRibbonTests {
    @Test("Marks run from 0 to 1 in stop order, one per stop")
    func marks() async throws {
        let itinerary = try #require(try await Plans.laToVegas().recommended)
        let marks = TripRibbon.marks(for: itinerary)
        #expect(marks.count == itinerary.stops.count)
        #expect(marks.first?.fraction == 0)
        #expect(marks.last?.fraction == 1)
        #expect(marks.map(\.fraction) == marks.map(\.fraction).sorted())
        #expect(marks.first?.kind == .origin)
        #expect(marks.last?.kind == .destination)
    }

    @Test("Progress follows the trip: 0 before, partway en route, 1 when done")
    func progress() async throws {
        let itinerary = try #require(try await Plans.laToVegas().recommended)
        var trip = ActiveTrip(itinerary: itinerary)
        #expect(TripRibbon.progress(of: trip, legProgress: nil) == 0)
        try trip.start(at: testNow)
        let firstStop = itinerary.stops[1].distanceFromStartMeters / itinerary.stops.last!.distanceFromStartMeters
        #expect(abs(TripRibbon.progress(of: trip, legProgress: 0.5) - firstStop / 2) < 1e-9)
        try trip.markArrived(at: testNow)
        #expect(abs(TripRibbon.progress(of: trip, legProgress: nil) - firstStop) < 1e-9)
        while trip.progress.phase != .completed { try trip.continueToNextStop(at: testNow) }
        #expect(TripRibbon.progress(of: trip, legProgress: nil) == 1)
    }

    @Test("Greeting depends on the local hour", arguments: [(3, "Good evening"), (9, "Good morning"), (15, "Good afternoon"), (20, "Good evening")])
    func greeting(hour: Int, expected: String) {
        let utc = TimeZone(identifier: "UTC")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let date = calendar.date(from: DateComponents(year: 2027, month: 5, day: 3, hour: hour))!
        let dependencies = SandboxEnvironment.makeDependencies(timeZone: utc, now: { date })
        #expect(HomeViewModel(dependencies: dependencies).greeting == expected)
    }
}
