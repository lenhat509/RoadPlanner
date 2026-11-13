import Foundation
import TripModels

/// How far the planner had to loosen the user's preferences to find a feasible plan.
/// Levels are cumulative. The rest-break limit (`maxContinuousDriving`) is never relaxed.
public enum RelaxationLevel: Int, CaseIterable, Comparable, Sendable {
    /// The user's policy as given.
    case standard
    /// Days start up to 1 h earlier and end up to 2 h later; +1 h of daily driving.
    case extendedDay
    /// Breaks shortened to 10 minutes.
    case shorterBreaks
    /// No end-of-day cutoff (daily driving and rest limits still apply).
    case nightDriving
    /// Lodging search areas and emergency fuel at pull-offs (the minimum fuel level is kept).
    case lastResort

    public static func < (lhs: RelaxationLevel, rhs: RelaxationLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A schedule plus the relaxations needed to obtain it.
public struct FeasibleSchedule: Sendable {
    public var schedule: OptimizedSchedule
    public var level: RelaxationLevel
    public var appliedPolicy: DrivingPolicy
    /// `false` when the requested deadline could not be met.
    public var deadlineMet: Bool
    public var warnings: [PlanWarning]
}

/// Feasibility-first planning: tries the strictest settings first and relaxes preferences
/// step by step until a plan exists. A deadline is only dropped after every relaxation
/// level has failed to meet it. The result always respects the rest-break limit.
public struct FeasibilityPlanner: Sendable {
    public var baseSettings: OptimizerSettings

    public init(baseSettings: OptimizerSettings) {
        self.baseSettings = baseSettings
    }

    public init(policy: DrivingPolicy, pricing: PricingDefaults = .standard) {
        var settings = OptimizerSettings(policy: policy)
        settings.pricing = pricing
        self.baseSettings = settings
    }

    /// Always returns a schedule (the last-resort level is feasible for any drivable route).
    public func solve(_ problem: OptimizationProblem) -> FeasibleSchedule {
        let deadlineModes = problem.arriveBy == nil ? [false] : [true, false]
        for enforceDeadline in deadlineModes {
            for level in RelaxationLevel.allCases {
                var settings = FeasibilityPlanner.settings(for: level, base: baseSettings)
                settings.enforceDeadline = enforceDeadline
                if case let .success(schedule) = ItineraryOptimizer(settings: settings).optimize(problem) {
                    let deadlineMet = problem.arriveBy.map { schedule.arrival <= $0 } ?? true
                    return FeasibleSchedule(
                        schedule: schedule,
                        level: level,
                        appliedPolicy: settings.policy,
                        deadlineMet: deadlineMet,
                        warnings: warnings(for: level, schedule: schedule, problem: problem, deadlineMet: deadlineMet)
                    )
                }
            }
        }
        // Unreachable for valid inputs; plan straight through with a warning rather than crash.
        let fallback = OptimizedSchedule(
            stops: [],
            arrival: problem.departure.addingTimeInterval(problem.routeDuration),
            fuelOnArrival: 0, finalDayIndex: 0, fuelCost: 0, lodgingCost: 0,
            tollCost: problem.tollCostUSD, drivingDuration: problem.routeDuration,
            fuelGallonsUsed: 0, referenceFuelPrice: 0, score: .infinity
        )
        return FeasibleSchedule(
            schedule: fallback, level: .lastResort, appliedPolicy: baseSettings.policy, deadlineMet: false,
            warnings: [PlanWarning(code: .fuelGap, message: "No safe schedule was found for this route. Check fuel and lodging availability before you go.")]
        )
    }

    /// Optimizer settings for a relaxation level (cumulative).
    public static func settings(for level: RelaxationLevel, base: OptimizerSettings) -> OptimizerSettings {
        var settings = base
        var policy = base.policy
        if level >= .extendedDay {
            policy.dayEnd = LocalTime(
                hour: min(23, policy.dayEnd.hour + 2),
                minute: policy.dayEnd.hour + 2 > 23 ? 30 : policy.dayEnd.minute
            )
            policy.dayStart = LocalTime(hour: max(5, policy.dayStart.hour - 1), minute: policy.dayStart.minute)
            policy.maxDailyDriving = max(policy.maxDailyDriving, min(12 * 3_600, policy.maxDailyDriving + 3_600))
            policy.minimumOvernightRest = max(7 * 3_600, policy.minimumOvernightRest - 3_600)
        }
        if level >= .shorterBreaks {
            policy.restStopDuration = min(policy.restStopDuration, 10 * 60)
            policy.fuelStopDuration = min(policy.fuelStopDuration, 10 * 60)
        }
        if level >= .nightDriving {
            settings.allowNightDriving = true
        }
        if level >= .lastResort {
            settings.allowLodgingSearchAreas = true
            settings.allowFuelAtPullOffs = true
        }
        settings.policy = policy
        return settings
    }

    private func warnings(
        for level: RelaxationLevel,
        schedule: OptimizedSchedule,
        problem: OptimizationProblem,
        deadlineMet: Bool
    ) -> [PlanWarning] {
        var warnings: [PlanWarning] = []
        if !deadlineMet, let deadline = problem.arriveBy {
            let formatter = Self.formatter(utcOffset: problem.destinationUTCOffset)
            warnings.append(PlanWarning(
                code: .deadlineMissed,
                message: "Arriving by \(formatter.string(from: deadline)) isn't possible with safe rest breaks. "
                    + "Earliest arrival: \(formatter.string(from: schedule.arrival))."
            ))
        }
        let relaxed = FeasibilityPlanner.settings(for: level, base: baseSettings).policy
        if level >= .extendedDay {
            warnings.append(PlanWarning(
                code: .extendedDrivingDay,
                message: "Some driving days start as early as \(relaxed.dayStart) or end as late as \(relaxed.dayEnd)."
            ))
        }
        if level >= .shorterBreaks {
            warnings.append(PlanWarning(code: .shorterBreaks, message: "Breaks are shortened to 10 minutes."))
        }
        if level >= .nightDriving {
            warnings.append(PlanWarning(
                code: .nightDriving,
                message: "Some driving happens late at night. Consider an extra overnight stop if you feel tired."
            ))
        }
        if schedule.stops.contains(where: { $0.candidate.isLodgingSearchArea }) {
            warnings.append(PlanWarning(
                code: .lodgingAreaOnly,
                message: "No lodging was found near the end of some days. Those stops show an area to search."
            ))
        }
        if schedule.stops.contains(where: { $0.candidate.isRoadsidePullOff && isRefuel($0.action) }) {
            warnings.append(PlanWarning(
                code: .fuelGap,
                message: "Part of the route has no known gas station within your range. Fill up early and carry extra fuel."
            ))
        }
        return warnings
    }

    private func isRefuel(_ action: StopAction) -> Bool {
        if case .refuel = action { return true }
        return false
    }

    static func formatter(utcOffset: Int) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: utcOffset)
        formatter.dateFormat = "EEE MMM d, h:mm a"
        return formatter
    }
}
