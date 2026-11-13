import Foundation
import TripModels
import TripPlanner

/// Generates deterministic places along a route (gas stations, rest areas, hotels).
public enum SyntheticPlaces {
    public struct Density: Sendable {
        /// Average spacing between gas stations, in driving minutes.
        public var fuelEveryMinutes: Double
        public var restEveryMinutes: Double
        public var lodgingEveryMinutes: Double

        public init(fuelEveryMinutes: Double = 25, restEveryMinutes: Double = 50, lodgingEveryMinutes: Double = 35) {
            self.fuelEveryMinutes = fuelEveryMinutes
            self.restEveryMinutes = restEveryMinutes
            self.lodgingEveryMinutes = lodgingEveryMinutes
        }

        public static let interstate = Density()
    }

    /// Places for one category along `profile`, offset slightly from the road.
    ///
    /// Prices vary deterministically with `seed` so "cheapest" and "fastest" plans differ.
    public static func along(
        _ profile: RouteProfile,
        category: PlaceCategory,
        everyMinutes: Double,
        seed: UInt64 = 1,
        utcOffsetMinutes: ((GeoCoordinate) -> Int)? = nil,
        withinTime: ClosedRange<TimeInterval>? = nil
    ) -> [FoundPlace] {
        var generator = SeededGenerator(seed: seed &+ UInt64(category.hashValueStable))
        var result: [FoundPlace] = []
        var time = everyMinutes * 60 * 0.6
        var index = 0
        while time < profile.totalDuration {
            defer {
                time += everyMinutes * 60 * Double.random(in: 0.6...1.4, using: &generator)
                index += 1
            }
            if let withinTime, !withinTime.contains(time) { continue }
            let onRoute = profile.coordinate(atTime: time)
            let offset = Double.random(in: 150...2_500, using: &generator)
            let coordinate = GeoCoordinate(
                latitude: onRoute.latitude + offset / 111_000,
                longitude: onRoute.longitude
            )
            let offsetMinutes = utcOffsetMinutes?(coordinate) ?? Place.estimatedUTCOffsetSeconds(for: coordinate) / 60
            let place = Place(
                id: "\(category.rawValue)-\(seed)-\(index)",
                name: name(for: category, index: index),
                address: "Exit \(Int(Units.miles(fromMeters: profile.distance(atTime: time))))",
                coordinate: coordinate,
                utcOffsetMinutes: offsetMinutes
            )
            let detour = 2 * offset * 1.3 / 13.4 + 120
            switch category {
            case .fuel:
                let base = Double.random(in: 2.95...4.45, using: &generator)
                result.append(FoundPlace(
                    place: place,
                    categories: [.fuel],
                    fuelPrices: [
                        .regular: rounded(base), .midgrade: rounded(base + 0.45),
                        .premium: rounded(base + 0.85), .diesel: rounded(base + 0.4),
                    ],
                    rating: Double.random(in: 3.2...4.6, using: &generator),
                    detourDuration: detour,
                    detourDistance: 2 * offset * 1.3
                ))
            case .rest:
                result.append(FoundPlace(
                    place: place, categories: [.rest], detourDuration: detour / 2 + 30, detourDistance: offset
                ))
            case .lodging:
                let level = PriceLevel(rawValue: Int.random(in: 1...3, using: &generator)) ?? .moderate
                let hasLiveRate = Bool.random(using: &generator)
                result.append(FoundPlace(
                    place: place,
                    categories: [.lodging],
                    priceLevel: level,
                    nightlyRate: hasLiveRate ? Double(Int.random(in: 79...239, using: &generator)) : nil,
                    rateProvider: hasLiveRate ? "Expedia" : nil,
                    rating: Double.random(in: 3.0...4.8, using: &generator),
                    detourDuration: detour,
                    detourDistance: 2 * offset * 1.3
                ))
            }
        }
        return result
    }

    /// All categories at the given density.
    public static func all(along profile: RouteProfile, density: Density = .interstate, seed: UInt64 = 1) -> [FoundPlace] {
        along(profile, category: .fuel, everyMinutes: density.fuelEveryMinutes, seed: seed)
            + along(profile, category: .rest, everyMinutes: density.restEveryMinutes, seed: seed)
            + along(profile, category: .lodging, everyMinutes: density.lodgingEveryMinutes, seed: seed)
    }

    private static func rounded(_ price: Double) -> Double { (price * 100).rounded() / 100 - 0.001 }

    private static func name(for category: PlaceCategory, index: Int) -> String {
        let brands: [PlaceCategory: [String]] = [
            .fuel: ["Shell", "Chevron", "Pilot Travel Center", "Love's", "Exxon", "Sinclair", "Maverik", "Circle K"],
            .rest: ["Rest Area", "Scenic Overlook", "Welcome Center", "Travel Plaza"],
            .lodging: ["Hampton Inn", "Holiday Inn Express", "La Quinta", "Best Western", "Comfort Inn", "Motel 6", "Courtyard"],
        ]
        let list = brands[category] ?? ["Stop"]
        return "\(list[index % list.count]) #\(index + 1)"
    }
}

/// SplitMix64 — tiny deterministic PRNG for reproducible fixtures.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension PlaceCategory {
    /// Stable per-category salt (Swift's `hashValue` is randomized per process).
    var hashValueStable: Int {
        switch self {
        case .fuel: 11
        case .rest: 23
        case .lodging: 37
        }
    }
}
