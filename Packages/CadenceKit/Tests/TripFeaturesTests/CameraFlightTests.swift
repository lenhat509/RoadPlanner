import Foundation
import Testing
@testable import TripFeatures
import TripModels

@Suite("CameraFlight")
struct CameraFlightTests {
    typealias Camera = CameraFlight.Camera

    /// Half the screen, in screen units (a phone is about twice as tall as it is wide).
    private let halfWidth = 0.5, halfHeight = 1.0

    /// How much of the screen `points` need from `camera`'s centre: ≤ 1 means all are on screen.
    private func screenUse(_ points: [GeoCoordinate], from camera: Camera) -> Double {
        points.map { point in
            let offset = CameraFlight.screenOffset(of: point, from: camera.center, heading: camera.heading, scale: camera.scale)
            return max(abs(offset.x) / halfWidth, abs(offset.y) / halfHeight)
        }.max() ?? 0
    }

    /// A north-up camera framing `points` so they use `fill` of the screen.
    private func framing(_ points: [GeoCoordinate], fill: Double) -> Camera {
        let center = GeoCoordinate(
            latitude: (points.map(\.latitude).min()! + points.map(\.latitude).max()!) / 2,
            longitude: (points.map(\.longitude).min()! + points.map(\.longitude).max()!) / 2
        )
        let unit = Camera(center: center, scale: 1)
        return Camera(center: center, scale: screenUse(points, from: unit) / fill)
    }

    private func line(_ a: GeoCoordinate, _ b: GeoCoordinate, count: Int = 20) -> [GeoCoordinate] {
        (0...count).map { step in
            let share = Double(step) / Double(count)
            return GeoCoordinate(latitude: a.latitude + (b.latitude - a.latitude) * share,
                                 longitude: a.longitude + (b.longitude - a.longitude) * share)
        }
    }

    private let losAngeles = GeoCoordinate(latitude: 34.05, longitude: -118.24)
    private let lasVegas = GeoCoordinate(latitude: 36.17, longitude: -115.14)
    private let newYork = GeoCoordinate(latitude: 40.71, longitude: -74.01)

    @Test("A flight starts at the view on screen and ends at the target")
    func ends() {
        let start = Camera(center: losAngeles, scale: 900_000, heading: 0, pitch: 0)
        let end = Camera(center: lasVegas, scale: 1_500, heading: 70, pitch: 45)
        for kind in [CameraFlight.Kind.frame, .anchored(losAngeles)] {
            let flight = CameraFlight(from: start, to: end, kind: kind)
            #expect(flight.camera(at: 0) == start)
            let last = flight.camera(at: 1)
            #expect(GeoMath.distance(last.center, end.center) < 1)
            #expect(abs(last.scale - end.scale) < 1e-6)
            #expect(abs(last.heading - end.heading) < 1e-9)
            #expect(abs(last.pitch - end.pitch) < 1e-9)
        }
    }

    @Test("Zooming from the whole trip into a leg keeps the whole leg on screen throughout")
    func frameKeepsTheLegInView() {
        let trip = line(losAngeles, lasVegas) + line(lasVegas, newYork)
        let leg = line(losAngeles, lasVegas)
        let whole = framing(trip, fill: 0.9)
        let legView = framing(leg, fill: 0.8)
        #expect(screenUse(leg, from: whole) < 1 && screenUse(leg, from: legView) < 1)

        let flight = CameraFlight(from: whole, to: legView, kind: .frame)
        let worst = flight.samples(count: 200).map { screenUse(leg, from: $0) }.max() ?? .infinity
        #expect(worst <= 1, "the leg needs \(worst) of the screen at some point")
        #expect(flight.samples(count: 50).allSatisfy { $0.heading == 0 }, "north stays up")

        // Moving the centre and zooming independently (what a plain animation does) loses it.
        let naiveWorst = (0...200).map { step -> Double in
            let time = Double(step) / 200, eased = time * time * (3 - 2 * time)
            let camera = Camera(
                center: GeoCoordinate(latitude: whole.center.latitude + (legView.center.latitude - whole.center.latitude) * eased,
                                      longitude: whole.center.longitude + (legView.center.longitude - whole.center.longitude) * eased),
                scale: whole.scale * pow(legView.scale / whole.scale, eased)
            )
            return screenUse(leg, from: camera)
        }.max() ?? 0
        #expect(naiveWorst > 1, "the test would catch a flight that loses the leg (\(naiveWorst))")
    }

