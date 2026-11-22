import SwiftUI
import TripModels

/// The whole route of a plan, the same wherever a plan is previewed: the plan screen, the trip in
/// progress (from Home) and Adjust visits. It draws the route (and other routes found, grey), the
/// stops with visits numbered, the routes' travel-time labels, and buttons to expand it to full
/// screen, zoom, and show the whole route again.
///
/// Collapsed, it is `collapsedHeight` tall (a third of the screen); expanded, it takes the space the
/// screen gives it (the screen hides its other content).
struct WholeRouteMap: View {
    let paths: [[GeoCoordinate]]
    let markers: [MapStopMarker]
    var badges: [MapRouteBadge] = []
    var onSelectBadge: ((String) -> Void)?
    var userLocation: GeoCoordinate?
    @Binding var isExpanded: Bool
    let collapsedHeight: CGFloat
    @State private var command: MapCommand?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RouteMap(
                paths: paths,
                markers: markers,
                chrome: UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 64),
                userLocation: userLocation,
                command: command,
                badges: badges,
                onSelectBadge: onSelectBadge,
                secondaryStyle: .alternatives
            )
            VStack(spacing: Theme.Spacing.xs) {
                MapControlButton(
                    systemImage: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    label: isExpanded ? "Collapse map" : "Expand map",
                    action: toggleExpanded
                )
                MapControlButton(systemImage: "plus", label: "Zoom in") { command = MapCommand(action: .zoomIn) }
                MapControlButton(systemImage: "minus", label: "Zoom out") { command = MapCommand(action: .zoomOut) }
                MapControlButton(systemImage: "scope", label: "Show the whole route") { command = MapCommand(action: .fitRoute) }
            }
            .padding(Theme.Spacing.s)
        }
        .frame(maxHeight: isExpanded ? .infinity : collapsedHeight)
    }

    private func toggleExpanded() {
        withAnimation(.snappy) { isExpanded.toggle() }
        // Re-frame the route once the map has its new size.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            command = MapCommand(action: .fitRoute)
        }
    }

    /// A third of the screen's height (the map's collapsed height).
    static func collapsedHeight(in size: CGSize) -> CGFloat { max(200, size.height / 3) }
}
