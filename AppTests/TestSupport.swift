import Foundation
import TripModels
import TripSandbox

enum TripSandboxSamples {
    static func request() -> TripRequest {
        SampleTrips.request(from: "la", to: "lv", goal: .fastest)
    }
}
