import GoogleMaps

/// Map styling. Night mode lowers glare in the car (see Google Maps Platform styling docs).
enum MapStyles {
    static let night: GMSMapStyle? = try? GMSMapStyle(jsonString: nightJSON)

    private static let nightJSON = """
    [
      {"elementType": "geometry", "stylers": [{"color": "#1d2c33"}]},
      {"elementType": "labels.text.fill", "stylers": [{"color": "#8ea6b0"}]},
      {"elementType": "labels.text.stroke", "stylers": [{"color": "#1a262c"}]},
      {"featureType": "poi", "elementType": "labels.icon", "stylers": [{"visibility": "off"}]},
      {"featureType": "road", "elementType": "geometry", "stylers": [{"color": "#33454f"}]},
      {"featureType": "road", "elementType": "geometry.stroke", "stylers": [{"color": "#212e35"}]},
      {"featureType": "road.highway", "elementType": "geometry", "stylers": [{"color": "#4b5f69"}]},
      {"featureType": "road.highway", "elementType": "labels.text.fill", "stylers": [{"color": "#c5d4da"}]},
      {"featureType": "transit", "stylers": [{"visibility": "off"}]},
      {"featureType": "water", "elementType": "geometry", "stylers": [{"color": "#0f1c22"}]}
    ]
    """
}
