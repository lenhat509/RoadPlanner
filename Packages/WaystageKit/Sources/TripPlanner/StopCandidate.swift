import Foundation
import TripModels

/// What a candidate stop can be used for.
public struct StopCapabilities: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let rest = StopCapabilities(rawValue: 1 << 0)
    public static let fuel = StopCapabilities(rawValue: 1 << 1)
    public static let lodging = StopCapabilities(rawValue: 1 << 2)
}

/// A place along the route the optimizer may choose as a stop.
public struct StopCandidate: Hashable, Sendable, Identifiable {
    public var id: String
    public var place: Place
    public var capabilities: StopCapabilities
    /// Distance from the start of the route to where the driver leaves the route, in meters.
    public var distanceAlong: Double
    /// Driving time from the start of the route to that point, in seconds.
    public var timeAlong: TimeInterval
    /// Extra time to drive to the place and back to the route.
    public var detourDuration: TimeInterval
    /// Extra distance to drive to the place and back to the route.
    public var detourDistance: Double
    /// Price per gallon for the vehicle's fuel grade.
    public var fuelPricePerGallon: Double?
    public var isFuelPriceEstimated: Bool
    /// The station lists the grade (rather than it being assumed for a station listing none).
    public var isFuelGradeConfirmed: Bool
    public var nightlyRate: Double?
    public var isLodgingRateEstimated: Bool
    public var lodgingProvider: String?
    public var bookingURL: URL?
    public var rating: Double?
    /// A generic "take a safe exit" break inserted where no facility was found.
    public var isRoadsidePullOff: Bool
    /// A placeholder overnight area used only when no real lodging is known (last-resort plans).
    public var isLodgingSearchArea: Bool

    public init(
        id: String,
        place: Place,
        capabilities: StopCapabilities,
        distanceAlong: Double,
        timeAlong: TimeInterval,
        detourDuration: TimeInterval = 0,
        detourDistance: Double = 0,
        fuelPricePerGallon: Double? = nil,
        isFuelPriceEstimated: Bool = false,
        isFuelGradeConfirmed: Bool = false,
        nightlyRate: Double? = nil,
        isLodgingRateEstimated: Bool = false,
        lodgingProvider: String? = nil,
        bookingURL: URL? = nil,
        rating: Double? = nil,
        isRoadsidePullOff: Bool = false,
        isLodgingSearchArea: Bool = false
    ) {
        self.id = id
        self.place = place
        self.capabilities = capabilities
        self.distanceAlong = distanceAlong
        self.timeAlong = timeAlong
        self.detourDuration = detourDuration
        self.detourDistance = detourDistance
        self.fuelPricePerGallon = fuelPricePerGallon
        self.isFuelPriceEstimated = isFuelPriceEstimated
        self.isFuelGradeConfirmed = isFuelGradeConfirmed
        self.nightlyRate = nightlyRate
        self.isLodgingRateEstimated = isLodgingRateEstimated
        self.lodgingProvider = lodgingProvider
        self.bookingURL = bookingURL
        self.rating = rating
        self.isRoadsidePullOff = isRoadsidePullOff
        self.isLodgingSearchArea = isLodgingSearchArea
    }

    /// `true` for real places (not generated pull-offs or lodging search areas).
    public var isSynthetic: Bool { isRoadsidePullOff || isLodgingSearchArea }
}
