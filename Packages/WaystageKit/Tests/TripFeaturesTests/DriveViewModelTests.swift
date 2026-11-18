import Foundation
import Testing
@testable import TripFeatures
import TripModels
import TripNavigation
import TripPlanner
import TripSandbox

@MainActor
@Suite("DriveViewModel")
struct DriveViewModelTests {
    private func makeModel(_ harness: FeatureHarness) async throws -> DriveViewModel {
        let itinerary = try #require(try await Plans.laToVegas().recommended)
        #expect(itinerary.stops.count >= 3, "LA → Las Vegas should include at least one break")
        return DriveViewModel(trip: ActiveTrip(itinerary: itinerary), dependencies: harness.dependencies)
    }

    /// Opens drive mode and taps Start on the first leg's preview.
    private func startDriving(_ model: DriveViewModel) async {
        await model.start()
        await model.beginNavigation()
    }

    /// Drives the current leg to its end.
    private func driveCurrentLeg(_ model: DriveViewModel) async throws {
        let leg = try #require(model.trip.legToTarget)
        for sample in samples(along: leg) {
            await model.handle(sample)
            if model.mode != .driving { break }
        }
    }

    @Test("A new trip opens on a silent preview of its first leg; Start begins guidance and the trip")
    func start() async throws {
        let harness = FeatureHarness()
        let model = try await makeModel(harness)
        await model.start()
        #expect(model.mode == .driving)
        #expect(model.stage == .preview, "the same flow as resuming: the leg first, then Start")
        #expect(model.trip.progress.phase == .notStarted, "not started until Start")
        #expect(model.banner == nil)
        #expect(model.nextStop?.name == model.trip.itinerary.stops[1].place.name)
        #expect(model.route != nil, "the engine has the leg's route for the preview")
        #expect(!harness.guidance.isGuiding)
        #expect(model.previewFrame == model.routeToTarget)
        #expect(harness.speech.spoken.isEmpty)
        #expect(harness.location.isUpdating)

        await model.beginNavigation()
        #expect(model.stage == .navigating)
        #expect(model.trip.progress.phase == .enRoute)
        #expect(model.banner != nil)
        #expect(harness.guidance.isGuiding)
        #expect(harness.speech.spoken.first?.hasPrefix("Head toward") == true)
        #expect(try await harness.repository.loadActiveTrip()?.progress.phase == .enRoute)
        await model.stop()
        #expect(!harness.location.isUpdating)
        #expect(!harness.guidance.isGuiding, "leaving drive mode ends guidance")
    }

    @Test("Leaving a new trip's preview keeps the trip not started")
    func leavePreview() async throws {
        let harness = FeatureHarness()
        let model = try await makeModel(harness)
        await model.start()
        await model.stop()
        #expect(try await harness.repository.loadActiveTrip()?.progress.phase == .notStarted)
    }

    @Test("Arriving at a stop offers 'Continue to next stop', which starts the next leg")
    func arriveAndContinue() async throws {
        let harness = FeatureHarness()
        let model = try await makeModel(harness)
        await startDriving(model)
        try await driveCurrentLeg(model)
        #expect(model.mode == .atStop)
        #expect(model.canContinueToNextStop)
        #expect(model.banner == nil)
        #expect(try await harness.repository.loadActiveTrip()?.progress.phase == .atStop)
        #expect(harness.speech.spoken.contains { $0.hasPrefix("You have arrived") })

        let spokenAtStop = harness.speech.spoken.count
        await model.continueToNextStop()
        #expect(model.mode == .driving)
        #expect(model.stage == .preview, "continuing shows the next leg before guidance starts")
        #expect(model.banner == nil)
        #expect(model.trip.progress.targetStopIndex == 2)
        #expect(model.route != nil)
        #expect(!harness.guidance.isGuiding)
        #expect(harness.speech.spoken.count == spokenAtStop, "the preview is silent")
        #expect(try await harness.repository.loadActiveTrip()?.progress.targetStopIndex == 2)

        await model.beginNavigation()
        #expect(model.stage == .navigating)
        #expect(model.banner != nil)
        #expect(harness.speech.spoken.count == spokenAtStop + 1, "starting speaks the first instruction")
    }

