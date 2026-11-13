import Foundation
import Testing
import TripModels
@testable import TripNavigation
import TripPlanner
import TripSandbox

@Suite("GuidanceEngine")
struct GuidanceEngineTests {
    /// ~40 km leg split into ~10 km steps.
    private let leg: RouteLeg = SyntheticRoute.make(
        from: GeoCoordinate(latitude: 39.0, longitude: -105.0),
        to: GeoCoordinate(latitude: 39.0, longitude: -104.54),
        stepLengthMeters: 10_000, vertexSpacingMeters: 200, summary: "I-70"
    ).legs[0]

    private var path: PolylineGeometry {
        PolylineGeometry(coordinates: (try? PolylineCodec.decode(leg.encodedPolyline)) ?? [])
    }

    /// Fixes every `spacing` meters along the leg.
    private func drive(spacing: Double = 100) -> [LocationSample] {
        let geometry = path
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        return stride(from: 0, through: geometry.totalLength, by: spacing).enumerated().map { index, distance in
            LocationSample(coordinate: geometry.coordinate(atDistance: distance), speed: 27, timestamp: start.addingTimeInterval(Double(index) * 4))
        }
    }

    @Test("Announces the departure instruction when guidance starts")
    func startAnnouncement() {
        var engine = GuidanceEngine(leg: leg, destinationName: "Rest Area")
        let update = engine.start()
        #expect(update.announcement == "Head toward I-70.")
        #expect(update.stepIndex == 0)
        #expect(update.arrival == .enRoute)
    }

    @Test("Reports the maneuver after the upcoming one, and the distance between them")
    func followingManeuver() throws {
        var engine = GuidanceEngine(leg: leg, destinationName: "Rest Area")
        let first = engine.start()
        #expect(first.followingManeuver != nil)
        #expect(abs((first.distanceBetweenManeuvers ?? 0) - 10_000) < 600)
        // On the second-to-last step the turn after the next one is the arrival.
        let lastStepStart = path.totalLength - 5_000
        let late = engine.update(with: LocationSample(
            coordinate: path.coordinate(atDistance: lastStepStart - 6_000), speed: 27, timestamp: Date()
        ))
        #expect(late.followingManeuver == .arrive)
        // On the last step there is nothing after the arrival.
        let end = engine.update(with: LocationSample(coordinate: path.coordinate(atDistance: lastStepStart), speed: 27, timestamp: Date()))
        #expect(end.upcomingManeuver == .arrive)
        #expect(end.followingManeuver == nil)
    }

    @Test("Progress, step index and remaining distance advance monotonically to arrival")
    func monotonicProgress() throws {
        var engine = GuidanceEngine(leg: leg, destinationName: "Rest Area")
        var previous: GuidanceUpdate?
        var updates: [GuidanceUpdate] = []
        for sample in drive() {
            let update = engine.update(with: sample)
            if let previous {
                #expect(update.stepIndex >= previous.stepIndex)
                #expect(update.distanceRemaining <= previous.distanceRemaining + 1)
                #expect(update.timeRemaining <= previous.timeRemaining + 1)
            }
            previous = update
            updates.append(update)
        }
        let last = try #require(updates.last)
        #expect(last.arrival == .arrived)
        #expect(last.progress > 0.99)
        #expect(last.upcomingManeuver == .arrive)
        #expect(updates.contains { $0.arrival == .approaching })
        #expect(updates.compactMap(\.announcement).filter { $0.hasPrefix("You have arrived") }.count == 1)
    }

    @Test("Voice prompts come at 2 mi, ½ mi and at the maneuver, once each, in order")
    func announcementsInOrder() {
        var engine = GuidanceEngine(leg: leg, destinationName: "Rest Area")
        let announcements = drive().compactMap { engine.update(with: $0).announcement }
        let secondInstruction = leg.steps[1].instruction
        let forStep = announcements.filter { $0.localizedCaseInsensitiveContains(secondInstruction) }
        #expect(forStep.count == 3, "\(forStep)")
        #expect(forStep.first?.hasPrefix("In 2 miles") == true)
        #expect(forStep.dropFirst().first?.hasPrefix("In half a mile") == true)
        #expect(forStep.last == "\(secondInstruction).")
        #expect(announcements.contains { $0.hasPrefix("Rest Area is ahead") })
    }

    @Test("Detects off-route driving only after repeated fixes, and recovers")
    func offRoute() {
        var engine = GuidanceEngine(leg: leg, destinationName: "Stop")
        let onRoute = path.coordinate(atDistance: 5_000)
        let offRoute = GeoCoordinate(latitude: onRoute.latitude + 0.003, longitude: onRoute.longitude) // ~330 m
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        _ = engine.update(with: LocationSample(coordinate: onRoute, timestamp: time))
        let first = engine.update(with: LocationSample(coordinate: offRoute, timestamp: time))
        let second = engine.update(with: LocationSample(coordinate: offRoute, timestamp: time))
        let third = engine.update(with: LocationSample(coordinate: offRoute, timestamp: time))
        #expect(!first.isOffRoute && !second.isOffRoute)
        #expect(third.isOffRoute)
        #expect(third.announcement == nil)
        let back = engine.update(with: LocationSample(coordinate: onRoute, timestamp: time))
        #expect(!back.isOffRoute)
    }

    @Test("Poor GPS accuracy widens the off-route threshold")
    func accuracyAware() {
        var engine = GuidanceEngine(leg: leg, destinationName: "Stop")
        let onRoute = path.coordinate(atDistance: 5_000)
        let nearby = GeoCoordinate(latitude: onRoute.latitude + 0.0011, longitude: onRoute.longitude) // ~120 m
        var last: GuidanceUpdate?
        for _ in 0..<5 {
            last = engine.update(with: LocationSample(coordinate: nearby, horizontalAccuracy: 100, timestamp: Date()))
        }
        #expect(last?.isOffRoute == false)
    }

    @Test("GPS jitter backwards does not rewind progress")
    func jitter() {
        var engine = GuidanceEngine(leg: leg, destinationName: "Stop")
        let ahead = engine.update(with: LocationSample(coordinate: path.coordinate(atDistance: 10_000), timestamp: Date()))
        let jittered = engine.update(with: LocationSample(coordinate: path.coordinate(atDistance: 9_700), timestamp: Date()))
        #expect(jittered.distanceRemaining - ahead.distanceRemaining <= 76)
    }

    @Test("A leg without steps still guides to the stop")
    func stepless() {
        var bare = leg
        bare.steps = []
        var engine = GuidanceEngine(leg: bare, destinationName: "Motel")
        #expect(engine.start().announcement == "Drive to Motel.")
        let end = engine.update(with: LocationSample(coordinate: path.coordinate(atDistance: path.totalLength), timestamp: Date()))
        #expect(end.arrival == .arrived)
        #expect(end.upcomingInstruction == "Arrive at Motel")
    }
}

@Suite("DistanceText")
struct DistanceTextTests {
    @Test("Short banner distances", arguments: [
        (16_093.44, "10 mi"), (3_862.4, "2.4 mi"), (482.8, "0.3 mi"), (137.0, "450 ft"), (5.0, "50 ft"),
    ])
    func short(meters: Double, expected: String) {
        #expect(DistanceText.short(meters) == expected)
    }

    @Test("Spoken distances", arguments: [
        (3_218.7, "2 miles"), (1_609.3, "1 mile"), (804.7, "half a mile"), (402.3, "a quarter mile"), (152.4, "500 feet"),
    ])
    func spoken(meters: Double, expected: String) {
        #expect(DistanceText.spoken(meters) == expected)
    }
}
