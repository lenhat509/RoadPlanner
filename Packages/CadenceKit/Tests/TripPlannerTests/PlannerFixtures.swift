import Foundation
import TripModels
@testable import TripPlanner

/// Builders for small, explicit optimization problems on a straight 60 mph road.
enum Fixture {
    /// Monday 08:00 at UTC-8.
    static let departure = Date(timeIntervalSince1970: 1_809_360_000)
    static let utcOffset = -8 * 3_600
    /// Highway speed in m/s (≈ 60 mph).
    static let speed = 26.8224

    static func candidate(
        _ id: String,
        atHours hours: Double,
        _ capabilities: StopCapabilities,
        fuelPrice: Double? = nil,
        nightlyRate: Double? = nil,
        detourMinutes: Double = 4,
        isPullOff: Bool = false,
        isLodgingArea: Bool = false
    ) -> StopCandidate {
        StopCandidate(
            id: id,
            place: Place(
                id: id,
                name: id,
                coordinate: GeoCoordinate(latitude: 40, longitude: -100 + hours),
                utcOffsetMinutes: utcOffset / 60
            ),
            capabilities: capabilities,
            distanceAlong: hours * 3_600 * speed,
            timeAlong: hours * 3_600,
            detourDuration: detourMinutes * 60,
            detourDistance: detourMinutes * 60 * 13.4,
            fuelPricePerGallon: capabilities.contains(.fuel) ? (fuelPrice ?? 3.5) : nil,
            nightlyRate: capabilities.contains(.lodging) ? (nightlyRate ?? 120) : nil,
            isRoadsidePullOff: isPullOff,
            isLodgingSearchArea: isLodgingArea
        )
    }

    /// Rest areas every `minutes` along a route of `hours`.
    static func restAreas(everyMinutes minutes: Double, hours: Double, prefix: String = "rest") -> [StopCandidate] {
        stride(from: minutes / 60, to: hours, by: minutes / 60).map {
            candidate("\(prefix)-\(Int($0 * 60))", atHours: $0, [.rest], detourMinutes: 2)
        }
    }

    static func gasStations(everyMinutes minutes: Double, hours: Double, price: Double = 3.5) -> [StopCandidate] {
        stride(from: minutes / 60, to: hours, by: minutes / 60).map {
            candidate("gas-\(Int($0 * 60))", atHours: $0, [.fuel, .rest], fuelPrice: price, detourMinutes: 4)
        }
    }

    static func lodging(everyMinutes minutes: Double, from start: Double, to end: Double, rate: Double = 120) -> [StopCandidate] {
        stride(from: start, to: end, by: minutes / 60).map {
            candidate("hotel-\(Int($0 * 60))", atHours: $0, [.lodging], nightlyRate: rate, detourMinutes: 6)
        }
    }

    static func problem(
        hours: Double,
        candidates: [StopCandidate],
        goal: OptimizationGoal = .fastest,
        vehicle: Vehicle = Vehicle(milesPerGallon: 30),
        arriveBy: Date? = nil
    ) -> OptimizationProblem {
        OptimizationProblem(
            routeDistance: hours * 3_600 * speed,
            routeDuration: hours * 3_600,
            candidates: candidates,
            vehicle: vehicle,
            departure: departure,
            arriveBy: arriveBy,
            originUTCOffset: utcOffset,
            destinationUTCOffset: utcOffset,
            goal: goal
        )
    }

    static func optimize(
        _ problem: OptimizationProblem,
        policy: DrivingPolicy = .standard
    ) -> Result<OptimizedSchedule, InfeasibilityReason> {
        ItineraryOptimizer(settings: OptimizerSettings(policy: policy)).optimize(problem)
    }

    /// Non-stop driving durations between consecutive stops.
    static func drivingSegments(_ schedule: OptimizedSchedule, departure: Date = departure) -> [TimeInterval] {
        var segments: [TimeInterval] = []
        var last = departure
        for stop in schedule.stops {
            segments.append(stop.arrival.timeIntervalSince(last))
            last = stop.departure
        }
        segments.append(schedule.arrival.timeIntervalSince(last))
        return segments
    }

    /// Local clock (seconds since local midnight) of a date at the fixture offset.
    static func localSecondsOfDay(_ date: Date) -> TimeInterval {
        let local = date.timeIntervalSince1970 + Double(utcOffset)
        return local.truncatingRemainder(dividingBy: 86_400)
    }
}

extension Result {
    var value: Success? { try? get() }

    var failureValue: Failure? {
        if case let .failure(error) = self { return error }
        return nil
    }
}
