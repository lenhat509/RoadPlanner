import Foundation
import TripPlanner

/// Wires the production adapters together.
public enum ServiceFactory {
    public struct Settings: Sendable {
        public var google: GoogleMapsConfiguration
        public var gateway: CadenceGatewayClient.Configuration?

        public init(google: GoogleMapsConfiguration, gateway: CadenceGatewayClient.Configuration?) {
            self.google = google
            self.gateway = gateway
        }
    }

    public struct Services: Sendable {
        public var planner: any TripPlanning
        public var routing: any RoutingProvider
        public var autocomplete: any PlaceAutocompleteProvider
    }

    public static func make(settings: Settings, transport: any HTTPTransport = RetryingTransport(URLSessionTransport())) -> Services {
        let routing = GoogleRoutesClient(configuration: settings.google, transport: transport)
        let places = GooglePlacesClient(configuration: settings.google, transport: transport)
        let gateway = settings.gateway.map { CadenceGatewayClient(configuration: $0, transport: transport) }
        let planner = TripPlanningService(routing: routing, places: places, lodging: gateway, fuelPrices: gateway)
        return Services(planner: planner, routing: routing, autocomplete: places)
    }
}
