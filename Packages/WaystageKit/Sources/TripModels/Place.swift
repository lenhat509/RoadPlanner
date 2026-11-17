import Foundation

/// A named location. `id` is the Google Place ID when the place came from Google.
public struct Place: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var address: String?
    public var coordinate: GeoCoordinate
    /// Offset from UTC in minutes at the place, as reported by the Places API.
    public var utcOffsetMinutes: Int?

    public init(
        id: String = UUID().uuidString,
        name: String,
        address: String? = nil,
        coordinate: GeoCoordinate,
        utcOffsetMinutes: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.coordinate = coordinate
        self.utcOffsetMinutes = utcOffsetMinutes
    }

    /// The UTC offset in seconds, falling back to a longitude-based estimate.
    ///
    /// The fallback (`round(longitude / 15)` hours) is only used for synthetic locations
    /// such as roadside pull-offs; real places carry the offset from Google.
    public var utcOffsetSeconds: Int {
        if let utcOffsetMinutes { return utcOffsetMinutes * 60 }
        return Place.estimatedUTCOffsetSeconds(for: coordinate)
    }

    public static func estimatedUTCOffsetSeconds(for coordinate: GeoCoordinate) -> Int {
        Int((coordinate.longitude / 15).rounded()) * 3_600
    }
}

extension Place {
    /// The Google Place ID, when the place came from Google (not a made-up roadside pull-off, a
    /// lodging area or a gateway hotel).
    public var googlePlaceID: String? {
        guard id.count >= 16, UUID(uuidString: id) == nil,
              !id.hasPrefix("pulloff-"), !id.hasPrefix("lodging-area-"),
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
        return id
    }
}