    @Test("Resuming a started trip opens a silent preview of the route from the car to the next stop")
    func resumePreview() async throws {
        let harness = FeatureHarness()
        let itinerary = try #require(try await Plans.laToVegas().recommended)
        var trip = ActiveTrip(itinerary: itinerary)
        try trip.start(at: testNow)
        let model = DriveViewModel(trip: trip, dependencies: harness.dependencies)
        #expect(model.stage == .preview)
        await model.start()
        #expect(harness.speech.spoken.isEmpty)
        #expect(model.banner == nil)
        let car = try #require(model.currentLocation)
        let target = try #require(model.trip.targetStop)
        #expect(GeoMath.distance(try #require(model.routeToTarget.first), car) < 1, "the route starts at the car")
        #expect(GeoMath.distance(try #require(model.routeToTarget.last), target.place.coordinate) < 500)
        #expect(model.previewFrame == model.routeToTarget)
        #expect(!model.routeAfterTarget.isEmpty, "the rest of the trip is drawn too")

        await model.beginNavigation()
        #expect(model.stage == .navigating)
        #expect(harness.speech.spoken.count == 1)
    }

    @Test("While driving, the route line starts at the car and shrinks as the car advances")
    func routeStartsAtCar() async throws {
        let model = try await makeModel(FeatureHarness())
        await startDriving(model)
        let leg = try #require(model.trip.legToTarget)
        let fixes = samples(along: leg)
        await model.handle(fixes[4])
        let early = model.routeToTarget
        #expect(GeoMath.distance(try #require(early.first), fixes[4].coordinate) < 1)
        await model.handle(fixes[20])
        let later = model.routeToTarget
        #expect(GeoMath.distance(try #require(later.first), fixes[20].coordinate) < 1)
        #expect(GeoMath.length(of: later) < GeoMath.length(of: early) - 3_000)
    }

    @Test("Starting away from the planned leg fetches directions from where the car is")
    func directionsFromCar() async throws {
        let harness = FeatureHarness()
        let itinerary = try #require(try await Plans.laToVegas().recommended)
        var trip = ActiveTrip(itinerary: itinerary)
        try trip.start(at: testNow)
        let origin = itinerary.stops[0].place.coordinate
        let elsewhere = GeoCoordinate(latitude: origin.latitude + 0.05, longitude: origin.longitude + 0.05)
        harness.location.send(LocationSample(coordinate: elsewhere, timestamp: testNow))
        let model = DriveViewModel(trip: trip, dependencies: harness.dependencies)
        await model.start()
        #expect(GeoMath.distance(try #require(model.routeToTarget.first), elsewhere) < 1)
        let fetchedStart = try #require(model.route?.coordinates.first)
        #expect(GeoMath.distance(fetchedStart, elsewhere) < 300, "directions start at the car")
    }

    @Test("A new trip opened away from the planned origin is guided from the car, announced once")
    func newTripFromElsewhere() async throws {
        let harness = FeatureHarness()
        let origin = try #require(try await Plans.laToVegas().recommended).stops[0].place.coordinate
        harness.location.send(LocationSample(
            coordinate: GeoCoordinate(latitude: origin.latitude + 0.05, longitude: origin.longitude), timestamp: testNow
        ))
        let model = try await makeModel(harness)
        await model.start()
        #expect(model.stage == .preview)
        let car = try #require(model.currentLocation)
        #expect(GeoMath.distance(try #require(model.route?.coordinates.first), car) < 300, "the previewed leg starts at the car")
        #expect(harness.speech.spoken.isEmpty)
        await model.beginNavigation()
        #expect(harness.speech.spoken.count == 1, "spoken: \(harness.speech.spoken)")
    }

