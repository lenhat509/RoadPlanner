import Foundation
import Testing
@testable import TripFeatures
import TripModels

@Suite("Formatting and presentation")
struct PresentationTests {
    private let formatters = TripFormatters(locale: Locale(identifier: "en_US_POSIX"))

    @Test("Durations", arguments: [(2_700.0, "45 min"), (19_200, "5 h 20 min"), (7_200, "2 h"), (273_600, "3 d 4 h"), (172_800, "2 d")])
    func durations(seconds: Double, expected: String) {
        #expect(formatters.duration(seconds) == expected)
    }

    @Test("Distances")
    func distances() {
        // en_US (not POSIX): POSIX grouping differs between Apple and Linux Foundation.
        let usd = TripFormatters(locale: Locale(identifier: "en_US"))
        #expect(usd.distance(Units.meters(fromMiles: 2_631.2)) == "2,631 mi")
        #expect(formatters.distance(Units.meters(fromMiles: 12.44)) == "12.4 mi")
        #expect(formatters.distance(100) == "330 ft")
    }

    @Test("Currency")
    func currency() {
        let usd = TripFormatters(locale: Locale(identifier: "en_US"))
        #expect(usd.currency(1_234.4) == "$1,234")
        #expect(usd.currency(3.089, precise: true) == "$3.09")
    }

    @Test("Local times use the stop's own UTC offset")
    func localTime() {
        let date = Date(timeIntervalSince1970: 1_809_360_000) // 16:00Z
        let pacific = formatters.clockTime(date, utcOffsetSeconds: -8 * 3_600)
        let eastern = formatters.clockTime(date, utcOffsetSeconds: -5 * 3_600)
        #expect(pacific.contains("8:00"))
        #expect(eastern.contains("11:00"))
        #expect(formatters.dayTitle(date, utcOffsetSeconds: 0).contains("May 3"))
    }

    @Test("Stop presentation describes fuel, lodging and pull-offs")
    func stops() {
        let place = Place(name: "Shell", address: "Exit 12", coordinate: GeoCoordinate(latitude: 0, longitude: 0), utcOffsetMinutes: 0)
        let arrival = Date(timeIntervalSince1970: 0)
        let fuel = ItineraryStop(
            kind: .fuel, place: place, arrival: arrival, departure: arrival.addingTimeInterval(900), distanceFromStartMeters: 0,
            fuelPurchase: FuelPurchase(gallons: 10.4, pricePerGallon: 3.09, isPriceEstimated: true), dayIndex: 0
        )
        let fuelText = StopPresentation(stop: fuel, formatters: formatters)
        #expect(fuelText.symbolName == "fuelpump.fill")
        #expect(fuelText.detail?.contains("10.4 gal") == true)
        #expect(fuelText.detail?.contains("(est.)") == true)
        #expect(fuelText.isEstimate)
        #expect(fuelText.timeText.contains("15 min stop"))
        #expect(fuelText.subtitle == "Fuel stop · Exit 12")

        var hotel = fuel
        hotel.kind = .lodging
        hotel.fuelPurchase = nil
        hotel.lodging = LodgingStay(nightlyRate: 129, isRateEstimated: false, provider: "Expedia")
        let hotelText = StopPresentation(stop: hotel, formatters: formatters)
        #expect(hotelText.symbolName == "bed.double.fill")
        #expect(hotelText.detail?.contains("/night · Expedia") == true)
        #expect(hotelText.timeText.hasPrefix("Check in"))

        var pullOff = fuel
        pullOff.kind = .rest
        pullOff.fuelPurchase = nil
        pullOff.isRoadsidePullOff = true
        let pullOffText = StopPresentation(stop: pullOff, formatters: formatters)
        #expect(pullOffText.symbolName == "parkingsign.circle.fill")
        #expect(pullOffText.subtitle.hasPrefix("Rest break"))
    }

