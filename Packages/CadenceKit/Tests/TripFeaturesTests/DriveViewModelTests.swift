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

        await model.continueToNextStop()
        #expect(model.mode == .driving)
        #expect(model.trip.progress.targetStopIndex == 2)
        #expect(model.guidance != nil)
        #expect(try await harness.repository.loadActiveTrip()?.progress.targetStopIndex == 2)
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
