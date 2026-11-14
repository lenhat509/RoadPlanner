import Foundation
import Testing
import TripModels
@testable import TripPlanner

@Suite("ItineraryOptimizer")
struct ItineraryOptimizerTests {
    @Test("A short trip needs no stops")
    func shortTrip() throws {
        let problem = Fixture.problem(hours: 2.5, candidates: Fixture.restAreas(everyMinutes: 30, hours: 2.5))
        let schedule = try #require(Fixture.optimize(problem).value)
        #expect(schedule.stops.isEmpty)
        #expect(abs(schedule.arrival.timeIntervalSince(Fixture.departure) - 2.5 * 3_600) < 1)
    }

    @Test("By default the driver rests at least every 3 hours")
    func defaultRestRhythm() throws {
        let problem = Fixture.problem(
            hours: 8, candidates: Fixture.restAreas(everyMinutes: 20, hours: 8) + Fixture.gasStations(everyMinutes: 60, hours: 8)
        )
        let schedule = try #require(Fixture.optimize(problem).value)
        let segments = Fixture.drivingSegments(schedule)
        #expect(segments.allSatisfy { $0 <= 3 * 3_600 + 1 })
        #expect(schedule.stops.count >= 2)
        #expect(schedule.stops.allSatisfy { $0.departure.timeIntervalSince($0.arrival) >= 15 * 60 - 1 })
    }

    @Test("Honours a custom 'drive before resting' interval")
    func customRestInterval() throws {
        var policy = DrivingPolicy.standard
        policy.maxContinuousDriving = 2 * 3_600
        let problem = Fixture.problem(
            hours: 7, candidates: Fixture.restAreas(everyMinutes: 20, hours: 7) + Fixture.gasStations(everyMinutes: 60, hours: 7)
        )
        let schedule = try #require(Fixture.optimize(problem, policy: policy).value)
        #expect(Fixture.drivingSegments(schedule).allSatisfy { $0 <= 2 * 3_600 + 1 })
        #expect(schedule.stops.count >= 3)
    }

    @Test("Refuels before the tank drops below the reserve")
    func fuelReserve() throws {
        let vehicle = Vehicle(milesPerGallon: 25, tankCapacityGallons: 12)
        let candidates = Fixture.restAreas(everyMinutes: 30, hours: 9) + Fixture.gasStations(everyMinutes: 30, hours: 9)
        let problem = Fixture.problem(hours: 9, candidates: candidates, vehicle: vehicle)
        let schedule = try #require(Fixture.optimize(problem).value)
        let reserve = 12 * DrivingPolicy.standard.fuelReserveFraction
        #expect(schedule.stops.contains { if case .refuel = $0.action { true } else { false } })
        #expect(schedule.stops.allSatisfy { $0.fuelOnArrival >= reserve - 1e-6 })
        #expect(schedule.fuelOnArrival >= reserve - 1e-6)
        #expect(schedule.fuelCost > 0)
    }

    @Test("Cheapest picks the cheaper station; fastest picks the smaller detour")
    func goalTradeOff() throws {
        let vehicle = Vehicle(milesPerGallon: 20, tankCapacityGallons: 12)
        let candidates = Fixture.restAreas(everyMinutes: 30, hours: 5.5) + [
            Fixture.candidate("pricey", atHours: 2.5, [.fuel, .rest], fuelPrice: 4.79, detourMinutes: 2),
            Fixture.candidate("cheap", atHours: 2.55, [.fuel, .rest], fuelPrice: 2.99, detourMinutes: 9),
        ]
        let cheapest = try #require(Fixture.optimize(Fixture.problem(hours: 5.5, candidates: candidates, goal: .cheapest, vehicle: vehicle)).value)
        let fastest = try #require(Fixture.optimize(Fixture.problem(hours: 5.5, candidates: candidates, goal: .fastest, vehicle: vehicle)).value)
        let cheapestStations = cheapest.stops.filter { if case .refuel = $0.action { true } else { false } }.map(\.candidate.id)
        let fastestStations = fastest.stops.filter { if case .refuel = $0.action { true } else { false } }.map(\.candidate.id)
        #expect(cheapestStations == ["cheap"])
        #expect(fastestStations == ["pricey"])
        #expect(cheapest.totalCost < fastest.totalCost)
        #expect(fastest.arrival <= cheapest.arrival)
    }

