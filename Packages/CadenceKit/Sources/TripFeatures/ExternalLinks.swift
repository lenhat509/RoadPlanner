import Foundation
import TripModels

/// Deep links into Google Maps and Expedia, using their documented URL formats.
///
/// * Google Maps URLs: https://developers.google.com/maps/documentation/urls/get-started
public enum ExternalLinks {
    /// Cross-platform Google Maps directions URL (opens the app when installed).
    public static func googleMapsDirections(from origin: GeoCoordinate?, to destination: Place, waypoints: [GeoCoordinate] = []) -> URL {
        var items = [URLQueryItem(name: "api", value: "1")]
        if let origin { items.append(URLQueryItem(name: "origin", value: origin.urlValue)) }
        items.append(URLQueryItem(name: "destination", value: destination.coordinate.urlValue))
        if destination.isGooglePlace { items.append(URLQueryItem(name: "destination_place_id", value: destination.id)) }
        if !waypoints.isEmpty {
            // Google Maps on mobile supports up to 3 waypoints in URLs; keep the next ones.
            items.append(URLQueryItem(name: "waypoints", value: waypoints.prefix(3).map(\.urlValue).joined(separator: "|")))
        }
        items.append(URLQueryItem(name: "travelmode", value: "driving"))
        items.append(URLQueryItem(name: "dir_action", value: "navigate"))
        return url("https://www.google.com/maps/dir/", items)
    }

    /// Google Maps place page (shows reviews, hours and — for hotels — Google's rates).
    public static func googleMapsPlace(_ place: Place) -> URL {
        var items = [URLQueryItem(name: "api", value: "1"), URLQueryItem(name: "query", value: place.coordinate.urlValue)]
        if place.isGooglePlace { items.append(URLQueryItem(name: "query_place_id", value: place.id)) }
        return url("https://www.google.com/maps/search/", items)
    }

    /// Google Maps hotel search near a point (prices come from Google Travel).
    public static func googleHotels(near coordinate: GeoCoordinate) -> URL {
        url("https://www.google.com/maps/search/", [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "query", value: "hotels near \(coordinate.urlValue)"),
        ])
    }

    /// Expedia hotel search for one night near a stop.
    public static func expediaHotelSearch(near place: Place, checkIn: Date, checkOut: Date, adults: Int) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: place.utcOffsetSeconds)
        formatter.dateFormat = "yyyy-MM-dd"
        return url("https://www.expedia.com/Hotel-Search", [
            URLQueryItem(name: "destination", value: place.address ?? place.name),
            URLQueryItem(name: "latLong", value: place.coordinate.urlValue),
            URLQueryItem(name: "startDate", value: formatter.string(from: checkIn)),
            URLQueryItem(name: "endDate", value: formatter.string(from: checkOut)),
            URLQueryItem(name: "adults", value: String(adults)),
        ])
    }

    private static func url(_ base: String, _ items: [URLQueryItem]) -> URL {
        var components = URLComponents(string: base)!
        components.queryItems = items
        return components.url!
    }
}

extension Place {
    /// `true` when `id` is a Google Place ID (not a generated or partner identifier).
    public var isGooglePlace: Bool {
        let syntheticPrefixes = ["pulloff-", "lodging-area-", "origin", "destination", "current-location"]
        return id.count >= 16 && !id.contains(":") && !syntheticPrefixes.contains { id.hasPrefix($0) }
            && UUID(uuidString: id) == nil
    }
}
