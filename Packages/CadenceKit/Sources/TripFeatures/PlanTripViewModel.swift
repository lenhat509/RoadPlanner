import Foundation
import Observation
import TripModels
import TripPersistence
import TripPlanner

/// The trip planning form: places, times, car and preferences.
@MainActor
@Observable
public final class PlanTripViewModel {
    public enum Field: Hashable, Sendable {
        case origin
        case destination
    }

    public struct LocationInput: Equatable, Sendable {
        public var text = ""
        public var place: Place?
        public var suggestions: [PlaceSuggestion] = []
        public var isResolving = false
    }

    /// Outcome of validating the form.
    public enum Validation: Equatable, Sendable {
        case valid(TripRequest)
        case invalid([TripRequestError])
    }

    public enum Status: Equatable, Sendable {
        case idle
        case planning(PlanningPhase?)
        case failed(String)
    }

    // Form state
    public var origin = LocationInput()
    public var destination = LocationInput()
    public var departure: Date {
        didSet { if !isApplyingDefaultDeparture { departureEditedByUser = true } }
    }
    public var arriveByEnabled = false
    public var arriveBy: Date
    public var mpgText: String
    /// When off, the default cadence applies (a break at most every 3 h, i.e. every 2–3 h).
    public var customRestEnabled = false
    public var restIntervalHours: Double
    public var goal: OptimizationGoal
    // Advanced
    public var tankGallonsText: String
    /// Refuel before the tank drops below this level (percent of the tank).
    public var minimumFuelPercent: Double
    public var startingFuelPercent: Double
    public var fuelType: FuelType
    public var maxDailyDrivingHours: Double
    public var travelers: Int

    public private(set) var status: Status = .idle
    public private(set) var result: PlanResult?

    private let dependencies: AppDependencies
    @ObservationIgnored private var isApplyingDefaultDeparture = false
    @ObservationIgnored private var departureEditedByUser = false
    private var searchTasks: [Field: Task<Void, Never>] = [:]
    private var planTask: Task<Void, Never>?
    private var sessionToken = UUID().uuidString

