@testable import Waystage
import MapKit
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

    private static let stopInfo = DriveViewModel.NextStopInfo(
        kind: .fuel, isPullOff: false, name: "Love's #4", kindTitle: "Fuel stop", symbolName: "fuelpump.fill",
        etaText: "4:24 PM", remainingText: "72 mi", durationText: "1 h 12 min",
        plannedAction: "Arrive with 21% · Fill about 11.1 gal", isDestination: false
    )

    @Test("A framed route fills about 80 % of the area clear of the chrome, centred in it")
    func framing() throws {
        let leg = [GeoCoordinate(latitude: 36.0, longitude: -115.0), GeoCoordinate(latitude: 36.5, longitude: -114.5)]
        let size = CGSize(width: 400, height: 800)
        let chrome = UIEdgeInsets(top: 150, left: 20, bottom: 330, right: 60)
        let rect = try #require(MapCameraDirector.framingRect(for: leg, in: size, insets: chrome))
        // Map points → screen points of this view.
        let scale = rect.width / size.width
        #expect(abs(rect.height / size.height - scale) < 1e-9, "same aspect ratio as the view: shown exactly")
        let a = MKMapPoint(leg[0].clCoordinate), b = MKMapPoint(leg[1].clCoordinate)
        let screen = { (point: MKMapPoint) in CGPoint(x: (point.x - rect.minX) / scale, y: (point.y - rect.minY) / scale) }
        let (pa, pb) = (screen(a), screen(b))
        let visible = CGRect(x: 20, y: 150, width: 400 - 80, height: 800 - 480)
        #expect(visible.contains(pa) && visible.contains(pb), "clear of the header and the sheet")
        let boxWidth = abs(pb.x - pa.x), boxHeight = abs(pb.y - pa.y)
        #expect(abs(max(boxWidth / visible.width, boxHeight / visible.height) - 0.8) < 0.001, "fills 80 % of the tighter side")
        #expect(abs((pa.x + pb.x) / 2 - visible.midX) < 0.5 && abs((pa.y + pb.y) / 2 - visible.midY) < 0.5, "centred")
        let tiny = try #require(MapCameraDirector.framingRect(for: [leg[0]], in: size, insets: .zero))
        #expect(tiny.width > 1_000 * MKMapPointsPerMeterAtLatitude(36), "a single point still shows ~1 km around it")
        #expect(MapCameraDirector.framingRect(for: [], in: size, insets: .zero) == nil)
        #expect(MapCameraDirector.framingRect(for: leg, in: .zero, insets: .zero) == nil, "no size yet: nothing to frame")
    }

    @Test("Camera moves: placed once, flights for framing and to the car, then glides between fixes")
    func cameraMotion() {
        let car = GeoCoordinate(latitude: 36, longitude: -115)
        let frame = TripMapView.Camera.frame([car])
        let follow = TripMapView.Camera.follow(car, course: 90)
        typealias Director = MapCameraDirector
        #expect(Director.motion(from: nil, to: frame, sinceLastFix: 0, isFlyingIn: false) == .immediate)
        #expect(Director.motion(from: nil, to: .free, sinceLastFix: 0, isFlyingIn: false) == nil)
        #expect(Director.motion(from: .overview, to: frame, sinceLastFix: 0, isFlyingIn: false) == .flight(.frame),
                "the whole trip → the leg keeps the leg in view")
        #expect(Director.motion(from: frame, to: follow, sinceLastFix: 9, isFlyingIn: false) == .flight(.anchored(car)),
                "the leg → the car keeps the car in view")
        #expect(Director.motion(from: .free, to: follow, sinceLastFix: 9, isFlyingIn: false) == .flight(.anchored(car)))
        #expect(Director.motion(from: follow, to: follow, sinceLastFix: 0.5, isFlyingIn: true) == nil, "a flight isn't cut short")
        #expect(Director.motion(from: follow, to: follow, sinceLastFix: 0.5, isFlyingIn: false) == .linear(0.5 * Director.glideShare),
                "a glide ends before the next fix is due")
        #expect(Director.motion(from: follow, to: follow, sinceLastFix: 30, isFlyingIn: false) == .linear(Director.maximumGlide * Director.glideShare))
        #expect(Director.motion(from: follow, to: follow, sinceLastFix: 0.5, isFlyingIn: false, lag: 5_000) == .immediate,
                "a camera far behind the car jumps to it")
        #expect(Director.motion(from: follow, to: follow, sinceLastFix: 0.5, isFlyingIn: false, lag: 50) == .linear(0.5 * Director.glideShare))
        #expect(Director.motion(from: follow, to: .free, sinceLastFix: 1, isFlyingIn: false) == nil, "the user's view is kept")
        #expect(Director.motion(from: follow, to: frame, sinceLastFix: 1, isFlyingIn: false) == .flight(.frame))
    }

    @Test("Route tags draw the chosen route's on top")
    func badgeOrder() {
        let place = GeoCoordinate(latitude: 36, longitude: -115)
        let badges = ["a", "b", "c"].map {
            MapRouteBadge(id: $0, coordinate: place, text: "1 h", accessibilityLabel: $0, isSelected: $0 == "a", isBest: $0 == "a")
        }
        #expect(MapRouteBadge.drawingOrder(badges).map(\.id) == ["b", "c", "a"])
    }

    @Test("The follow camera looks ahead of the car along its heading")
    func lookAhead() {
        let car = GeoCoordinate(latitude: 36, longitude: -115)
        let center = MapCameraDirector.followCenter(car: car, heading: 90)
        #expect(abs(GeoMath.distance(car, center) - MapCameraDirector.followLookAhead) < 1)
        #expect(center.longitude > car.longitude, "east of the car when heading east")
    }

    @Test("Google fit insets are the chrome plus the 80 % margin")
    func fitInsets() {
        let insets = MapCameraDirector.fitInsets(
            in: CGSize(width: 400, height: 800), chrome: UIEdgeInsets(top: 100, left: 0, bottom: 300, right: 0)
        )
        #expect(abs(insets.top - (100 + 400 * 0.1)) < 1e-9)
        #expect(abs(insets.bottom - (300 + 400 * 0.1)) < 1e-9)
        #expect(abs(insets.left - 400 * 0.1) < 1e-9)
    }

    @Test("The legend layout wraps onto new lines when narrow")
    func flowLayoutWraps() throws {
        let items = ForEach(0..<6) { _ in Color.red.frame(width: 100, height: 20) }
        let narrow = ImageRenderer(content: FlowLayout(spacing: 10, lineSpacing: 5) { items }.frame(width: 230))
        let wide = ImageRenderer(content: FlowLayout(spacing: 10, lineSpacing: 5) { items }.frame(width: 700))
        narrow.scale = 1
        wide.scale = 1
        // 2 per line at 230 pt → 3 lines (20 + 5 + 20 + 5 + 20); all 6 fit on one line at 700 pt.
        #expect(narrow.uiImage?.size.height == 70)
        #expect(wide.uiImage?.size.height == 20)
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
            AnyView(TripRibbonView(
                marks: [
                    RibbonMark(id: "a", fraction: 0, kind: .origin, isPullOff: false),
                    RibbonMark(id: "b", fraction: 0.4, kind: .fuel, isPullOff: false),
                    RibbonMark(id: "c", fraction: 1, kind: .destination, isPullOff: false),
                ],
                progress: 0.5
            )),
            AnyView(RouteRail().frame(height: 100)),
            AnyView(NumberTile(title: "Fuel economy", unit: "mpg", text: .constant("28"), identifier: "test")),
            AnyView(ChoiceTile(systemImage: "hare.fill", title: "Fastest", subtitle: "Arrive earliest", isSelected: true) {}),
            AnyView(FuelGauge(reserveFraction: 0.15)),
            AnyView(RhythmStrip(intervalHours: 2.5)),
            AnyView(MapControlButton(systemImage: "plus", label: "Zoom in") {}),
            AnyView(DecorativeRoute().frame(width: 170, height: 110)),
            AnyView(SectionLabel(title: "Your car")),
            AnyView(BottomActionBar { Button("Start driving") {}.buttonStyle(.primary) }),
            AnyView(MetricView(value: "2,631 mi", label: "Distance")),
            AnyView(WarningList(warnings: [PlanWarning(code: .estimatedPrices, message: "Some prices are estimates.")])),
            AnyView(ManeuverBannerView(
                banner: DriveViewModel.Banner(symbolName: "arrow.up.right", distanceText: "0.5 mi", instruction: "Take the ramp onto I-15 N"),
                isRerouting: false
            )),
            AnyView(ManeuverBannerView(
                banner: DriveViewModel.Banner(
                    symbolName: "arrow.turn.up.left", distanceText: "500 ft", instruction: "Turn left onto Main St",
                    thenSymbolName: "arrow.turn.up.right"
                ),
                isRerouting: false
            )),
            AnyView(PreviewHeader(destination: Self.stopInfo)),
            AnyView(PreviewSheet(info: Self.stopInfo, onExit: {}, onStart: {}) { Button("End trip") {} }),
            AnyView(NextStopPanel(
                info: Self.stopInfo, canContinue: true, ribbon: [], progress: 0.3, onExit: {}, onContinue: {}
            ) { Button("End trip") {} }),
            AnyView(ArrivalCard(info: Self.stopInfo, nextStopName: "Motel 6", onExit: {}, onContinue: {}) { Button("End trip") {} }),
            AnyView(ExitNavigationButton {}),
            AnyView(UserLocationDot()),
            AnyView(PreviewSheet(
                info: Self.stopInfo, headline: "Head to the start of your trip", startTitle: "Directions to start",
                onExit: {}, onStart: {}
            ) { Button("Start the trip from here") {} }),
            AnyView(StatusPill(message: "Finding the route…", systemImage: "location.magnifyingglass")),
            AnyView(CompletedCard(destination: "Las Vegas", summary: "270 mi") {}),
            AnyView(SafetyNoticeView {}),
            AnyView(RouteChoiceRow(choice: RouteChoice(
                id: "route-1", title: "via Salt Lake City", durationText: "1 d 4 h", distanceText: "1,270 mi",
                isBest: true, isSelected: true, labelCoordinate: GeoCoordinate(latitude: 40.8, longitude: -111.9)
            )) {}),
            AnyView(RouteBadgeLabel(text: "1 d 4 h", isSelected: true, isBest: true)),
            AnyView(RouteBadgeLabel(text: "1 d 6 h", isSelected: false, isBest: false)),
            AnyView(LaunchIntroView {}.frame(height: 844)),
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
