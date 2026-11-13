import TripModels

/// Converts itineraries into map paths and markers.
enum MapContent {
    static func paths(for itinerary: Itinerary) -> [[GeoCoordinate]] {
        if !itinerary.legs.isEmpty {
            let coordinates = itinerary.legs.flatMap { (try? PolylineCodec.decode($0.encodedPolyline)) ?? [] }
            if !coordinates.isEmpty { return [GeoMath.simplify(coordinates, minimumSpacingMeters: 150)] }
        }
        let overview = (try? PolylineCodec.decode(itinerary.overviewPolyline)) ?? []
        return overview.isEmpty ? [] : [overview]
    }

    static func markers(for stops: [ItineraryStop], activeID: String? = nil) -> [MapStopMarker] {
        stops.map { stop in
            MapStopMarker(
                id: stop.id,
                coordinate: stop.place.coordinate,
                title: stop.place.name,
                kind: stop.kind,
                isPullOff: stop.isRoadsidePullOff,
                isActive: stop.id == activeID
            )
        }
    }
}