    @Test("A fix far from a leg loaded without a position fetches directions from the car")
    func firstFixAway() async throws {
        let harness = FeatureHarness(startLocation: nil)
        let itinerary = try #require(try await Plans.laToVegas().recommended)
        var trip = ActiveTrip(itinerary: itinerary)
        try trip.start(at: testNow)
        let model = DriveViewModel(trip: trip, dependencies: harness.dependencies)
        await model.start()
        let origin = itinerary.stops[0].place.coordinate
        #expect(GeoMath.distance(try #require(model.route?.coordinates.first), origin) < 300, "no position: from the previous stop")
        let away = GeoCoordinate(latitude: origin.latitude + 0.05, longitude: origin.longitude)
        await model.handle(LocationSample(coordinate: away, speed: 10, timestamp: testNow))
        #expect(GeoMath.distance(try #require(model.route?.coordinates.first), away) < 300)
        #expect(GeoMath.distance(try #require(model.routeToTarget.first), away) < 1)
    }

    // MARK: Plan start vs. the car

    private func farStartModel(_ harness: FeatureHarness) async throws -> DriveViewModel {
        let itinerary = try #require(try await Plans.sfToVegas().recommended)
        return DriveViewModel(trip: ActiveTrip(itinerary: itinerary), dependencies: harness.dependencies)
    }

    @Test("Opening a trip far from its start previews the way to the start; the trip hasn't begun")
    func farFromStartPreview() async throws {
        let harness = FeatureHarness()
        let model = try await farStartModel(harness)
        #expect(model.isHeadingToStart)
        #expect(model.stage == .preview)
        #expect(model.previewFrame.count >= 2, "the map can frame car → start before directions load")
        await model.start()
        #expect(model.trip.progress.phase == .notStarted)
        #expect(model.isHeadingToStart)
        #expect(harness.speech.spoken.isEmpty)
        let start = model.trip.itinerary.stops[0]
        #expect(model.nextStop?.kind == .origin)
        #expect(model.nextStop?.kindTitle == "Trip start")
        #expect(model.nextStop?.name == start.place.name)
        let car = try #require(model.currentLocation)
        #expect(GeoMath.distance(try #require(model.routeToTarget.first), car) < 1)
        #expect(GeoMath.distance(try #require(model.routeToTarget.last), start.place.coordinate) < 500)
        #expect(!model.routeAfterTarget.isEmpty, "the planned trip is drawn beyond the start")
        #expect(harness.guidance.destination?.name == start.place.name)
        #expect(try await harness.repository.loadActiveTrip()?.progress.phase == .notStarted, "kept for resuming")
    }

