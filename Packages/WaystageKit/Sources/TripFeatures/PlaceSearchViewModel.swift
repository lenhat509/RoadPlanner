import Foundation
import Observation
import TripModels
import TripPlanner

/// Finding one place to stop at (adding a stop to a plan), with how long to stay: the same place
/// search as the plan form.
@MainActor
@Observable
public final class PlaceSearchViewModel {
    public private(set) var text = ""
    public private(set) var suggestions: [PlaceSuggestion] = []
    public private(set) var place: Place?
    public private(set) var isResolving = false
    public private(set) var errorMessage: String?
    public private(set) var stayMinutes: Double = 60

    /// Sets the stay, within 5 min to 12 h.
    public func setStay(_ minutes: Double) {
        stayMinutes = min(max(minutes, PlanTripViewModel.stayRange.lowerBound), PlanTripViewModel.stayRange.upperBound)
    }

    private let dependencies: AppDependencies
    private var searchTask: Task<Void, Never>?
    private var sessionToken = UUID().uuidString

    public init(dependencies: AppDependencies) {
        self.dependencies = dependencies
    }

    public var stayText: String { dependencies.formatters.duration(stayMinutes * 60) }

    public var stay: TimeInterval { stayMinutes * 60 }

    /// Called as the user types; fetches suggestions after a short pause.
    public func queryChanged(_ newText: String) {
        guard newText != text else { return }
        text = newText
        if place?.name != newText { place = nil }
        searchTask?.cancel()
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, place == nil else {
            suggestions = []
            return
        }
        let debounce = dependencies.autocompleteDebounce
        let autocomplete = dependencies.autocomplete
        let bias = dependencies.location.lastKnownLocation
        let token = sessionToken
        searchTask = Task { [weak self] in
            if debounce > 0 { try? await Task.sleep(nanoseconds: UInt64(debounce * 1e9)) }
            guard !Task.isCancelled else { return }
            let found = (try? await autocomplete.suggestions(for: trimmed, near: bias, sessionToken: token)) ?? []
            guard !Task.isCancelled, let self, self.place == nil,
                  self.text.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
            self.suggestions = found
        }
    }

    /// Waits for a pending search (tests).
    public func waitForSuggestions() async { await searchTask?.value }

    public func select(_ suggestion: PlaceSuggestion) async {
        searchTask?.cancel()
        searchTask = nil
        text = suggestion.primaryText
        suggestions = []
        isResolving = true
        defer { isResolving = false }
        do {
            let chosen = try await dependencies.autocomplete.place(for: suggestion.placeID, sessionToken: sessionToken)
            place = chosen
            text = chosen.name
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load that place. Check your connection and try again."
        }
        // A session ends with a details request (Places billing best practice).
        sessionToken = UUID().uuidString
    }
}
