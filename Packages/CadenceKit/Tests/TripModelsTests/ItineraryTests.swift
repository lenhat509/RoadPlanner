import Foundation
import Testing
@testable import TripModels

@Suite("Itinerary model")
struct ItineraryTests {
    private func stop(_ kind: StopKind, arrival: Date?, departure: Date?, day: Int = 0) -> ItineraryStop {
        ItineraryStop(
            kind: kind,
            place: Place(name: kind.rawValue, coordinate: GeoCoordinate(latitude: 0, longitude: 0)),
            arrival: arrival,
            departure: departure,
            distanceFromStartMeters: 0,
            dayIndex: day
        )
    }

    @Test("Cost breakdown totals its parts")
    func costTotal() {
        let cost = CostBreakdown(fuel: 120.5, lodging: 210, tolls: 12.25)
        #expect(cost.total == 342.75)
        #expect(CostBreakdown.zero.total == 0)
    }

    @Test("Dwell duration is the time between arrival and departure")
    func dwell() {
        let now = Date(timeIntervalSince1970: 0)
        let rest = stop(.rest, arrival: now, departure: now.addingTimeInterval(900))
        #expect(rest.dwellDuration == 900)
        #expect(stop(.origin, arrival: nil, departure: now).dwellDuration == nil)
    }

    @Test("Fuel purchase cost multiplies gallons by price")
    func fuelPurchaseCost() {
        let purchase = FuelPurchase(gallons: 10, pricePerGallon: 3.499, isPriceEstimated: false)
        #expect(abs(purchase.cost - 34.99) < 1e-9)
    }

    @Test("Stops are grouped by travel day")
    func daysGrouping() {
        let now = Date(timeIntervalSince1970: 0)
        let itinerary = Itinerary(
            goal: .fastest,
            request: TripRequest.sample(departure: now),
            stops: [
                stop(.origin, arrival: nil, departure: now, day: 0),
                stop(.rest, arrival: now, departure: now, day: 0),
                stop(.lodging, arrival: now, departure: now, day: 0),
                stop(.fuel, arrival: now, departure: now, day: 1),
                stop(.destination, arrival: now, departure: nil, day: 1),
            ],
            legs: [],
            totals: TripTotals(distanceMeters: 0, drivingDuration: 0, elapsedDuration: 0, cost: .zero)
        )
        let days = itinerary.days
        #expect(days.count == 2)
        #expect(days[0].stops.count == 3)
        #expect(days[1].stops.map(\.kind) == [.fuel, .destination])
        #expect(itinerary.nights == 1)
    }

    @Test("Maneuvers decode from Google Routes enum strings")
    func maneuverMapping() {
        #expect(Maneuver(googleValue: "TURN_SLIGHT_LEFT") == .turnSlightLeft)
        #expect(Maneuver(googleValue: "RAMP_RIGHT") == .rampRight)
        #expect(Maneuver(googleValue: "SOMETHING_NEW") == .unknown)
        #expect(Maneuver(googleValue: nil) == .unknown)
    }
}