    @Test("Driving to the start begins the trip and guidance carries on to the first stop")
    func reachingTheStart() async throws {
        let harness = FeatureHarness()
        let model = try await farStartModel(harness)
        await startDriving(model)
        #expect(model.stage == .navigating)
        #expect(model.banner != nil)
        let toStart = PolylineGeometry(coordinates: try #require(model.route?.coordinates))
        for distance in Array(stride(from: 0, to: toStart.totalLength, by: 500)) + [toStart.totalLength] where model.isHeadingToStart {
            await model.handle(LocationSample(coordinate: toStart.coordinate(atDistance: distance), speed: 30, timestamp: testNow))
        }
        #expect(!model.isHeadingToStart)
        #expect(model.trip.progress.phase == .enRoute)
        #expect(model.trip.progress.targetStopIndex == 1)
        #expect(model.stage == .navigating)
        #expect(model.nextStop?.name == model.trip.itinerary.stops[1].place.name)
        #expect(harness.speech.spoken.contains { $0.hasPrefix("You have arrived") })
        #expect(harness.guidance.isGuiding, "guidance carries on to the first stop")
        #expect(harness.guidance.destination?.name == model.trip.itinerary.stops[1].place.name)
        #expect(try await harness.repository.loadActiveTrip()?.progress.phase == .enRoute)
    }

    @Test("The driver can start the trip from where they are instead")
    func startFromHere() async throws {
        let harness = FeatureHarness()
        let model = try await farStartModel(harness)
        await model.start()
        await model.startTripFromHere()
        #expect(!model.isHeadingToStart)
        #expect(model.trip.progress.phase == .enRoute)
        #expect(model.stage == .preview, "still a preview: the new route is shown before Start")
        let car = try #require(model.currentLocation)
        #expect(GeoMath.distance(try #require(model.route?.coordinates.first), car) < 300, "directions to the first stop come from the car")
    }

    @Test("\"I've arrived\" while heading to the start begins the trip")
    func confirmStart() async throws {
        let model = try await farStartModel(FeatureHarness())
        await model.start()
        await model.confirmArrival()
        #expect(!model.isHeadingToStart)
        #expect(model.trip.progress.phase == .enRoute)
    }

    @Test("A trip opened near its start previews its first leg (not the way to the start)")
    func nearStart() async throws {
        let model = try await makeModel(FeatureHarness())
        #expect(!model.isHeadingToStart)
        #expect(model.stage == .preview)
        #expect(!model.previewFrame.isEmpty, "the planned first leg frames the map before directions load")
    }

    @Test("At a stop the map shows the next leg")
    func atStopShowsNextLeg() async throws {
        let model = try await makeModel(FeatureHarness())
        await startDriving(model)
        await model.confirmArrival()
        #expect(model.mode == .atStop)
        let stop = try #require(model.trip.targetStop)
        #expect(GeoMath.distance(try #require(model.routeToTarget.first), stop.place.coordinate) < 500)
        #expect(model.previewFrame == model.routeToTarget)
    }

    @Test("The next-stop option appears when approaching a stop")
    func approaching() async throws {
        let model = try await makeModel(FeatureHarness())
        await startDriving(model)
        #expect(!model.canContinueToNextStop)
        let leg = try #require(model.trip.legToTarget)
        let path = PolylineGeometry(coordinates: try PolylineCodec.decode(leg.encodedPolyline))
        for sample in samples(along: leg) where path.project(sample.coordinate).map({ path.totalLength - $0.distanceAlong > 300 }) ?? false {
            await model.handle(sample)
        }
        #expect(try #require(model.legProgress).distanceRemaining <= DriveViewModel.approachDistance)
        #expect(model.canContinueToNextStop)
    }

    @Test("Driving away from a stop automatically continues to the next one")
    func autoDeparture() async throws {
        let model = try await makeModel(FeatureHarness())
        await startDriving(model)
        await model.confirmArrival()
        #expect(model.mode == .atStop)
        let stop = try #require(model.trip.targetStop)
        let away = GeoCoordinate(latitude: stop.place.coordinate.latitude + 0.01, longitude: stop.place.coordinate.longitude)
        await model.handle(LocationSample(coordinate: away, speed: 20, timestamp: testNow))
        #expect(model.mode == .driving)
        #expect(model.stage == .navigating, "already driving: no preview")
        #expect(model.trip.progress.targetStopIndex == 2)
    }

    @Test("Going off route triggers a reroute with fresh directions")
    func reroute() async throws {
        let harness = FeatureHarness()
        let model = try await makeModel(harness)
        await startDriving(model)
        let leg = try #require(model.trip.legToTarget)
        let onRoute = samples(along: leg)[10]
        await model.handle(onRoute)
        let off = GeoCoordinate(latitude: onRoute.coordinate.latitude + 0.02, longitude: onRoute.coordinate.longitude)
        for _ in 0..<3 { await model.handle(LocationSample(coordinate: off, speed: 25, timestamp: testNow)) }
        #expect(harness.speech.spoken.contains("Rerouting."))
        #expect(!model.isRerouting)
        #expect(GeoMath.distance(try #require(model.route?.coordinates.first), off) < 300, "the new route starts at the car")
    }

    @Test("Skipping a stop loads directions to the following one")
    func skip() async throws {
        let harness = FeatureHarness()
        let model = try await makeModel(harness)
        await startDriving(model)
        let skipped = try #require(model.trip.targetStop)
        await model.skipTargetStop()
        #expect(model.trip.progress.skippedStopIDs.contains(skipped.id))
        #expect(model.route != nil)
        #expect(harness.guidance.destination?.name == model.trip.targetStop?.place.name)
        #expect(harness.guidance.isGuiding, "guidance carries on")
        #expect(!model.upcomingStops.contains { $0.id == skipped.id })
    }

    @Test("Muting stops speech and is remembered")
    func mute() async throws {
        let harness = FeatureHarness()
        let model = try await makeModel(harness)
        await startDriving(model)
        let spokenBefore = harness.speech.spoken.count
        model.isMuted = true
        #expect(!harness.preferences.load().voiceGuidanceEnabled)
        try await driveCurrentLeg(model)
        #expect(harness.speech.spoken.count == spokenBefore)
        #expect(harness.speech.stopCount > 0)
    }

    @Test("Reaching the destination completes the trip; ending clears it")
    func completion() async throws {
        let harness = FeatureHarness()
        let model = try await makeModel(harness)
        await startDriving(model)
        while !model.trip.isFinalTarget { await model.skipTargetStop() }
        try await driveCurrentLeg(model)
        #expect(model.mode == .completed)
        #expect(!model.canContinueToNextStop)
        #expect(try await harness.repository.loadActiveTrip()?.progress.phase == .completed)
        await model.endTrip()
        #expect(try await harness.repository.loadActiveTrip() == nil)
    }

    @Test("Location-only progress is saved at most every 30 seconds")
    func throttledSaves() async throws {
        let harness = FeatureHarness()
        let model = try await makeModel(harness)
        await model.start()
        let before = await harness.repository.activeSaveCount
        let leg = try #require(model.trip.legToTarget)
        for sample in samples(along: leg).prefix(20) { await model.handle(sample) }
        #expect(await harness.repository.activeSaveCount == before) // clock is frozen → not due yet
    }

    @Test("Resuming mid-leg, the map opens on the rest of the leg from the car, before directions load")
    func resumeFramesRestOfLeg() async throws {
        let harness = FeatureHarness()
        let itinerary = try #require(try await Plans.laToVegas().recommended)
        var trip = ActiveTrip(itinerary: itinerary)
        try trip.start(at: testNow)
        let planned = try PolylineCodec.decode(try #require(trip.legToTarget).encodedPolyline)
        let midway = PolylineGeometry(coordinates: planned).coordinate(atDistance: GeoMath.length(of: planned) / 2)
        harness.location.send(LocationSample(coordinate: midway, timestamp: testNow))
        let model = DriveViewModel(trip: trip, dependencies: harness.dependencies)
        let opening = model.previewFrame
        #expect(GeoMath.distance(try #require(opening.first), midway) < 1, "starts at the car")
        #expect(GeoMath.length(of: opening) < GeoMath.length(of: planned) * 0.6, "only what's left of the leg")
        await model.start()
        // Directions from the car cover about the same ground: the view barely changes.
        let loaded = model.previewFrame
        #expect(GeoMath.distance(try #require(loaded.first), midway) < 300)
        #expect(abs(GeoMath.length(of: loaded) - GeoMath.length(of: opening)) < GeoMath.length(of: opening) * 0.25)
    }

    @Test("Resuming a trip mid-leg picks up guidance from the current position")
    func resume() async throws {
        let harness = FeatureHarness()
        let itinerary = try #require(try await Plans.laToVegas().recommended)
        var trip = ActiveTrip(itinerary: itinerary)
        try trip.start(at: testNow)
        let model = DriveViewModel(trip: trip, dependencies: harness.dependencies)
        await model.start()
        let leg = try #require(model.trip.legToTarget)
        let midway = samples(along: leg)[samples(along: leg).count / 2]
        await model.handle(midway)
        #expect((model.legFraction ?? 0) > 0.4)
    }

    // MARK: Navigation engine

    @Test("Declined navigation terms: the planned leg and a message; Start asks again")
    func termsDeclined() async throws {
        let harness = FeatureHarness()
        harness.guidance.declinesTerms = true
        let model = try await makeModel(harness)
        await model.start()
        #expect(!model.isGuidanceReady)
        #expect(model.statusMessage == GuidanceError.termsNotAccepted.message)
        #expect(model.route == nil)
        #expect(!model.routeToTarget.isEmpty, "the planned leg is still shown")
        await model.beginNavigation()
        #expect(model.stage == .preview, "no guidance without the terms")
        #expect(harness.guidance.prepareCount == 2)
        #expect(model.trip.progress.phase == .notStarted)

        harness.guidance.declinesTerms = false
        await model.beginNavigation()
        #expect(model.stage == .navigating)
        #expect(model.route != nil)
        #expect(harness.guidance.isGuiding)
    }

    @Test("Ending guidance from CarPlay returns to the leg's preview at once")
    func pause() async throws {
        let harness = FeatureHarness()
        let model = try await makeModel(harness)
        await startDriving(model)
        #expect(harness.guidance.isGuiding)
        await model.pauseGuidance()
        #expect(model.stage == .preview)
        #expect(model.banner == nil)
        #expect(model.route != nil, "the route is shown again for the preview")
        #expect(!harness.guidance.isGuiding)
        #expect(model.trip.progress.phase == .enRoute, "the trip carries on")
        await model.beginNavigation()
        #expect(harness.guidance.isGuiding)
    }

    @Test("With an engine that draws its own guidance (Google), drive mode draws no route or banner")
    func engineDrawsGuidance() async throws {
        let engine = FakeNavigationEngine()
        let model = try await makeModel(FeatureHarness(guidance: engine))
        await model.start()
        #expect(engine.destinations.map(\.name) == [model.trip.itinerary.stops[1].place.name])
        #expect(engine.destinations.first?.placeID == model.trip.itinerary.stops[1].place.googlePlaceID)
        #expect(!model.drawsRouteToTarget)
        #expect(!model.previewFrame.isEmpty, "the map still frames the leg")
        await model.beginNavigation()
        #expect(engine.isGuiding)
        await engine.send(.instruction(GuidanceInstruction(maneuver: .turnLeft, text: "Turn left", distanceToManeuver: 200)))
        #expect(model.banner == nil, "the engine draws its own header")

        await engine.send(.progress(distanceRemaining: 5_000, timeRemaining: 300))
        #expect(model.nextStop?.durationText == "5 min")
        #expect(!model.canContinueToNextStop)
        await engine.send(.progress(distanceRemaining: 600, timeRemaining: 40))
        #expect(model.canContinueToNextStop)

        await engine.send(.arrived)
        #expect(model.mode == .atStop)
        #expect(!engine.isGuiding)
        #expect(model.drawsRouteToTarget, "at a stop the planned next leg is drawn by drive mode")

        await model.continueToNextStop()
        #expect(engine.destinations.count == 2)
        #expect(model.stage == .preview)
        #expect(!engine.isGuiding)
    }

    @Test("Directions that couldn't load are retried from a later fix")
    func retry() async throws {
        let engine = FakeNavigationEngine()
        engine.failure = .locationUnavailable
        let model = try await makeModel(FeatureHarness(guidance: engine))
        model.loadRetryInterval = 0
        await model.start()
        #expect(model.route == nil)
        #expect(model.statusMessage == GuidanceError.locationUnavailable.message)
        engine.failure = nil
        await model.handle(LocationSample(coordinate: SampleTrips.city("la").coordinate, timestamp: testNow))
        #expect(model.route != nil)
        #expect(model.statusMessage == nil)
    }
}

/// A navigation engine that, like Google's Navigation SDK, draws its own guidance and reports
/// events from outside (sent by the test).
@MainActor
final class FakeNavigationEngine: TurnByTurnGuidance {
    let drawsOwnGuidance = true
    var eventHandler: (@MainActor (GuidanceEvent) async -> Void)?
    var isMuted = false
    var failure: GuidanceError?
    private(set) var destinations: [GuidanceDestination] = []
    private(set) var isGuiding = false

    func prepare() async throws {}

    func setDestination(_ destination: GuidanceDestination, from origin: GeoCoordinate?) async throws -> GuidanceRoute {
        isGuiding = false
        if let failure { throw failure }
        destinations.append(destination)
        let start = origin ?? destination.coordinate
        let distance = GeoMath.distance(start, destination.coordinate)
        return GuidanceRoute(coordinates: [start, destination.coordinate], distanceMeters: distance, duration: distance / 25)
    }

    func startGuidance() async { isGuiding = true }
    func stopGuidance() { isGuiding = false }
    func didUpdateLocation(_ sample: LocationSample) async {}

    func send(_ event: GuidanceEvent) async {
        await eventHandler?(event)
    }
}
