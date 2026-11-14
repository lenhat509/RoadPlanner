import Foundation
import Testing
@testable import TripFeatures
import TripModels
import TripPersistence

@Suite("Disclosures")
struct DisclosuresTests {
    private var agreementText: String {
        Disclosures.keyPoints.map { "\($0.title). \($0.detail)" }.joined(separator: " ") + " " + Disclosures.agreementLine
    }

    @Test("The agreement covers the data source, bookings, availability, estimated costs and safety")
    func keyPoints() {
        let text = agreementText
        // (1) Plans are based on Google Maps data, and only as accurate as it.
        #expect(text.contains("Google Maps") && text.contains("wrong or out of date"))
        // (2) Nothing is booked; the user books lodging.
        #expect(text.contains("doesn't reserve") && text.contains("Book lodging yourself"))
        // (3) Costs are estimates; real fuel and lodging costs can differ.
        #expect(text.contains("Costs are estimates") && text.contains("What you pay can differ"))
        // (4) Hotel availability: check the website or call.
        #expect(text.contains("hotel's website or by phone"))
        // Beyond those: safety, and the vehicles it's made for.
        #expect(text.contains("don't use the app while moving"))
        #expect(text.contains("trucks, RVs or trailers"))
        #expect(Disclosures.agreementLine.contains("Google Maps Terms of Service"), "Google Maps' terms flow down to users")
        #expect(Set(Disclosures.keyPoints.map(\.id)).count == Disclosures.keyPoints.count)
    }

    @Test("People agree on first use, and again when the terms change; older settings still load")
    func agreement() throws {
        var preferences = UserPreferences()
        #expect(TermsAgreement.isNeeded(preferences))
        TermsAgreement.accept(&preferences)
        #expect(!TermsAgreement.isNeeded(preferences))
        preferences.acceptedTermsVersion = Disclosures.termsVersion - 1
        #expect(TermsAgreement.isNeeded(preferences), "a newer version needs agreeing to again")

        // Preferences saved before the agreement existed decode, and need it.
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(UserPreferences())) as? [String: Any] ?? [:]
        legacy.removeValue(forKey: "acceptedTermsVersion")
        let decoded = try JSONDecoder().decode(UserPreferences.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(TermsAgreement.isNeeded(decoded))
    }

    @Test("The Terms of Use in the app match docs/TERMS_OF_USE.md")
    func termsMatchTheDocument() throws {
        let document = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/TERMS_OF_USE.md")
        let markdown = try String(contentsOf: document, encoding: .utf8)
        // Links become plain text, as in the app.
        let plain = markdown.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        #expect(plain.contains("Last updated: \(Disclosures.termsLastUpdated)"))
        for (index, section) in Disclosures.termsOfUse.enumerated() {
            #expect(plain.contains("## \(index + 1). \(section.title)"), "missing section \(section.title)")
            for paragraph in section.paragraphs {
                #expect(plain.contains(paragraph), "out of sync: \(paragraph.prefix(60))…")
            }
        }
        let terms = Disclosures.termsOfUse.flatMap(\.paragraphs).joined(separator: " ")
        for topic in ["Google Maps", "doesn't make reservations", "estimates", "by phone", "as is", "passenger cars"] {
            #expect(terms.contains(topic), "the terms cover \(topic)")
        }
    }

    @Test("Stops remind what's not booked, what to check, and where it's safe to stop")
    func stopNotices() {
        let place = Place(name: "Motel 6", coordinate: GeoCoordinate(latitude: 0, longitude: 0), utcOffsetMinutes: 0)
        let formatters = TripFormatters(locale: Locale(identifier: "en_US_POSIX"))
        var hotel = ItineraryStop(kind: .lodging, place: place, arrival: nil, departure: nil, distanceFromStartMeters: 0, dayIndex: 0)
        hotel.lodging = LodgingStay(nightlyRate: 89, isRateEstimated: false, provider: "Expedia")
        #expect(StopPresentation(stop: hotel, formatters: formatters).detail?.hasSuffix("· not booked") == true)
        #expect(Disclosures.notice(for: hotel) == Disclosures.lodgingNotBooked)

        var pullOff = ItineraryStop(kind: .rest, place: place, arrival: nil, departure: nil, distanceFromStartMeters: 0, dayIndex: 0)
        pullOff.isRoadsidePullOff = true
        #expect(StopPresentation(stop: pullOff, formatters: formatters).detail?.contains("legal and safe") == true)
        #expect(Disclosures.notice(for: pullOff) == Disclosures.pullOffSafety)

        var fuel = ItineraryStop(kind: .fuel, place: place, arrival: nil, departure: nil, distanceFromStartMeters: 0, dayIndex: 0)
        fuel.fuelPurchase = FuelPurchase(gallons: 10, pricePerGallon: 3.5, isPriceEstimated: false)
        #expect(Disclosures.notice(for: fuel) == Disclosures.fuelStopCheck)
        #expect(Disclosures.lodgingNotBooked.contains("website or by phone"))
        #expect(Disclosures.costEstimate.contains("can differ"))
    }
}