    @Test("Buys only the fuel needed to reach the destination on the last fill")
    func topUpToDestination() throws {
        let vehicle = Vehicle(milesPerGallon: 30, tankCapacityGallons: 14, initialFuelFraction: 0.5)
        let candidates = Fixture.restAreas(everyMinutes: 30, hours: 6) + Fixture.gasStations(everyMinutes: 60, hours: 6)
        let schedule = try #require(Fixture.optimize(Fixture.problem(hours: 6, candidates: candidates, goal: .cheapest, vehicle: vehicle)).value)
        // A full tank would leave lots of fuel in the tank; the plan should arrive near the reserve.
        #expect(schedule.fuelOnArrival < 14 * 0.5)
    }

    @Test("Stops overnight when a trip exceeds a day's driving")
    func overnight() throws {
        let hours = 15.0
        let candidates = Fixture.restAreas(everyMinutes: 30, hours: hours)
            + Fixture.gasStations(everyMinutes: 45, hours: hours)
            + Fixture.lodging(everyMinutes: 30, from: 5, to: 12)
        let schedule = try #require(Fixture.optimize(Fixture.problem(hours: hours, candidates: candidates)).value)
        let overnights = schedule.stops.filter { if case .overnight = $0.action { true } else { false } }
        #expect(overnights.count == 1)
        let stay = try #require(overnights.first)
        #expect(Fixture.localSecondsOfDay(stay.arrival) <= 21 * 3_600 + 1)
        #expect(Fixture.localSecondsOfDay(stay.departure) >= 8 * 3_600 - 1)
        #expect(stay.departure.timeIntervalSince(stay.arrival) >= 9 * 3_600 - 1)
        #expect(schedule.finalDayIndex == 1)
        #expect(schedule.lodgingCost == 120)
        // Daily driving ≤ 10 h.
        let firstDay = schedule.stops.prefix { $0.candidate.id != stay.candidate.id }
        var drivenDayOne = 0.0
        var last = Fixture.departure
        for stop in firstDay + [stay] {
            drivenDayOne += stop.arrival.timeIntervalSince(last)
            last = stop.departure
        }
        let breaks = firstDay.reduce(0.0) { $0 + $1.departure.timeIntervalSince($1.arrival) }
        #expect(drivenDayOne - breaks <= 10 * 3_600 + 1)
    }

    @Test("Meets an arrival deadline when it is achievable")
    func meetsDeadline() throws {
        let hours = 15.0
        let candidates = Fixture.restAreas(everyMinutes: 30, hours: hours)
            + Fixture.gasStations(everyMinutes: 60, hours: hours)
            + Fixture.lodging(everyMinutes: 30, from: 5, to: 12)
        let deadline = Fixture.departure.addingTimeInterval(31 * 3_600)
        let schedule = try #require(Fixture.optimize(Fixture.problem(hours: hours, candidates: candidates, goal: .cheapest, arriveBy: deadline)).value)
        #expect(schedule.arrival <= deadline)
    }

    @Test("Reports an unachievable deadline")
    func impossibleDeadline() {
        let hours = 15.0
        let candidates = Fixture.restAreas(everyMinutes: 30, hours: hours)
            + Fixture.gasStations(everyMinutes: 60, hours: hours)
            + Fixture.lodging(everyMinutes: 30, from: 5, to: 12)
        let deadline = Fixture.departure.addingTimeInterval(16 * 3_600)
        let result = Fixture.optimize(Fixture.problem(hours: hours, candidates: candidates, arriveBy: deadline))
        #expect(result.failureValue == .deadline)
    }

