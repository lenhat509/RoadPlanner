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

    /// Every stop, with the places to visit numbered in route order (1, 2, …).
    static func markers(for stops: [ItineraryStop], activeID: String? = nil) -> [MapStopMarker] {
        var visits = 0
        return stops.map { stop in
            var marker = MapStopMarker(
                id: stop.id,
                coordinate: stop.place.coordinate,
                title: stop.place.name,
                kind: stop.kind,
                isPullOff: stop.isRoadsidePullOff,
                isActive: stop.id == activeID
            )
            if stop.kind == .visit {
                visits += 1
                marker.number = visits
            }
            return marker
        }
    }

    /// Where to label a route: halfway along it.
    static func labelCoordinate(for paths: [[GeoCoordinate]]) -> GeoCoordinate? {
        guard let route = paths.first, !route.isEmpty else { return nil }
        return route[route.count / 2]
    }
}
