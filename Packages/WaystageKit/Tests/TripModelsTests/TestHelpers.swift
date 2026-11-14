import Foundation
@testable import TripModels

extension TripRequest {
    static func sample(departure: Date, arriveBy: Date? = nil, goal: OptimizationGoal = .balanced) -> TripRequest {
        TripRequest(
            origin: Place(id: "origin", name: "San Francisco", coordinate: GeoCoordinate(latitude: 37.77, longitude: -122.42)),
            destination: Place(id: "destination", name: "New York", coordinate: GeoCoordinate(latitude: 40.71, longitude: -74.0)),
            departure: departure,
            arriveBy: arriveBy,
            vehicle: Vehicle(milesPerGallon: 30),
            policy: .standard,
            goal: goal
        )
    }
}
