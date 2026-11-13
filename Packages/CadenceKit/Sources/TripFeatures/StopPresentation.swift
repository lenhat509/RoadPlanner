import Foundation
import TripModels
import TripPlanner

/// Display-ready description of one itinerary stop.
public struct StopPresentation: Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: StopKind
    public var symbolName: String
    public var title: String
    public var subtitle: String
    /// "Arrive 1:31 PM · 15 min break" style summary.
    public var timeText: String
    /// Planned action: fuel amount and price, nightly rate, …
    public var detail: String?
    public var isEstimate: Bool

    public init(stop: ItineraryStop, formatters: TripFormatters) {
        id = stop.id
        kind = stop.kind
        symbolName = StopPresentation.symbolName(for: stop)
        title = stop.place.name
        let offset = stop.place.utcOffsetSeconds
        let kindTitle = stop.isRoadsidePullOff ? "Rest break" : stop.kind.displayName
        subtitle = [kindTitle, stop.place.address].compactMap { $0 }.joined(separator: " · ")

        switch stop.kind {
        case .origin:
            timeText = stop.departure.map { "Depart \(formatters.clockTime($0, utcOffsetSeconds: offset))" } ?? ""
        case .destination:
            timeText = stop.arrival.map { "Arrive \(formatters.clockTime($0, utcOffsetSeconds: offset))" } ?? ""
        case .lodging:
            let arrival = stop.arrival.map { "Check in \(formatters.clockTime($0, utcOffsetSeconds: offset))" }
            let departure = stop.departure.map { "leave \(formatters.dateTime($0, utcOffsetSeconds: offset))" }
            timeText = [arrival, departure].compactMap { $0 }.joined(separator: " · ")
        case .rest, .fuel:
            let arrival = stop.arrival.map { "Arrive \(formatters.clockTime($0, utcOffsetSeconds: offset))" }
            let dwell = stop.dwellDuration.map { "\(formatters.duration($0)) stop" }
            timeText = [arrival, dwell].compactMap { $0 }.joined(separator: " · ")
        }

        var isEstimate = false
        if let purchase = stop.fuelPurchase {
            isEstimate = purchase.isPriceEstimated
            let price = formatters.currency(purchase.pricePerGallon, precise: true)
            detail = "Fill about \(formatters.gallons(purchase.gallons)) at \(price)/gal\(purchase.isPriceEstimated ? " (est.)" : "")"
                + " · \(formatters.currency(purchase.cost))"
        } else if let lodging = stop.lodging {
            isEstimate = lodging.isRateEstimated
            let rate = formatters.currency(lodging.nightlyRate)
            let source = lodging.provider.map { " · \($0)" } ?? ""
            detail = "\(rate)/night\(lodging.isRateEstimated ? " (est.)" : "")\(source)"
        } else if stop.isRoadsidePullOff {
            detail = "No facility found nearby: take the next safe exit or rest area."
        } else {
            detail = nil
        }
        self.isEstimate = isEstimate
    }

    /// SF Symbol for a stop.
    public static func symbolName(for stop: ItineraryStop) -> String {
        if stop.isRoadsidePullOff { return "parkingsign.circle.fill" }
        return symbolName(for: stop.kind)
    }

    public static func symbolName(for kind: StopKind) -> String {
        switch kind {
        case .origin: "circle.circle.fill"
        case .rest: "cup.and.saucer.fill"
        case .fuel: "fuelpump.fill"
        case .lodging: "bed.double.fill"
        case .destination: "flag.checkered"
        }
    }
}

extension PlanningPhase {
    /// User-facing description of the planning step.
    public var displayText: String {
        switch self {
        case .findingRoute: "Finding the best route…"
        case .findingStops: "Finding rest stops, gas and hotels…"
        case .optimizing: "Optimizing your stops…"
        case .finalizing: "Getting turn-by-turn directions…"
        }
    }

    /// Overall progress, `0...1`.
    public var fraction: Double {
        switch self {
        case .findingRoute: 0.05
        case let .findingStops(completed, total): 0.1 + 0.65 * Double(completed) / Double(max(1, total))
        case .optimizing: 0.8
        case .finalizing: 0.9
        }
    }
}

extension Maneuver {
    /// SF Symbol for a maneuver banner.
    public var symbolName: String {
        switch self {
        case .depart, .straight, .nameChange, .unknown: "arrow.up"
        case .turnLeft: "arrow.turn.up.left"
        case .turnRight: "arrow.turn.up.right"
        case .turnSlightLeft, .forkLeft, .rampLeft: "arrow.up.left"
        case .turnSlightRight, .forkRight, .rampRight: "arrow.up.right"
        case .turnSharpLeft: "arrow.turn.left.down"
        case .turnSharpRight: "arrow.turn.right.down"
        case .uturnLeft: "arrow.uturn.left"
        case .uturnRight: "arrow.uturn.right"
        case .merge: "arrow.merge"
        case .roundaboutLeft: "arrow.counterclockwise"
        case .roundaboutRight: "arrow.clockwise"
        case .ferry: "ferry.fill"
        case .arrive: "mappin.circle.fill"
        }
    }
}