    @Test("Reports a stretch with no gas station within range")
    func fuelGap() {
        let vehicle = Vehicle(milesPerGallon: 20, tankCapacityGallons: 10)
        let result = Fixture.optimize(Fixture.problem(hours: 6, candidates: Fixture.restAreas(everyMinutes: 30, hours: 6), vehicle: vehicle))
        guard case .fuelRange = result.failureValue else {
            Issue.record("Expected a fuel range failure, got \(String(describing: result))")
            return
        }
    }

    @Test("Prefers real facilities over roadside pull-offs")
    func avoidsPullOffs() throws {
        let candidates = [
            Fixture.candidate("pulloff", atHours: 2.5, [.rest], detourMinutes: 4, isPullOff: true),
            Fixture.candidate("restarea", atHours: 2.4, [.rest], detourMinutes: 4),
        ]
        let schedule = try #require(Fixture.optimize(Fixture.problem(hours: 5, candidates: candidates)).value)
        #expect(schedule.stops.map(\.candidate.id) == ["restarea"])
    }

    @Test("Ignores lodging search areas unless allowed")
    func lodgingAreasGated() {
        let candidates = Fixture.restAreas(everyMinutes: 30, hours: 15)
            + Fixture.gasStations(everyMinutes: 60, hours: 15)
            + Fixture.lodging(everyMinutes: 30, from: 5, to: 12).map { candidate in
                var area = candidate
                area.isLodgingSearchArea = true
                return area
            }
        #expect(Fixture.optimize(Fixture.problem(hours: 15, candidates: candidates)).value == nil)
        var settings = OptimizerSettings(policy: .standard)
        settings.allowLodgingSearchAreas = true
        #expect(ItineraryOptimizer(settings: settings).optimize(Fixture.problem(hours: 15, candidates: candidates)).value != nil)
    }

    @Test("Goals are ordered: cheapest costs least, fastest arrives first, balanced in between")
    func goalOrdering() throws {
        let hours = 20.0
        var candidates = Fixture.restAreas(everyMinutes: 30, hours: hours)
        candidates += stride(from: 0.75, to: hours, by: 0.75).map {
            Fixture.candidate("gas-\(Int($0 * 60))", atHours: $0, [.fuel, .rest],
                              fuelPrice: 3 + (sin($0 * 3) + 1) * 0.6, detourMinutes: 2 + (cos($0 * 5) + 1) * 4)
        }
        candidates += stride(from: 6.0, to: 13.0, by: 0.5).map {
            Fixture.candidate("hotel-\(Int($0 * 60))", atHours: $0, [.lodging], nightlyRate: 80 + (sin($0 * 7) + 1) * 70)
        }
        let vehicle = Vehicle(milesPerGallon: 24, tankCapacityGallons: 13)
        func run(_ goal: OptimizationGoal) throws -> OptimizedSchedule {
            try #require(Fixture.optimize(Fixture.problem(hours: hours, candidates: candidates, goal: goal, vehicle: vehicle)).value)
        }
        let fastest = try run(.fastest), cheapest = try run(.cheapest), balanced = try run(.balanced)
        #expect(cheapest.totalCost <= balanced.totalCost + 0.01)
        #expect(balanced.totalCost <= fastest.totalCost + 0.01)
        #expect(fastest.arrival <= balanced.arrival)
        #expect(balanced.arrival <= cheapest.arrival)
    }