    @Test("Going from the leg down to the car keeps the car on screen while the map turns and tilts")
    func anchoredKeepsTheCarInView() {
        let car = GeoCoordinate(latitude: 34.06, longitude: -118.25)
        let legView = framing(line(car, lasVegas), fill: 0.8)
        let follow = Camera(
            center: GeoMath.destination(from: car, bearing: 50, distance: 230), scale: 1_500, heading: 50, pitch: 45
        )
        let flight = CameraFlight(from: legView, to: follow, kind: .anchored(car))
        let first = CameraFlight.screenOffset(of: car, from: legView.center, heading: legView.heading, scale: legView.scale)
        let last = CameraFlight.screenOffset(of: car, from: follow.center, heading: follow.heading, scale: follow.scale)
        for camera in flight.samples(count: 200) {
            // The car's place on screen stays on the straight line between where it starts and ends.
            let offset = CameraFlight.screenOffset(of: car, from: camera.center, heading: camera.heading, scale: camera.scale)
            #expect(offset.x >= min(first.x, last.x) - 1e-3 && offset.x <= max(first.x, last.x) + 1e-3)
            #expect(offset.y >= min(first.y, last.y) - 1e-3 && offset.y <= max(first.y, last.y) + 1e-3)
            #expect(screenUse([car], from: camera) < 1)
        }

        // Moving the centre straight from the leg's middle to the car (a plain animation) zooms
        // in over empty desert first.
        let middle = flight.camera(at: 0.5)
        let naive = Camera(
            center: GeoCoordinate(latitude: (legView.center.latitude + follow.center.latitude) / 2,
                                  longitude: (legView.center.longitude + follow.center.longitude) / 2),
            scale: middle.scale, heading: middle.heading
        )
        #expect(screenUse([car], from: naive) > 1, "the test would catch a flight that loses the car")
    }

    @Test("Headings turn the short way round")
    func shortTurn() {
        #expect(CameraFlight.turn(from: 350, to: 10) == 20)
        #expect(CameraFlight.turn(from: 10, to: 350) == -20)
        #expect(CameraFlight.turn(from: 0, to: 180) == 180)
        let start = Camera(center: losAngeles, scale: 1_000, heading: 350)
        let end = Camera(center: losAngeles, scale: 1_000, heading: 10)
        let middle = CameraFlight(from: start, to: end, kind: .anchored(losAngeles)).camera(at: 0.5).heading
        #expect(abs(middle - 360) < 1e-9, "through north, not south (\(middle))")
    }

    @Test("Screen offsets convert to ground points and back")
    func screenRoundTrip() {
        let point = GeoMath.destination(from: losAngeles, bearing: 120, distance: 4_000)
        let offset = CameraFlight.screenOffset(of: point, from: losAngeles, heading: 30, scale: 10)
        #expect(abs(offset.x - 4_000 * sin(90 * Double.pi / 180) / 10) < 0.5, "90° right of a map turned to 30°")
        let back = CameraFlight.ground(from: losAngeles, offset: offset, heading: 30, scale: 10)
        #expect(GeoMath.distance(back, point) < 1)
    }

    @Test("Bigger zooms take longer, within bounds")
    func duration() {
        #expect(CameraFlight.duration(fromScale: 1_000, toScale: 1_000) == CameraFlight.minimumDuration)
        #expect(abs(CameraFlight.duration(fromScale: 1_000, toScale: 4_000) - (CameraFlight.minimumDuration + 2 * CameraFlight.secondsPerZoomLevel)) < 1e-9)
        #expect(CameraFlight.duration(fromScale: 4_000, toScale: 1_000) == CameraFlight.duration(fromScale: 1_000, toScale: 4_000))
        #expect(CameraFlight.duration(fromScale: 1, toScale: 1e9) == CameraFlight.maximumDuration)
    }
}
