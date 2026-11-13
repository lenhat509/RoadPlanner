@testable import Cadence
import SwiftUI
import Testing
import TripFeatures
import TripModels
import TripPlanner
import TripSandbox
import UIKit

@MainActor
@Suite("Design system and components")
struct DesignSystemTests {
    @Test("Every stop kind has a distinct colour and icon")
    func stopStyles() {
        let colors = StopKind.allCases.map { UIColor(Theme.color(for: $0)).cgColor.components ?? [] }
        #expect(Set(colors.map { $0.map { ($0 * 100).rounded() } }).count == StopKind.allCases.count)
        let symbols = StopKind.allCases.map(StopPresentation.symbolName(for:))
        #expect(Set(symbols).count == symbols.count)
        #expect(symbols.allSatisfy { UIImage(systemName: $0) != nil })
    }

    @Test("Legend lists each stop type present, in trip order, once")
    func legend() async throws {
        let itinerary = try #require(try await SandboxEnvironment.samplePlan().recommended)
        let entries = StopLegend.entries(for: itinerary.stops)
        #expect(entries.first?.kind == .origin)
        #expect(entries.last?.kind == .destination)
        #expect(Set(entries).count == entries.count)
        #expect(Set(entries.map(\.kind)) == Set(itinerary.stops.map(\.kind)))
        #expect(StopLegend.Entry(kind: .rest, isPullOff: true).id != StopLegend.Entry(kind: .rest, isPullOff: false).id)
        #expect(Theme.legendTitle(for: .lodging) == "Overnight stay")
    }

    @Test("Map marker icons render at the expected size and are cached")
    func markerIcons() {
        let active = MarkerIconFactory.icon(for: .fuel, isPullOff: false, isActive: true)
        let inactive = MarkerIconFactory.icon(for: .fuel, isPullOff: false, isActive: false)
        #expect(active.size == CGSize(width: 26, height: 26))
        #expect(inactive.size == CGSize(width: 20, height: 20))
        #expect(MarkerIconFactory.icon(for: .fuel, isPullOff: false, isActive: true) === active)
    }

    @Test("Maneuver symbols exist in SF Symbols")
    func maneuverSymbols() {
        for maneuver in Maneuver.allCases {
            #expect(UIImage(systemName: maneuver.symbolName) != nil, "\(maneuver)")
        }
    }

    @Test("Hours are written naturally")
    func hoursText() {
        #expect(PlanTripScreen.hoursText(2.5) == "2 h 30 min")
        #expect(PlanTripScreen.hoursText(3) == "3 h")
        #expect(PlanTripScreen.hoursText(0.75) == "45 min")
    }

    @Test("Components render without layout errors")
    func componentsRender() throws {
        let option = PlanOption(
            goal: .fastest, title: "Fastest", durationText: "4 h 10 min", costText: "$61",
            nightsText: "0 nights", arrivalText: "Arrive 12:10 PM", isRecommended: true, badges: ["Fastest"]
        )
        let views: [AnyView] = [
            AnyView(PlanOptionCard(option: option, isSelected: true) {}),
            AnyView(StopDot(kind: .lodging)),
            AnyView(StopLegend(entries: [.init(kind: .origin, isPullOff: false), .init(kind: .rest, isPullOff: true)])),
            AnyView(VehicleArrow(rotation: 45)),
            AnyView(MetricView(value: "2,631 mi", label: "Distance")),
            AnyView(WarningList(warnings: [PlanWarning(code: .estimatedPrices, message: "Some prices are estimates.")])),
            AnyView(ManeuverBannerView(
                banner: DriveViewModel.Banner(symbolName: "arrow.up.right", distanceText: "0.5 mi", instruction: "Take the ramp onto I-15 N"),
                isRerouting: false
            )),
            AnyView(CompletedCard(destination: "Las Vegas", summary: "270 mi") {}),
            AnyView(SafetyNoticeView {}),
        ]
        for view in views {
            let renderer = ImageRenderer(content: view.frame(width: 390))
            renderer.scale = 1
            #expect(renderer.uiImage != nil)
        }
    }

    @Test("Map content converts itineraries to paths and markers")
    func mapContent() async throws {
        let plan = try await SandboxEnvironment.samplePlan()
        let itinerary = try #require(plan.recommended)
        let paths = MapContent.paths(for: itinerary)
        #expect(paths.count == 1)
        #expect((paths.first?.count ?? 0) > 10)
        let markers = MapContent.markers(for: itinerary.stops, activeID: itinerary.stops[1].id)
        #expect(markers.count == itinerary.stops.count)
        #expect(markers.filter(\.isActive).count == 1)
    }
}
