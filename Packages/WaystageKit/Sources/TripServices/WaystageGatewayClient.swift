import Foundation
import TripModels
import TripPlanner

/// Client for the Waystage gateway (see `Backend/gateway`), which holds the secrets for
/// Expedia Rapid (live lodging rates) and the U.S. EIA (regional fuel prices) so they never
/// ship inside the app binary.
public struct WaystageGatewayClient: LodgingRateProvider, RegionalFuelPriceProvider {
    public struct Configuration: Hashable, Sendable {
        public var baseURL: URL
        /// Per-app token checked by the gateway (rotate via remote config; see docs/SECURITY.md).
        public var appToken: String

        public init(baseURL: URL, appToken: String) {
            self.baseURL = baseURL
            self.appToken = appToken
        }
    }

    private let configuration: Configuration
    private let transport: any HTTPTransport

    public init(configuration: Configuration, transport: any HTTPTransport) {
        self.configuration = configuration
        self.transport = transport
    }

    public func offers(for query: LodgingQuery) async throws -> [LodgingOffer] {
        let request = makeRequest(path: "v1/lodging/rates", items: [
            "lat": String(format: "%.5f", query.center.latitude),
            "lng": String(format: "%.5f", query.center.longitude),
            "radiusKm": String(format: "%.1f", query.radiusMeters / 1_000),
            "checkin": Self.day(query.checkIn),
            "checkout": Self.day(query.checkOut),
            "adults": String(query.adults),
        ])
        let response = try await transport.send(request).validated()
        let decoded = try JSON.decode(LodgingRatesResponse.self, from: response.body)
        return decoded.offers.compactMap { offer in
            guard offer.nightlyRate > 0, offer.currency == "USD" else { return nil }
            return LodgingOffer(
                propertyID: offer.propertyId,
                name: offer.name,
                coordinate: GeoCoordinate(latitude: offer.latitude, longitude: offer.longitude),
                nightlyRate: offer.nightlyRate,
                currencyCode: offer.currency,
                provider: offer.provider,
                bookingURL: offer.bookingUrl.flatMap(URL.init(string:))
            )
        }
    }

    /// Regional averages (EIA) exist for regular, midgrade, premium and diesel; any grade uses
    /// regular's, and E85 has none.
    public func averagePrice(near coordinate: GeoCoordinate, fuelType: FuelType) async throws -> Double? {
        let series: FuelType
        switch fuelType {
        case .e85: return nil
        case .any: series = .regular
        default: series = fuelType
        }
        let request = makeRequest(path: "v1/fuel/average", items: [
            "lat": String(format: "%.4f", coordinate.latitude),
            "lng": String(format: "%.4f", coordinate.longitude),
            "fuelType": series.rawValue,
        ])
        let response = try await transport.send(request).validated()
        return try JSON.decode(FuelAverageResponse.self, from: response.body).pricePerGallon
    }

    private func makeRequest(path: String, items: [String: String]) -> HTTPRequest {
        var components = URLComponents(url: configuration.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = items.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return HTTPRequest(
            method: .get,
            url: components.url!,
            headers: ["Accept": "application/json", "X-Waystage-App-Token": configuration.appToken]
        )
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

struct LodgingRatesResponse: Decodable {
    struct Offer: Decodable {
        var propertyId: String
        var name: String
        var latitude: Double
        var longitude: Double
        var nightlyRate: Double
        var currency: String
        var provider: String
        var bookingUrl: String?
    }

    var offers: [Offer]
}

struct FuelAverageResponse: Decodable {
    var pricePerGallon: Double?
    var region: String?
    var period: String?
}
