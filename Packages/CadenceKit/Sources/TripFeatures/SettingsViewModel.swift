import Foundation
import Observation
import TripModels
import TripPersistence

/// Default car and driving preferences. Changes are saved immediately.
@MainActor
@Observable
public final class SettingsViewModel {
    public var preferences: UserPreferences {
        didSet { dependencies.preferences.save(preferences) }
    }

    private let dependencies: AppDependencies

    public init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        self.preferences = dependencies.preferences.load()
    }

    public var restIntervalHours: Double {
        get { preferences.policy.maxContinuousDriving / 3_600 }
        set {
            let clamped = min(5, max(0.5, newValue))
            preferences.policy.maxContinuousDriving = clamped * 3_600
            preferences.policy.maxDailyDriving = max(preferences.policy.maxDailyDriving, preferences.policy.maxContinuousDriving)
        }
    }

    /// Refuel before the tank drops below this percentage (5–50 %).
    public var minimumFuelPercent: Double {
        get { (preferences.policy.fuelReserveFraction * 100).rounded() }
        set { preferences.policy.fuelReserveFraction = min(50, max(5, newValue)) / 100 }
    }

    public var restBreakMinutes: Double {
        get { preferences.policy.restStopDuration / 60 }
        set { preferences.policy.restStopDuration = min(60, max(10, newValue)) * 60 }
    }

    public var maxDailyDrivingHours: Double {
        get { preferences.policy.maxDailyDriving / 3_600 }
        set { preferences.policy.maxDailyDriving = max(preferences.policy.maxContinuousDriving, min(14, max(2, newValue)) * 3_600) }
    }

    public var dayStartHour: Int {
        get { preferences.policy.dayStart.hour }
        set { preferences.policy.dayStart = LocalTime(hour: min(newValue, preferences.policy.dayEnd.hour - 1)) }
    }

    public var dayEndHour: Int {
        get { preferences.policy.dayEnd.hour }
        set { preferences.policy.dayEnd = LocalTime(hour: max(newValue, preferences.policy.dayStart.hour + 1)) }
    }

    public var restSummary: String {
        let formatters = dependencies.formatters
        return "Break every \(formatters.duration(preferences.policy.maxContinuousDriving)) or sooner, "
            + "\(formatters.duration(preferences.policy.restStopDuration)) each"
    }

    public func resetToDefaults() {
        let accepted = preferences.hasAcceptedSafetyNotice
        preferences = .default
        preferences.hasAcceptedSafetyNotice = accepted
    }

    public func acceptSafetyNotice() {
        preferences.hasAcceptedSafetyNotice = true
    }
}
