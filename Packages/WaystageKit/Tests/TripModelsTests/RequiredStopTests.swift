import Foundation
import Testing
@testable import TripModels

@Suite("Stops on the way")
struct RequiredStopTests {
    private let origin = Place(id: "o", name: "Origin", coordinate: GeoCoordinate(latitude: 37.77, longitude: -122.42))
    private let destination = Place(id: "d", name: "Destination", coordinate: GeoCoordinate(latitude: 40.71, longitude: -74.0))
    private let yellowstone = Place(id: "ys", name: "Yellowstone", coordinate: GeoCoordinate(latitude: 44.43, longitude: -110.59))

    private func request(stops: [RequiredStop]?) -> TripRequest {
        TripRequest(
            origin: origin, destination: destination, departure: Date(timeIntervalSince1970: 1_800_000_000),
            vehicle: Vehicle(milesPerGallon: 30), stops: stops
        )
    }

    @Test("A visit of up to 14 days is valid")
    func validVisit() {
        #expect(request(stops: [.visit(yellowstone, stay: 3.0 * 3_600)]).validationErrors().isEmpty)
        #expect(request(stops: [.visit(yellowstone, stay: 2.0 * 60)]).validationErrors() == [.invalidStay])
        #expect(request(stops: [.visit(yellowstone, stay: 2.0 * 86_400 + 3 * 3_600)]).validationErrors().isEmpty)
        #expect(request(stops: [.visit(yellowstone, stay: 15.0 * 86_400)]).validationErrors() == [.invalidStay])
        // Nights: 1 to 14, with 0 to 23 hours on the last day.
        #expect(request(stops: [.visit(yellowstone, stay: 3.0 * 3_600, nights: 2, overnight: .nearbyHotel)]).validationErrors().isEmpty)
        #expect(request(stops: [.visit(yellowstone, stay: 0.0, nights: 1)]).validationErrors().isEmpty)
        #expect(request(stops: [.visit(yellowstone, stay: 0.0, nights: 15)]).validationErrors() == [.invalidStay])
        #expect(request(stops: [.visit(yellowstone, stay: 24.0 * 3_600, nights: 1)]).validationErrors() == [.invalidStay])
        #expect(RequiredStop.visit(yellowstone, stay: 3_600.0, overnight: .nearbyHotel).overnight == nil, "no nights: nowhere to sleep")
    }

    @Test("At most 10 places to visit and 25 stops in all, each with a place")
    func limits() {
        let eleven = (0..<11).map { _ in RequiredStop.visit(yellowstone, stay: 3_600) }
        #expect(request(stops: eleven).validationErrors() == [.tooManyStops])
        let hotels = (0..<15).map { _ in RequiredStop(place: yellowstone, purpose: .lodging) }
        let ten = Array(eleven.prefix(10))
        #expect(request(stops: ten + hotels).validationErrors().isEmpty, "kept stops and hotels don't count as places to visit")
        #expect(request(stops: ten + hotels + [hotels[0]]).validationErrors() == [.tooManyKeptStops])
        let nowhere = Place(id: "x", name: "", coordinate: GeoCoordinate(latitude: 200, longitude: 0))
        #expect(request(stops: [.visit(nowhere, stay: 3_600)]).validationErrors() == [.invalidStop])
    }

    @Test("A kept break needs no stay; an empty list is no stops")
    func keptStopsAndEmptyList() {
        #expect(request(stops: [RequiredStop(place: yellowstone, purpose: .rest)]).validationErrors().isEmpty)
        #expect(request(stops: []).stops == nil)
        #expect(request(stops: []).requiredStops.isEmpty)
    }

    @Test("A trip saved before 1.2.0 still opens: no stops, nothing avoided, no stops marked as required")
    func decodesOlderTrips() throws {
        var saved = request(stops: [.visit(yellowstone, stay: 3_600)])
        saved.stops = nil
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        for key in ["stops", "avoidedPlaceIDs", "startState"] { json.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(TripRequest.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.requiredStops.isEmpty && decoded.avoidedPlaceIDs == nil && decoded.startState == nil)

        let stop = ItineraryStop(kind: .rest, place: yellowstone, arrival: nil, departure: nil, distanceFromStartMeters: 0, dayIndex: 0)
        var stopJSON = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(stop)) as? [String: Any])
        stopJSON.removeValue(forKey: "isRequired")
        let decodedStop = try JSONDecoder().decode(ItineraryStop.self, from: JSONSerialization.data(withJSONObject: stopJSON))
        #expect(!decodedStop.isRequiredStop)
    }

    @Test("A trip saved with the Balanced goal (before 1.2.0) opens as the fastest")
    func decodesBalanced() throws {
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(request(stops: nil))) as? [String: Any])
        json["goal"] = "balanced"
        let decoded = try JSONDecoder().decode(TripRequest.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.goal == .fastest)
        #expect(OptimizationGoal.allCases == [.fastest, .cheapest])
    }

    @Test("Stops round-trip with their purpose, stay and kept hotel")
    func roundTrip() throws {
        let hotel = RequiredStop(
            place: yellowstone, purpose: .lodging, lodging: LodgingStay(nightlyRate: 150, isRateEstimated: false, provider: "Expedia")
        )
        let original = request(stops: [.visit(yellowstone, stay: 5_400), hotel])
        let decoded = try JSONDecoder().decode(TripRequest.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(decoded.requiredStops.map(\.purpose) == [.visit, .lodging])
        #expect(decoded.requiredStops.first?.stay == 5_400)
    }
}
