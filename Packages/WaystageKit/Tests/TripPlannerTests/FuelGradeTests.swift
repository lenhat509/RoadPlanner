import Foundation
import Testing
import TripModels
@testable import TripPlanner
import TripSandbox

@Suite("Fuel grades")
struct FuelGradeTests {
    // MARK: Grades

    @Test("Grades name their octane and ethanol level; any grade is the default")
    func labels() {
        #expect(FuelType.allCases.first == .any)
        #expect(FuelType.any.title == "Any gasoline")
        #expect(FuelType.regular.title == "Regular 87 · E10")
        #expect(FuelType.midgrade.title == "Midgrade 89 · E10")
        #expect(FuelType.premium.title == "Premium 91+ · E10")
        #expect(FuelType.e85.title == "Flex fuel · E85")
        #expect(FuelType.diesel.title == "Diesel · no ethanol")
        #expect(FuelType.allCases.allSatisfy { !$0.ethanolDescription.isEmpty && !$0.planningNote.isEmpty })
        #expect(Vehicle(milesPerGallon: 30).fuelType == .any)
    }

    @Test("E85 goes about a quarter fewer miles per gallon, so the range is shorter")
    func e85Range() {
        let gasoline = Vehicle(milesPerGallon: 30, tankCapacityGallons: 15, fuelType: .regular)
        let flex = Vehicle(milesPerGallon: 30, tankCapacityGallons: 15, fuelType: .e85)
        #expect(abs(flex.effectiveMilesPerGallon - 22.5) < 1e-9)
        #expect(abs(flex.fullTankRangeMiles - gasoline.fullTankRangeMiles * 0.75) < 1e-9)
        #expect(flex.gallons(forMeters: Units.metersPerMile) > gasoline.gallons(forMeters: Units.metersPerMile))
    }

    // MARK: Which stations sell the grade

    private func station(_ name: String = "Shell", prices: [FuelType: Double]) -> FoundPlace {
        FoundPlace(
            place: Place(id: name, name: name, coordinate: GeoCoordinate(latitude: 36, longitude: -115)),
            categories: [.fuel], fuelPrices: prices
        )
    }

