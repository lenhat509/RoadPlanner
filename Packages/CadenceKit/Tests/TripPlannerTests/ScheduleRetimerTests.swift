import Foundation
import Testing
import TripModels
@testable import TripPlanner

@Suite("ScheduleRetimer")
struct ScheduleRetimerTests {
    private let start = Fixture.departure

    private func makeItinerary(includeLodging: Bool) -> Itinerary {
        let place = Place(name: "P", coordinate: GeoCoordinate(latitude: 40, longitude: -100), utcOffsetMinutes: -480)
        var stops = [
            ItineraryStop(
                id: "o", kind: .origin, place: place, arrival: nil, departure: start,
                distanceFromStartMeters: 0, fuelOnArrivalGallons: 14, dayIndex: 0
            ),
            ItineraryStop(
                id: "f", kind: .fuel, place: place,
                arrival: start.addingTimeInterval(2 * 3_600), departure: start.addingTimeInterval(2.25 * 3_600),
                distanceFromStartMeters: 0, fuelOnArrivalGallons: 6,
                fuelPurchase: FuelPurchase(gallons: 8, pricePerGallon: 3, isPriceEstimated: false), dayIndex: 0
            ),
        ]
        if includeLodging {
            stops.append(ItineraryStop(
                id: "l", kind: .lodging, place: place,
                arrival: start.addingTimeInterval(5 * 3_600), departure: start.addingTimeInterval(24 * 3_600),
                distanceFromStartMeters: 0, lodging: LodgingStay(nightlyRate: 100, isRateEstimated: false), dayIndex: 0
            ))
        }
        stops.append(ItineraryStop(
            id: "d", kind: .destination, place: place, arrival: start.addingTimeInterval(8 * 3_600), departure: nil,
            distanceFromStartMeters: 0, dayIndex: includeLodging ? 1 : 0
        ))
        return Itinerary(
            goal: .fastest,
            request: TripRequest(
                origin: place, destination: Place(name: "D", coordinate: GeoCoordinate(latitude: 41, longitude: -90)),
                departure: start, vehicle: Vehicle(milesPerGallon: 30, tankCapacityGallons: 14)
            ),
            stops: stops,
            legs: [],
            totals: TripTotals(distanceMeters: 0, drivingDuration: 0, elapsedDuration: 0, cost: .zero)
        )
    }

    private func leg(hours: Double, miles: Double) -> RouteLeg {
        RouteLeg(distanceMeters: Units.meters(fromMiles: miles), duration: hours * 3_600, encodedPolyline: "", steps: [])
    }

    @Test("Shifts arrivals by the real leg durations and keeps break lengths")
    func shiftsTimes() throws {
        let retimed = ScheduleRetimer().retime(makeItinerary(includeLodging: false), legs: [leg(hours: 2.5, miles: 150), leg(hours: 3, miles: 180)])
        let fuel = retimed.stops[1]
        #expect(fuel.arrival == start.addingTimeInterval(2.5 * 3_600))
        #expect(fuel.dwellDuration == 0.25 * 3_600)
        #expect(retimed.stops[2].arrival == start.addingTimeInterval(5.75 * 3_600))
        #expect(retimed.legs.count == 2)
        #expect(abs(retimed.totals.distanceMeters - Units.meters(fromMiles: 330)) < 1)
    }

    @Test("Recomputes fuel so the planned post-fill level is kept")
    func fuelRecomputed() throws {
        let retimed = ScheduleRetimer().retime(makeItinerary(includeLodging: false), legs: [leg(hours: 2.5, miles: 240), leg(hours: 3, miles: 180)])
        let fuel = retimed.stops[1]
        // 240 mi at 30 mpg = 8 gal used → 6 gal on arrival; planned level after fill = 14.
        #expect(abs((fuel.fuelOnArrivalGallons ?? 0) - 6) < 1e-9)
        #expect(abs((fuel.fuelPurchase?.gallons ?? 0) - 8) < 1e-9)
        #expect(abs(retimed.totals.cost.fuel - 24) < 1e-9)
    }

    @Test("Overnight departures follow the next-morning rule")
    func overnightRule() throws {
        let retimed = ScheduleRetimer().retime(
            makeItinerary(includeLodging: true),
            legs: [leg(hours: 2, miles: 120), leg(hours: 3, miles: 180), leg(hours: 3, miles: 180)]
        )
        let lodging = retimed.stops[2]
        let departure = try #require(lodging.departure)
        let local = departure.timeIntervalSince1970 - 8 * 3_600
        #expect(local.truncatingRemainder(dividingBy: 86_400) == 8 * 3_600)
        #expect(departure.timeIntervalSince(try #require(lodging.arrival)) >= 9 * 3_600)
        #expect(retimed.totals.cost.lodging == 100)
    }

    @Test("Mismatched leg counts leave the itinerary unchanged")
    func mismatch() {
        let original = makeItinerary(includeLodging: false)
        #expect(ScheduleRetimer().retime(original, legs: [leg(hours: 1, miles: 60)]) == original)
    }
}
