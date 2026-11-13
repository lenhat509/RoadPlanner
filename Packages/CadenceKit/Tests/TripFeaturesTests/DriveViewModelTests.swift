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

    /// Drives the current leg to its end.
    private func driveCurrentLeg(_ model: DriveViewModel) async throws {
        let leg = try #require(model.trip.legToTarget)
        for sample in samples(along: leg) {
            await model.handle(sample)
            if model.mode != .driving { break }
        }
    }

    @Test("Starting begins guidance, speaks the first instruction and saves progress")
    func start() async throws {
        let harness = FeatureHarness()
        let model = try await makeModel(harness)
        await model.start()
        #expect(model.trip.progress.phase == .enRoute)
        #expect(model.mode == .driving)
        #expect(model.stage == .navigating, "a new trip goes straight to guidance (the plan was the preview)")
        #expect(model.banner != nil)
        #expect(model.nextStop?.name == model.trip.itinerary.stops[1].place.name)
        #expect(!model.legCoordinates.isEmpty)
        #expect(harness.speech.spoken.first?.hasPrefix("Head toward") == true)
        #expect(try await harness.repository.loadActiveTrip()?.progress.phase == .enRoute)
        #expect(harness.location.isUpdating)
        await model.stop()
        #expect(!harness.location.isUpdating)
    }

    @Test("Arriving at a stop offers 'Continue to next stop', which starts the next leg")
    func arriveAndContinue() async throws {
        let harness = FeatureHarness()
        let model = try await makeModel(harness)
        await model.start()
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
        #expect(model.guidance != nil)
        #expect(harness.speech.spoken.count == spokenAtStop, "the preview is silent")
        #expect(try await harness.repository.loadActiveTrip()?.progress.targetStopIndex == 2)

        model.beginNavigation()
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

        model.beginNavigation()
        #expect(model.stage == .navigating)
        #expect(harness.speech.spoken.count == 1)
    }

    @Test("While driving, the route line starts at the car and shrinks as the car advances")
    func routeStartsAtCar() async throws {
        let model = try await makeModel(FeatureHarness())
        await model.start()
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
        #expect(model.trip.rerouteLegs[0] != nil, "fresh directions replace the planned leg")
        #expect(GeoMath.distance(try #require(model.routeToTarget.first), elsewhere) < 1)
        let fetchedStart = try #require(model.legCoordinates.first)
        #expect(GeoMath.distance(fetchedStart, elsewhere) < 300)
    }

    @Test("A new trip started away from the planned origin is guided from the car, announced once")
    func newTripFromElsewhere() async throws {
        let harness = FeatureHarness()
        let origin = try #require(try await Plans.laToVegas().recommended).stops[0].place.coordinate
        harness.location.send(LocationSample(
            coordinate: GeoCoordinate(latitude: origin.latitude + 0.05, longitude: origin.longitude), timestamp: testNow
        ))
        let model = try await makeModel(harness)
        await model.start()
        #expect(model.stage == .navigating)
        #expect(model.trip.rerouteLegs[0] != nil)
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
        #expect(model.trip.rerouteLegs[0] == nil)
        let origin = itinerary.stops[0].place.coordinate
        let away = GeoCoordinate(latitude: origin.latitude + 0.05, longitude: origin.longitude)
        await model.handle(LocationSample(coordinate: away, speed: 10, timestamp: testNow))
        #expect(model.trip.rerouteLegs[0] != nil)
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
        #expect(model.trip.rerouteLegs.isEmpty, "directions to the start are not part of the plan")
        #expect(try await harness.repository.loadActiveTrip()?.progress.phase == .notStarted, "kept for resuming")
    }

    @Test("Driving to the start begins the trip and guidance carries on to the first stop")
    func reachingTheStart() async throws {
        let harness = FeatureHarness()
        let model = try await farStartModel(harness)
        await model.start()
        model.beginNavigation()
        #expect(model.stage == .navigating)
        #expect(model.banner != nil)
        let toStart = PolylineGeometry(coordinates: model.legCoordinates)
        for distance in Array(stride(from: 0, to: toStart.totalLength, by: 500)) + [toStart.totalLength] where model.isHeadingToStart {
            await model.handle(LocationSample(coordinate: toStart.coordinate(atDistance: distance), speed: 30, timestamp: testNow))
        }
        #expect(!model.isHeadingToStart)
        #expect(model.trip.progress.phase == .enRoute)
        #expect(model.trip.progress.targetStopIndex == 1)
        #expect(model.stage == .navigating)
        #expect(model.nextStop?.name == model.trip.itinerary.stops[1].place.name)
        #expect(harness.speech.spoken.contains("You've reached the start of your trip."))
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
        #expect(model.trip.rerouteLegs[0] != nil, "directions to the first stop come from the car")
        let car = try #require(model.currentLocation)
        #expect(GeoMath.distance(try #require(model.legCoordinates.first), car) < 300)
    }

    @Test("\"I've arrived\" while heading to the start begins the trip")
    func confirmStart() async throws {
        let model = try await farStartModel(FeatureHarness())
        await model.start()
        await model.confirmArrival()
        #expect(!model.isHeadingToStart)
        #expect(model.trip.progress.phase == .enRoute)
    }

    @Test("A trip opened near its start begins right away")
    func nearStart() async throws {
        let model = try await makeModel(FeatureHarness())
        #expect(!model.isHeadingToStart)
        #expect(model.stage == .navigating)
        #expect(!model.previewFrame.isEmpty, "the planned first leg frames the map before directions load")
    }

    @Test("At a stop the map shows the next leg")
    func atStopShowsNextLeg() async throws {
        let model = try await makeModel(FeatureHarness())
        await model.start()
        await model.confirmArrival()
        #expect(model.mode == .atStop)
        let stop = try #require(model.trip.targetStop)
        #expect(GeoMath.distance(try #require(model.routeToTarget.first), stop.place.coordinate) < 500)
        #expect(model.previewFrame == model.routeToTarget)
    }

    @Test("The next-stop option appears when approaching a stop")
    func approaching() async throws {
        let model = try await makeModel(FeatureHarness())
        await model.start()
        #expect(!model.canContinueToNextStop)
        let leg = try #require(model.trip.legToTarget)
        let path = PolylineGeometry(coordinates: try PolylineCodec.decode(leg.encodedPolyline))
        for sample in samples(along: leg) where path.project(sample.coordinate).map({ path.totalLength - $0.distanceAlong > 300 }) ?? false {
            await model.handle(sample)
        }
        #expect(model.guidance?.arrival == .approaching)
        #expect(model.canContinueToNextStop)
    }

    @Test("Driving away from a stop automatically continues to the next one")
    func autoDeparture() async throws {
        let model = try await makeModel(FeatureHarness())
        await model.start()
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
        await model.start()
        let leg = try #require(model.trip.legToTarget)
        let onRoute = samples(along: leg)[10]
        await model.handle(onRoute)
        let off = GeoCoordinate(latitude: onRoute.coordinate.latitude + 0.02, longitude: onRoute.coordinate.longitude)
        for _ in 0..<3 { await model.handle(LocationSample(coordinate: off, speed: 25, timestamp: testNow)) }
        #expect(harness.speech.spoken.contains("Rerouting."))
        #expect(model.trip.rerouteLegs[0] != nil)
        #expect(!model.isRerouting)
        #expect(model.guidance?.isOffRoute == false)
    }

    @Test("Skipping a stop loads directions to the following one")
    func skip() async throws {
        let model = try await makeModel(FeatureHarness())
        await model.start()
        let skipped = try #require(model.trip.targetStop)
        await model.skipTargetStop()
        #expect(model.trip.progress.skippedStopIDs.contains(skipped.id))
        #expect(model.guidance != nil)
        #expect(!model.upcomingStops.contains { $0.id == skipped.id })
    }

    @Test("Muting stops speech and is remembered")
    func mute() async throws {
        let harness = FeatureHarness()
        let model = try await makeModel(harness)
        await model.start()
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
        await model.start()
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
        #expect((model.guidance?.progress ?? 0) > 0.4)
    }
}
