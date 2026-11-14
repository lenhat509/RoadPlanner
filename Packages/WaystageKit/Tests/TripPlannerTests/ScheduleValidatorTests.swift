import Foundation
import Testing
import TripModels
@testable import TripPlanner

@Suite("ScheduleValidator")
struct ScheduleValidatorTests {
    private let start = Fixture.departure

    private func stop(_ kind: StopKind, arrivalHours: Double?, departureHours: Double?, fuel: Double? = 10, day: Int = 0) -> ItineraryStop {
        ItineraryStop(
            kind: kind,
            place: Place(name: kind.rawValue, coordinate: GeoCoordinate(latitude: 40, longitude: -100)),
            arrival: arrivalHours.map { start.addingTimeInterval($0 * 3_600) },
            departure: departureHours.map { start.addingTimeInterval($0 * 3_600) },
            distanceFromStartMeters: 0,
            fuelOnArrivalGallons: fuel,
            dayIndex: day
        )
    }

    private func itinerary(_ stops: [ItineraryStop], arriveBy: Date? = nil, warnings: [PlanWarning] = []) -> Itinerary {
        Itinerary(
            goal: .fastest,
            request: TripRequest(
                origin: Place(name: "A", coordinate: GeoCoordinate(latitude: 40, longitude: -100)),
                destination: Place(name: "B", coordinate: GeoCoordinate(latitude: 40, longitude: -90)),
                departure: start,
                arriveBy: arriveBy,
                vehicle: Vehicle(milesPerGallon: 30)
            ),
            stops: stops,
            legs: [],
            totals: TripTotals(distanceMeters: 0, drivingDuration: 0, elapsedDuration: 0, cost: .zero),
            warnings: warnings
        )
    }

    @Test("A compliant schedule has no violations")
    func compliant() {
        let plan = itinerary([
            stop(.origin, arrivalHours: nil, departureHours: 0, fuel: 14),
            stop(.rest, arrivalHours: 2.9, departureHours: 3.15),
            stop(.destination, arrivalHours: 5.5, departureHours: nil),
        ])
        #expect(ScheduleValidator().violations(in: plan).isEmpty)
    }

    @Test("Flags non-stop driving over the limit")
    func continuousDriving() {
        let plan = itinerary([
            stop(.origin, arrivalHours: nil, departureHours: 0, fuel: 14),
            stop(.rest, arrivalHours: 3.5, departureHours: 3.75),
            stop(.destination, arrivalHours: 5, departureHours: nil),
        ])
        #expect(ScheduleValidator().violations(in: plan).contains { if case .continuousDrivingTooLong(0, _) = $0 { true } else { false } })
    }

    @Test("Flags fuel below the reserve unless a fuel gap was reported")
    func fuelReserve() {
        let stops = [
            stop(.origin, arrivalHours: nil, departureHours: 0, fuel: 14),
            stop(.rest, arrivalHours: 2, departureHours: 2.25, fuel: 1),
            stop(.destination, arrivalHours: 4, departureHours: nil),
        ]
        #expect(ScheduleValidator().violations(in: itinerary(stops)).contains(.fuelBelowReserve(stopIndex: 1, gallons: 1)))
        let accepted = itinerary(stops, warnings: [PlanWarning(code: .fuelGap, message: "")])
        #expect(ScheduleValidator().violations(in: accepted).isEmpty)
    }

    @Test("Flags too much driving in one day")
    func dailyDriving() {
        let plan = itinerary([
            stop(.origin, arrivalHours: nil, departureHours: 0, fuel: 14),
            stop(.rest, arrivalHours: 3, departureHours: 3.25),
            stop(.rest, arrivalHours: 6.25, departureHours: 6.5),
            stop(.rest, arrivalHours: 9.5, departureHours: 9.75),
            stop(.destination, arrivalHours: 12.25, departureHours: nil),
        ])
        #expect(ScheduleValidator().violations(in: plan).contains { if case .dailyDrivingTooLong(0, _) = $0 { true } else { false } })
    }

    @Test("Flags a missed deadline unless the plan already warns about it")
    func deadline() {
        let stops = [
            stop(.origin, arrivalHours: nil, departureHours: 0, fuel: 14),
            stop(.destination, arrivalHours: 2, departureHours: nil),
        ]
        let deadline = start.addingTimeInterval(3_600)
        #expect(!ScheduleValidator().violations(in: itinerary(stops, arriveBy: deadline)).isEmpty)
        let warned = itinerary(stops, arriveBy: deadline, warnings: [PlanWarning(code: .deadlineMissed, message: "")])
        #expect(ScheduleValidator().violations(in: warned).isEmpty)
    }

    @Test("Flags time running backwards")
    func backwards() {
        let plan = itinerary([
            stop(.origin, arrivalHours: nil, departureHours: 1, fuel: 14),
            stop(.destination, arrivalHours: 0.5, departureHours: nil),
        ])
        #expect(ScheduleValidator().violations(in: plan).contains(.timeGoesBackwards(stopIndex: 1)))
    }
}