    @Test("Fuel stops show the tank level on arrival")
    func fuelLevelOnArrival() {
        let place = Place(name: "Shell", coordinate: GeoCoordinate(latitude: 0, longitude: 0), utcOffsetMinutes: 0)
        let stop = ItineraryStop(
            kind: .fuel, place: place, arrival: Date(timeIntervalSince1970: 0), departure: Date(timeIntervalSince1970: 900),
            distanceFromStartMeters: 0, fuelOnArrivalGallons: 3.5,
            fuelPurchase: FuelPurchase(gallons: 10.5, pricePerGallon: 3.2, isPriceEstimated: false), dayIndex: 0
        )
        let text = StopPresentation(stop: stop, formatters: formatters, tankCapacityGallons: 14)
        #expect(text.detail?.hasPrefix("Arrive with 25% · ") == true)
    }

    @Test("Every maneuver has a banner symbol")
    func maneuverSymbols() {
        for maneuver in Maneuver.allCases { #expect(!maneuver.symbolName.isEmpty) }
        #expect(Maneuver.turnLeft.symbolName == "arrow.turn.up.left")
    }
}

@Suite("ExternalLinks")
struct ExternalLinksTests {
    private let hotel = Place(
        id: "ChIJN1t_tDeuEmsRUsoyG83frY4", name: "Hampton Inn", address: "1 Inn Ct, Reno, NV",
        coordinate: GeoCoordinate(latitude: 39.5296, longitude: -119.8138), utcOffsetMinutes: -480
    )

    @Test("Google Maps directions use the documented URL parameters")
    func directions() throws {
        let url = ExternalLinks.googleMapsDirections(
            from: GeoCoordinate(latitude: 37.7749, longitude: -122.4194), to: hotel,
            waypoints: [GeoCoordinate(latitude: 38, longitude: -121), GeoCoordinate(latitude: 38.5, longitude: -120)]
        )
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(url.host == "www.google.com")
        #expect(query["api"] == "1")
        #expect(query["origin"] == "37.774900,-122.419400")
        #expect(query["destination"] == "39.529600,-119.813800")
        #expect(query["destination_place_id"] == hotel.id)
        #expect(query["waypoints"] == "38.000000,-121.000000|38.500000,-120.000000")
        #expect(query["travelmode"] == "driving")
        #expect(query["dir_action"] == "navigate")
    }

    @Test("Synthetic places never send a fake place ID")
    func syntheticPlaces() {
        let pullOff = Place(id: "pulloff-5400", name: "Roadside break", coordinate: GeoCoordinate(latitude: 1, longitude: 2))
        #expect(!pullOff.isGooglePlace)
        #expect(!ExternalLinks.googleMapsPlace(pullOff).absoluteString.contains("query_place_id"))
        #expect(!Place(id: "expedia:123456789012345", name: "x", coordinate: GeoCoordinate(latitude: 0, longitude: 0)).isGooglePlace)
        #expect(hotel.isGooglePlace)
    }

    @Test("Expedia hotel search carries dates in the stop's time zone")
    func expedia() throws {
        let checkIn = Date(timeIntervalSince1970: 1_809_399_600) // 2027-05-04 03:00Z = May 3, 8 PM PDT-ish
        let url = ExternalLinks.expediaHotelSearch(near: hotel, checkIn: checkIn, checkOut: checkIn.addingTimeInterval(86_400), adults: 2)
        let query = try #require(url.query)
        #expect(url.host == "www.expedia.com")
        #expect(query.contains("startDate=2027-05-03"))
        #expect(query.contains("endDate=2027-05-04"))
        #expect(query.contains("adults=2"))
    }

    @Test("Hotel search near a point uses Google Maps search")
    func googleHotels() {
        let url = ExternalLinks.googleHotels(near: hotel.coordinate)
        #expect(url.absoluteString.contains("query=hotels%20near%2039.529600,-119.813800"))
    }
}