    @Test("Never checks into a hotel in the morning, even when morning hotels are cheaper")
    func noMorningCheckIn() throws {
        let hours = 15.0
        let candidates = Fixture.restAreas(everyMinutes: 30, hours: hours)
            + Fixture.gasStations(everyMinutes: 60, hours: hours)
            + Fixture.lodging(everyMinutes: 30, from: 0.5, to: 5, rate: 40) // arrivals 08:30–13:00 local
            + Fixture.lodging(everyMinutes: 30, from: 7, to: 12, rate: 150)
        let schedule = try #require(Fixture.optimize(Fixture.problem(hours: hours, candidates: candidates, goal: .cheapest)).value)
        let overnights = schedule.stops.filter { if case .overnight = $0.action { true } else { false } }
        #expect(!overnights.isEmpty)
        for stay in overnights {
            let local = Fixture.localSecondsOfDay(stay.arrival)
            #expect(local >= 14 * 3_600 || local < 8 * 3_600, "checked in at \(local / 3_600) h local")
            #expect(stay.departure.timeIntervalSince(stay.arrival) < 16 * 3_600, "waited \(stay.departure.timeIntervalSince(stay.arrival) / 3_600) h")
        }
    }

    @Test("Fuel cost counts all gas the trip uses, including what was already in the tank")
    func fuelCostCountsGasUsed() throws {
        // 2.5 h at 60 mph = 150 mi; 30 mpg → 5 gal; no fuel stop needed on a full tank.
        var problem = Fixture.problem(hours: 2.5, candidates: [])
        problem.referenceFuelPrice = 3.5
        let schedule = try #require(Fixture.optimize(problem).value)
        #expect(schedule.stops.isEmpty)
        #expect(abs(schedule.fuelCost - 5 * 3.5) < 0.05)
        #expect(abs(schedule.fuelGallonsUsed - 5) < 0.01)
    }

    @Test("Leftover fuel is not charged to the trip")
    func leftoverFuelCredited() throws {
        let vehicle = Vehicle(milesPerGallon: 25, tankCapacityGallons: 12)
        var problem = Fixture.problem(
            hours: 9, candidates: Fixture.restAreas(everyMinutes: 30, hours: 9) + Fixture.gasStations(everyMinutes: 30, hours: 9, price: 3.5),
            vehicle: vehicle
        )
        problem.referenceFuelPrice = 3.5
        let schedule = try #require(Fixture.optimize(problem).value)
        // With a single price everywhere, trip fuel cost = gallons burned × price, whatever was bought.
        #expect(abs(schedule.fuelCost - schedule.fuelGallonsUsed * 3.5) < 0.05)
    }

    @Test("Respects the driver's minimum fuel level", arguments: [0.25, 0.4])
    func minimumFuelLevel(fraction: Double) throws {
        var policy = DrivingPolicy.standard
        policy.fuelReserveFraction = fraction
        let vehicle = Vehicle(milesPerGallon: 25, tankCapacityGallons: 14)
        let candidates = Fixture.restAreas(everyMinutes: 30, hours: 8) + Fixture.gasStations(everyMinutes: 20, hours: 8)
        let schedule = try #require(Fixture.optimize(Fixture.problem(hours: 8, candidates: candidates, vehicle: vehicle), policy: policy).value)
        #expect(schedule.stops.contains { if case .refuel = $0.action { true } else { false } })
        #expect(schedule.stops.allSatisfy { $0.fuelOnArrival >= 14 * fraction - 1e-6 })
        #expect(schedule.fuelOnArrival >= 14 * fraction - 1e-6)
    }

    @Test("A car starting low on fuel may dip into the reserve to reach the first station")
    func lowStartingFuel() throws {
        let vehicle = Vehicle(milesPerGallon: 30, tankCapacityGallons: 14, initialFuelFraction: 0.1)
        let candidates = Fixture.restAreas(everyMinutes: 30, hours: 5) + Fixture.gasStations(everyMinutes: 20, hours: 5)
        let schedule = try #require(Fixture.optimize(Fixture.problem(hours: 5, candidates: candidates, vehicle: vehicle)).value)
        let firstStop = try #require(schedule.stops.first)
        guard case .refuel = firstStop.action else {
            Issue.record("First stop should refuel, got \(firstStop.action)")
            return
        }
    }
}
