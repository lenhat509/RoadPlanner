import Foundation
import Testing
import TripModels
@testable import TripPlanner

@Suite("CandidateBuilder")
struct CandidateBuilderTests {
    /// 4-hour east-west route.
    private let profile = RouteProfile(
        coordinates: (0...400).map { GeoCoordinate(latitude: 39, longitude: -100 + Double($0) * 0.01) },
        totalDuration: 4 * 3_600
    )
    private let builder = CandidateBuilder()

    private func station(_ id: String, longitude: Double, latitudeOffset: Double = 0.01, prices: [FuelType: Double] = [.regular: 3.19]) -> FoundPlace {
        FoundPlace(
            place: Place(id: id, name: id, coordinate: GeoCoordinate(latitude: 39 + latitudeOffset, longitude: longitude), utcOffsetMinutes: -360),
            categories: [.fuel],
            fuelPrices: prices
        )
    }

    @Test("Projects places onto the route and computes time along it")
    func projection() throws {
        let candidates = builder.build(profile: profile, places: [station("a", longitude: -98)], fuelType: .regular)
        let candidate = try #require(candidates.first { $0.id == "a" })
        #expect(abs(candidate.timeAlong - 2 * 3_600) < 60)
        #expect(candidate.capabilities.contains([.fuel, .rest]))
        #expect(candidate.fuelPricePerGallon == 3.19)
        #expect(!candidate.isFuelPriceEstimated)
    }

    @Test("Ignores places far from the route")
    func farPlaces() {
        let candidates = builder.build(
            profile: profile, places: [station("far", longitude: -98, latitudeOffset: 0.5)], fuelType: .regular
        )
        #expect(!candidates.contains { $0.id == "far" })
    }

    @Test("Prefers the provider's detour; otherwise estimates one")
    func detours() throws {
        var routed = station("routed", longitude: -99)
        routed.detourDuration = 333
        routed.detourDistance = 2_000
        let candidates = builder.build(profile: profile, places: [routed, station("estimated", longitude: -98)], fuelType: .regular)
        #expect(try #require(candidates.first { $0.id == "routed" }).detourDuration == 333)
        let estimated = try #require(candidates.first { $0.id == "estimated" })
        // ~1.1 km off route → 2 × 1.1 km × 1.3 / 13.4 m/s + 120 s ≈ 335 s.
        #expect(estimated.detourDuration > 250 && estimated.detourDuration < 450)
    }

    @Test("Falls back to regional, then national fuel prices and flags them")
    func fuelPriceFallback() throws {
        let noPrice = station("noprice", longitude: -98.5, prices: [:])
        let regional = builder.build(profile: profile, places: [noPrice], fuelType: .regular) { _ in 3.77 }
        let regionalCandidate = try #require(regional.first { $0.id == "noprice" })
        #expect(regionalCandidate.fuelPricePerGallon == 3.77)
        #expect(regionalCandidate.isFuelPriceEstimated)

        let national = builder.build(profile: profile, places: [noPrice], fuelType: .diesel)
        #expect(try #require(national.first { $0.id == "noprice" }).fuelPricePerGallon == PricingDefaults.standard.fuelPrice(for: .diesel))
    }

    @Test("Merges duplicate places and their categories")
    func duplicates() throws {
        let fuel = station("dup", longitude: -98)
        var rest = fuel
        rest.categories = [.rest]
        rest.fuelPrices = [:]
        let candidates = builder.build(profile: profile, places: [fuel, rest], fuelType: .regular)
        #expect(candidates.filter { $0.id == "dup" }.count == 1)
    }

    @Test("Attaches live lodging offers to the matching place, adds unmatched offers")
    func lodgingOffers() throws {
        let hotel = FoundPlace(
            place: Place(id: "hotel", name: "Hotel", coordinate: GeoCoordinate(latitude: 39.005, longitude: -97.5)),
            categories: [.lodging],
            priceLevel: .expensive
        )
        let matching = LodgingOffer(
            propertyID: "1", name: "Hotel", coordinate: GeoCoordinate(latitude: 39.0051, longitude: -97.5),
            nightlyRate: 99, provider: "Expedia"
        )
        let separate = LodgingOffer(
            propertyID: "2", name: "Inn", coordinate: GeoCoordinate(latitude: 39.002, longitude: -97.2),
            nightlyRate: 79, provider: "Expedia"
        )
        let candidates = builder.build(profile: profile, places: [hotel], lodgingOffers: [matching, separate], fuelType: .regular)
        let matched = try #require(candidates.first { $0.id == "hotel" })
        #expect(matched.nightlyRate == 99)
        #expect(matched.lodgingProvider == "Expedia")
        #expect(!matched.isLodgingRateEstimated)
        #expect(candidates.contains { $0.id == "expedia:2" && $0.nightlyRate == 79 })
    }

    @Test("Estimates lodging rates from the Google price level")
    func lodgingEstimate() throws {
        let hotel = FoundPlace(
            place: Place(id: "h", name: "H", coordinate: GeoCoordinate(latitude: 39.005, longitude: -97.5)),
            categories: [.lodging],
            priceLevel: .inexpensive
        )
        let candidate = try #require(builder.build(profile: profile, places: [hotel], fuelType: .regular).first { $0.id == "h" })
        #expect(candidate.nightlyRate == PricingDefaults.standard.nightlyRate(for: .inexpensive))
        #expect(candidate.isLodgingRateEstimated)
    }

    @Test("Adds roadside pull-offs only where no rest facility exists")
    func pullOffs() {
        // A rest area at 1 h; nothing else.
        let rest = FoundPlace(
            place: Place(id: "ra", name: "Rest Area", coordinate: GeoCoordinate(latitude: 39.001, longitude: -99)),
            categories: [.rest]
        )
        let candidates = builder.build(profile: profile, places: [rest], fuelType: .regular)
        let pullOffs = candidates.filter(\.isRoadsidePullOff)
        #expect(!pullOffs.isEmpty)
        #expect(!pullOffs.contains { abs($0.timeAlong - 3_600) < 450 })
        // Every 15 minutes of road has some rest-capable candidate.
        let restTimes = candidates.filter { $0.capabilities.contains(.rest) }.map(\.timeAlong)
        for minute in stride(from: 15.0, to: 225, by: 15) {
            #expect(restTimes.contains { abs($0 - minute * 60) <= 451 })
        }
    }

    @Test("Thins dense clusters but keeps the cheapest and the closest station")
    func thinning() {
        var places: [FoundPlace] = []
        for index in 0..<12 {
            var place = station("s\(index)", longitude: -98 + Double(index) * 0.001, latitudeOffset: 0.001 + Double(index) * 0.002,
                                prices: [.regular: 4.0 - Double(index) * 0.05])
            place.detourDuration = 120 + Double(index) * 30
            places.append(place)
        }
        let candidates = builder.build(profile: profile, places: places, fuelType: .regular).filter { $0.capabilities.contains(.fuel) }
        #expect(candidates.count <= 4)
        #expect(candidates.contains { $0.id == "s11" }) // cheapest
        #expect(candidates.contains { $0.id == "s0" }) // closest
    }

    @Test("Output is sorted along the route")
    func sorted() {
        let places = [station("b", longitude: -97), station("a", longitude: -99)]
        let candidates = builder.build(profile: profile, places: places, fuelType: .regular)
        #expect(candidates.map(\.distanceAlong) == candidates.map(\.distanceAlong).sorted())
    }
}
