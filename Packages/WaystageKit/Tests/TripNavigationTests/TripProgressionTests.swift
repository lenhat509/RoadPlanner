import Foundation
import Testing
import TripModels
@testable import TripNavigation

@Suite("Trip progression")
struct TripProgressionTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// origin → rest (2h) → lodging (5h, departs next 08:00) → destination.
    private func makeTrip() -> ActiveTrip {
        let place = Place(name: "P", coordinate: GeoCoordinate(latitude: 40, longitude: -100), utcOffsetMinutes: 0)
        func at(_ hours: Double) -> Date { start.addingTimeInterval(hours * 3_600) }
        let stops = [
            ItineraryStop(id: "origin", kind: .origin, place: place, arrival: nil, departure: at(0), distanceFromStartMeters: 0, dayIndex: 0),
            ItineraryStop(id: "rest", kind: .rest, place: place, arrival: at(2), departure: at(2.25), distanceFromStartMeters: 1, dayIndex: 0),
            ItineraryStop(id: "hotel", kind: .lodging, place: place, arrival: at(5), departure: at(20), distanceFromStartMeters: 2, dayIndex: 0),
            ItineraryStop(id: "dest", kind: .destination, place: place, arrival: at(23), departure: nil, distanceFromStartMeters: 3, dayIndex: 1),
        ]
        let itinerary = Itinerary(
            goal: .balanced,
            request: TripRequest(
                origin: place, destination: Place(name: "D", coordinate: GeoCoordinate(latitude: 41, longitude: -90)),
                departure: start, vehicle: Vehicle(milesPerGallon: 30)
            ),
            stops: stops, legs: [],
            totals: TripTotals(distanceMeters: 0, drivingDuration: 0, elapsedDuration: 0, cost: .zero)
        )
        return ActiveTrip(itinerary: itinerary)
    }

    @Test("Start → arrive → continue → … → completed")
    func happyPath() throws {
        var trip = makeTrip()
        #expect(trip.completionFraction == 0)
        try trip.start(at: start)
        #expect(trip.progress.phase == .enRoute)
        #expect(trip.targetStop?.id == "rest")
        #expect(throws: TripTransitionError.alreadyStarted) { try trip.start(at: start) }

        try trip.markArrived(at: start.addingTimeInterval(7_000))
        #expect(trip.progress.phase == .atStop)
        #expect(trip.progress.actualArrivals["rest"] != nil)

        try trip.continueToNextStop(at: start.addingTimeInterval(8_000))
        #expect(trip.progress.phase == .enRoute)
        #expect(trip.targetStop?.id == "hotel")
        #expect(trip.progress.actualDepartures["rest"] != nil)

        try trip.markArrived(at: start.addingTimeInterval(18_000))
        try trip.continueToNextStop(at: start.addingTimeInterval(72_000))
        #expect(trip.isFinalTarget)
        try trip.markArrived(at: start.addingTimeInterval(83_000))
        #expect(trip.progress.phase == .completed)
        #expect(trip.completionFraction == 1)
        #expect(throws: TripTransitionError.tripCompleted) { try trip.continueToNextStop(at: start) }
    }

    @Test("'Next stop' while still driving records the stop as visited and moves on")
    func continueWhileEnRoute() throws {
        var trip = makeTrip()
        try trip.start(at: start)
        let now = start.addingTimeInterval(7_100)
        try trip.continueToNextStop(at: now)
        #expect(trip.targetStop?.id == "hotel")
        #expect(trip.progress.actualArrivals["rest"] == now)
        #expect(trip.progress.actualDepartures["rest"] == now)
    }

    @Test("Skipping a stop marks it skipped; the destination cannot be skipped")
    func skipping() throws {
        var trip = makeTrip()
        #expect(throws: TripTransitionError.notStarted) { try trip.skipTargetStop(at: start) }
        try trip.start(at: start)
        try trip.skipTargetStop(at: start)
        try trip.skipTargetStop(at: start)
        #expect(trip.progress.skippedStopIDs == ["rest", "hotel"])
        #expect(throws: TripTransitionError.cannotSkipDestination) { try trip.skipTargetStop(at: start) }
    }

    @Test("Arriving at the destination completes the trip directly")
    func destinationCompletes() throws {
        var trip = makeTrip()
        try trip.start(at: start)
        try trip.skipTargetStop(at: start)
        try trip.skipTargetStop(at: start)
        try trip.markArrived(at: start.addingTimeInterval(80_000))
        #expect(trip.progress.phase == .completed)
    }

    @Test("Delays shift later stops; overnight departures keep their morning time")
    func projectedSchedule() throws {
        var trip = makeTrip()
        try trip.start(at: start)
        // 1.5 h in, guidance says 1 h left → arrive at 2.5 h (30 min late).
        let now = start.addingTimeInterval(1.5 * 3_600)
        let projected = trip.projectedSchedule(now: now, remainingToTarget: 3_600)
        let rest = try #require(projected.first { $0.stopID == "rest" })
        #expect(rest.delay == 1_800)
        let hotel = try #require(projected.first { $0.stopID == "hotel" })
        #expect(hotel.delay == 1_800)
        #expect(hotel.departure == start.addingTimeInterval(20 * 3_600))
        let destination = try #require(projected.first { $0.stopID == "dest" })
        #expect(destination.delay == 0)
    }

    @Test("A very late hotel arrival pushes the next morning back to keep minimum rest")
    func lateHotelArrival() throws {
        var trip = makeTrip()
        try trip.start(at: start)
        let projected = trip.projectedSchedule(now: start.addingTimeInterval(9 * 3_600), remainingToTarget: 4 * 3_600)
        let hotel = try #require(projected.first { $0.stopID == "hotel" })
        // Arrive at 11 h (+2 h + rest dwell); minimum overnight rest is 9 h.
        let arrival = try #require(hotel.arrival)
        #expect(try #require(hotel.departure) >= arrival.addingTimeInterval(9 * 3_600))
    }
}