    @Test("A station sells a grade when it lists it; one listing other grades doesn't")
    func listedGrades() {
        let listed = station(prices: [.regular: 3.10, .premium: 3.95])
        #expect(FuelOffer.at(listed, for: .premium) == .confirmed(pricePerGallon: 3.95))
        #expect(FuelOffer.at(listed, for: .midgrade) == .unavailable)
        #expect(FuelOffer.at(listed, for: .e85) == .unavailable)
        #expect(FuelOffer.at(listed, for: .any) == .confirmed(pricePerGallon: 3.10), "any grade: its cheapest gasoline")
        #expect(FuelOffer.at(station(prices: [.diesel: 3.60]), for: .any) == .unavailable, "diesel-only is no gasoline")
        #expect(FuelOffer.at(station(prices: [.e85: 2.70, .regular: 3.20]), for: .any) == .confirmed(pricePerGallon: 3.20),
                "E85 isn't gasoline for a regular car")
    }

    @Test("Without station data: gasoline grades are assumed (nearly every station sells them), others aren't")
    func unlistedGrades() {
        let silent = station(prices: [:])
        for grade in [FuelType.any, .regular, .midgrade, .premium] {
            #expect(FuelOffer.at(silent, for: grade) == .assumed, "\(grade)")
        }
        #expect(FuelOffer.at(silent, for: .e85) == .unavailable, "few stations sell E85: it must be listed")
        #expect(FuelOffer.at(silent, for: .diesel) == .unavailable)
        #expect(FuelOffer.at(station("Pilot Travel Center", prices: [:]), for: .diesel) == .assumed, "truck stops sell diesel")
        #expect(FuelOffer.at(station("Love's Travel Stop", prices: [:]), for: .diesel) == .assumed)
    }

    @Test("A station without the grade is only a place for a break, priced at the grade where it is sold")
    func candidates() throws {
        let route = SyntheticRoute.make(
            from: GeoCoordinate(latitude: 36, longitude: -115), to: GeoCoordinate(latitude: 36, longitude: -112)
        )
        let profile = route.profile()
        func place(_ id: String, prices: [FuelType: Double]) -> FoundPlace {
            FoundPlace(
                place: Place(id: id, name: id, coordinate: profile.geometry.coordinate(atDistance: 100_000)),
                categories: [.fuel], fuelPrices: prices
            )
        }
        let builder = CandidateBuilder()
        let built = builder.build(
            profile: profile,
            places: [place("regular-only", prices: [.regular: 3.0]), place("premium", prices: [.regular: 3.1, .premium: 4.0])],
            fuelType: .premium
        )
        let regularOnly = try #require(built.first { $0.id == "regular-only" })
        #expect(!regularOnly.capabilities.contains(.fuel))
        #expect(regularOnly.capabilities.contains(.rest))
        let premium = try #require(built.first { $0.id == "premium" })
        #expect(premium.capabilities.contains(.fuel))
        #expect(premium.fuelPricePerGallon == 4.0)
        #expect(premium.isFuelGradeConfirmed)
        #expect(!premium.isFuelPriceEstimated)
    }

    // MARK: Planning

    /// Fixed gas stations along a route (and nothing else).
    struct StaticStations: PlaceSearchProvider {
        let stations: [FoundPlace]
        func searchAlongRoute(_ search: AlongRouteSearch) async throws -> [FoundPlace] {
            search.category == .fuel ? stations : []
        }
    }

    private func request(grade: FuelType, goal: OptimizationGoal = .cheapest, tank: Double = 12) -> TripRequest {
        var request = SampleTrips.request(from: "la", to: "den", goal: goal)
        request.vehicle = Vehicle(milesPerGallon: 25, tankCapacityGallons: tank, fuelType: grade)
        return request
    }

    @Test("The cheapest plan fills up at the cheapest station that sells the grade")
    func cheapestStationWithTheGrade() async throws {
        // A day's drive (LA → Las Vegas) on a small tank: one fill-up is needed.
        func trip(_ grade: FuelType) -> TripRequest {
            var request = SampleTrips.request(from: "la", to: "lv", goal: .cheapest)
            request.vehicle = Vehicle(milesPerGallon: 25, tankCapacityGallons: 6, fuelType: grade)
            return request
        }
        let base = trip(.premium)
        let route = SyntheticRoute.make(from: base.origin.coordinate, to: base.destination.coordinate)
        let geometry = route.profile().geometry
        func station(_ id: String, at share: Double, _ prices: [FuelType: Double]) -> FoundPlace {
            FoundPlace(
                place: Place(id: id, name: id, coordinate: geometry.coordinate(atDistance: geometry.totalLength * share)),
                categories: [.fuel], fuelPrices: prices, detourDuration: 240, detourDistance: 1_000
            )
        }
        // Along the way: a cheap station without premium and two premium stations, three times.
        var stations: [FoundPlace] = []
        for (index, share) in [0.3, 0.45, 0.6].enumerated() {
            stations.append(station("regular-\(index)", at: share, [.regular: 2.79]))
            stations.append(station("premium-dear-\(index)", at: share + 0.01, [.regular: 3.40, .premium: 4.49]))
            stations.append(station("premium-cheap-\(index)", at: share + 0.02, [.regular: 3.30, .premium: 3.99]))
        }
        let service = TripPlanningService(routing: FakeRoutingProvider(), places: StaticStations(stations: stations))

        let premium = try #require(try await service.plan(base) { _ in }.recommended)
        let premiumStops = premium.stops.filter { $0.fuelPurchase != nil }
        #expect(premiumStops.count == 1)
        #expect(!premium.warnings.contains { $0.code == .fuelGap })
        #expect(premiumStops.allSatisfy { $0.place.id.hasPrefix("premium-cheap") }, "\(premiumStops.map(\.place.id))")
        #expect(premiumStops.allSatisfy { $0.fuelPurchase?.pricePerGallon == 3.99 && $0.fuelPurchase?.grade == .premium })

        let any = try #require(try await service.plan(trip(.any)) { _ in }.recommended)
        let anyStops = any.stops.filter { $0.fuelPurchase != nil }
        #expect(anyStops.allSatisfy { $0.place.id.hasPrefix("regular") }, "any grade: the cheapest pump anywhere: \(anyStops.map(\.place.id))")
    }

    /// Records every place a search returns, to check the stops a plan picks.
    final class RecordingPlaces: PlaceSearchProvider, @unchecked Sendable {
        let inner: any PlaceSearchProvider
        private let lock = NSLock()
        private var seen: [String: FoundPlace] = [:]

        init(_ inner: any PlaceSearchProvider) { self.inner = inner }

        func searchAlongRoute(_ search: AlongRouteSearch) async throws -> [FoundPlace] {
            let found = try await inner.searchAlongRoute(search)
            record(found)
            return found
        }

        private func record(_ found: [FoundPlace]) {
            lock.lock()
            defer { lock.unlock() }
            for place in found { seen[place.place.id] = place }
        }

        func place(_ id: String) -> FoundPlace? {
            lock.lock()
            defer { lock.unlock() }
            return seen[id]
        }
    }

    @Test("Every fuel stop sells the chosen grade", arguments: [FuelType.regular, .midgrade, .premium, .diesel, .e85])
    func everyStopSellsTheGrade(_ grade: FuelType) async throws {
        let places = RecordingPlaces(FakePlaceSearchProvider())
        let service = TripPlanningService(routing: FakeRoutingProvider(), places: places)
        // A roomy tank, so even E85 (a quarter fewer miles per gallon) reaches the next E85 pump.
        let result = try await service.plan(request(grade: grade, goal: .balanced, tank: 18)) { _ in }
        for route in result.routes {
            for itinerary in route.options {
                let fuelStops = itinerary.stops.filter { $0.fuelPurchase != nil && !$0.isRoadsidePullOff }
                #expect(!fuelStops.isEmpty)
                // Where E85 is too scarce along a route, that plan uses regular (and says so).
                let planned = itinerary.warnings.contains { $0.code == .fuelGradeUnavailable } ? FuelType.regular : grade
                if planned != grade { #expect(grade == .e85) }
                for stop in fuelStops {
                    let purchase = try #require(stop.fuelPurchase)
                    #expect(purchase.grade == planned)
                    let station = try #require(places.place(stop.place.id))
                    let offer = FuelOffer.at(station, for: planned)
                    #expect(offer != .unavailable, "\(stop.place.name) doesn't sell \(grade.title)")
                    if case let .confirmed(price) = offer {
                        #expect(purchase.pricePerGallon == price)
                        #expect(purchase.isGradeConfirmed == true)
                    }
                }
                #expect(!itinerary.warnings.contains { $0.code == .fuelGap }, "\(grade): \(itinerary.warnings)")
            }
        }
        let recommended = try #require(result.recommended)
        #expect(recommended.stops.compactMap(\.fuelPurchase).allSatisfy { $0.grade == grade }, "the best plan keeps the grade")
    }

    @Test("When E85 is too scarce, the plan fills up with regular gasoline and says so")
    func scarceE85() async throws {
        var mix = SyntheticPlaces.FuelMix.typical
        mix.e85 = 0
        let service = TripPlanningService(routing: FakeRoutingProvider(), places: FakePlaceSearchProvider(fuelMix: mix))
        let itinerary = try #require(try await service.plan(request(grade: .e85)) { _ in }.recommended)
        #expect(itinerary.warnings.contains { $0.code == .fuelGradeUnavailable && $0.message.contains("E85") })
        #expect(!itinerary.warnings.contains { $0.code == .fuelGap })
        let purchases = itinerary.stops.compactMap(\.fuelPurchase)
        #expect(!purchases.isEmpty)
        #expect(purchases.allSatisfy { $0.grade == .regular })
    }

    @Test("When no station along the way is known to sell diesel, the plan says so")
    func missingDiesel() async throws {
        var mix = SyntheticPlaces.FuelMix.typical
        mix.reporting = 1
        mix.diesel = 0
        let service = TripPlanningService(routing: FakeRoutingProvider(), places: FakePlaceSearchProvider(fuelMix: mix))
        let itinerary = try #require(try await service.plan(request(grade: .diesel)) { _ in }.recommended)
        let gap = try #require(itinerary.warnings.first { $0.code == .fuelGap })
        #expect(gap.message.contains("diesel"), "\(gap.message)")
    }
}
