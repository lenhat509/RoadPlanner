import Foundation
import TripModels

/// Credentials and locale for Google Maps Platform web services.
public struct GoogleMapsConfiguration: Hashable, Sendable {
    /// API key restricted to the app's bundle ID (and only the Routes + Places APIs).
    public var apiKey: String
    /// Sent as `X-Ios-Bundle-Identifier` so iOS-restricted keys work with web-service calls.
    public var iosBundleIdentifier: String?
    public var languageCode: String
    public var regionCode: String

    public init(apiKey: String, iosBundleIdentifier: String? = nil, languageCode: String = "en-US", regionCode: String = "US") {
        self.apiKey = apiKey
        self.iosBundleIdentifier = iosBundleIdentifier
        self.languageCode = languageCode
        self.regionCode = regionCode
    }

    func headers(fieldMask: String?) -> [String: String] {
        var headers = ["Content-Type": "application/json", "X-Goog-Api-Key": apiKey]
        if let fieldMask { headers["X-Goog-FieldMask"] = fieldMask }
        if let iosBundleIdentifier { headers["X-Ios-Bundle-Identifier"] = iosBundleIdentifier }
        return headers
    }
}

/// `google.type.LatLng`
struct GoogleLatLng: Codable, Hashable {
    var latitude: Double
    var longitude: Double

    init(_ coordinate: GeoCoordinate) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var coordinate: GeoCoordinate { GeoCoordinate(latitude: latitude, longitude: longitude) }
}

/// `google.type.Money` — `units` is an int64 encoded as a JSON string.
struct GoogleMoney: Codable, Hashable {
    var currencyCode: String?
    var units: String?
    var nanos: Int?

    var amount: Double { (Double(units ?? "0") ?? 0) + Double(nanos ?? 0) / 1e9 }
}

/// Parses protobuf `Duration` JSON strings such as `"3600s"` or `"12.5s"`.
enum GoogleDuration {
    static func seconds(_ value: String?) -> TimeInterval? {
        guard var value, value.hasSuffix("s") else { return nil }
        value.removeLast()
        return TimeInterval(value)
    }
}

/// `google.type.LocalizedText`
struct GoogleLocalizedText: Codable, Hashable {
    var text: String?
}