    public init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        let preferences = dependencies.preferences.load()
        let now = dependencies.now()
        departure = PlanTripViewModel.defaultDeparture(
            now: now, utcOffsetSeconds: dependencies.timeZone.secondsFromGMT(for: now), policy: preferences.policy
        )
        arriveBy = now.addingTimeInterval(3 * 86_400)
        mpgText = PlanTripViewModel.format(preferences.vehicle.milesPerGallon)
        tankGallonsText = PlanTripViewModel.format(preferences.vehicle.tankCapacityGallons)
        startingFuelPercent = 100
        minimumFuelPercent = (preferences.policy.fuelReserveFraction * 100).rounded()
        fuelType = preferences.vehicle.fuelType
        goal = preferences.goal
        travelers = preferences.travelers
        maxDailyDrivingHours = preferences.policy.maxDailyDriving / 3_600
        restIntervalHours = min(3, preferences.policy.maxContinuousDriving / 3_600)
        customRestEnabled = preferences.policy.maxContinuousDriving != DrivingPolicy.standard.maxContinuousDriving
    }

    // MARK: Places

    public func input(for field: Field) -> LocationInput {
        field == .origin ? origin : destination
    }

    private func update(_ field: Field, _ change: (inout LocationInput) -> Void) {
        switch field {
        case .origin: change(&origin)
        case .destination: change(&destination)
        }
    }

    /// Called as the user types; fetches suggestions after a short pause.
    public func queryChanged(_ text: String, for field: Field) {
        // Text fields re-send their current text on focus changes; that must not search again.
        guard text != input(for: field).text else { return }
        update(field) {
            $0.text = text
            if $0.place?.name != text { $0.place = nil }
        }
        searchTasks[field]?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, input(for: field).place == nil else {
            update(field) { $0.suggestions = [] }
            return
        }
        let debounce = dependencies.autocompleteDebounce
        let autocomplete = dependencies.autocomplete
        let bias = dependencies.location.lastKnownLocation
        let token = sessionToken
        searchTasks[field] = Task { [weak self] in
            if debounce > 0 { try? await Task.sleep(nanoseconds: UInt64(debounce * 1e9)) }
            guard !Task.isCancelled else { return }
            let suggestions = (try? await autocomplete.suggestions(for: trimmed, near: bias, sessionToken: token)) ?? []
            guard !Task.isCancelled, let self else { return }
            // Ignore stale results: the text changed or a place was chosen meanwhile.
            let current = self.input(for: field)
            guard current.place == nil, current.text.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
            self.update(field) { $0.suggestions = suggestions }
        }
    }

    /// Waits for pending autocomplete requests (tests and UI previews).
    public func waitForSuggestions() async {
        for task in searchTasks.values { await task.value }
    }

    public func select(_ suggestion: PlaceSuggestion, for field: Field) async {
        // A search still in flight would otherwise bring the list back after this tap.
        searchTasks[field]?.cancel()
        searchTasks[field] = nil
        update(field) {
            $0.text = suggestion.primaryText
            $0.suggestions = []
            $0.isResolving = true
        }
        do {
            let place = try await dependencies.autocomplete.place(for: suggestion.placeID, sessionToken: sessionToken)
            update(field) {
                $0.place = place
                $0.text = place.name
                $0.isResolving = false
            }
            if field == .origin { refreshDefaultDeparture(for: place) }
        } catch {
            update(field) { $0.isResolving = false }
            status = .failed("Couldn't load that place. Check your connection and try again.")
        }
        // A session ends with a details request (Places billing best practice).
        sessionToken = UUID().uuidString
    }

    /// Fills `field` with the device's position (asking for permission first if needed).
    public func useCurrentLocation(for field: Field) async {
        let location = dependencies.location
        if location.authorization != .authorized {
            guard await location.requestAuthorization() == .authorized else {
                status = .failed("Allow location access in Settings to start from your current location.")
                return
            }
        }
        update(field) { $0.isResolving = true }
        let coordinate = await location.requestLocation()
        update(field) { $0.isResolving = false }
        guard let coordinate else {
            status = .failed("Couldn't find your location. Check that Location Services is on, then try again.")
            return
        }
        if case .failed = status { status = .idle }
        let place = Place(
            id: "current-location",
            name: "Current Location",
            coordinate: coordinate,
            utcOffsetMinutes: PlanTripViewModel.utcOffsetSeconds(
                at: coordinate, phoneTimeZone: dependencies.timeZone, date: dependencies.now()
            ) / 60
        )
        update(field) {
            $0.place = place
            $0.text = place.name
            $0.suggestions = []
        }
        if field == .origin { refreshDefaultDeparture(for: place) }
    }

    /// Re-evaluates the suggested departure in the start's time zone (unless the user picked one).
    private func refreshDefaultDeparture(for origin: Place) {
        guard !departureEditedByUser else { return }
        isApplyingDefaultDeparture = true
        defer { isApplyingDefaultDeparture = false }
        departure = PlanTripViewModel.defaultDeparture(
            now: dependencies.now(), utcOffsetSeconds: origin.utcOffsetSeconds, policy: dependencies.preferences.load().policy
        )
    }

    public func swapLocations() {
        swap(&origin, &destination)
    }

    // MARK: Validation

    /// The request the form describes, or the problems preventing it.
    public func makeRequest() -> Validation {
        var errors: [TripRequestError] = []
        if origin.place == nil { errors.append(.invalidOrigin) }
        if destination.place == nil { errors.append(.invalidDestination) }
        let mpg = PlanTripViewModel.parse(mpgText) ?? -1
        let tank = PlanTripViewModel.parse(tankGallonsText) ?? Vehicle.defaultTankCapacityGallons
        var policy = dependencies.preferences.load().policy
        policy.maxContinuousDriving = customRestEnabled ? restIntervalHours * 3_600 : DrivingPolicy.standard.maxContinuousDriving
        policy.maxDailyDriving = max(policy.maxContinuousDriving, maxDailyDrivingHours * 3_600)
        policy.fuelReserveFraction = minimumFuelPercent / 100
        guard let origin = origin.place, let destination = destination.place else { return .invalid(errors) }
        let request = TripRequest(
            origin: origin,
            destination: destination,
            departure: departure,
            arriveBy: arriveByEnabled ? arriveBy : nil,
            vehicle: Vehicle(
                milesPerGallon: mpg,
                tankCapacityGallons: tank,
                initialFuelFraction: startingFuelPercent / 100,
                fuelType: fuelType
            ),
            policy: policy,
            goal: goal,
            travelers: travelers
        )
        errors += request.validationErrors()
        return errors.isEmpty ? .valid(request) : .invalid(errors)
    }

    public var validationErrors: [TripRequestError] {
        if case let .invalid(errors) = makeRequest() { return errors }
        return []
    }

    public var canPlan: Bool {
        if case .planning = status { return false }
        return validationErrors.isEmpty
    }

    public var isPlanning: Bool {
        if case .planning = status { return true }
        return false
    }

    public var progressText: String? {
        guard case let .planning(phase) = status else { return nil }
        return phase?.displayText ?? "Getting started…"
    }

    public var progressFraction: Double {
        guard case let .planning(phase) = status else { return 0 }
        return phase?.fraction ?? 0.02
    }

    /// "A full tank goes about 392 mi. Fuel stops keep at least 15% (2.1 gal) in the tank."
    public var rangeSummary: String? {
        guard let mpg = PlanTripViewModel.parse(mpgText), mpg > 0,
              let tank = PlanTripViewModel.parse(tankGallonsText), tank > 0 else { return nil }
        let formatters = dependencies.formatters
        let range = formatters.distance(Units.meters(fromMiles: mpg * tank))
        let minimum = formatters.gallons(tank * minimumFuelPercent / 100)
        return "A full tank goes about \(range). Fuel stops keep at least \(Int(minimumFuelPercent))% (\(minimum)) in the tank."
    }

    public var errorMessage: String? {
        if case let .failed(message) = status { return message }
        return nil
    }

    // MARK: Planning

    /// Starts planning in a cancellable task.
    public func startPlanning() {
        planTask?.cancel()
        planTask = Task { [weak self] in await self?.plan() }
    }

    public func cancelPlanning() {
        planTask?.cancel()
        planTask = nil
        status = .idle
    }

    public func plan() async {
        switch makeRequest() {
        case let .invalid(errors):
            status = .failed(errors.map(\.message).joined(separator: "\n"))
        case let .valid(request):
            status = .planning(nil)
            rememberPreferences(from: request)
            do {
                let result = try await dependencies.planner.plan(request) { [weak self] phase in
                    Task { @MainActor in self?.report(phase) }
                }
                try Task.checkCancellation()
                self.result = result
                status = .idle
            } catch is CancellationError {
                status = .idle
            } catch let error as PlanningError {
                status = .failed(error.message)
            } catch {
                status = .failed("Something went wrong while planning. Please try again.")
            }
        }
    }

    public func clearResult() {
        result = nil
    }

    public func dismissError() {
        if case .failed = status { status = .idle }
    }

    private func report(_ phase: PlanningPhase) {
        guard case .planning = status else { return }
        status = .planning(phase)
    }

    private func rememberPreferences(from request: TripRequest) {
        var preferences = dependencies.preferences.load()
        preferences.vehicle.milesPerGallon = request.vehicle.milesPerGallon
        preferences.vehicle.tankCapacityGallons = request.vehicle.tankCapacityGallons
        preferences.vehicle.fuelType = request.vehicle.fuelType
        preferences.goal = request.goal
        preferences.travelers = request.travelers
        preferences.policy.maxContinuousDriving = request.policy.maxContinuousDriving
        preferences.policy.maxDailyDriving = request.policy.maxDailyDriving
        preferences.policy.fuelReserveFraction = request.policy.fuelReserveFraction
        dependencies.preferences.save(preferences)
    }

    // MARK: Helpers

    /// The phone's UTC offset, unless it is clearly not the location's (more than 2 h from the
    /// longitude-based estimate — e.g. a simulator or a phone still on another time zone); then the
    /// estimate. Day windows ("stop by 9 PM") must use the location's local time.
    static func utcOffsetSeconds(at coordinate: GeoCoordinate, phoneTimeZone: TimeZone, date: Date) -> Int {
        let phone = phoneTimeZone.secondsFromGMT(for: date)
        let estimate = Place.estimatedUTCOffsetSeconds(for: coordinate)
        return abs(phone - estimate) <= 2 * 3_600 ? phone : estimate
    }

    static func parse(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// The next quarter hour, unless that is outside the driving day at the start (late evening
    /// or night): then the start of the next driving day, e.g. 8:00 AM.
    static func defaultDeparture(now: Date, utcOffsetSeconds: Int, policy: DrivingPolicy) -> Date {
        let candidate = nextQuarterHour(after: now)
        let local = candidate.timeIntervalSince1970 + Double(utcOffsetSeconds)
        let midnight = floor(local / 86_400) * 86_400
        let timeOfDay = local - midnight
        let latestStart = policy.dayEnd.secondsFromMidnight - 3_600
        if timeOfDay >= policy.dayStart.secondsFromMidnight && timeOfDay <= latestStart { return candidate }
        let nextDayStart = timeOfDay < policy.dayStart.secondsFromMidnight
            ? midnight + policy.dayStart.secondsFromMidnight
            : midnight + 86_400 + policy.dayStart.secondsFromMidnight
        return Date(timeIntervalSince1970: nextDayStart - Double(utcOffsetSeconds))
    }

    static func nextQuarterHour(after date: Date) -> Date {
        let quarter: TimeInterval = 900
        return Date(timeIntervalSince1970: (date.timeIntervalSince1970 / quarter).rounded(.up) * quarter)
    }
}
