import SwiftUI
import TripModels

/// A route's travel-time tag on the map ("1 d 4 h"). Tapping it chooses the route.
struct MapRouteBadge: Equatable, Identifiable {
    let id: String
    /// On the route, where it is farthest from the other routes.
    let coordinate: GeoCoordinate
    let text: String
    /// What VoiceOver reads: the route's name and travel time.
    let accessibilityLabel: String
    let isSelected: Bool
    /// The best of several routes (marked with a star).
    let isBest: Bool
}

/// The tag's look, shared by the Apple map (a view) and the Google map (rendered to a marker
/// image): the selected route's tag is filled with the route colour, the others are white.
struct RouteBadgeLabel: View {
    let text: String
    let isSelected: Bool
    let isBest: Bool

    var body: some View {
        HStack(spacing: 4) {
            if isBest {
                Image(systemName: "star.fill")
                    .font(.system(size: 9, weight: .heavy))
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(isSelected ? Color.white : Theme.routeCasing)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(isSelected ? Theme.routeLine : Theme.card))
        .overlay(Capsule().strokeBorder(isSelected ? Color.white.opacity(0.9) : Theme.routeLine.opacity(0.45), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
        // Room for the shadow when rendered to an image.
        .padding(4)
    }
}

extension MapRouteBadge {
    /// The selected route's tag last, so it draws on top.
    static func drawingOrder(_ badges: [MapRouteBadge]) -> [MapRouteBadge] {
        badges.filter { !$0.isSelected } + badges.filter(\.isSelected)
    }
}
