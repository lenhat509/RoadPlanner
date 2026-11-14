import Foundation
import TripModels

/// Defaults the planning form starts from, plus app settings.
public struct UserPreferences: Codable, Hashable, Sendable {
    public var vehicle: Vehicle
    public var policy: DrivingPolicy
    public var goal: OptimizationGoal
    public var travelers: Int
    public var voiceGuidanceEnabled: Bool
    public var hasAcceptedSafetyNotice: Bool
    /// The version of the terms the user agreed to (nil: not yet). Optional, so settings saved
    /// before the agreement existed still load.
    public var acceptedTermsVersion: Int?

    public init(
        vehicle: Vehicle = Vehicle(milesPerGallon: 28),
        policy: DrivingPolicy = .standard,
        goal: OptimizationGoal = .balanced,
        travelers: Int = 2,
        voiceGuidanceEnabled: Bool = true,
        hasAcceptedSafetyNotice: Bool = false,
        acceptedTermsVersion: Int? = nil
    ) {
        self.vehicle = vehicle
        self.policy = policy
        self.goal = goal
        self.travelers = travelers
        self.voiceGuidanceEnabled = voiceGuidanceEnabled
        self.hasAcceptedSafetyNotice = hasAcceptedSafetyNotice
        self.acceptedTermsVersion = acceptedTermsVersion
    }

    public static let `default` = UserPreferences()
}

public protocol PreferencesStore: Sendable {
    func load() -> UserPreferences
    func save(_ preferences: UserPreferences)
}

/// `UserDefaults`-backed store (JSON-encoded under one key).
public final class UserDefaultsPreferencesStore: PreferencesStore, @unchecked Sendable {
    // UserDefaults is documented as thread-safe; the lock guards encode/decode pairs.
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, key: String = "waystage.preferences.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> UserPreferences {
        lock.withLock {
            guard let data = defaults.data(forKey: key),
                  let preferences = try? JSONDecoder().decode(UserPreferences.self, from: data) else { return .default }
            return preferences
        }
    }

    public func save(_ preferences: UserPreferences) {
        lock.withLock {
            if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: key) }
        }
    }
}

public final class InMemoryPreferencesStore: PreferencesStore, @unchecked Sendable {
    private let lock = NSLock()
    private var preferences: UserPreferences

    public init(_ preferences: UserPreferences = .default) { self.preferences = preferences }

    public func load() -> UserPreferences { lock.withLock { preferences } }

    public func save(_ preferences: UserPreferences) { lock.withLock { self.preferences = preferences } }
}
