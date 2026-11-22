import SwiftUI
import TripModels

/// A route's travel-time tag on the map ("1 d 4 h"). Tapping it chooses the route.
struct MapRouteBadge: Equatable, Identifiable {
    let id: String
    /// On the route, clear of its stops and of the other routes; the tag stands above it.
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
///
/// It is a callout standing above its point with a small pointer down to the route, so the route
/// line and the stops along it stay visible. Maps anchor it at the bottom centre.
struct RouteBadgeLabel: View {
    let text: String
    let isSelected: Bool
    let isBest: Bool

    /// The pointer's size, and the transparent margin kept for the shadow.
    static let pointerHeight: CGFloat = 6
    static let pointerWidth: CGFloat = 12
    static let shadowMargin: CGFloat = 4

    var body: some View {
        HStack(spacing: 4) {
            if isBest {
                Image(systemName: "star.fill")
                    .font(.system(size: 9, weight: .heavy))
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.system(size: 13, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(isSelected ? Color.white : Theme.routeCasing)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .padding(.bottom, Self.pointerHeight)
        .background(callout.fill(isSelected ? Theme.routeLine : Theme.card))
        .overlay(callout.stroke(isSelected ? Color.white.opacity(0.9) : Theme.routeLine.opacity(0.45), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
        // Room for the shadow when rendered to an image.
        .padding(Self.shadowMargin)
    }

    private var callout: CalloutShape {
        CalloutShape(pointerWidth: Self.pointerWidth, pointerHeight: Self.pointerHeight)
    }

    /// Where the pointer's tip is in a rendered tag of `size`, as a unit point (for map anchors).
    static func tipAnchor(in size: CGSize) -> CGPoint {
        CGPoint(x: 0.5, y: size.height > 0 ? (size.height - shadowMargin) / size.height : 1)
    }
}

/// A capsule with a small pointer at the bottom centre.
struct CalloutShape: Shape {
    var pointerWidth: CGFloat
    var pointerHeight: CGFloat

    func path(in rect: CGRect) -> Path {
        let bubble = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(0, rect.height - pointerHeight))
        // Small corners, like the app's other boxes.
        let radius = min(4, min(bubble.height, bubble.width) / 2)
        var path = Path()
        path.move(to: CGPoint(x: bubble.minX + radius, y: bubble.minY))
        path.addLine(to: CGPoint(x: bubble.maxX - radius, y: bubble.minY))
        path.addArc(tangent1End: CGPoint(x: bubble.maxX, y: bubble.minY), tangent2End: CGPoint(x: bubble.maxX, y: bubble.midY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: bubble.maxX, y: bubble.maxY), tangent2End: CGPoint(x: bubble.maxX - radius, y: bubble.maxY), radius: radius)
        path.addLine(to: CGPoint(x: bubble.midX + pointerWidth / 2, y: bubble.maxY))
        path.addLine(to: CGPoint(x: bubble.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: bubble.midX - pointerWidth / 2, y: bubble.maxY))
        path.addLine(to: CGPoint(x: bubble.minX + radius, y: bubble.maxY))
        path.addArc(tangent1End: CGPoint(x: bubble.minX, y: bubble.maxY), tangent2End: CGPoint(x: bubble.minX, y: bubble.midY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: bubble.minX, y: bubble.minY), tangent2End: CGPoint(x: bubble.minX + radius, y: bubble.minY), radius: radius)
        path.closeSubpath()
        return path
    }
}

extension MapRouteBadge {
    /// The selected route's tag last, so it draws on top.
    static func drawingOrder(_ badges: [MapRouteBadge]) -> [MapRouteBadge] {
        badges.filter { !$0.isSelected } + badges.filter(\.isSelected)
    }
}
