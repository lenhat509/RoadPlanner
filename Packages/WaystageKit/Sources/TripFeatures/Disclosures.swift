import Foundation
import TripModels
import TripPersistence

/// What people need to know before relying on a plan, in one place: the points they agree to on
/// first launch, the full Terms of Use, and the short notices shown where each matters.
///
/// Plain language on purpose. The Terms of Use must match `docs/TERMS_OF_USE.md` (a test checks).
/// Have a lawyer review them before release.
public enum Disclosures {
    /// Bump when the agreement or the terms change: everyone is asked to agree again.
    public static let termsVersion = 1
    public static let termsLastUpdated = "November 14, 2026"

    public static let googleMapsTermsURL = URL(string: "https://maps.google.com/help/terms_maps/")!
    public static let googlePrivacyURL = URL(string: "https://policies.google.com/privacy")!

    /// One point of the first-launch agreement.
    public struct Point: Identifiable, Hashable, Sendable {
        public var id: String
        public var systemImage: String
        public var title: String
        public var detail: String
    }

    /// What someone agrees to before using Waystage.
    public static let keyPoints: [Point] = [
        Point(
            id: "data", systemImage: "map", title: "Plans come from Google Maps data",
            detail: "Routes, stops, opening hours and prices come from Google Maps and partners and can be wrong or out of date. Road signs, local laws and conditions come first."
        ),
        Point(
            id: "booking", systemImage: "bed.double", title: "Nothing is booked for you",
            detail: "Waystage doesn't reserve hotels or anything else. Book lodging yourself, with the hotel or on a booking site."
        ),
        Point(
            id: "availability", systemImage: "phone", title: "Check hotels before you go",
            detail: "Rooms and rates change. Confirm availability and the total price on the hotel's website or by phone."
        ),
        Point(
            id: "costs", systemImage: "dollarsign.circle", title: "Costs are estimates",
            detail: "Fuel, lodging and toll costs are estimated from Google Maps and partner data. What you pay can differ, including taxes and fees."
        ),
        Point(
            id: "safety", systemImage: "steeringwheel", title: "You're the driver",
            detail: "Set up before you drive and don't use the app while moving. Rest whenever you're tired, and keep fuel in reserve in remote areas."
        ),
        Point(
            id: "vehicles", systemImage: "car", title: "Made for cars",
            detail: "Routes don't account for trucks, RVs or trailers, or for commercial drivers' hours-of-service rules."
        ),
    ]

    public static let agreementLine = "By tapping Agree and continue, you agree to the Waystage Terms of Use and the Google Maps Terms of Service, and acknowledge the Waystage and Google Privacy Policies."

    // MARK: Notices where they matter

    /// Under a plan's costs.
    public static let costEstimate = "Estimated from Google Maps and partner data. Actual fuel, lodging and toll costs can differ, including taxes and fees."
    /// At a hotel stop.
    public static let lodgingNotBooked = "Not booked. Waystage doesn't make reservations: check availability and the total price (taxes and fees) on the hotel's website or by phone, then book it yourself."
    /// At a fuel stop.
    public static let fuelStopCheck = "Prices and fuel grades are as the station reported them to Google Maps and may have changed. Check opening hours, especially at night."
    /// At a roadside break (no facility found).
    public static let pullOffSafety = "Stop only where it's legal and safe, such as an exit, rest area or parking lot. Don't stop on the highway shoulder except in an emergency."

    /// The notice for a stop, if it needs one.
    public static func notice(for stop: ItineraryStop) -> String? {
        if stop.isRoadsidePullOff { return pullOffSafety }
        if stop.lodging != nil || stop.kind == .lodging { return lodgingNotBooked }
        if stop.fuelPurchase != nil { return fuelStopCheck }
        return nil
    }

    // MARK: Terms of Use

    public struct TermsSection: Hashable, Sendable {
        public var title: String
        public var paragraphs: [String]
    }

    /// The full Terms of Use (same text as `docs/TERMS_OF_USE.md`).
    public static let termsOfUse: [TermsSection] = [
        TermsSection(title: "About these terms", paragraphs: [
            "These terms apply when you use the Waystage app. By using Waystage you agree to them. If you don't agree, please don't use the app.",
        ]),
        TermsSection(title: "Plans are suggestions", paragraphs: [
            "Waystage suggests routes, breaks, fuel stops and overnight stays to help you plan a long drive. It is a planning aid, not a guarantee: you decide where, when and how to drive.",
        ]),
        TermsSection(title: "Where the information comes from", paragraphs: [
            "Routes, places, opening hours, fuel prices and fuel grades come from Google Maps. Hotel rates come from Expedia where available, and regional fuel prices from the U.S. Energy Information Administration.",
            "This information can be incomplete, inaccurate or out of date, and conditions change: closures, construction, weather and traffic. Waystage is only as accurate as these sources. Always follow road signs, traffic laws and instructions from the authorities over the app.",
        ]),
        TermsSection(title: "Google Maps", paragraphs: [
            "Waystage uses Google Maps features and content. Your use of them is subject to the Google Maps/Google Earth Additional Terms of Service and the Google Privacy Policy. Google owns its content; don't copy, scrape or otherwise misuse it.",
        ]),
        TermsSection(title: "Lodging and bookings", paragraphs: [
            "Waystage doesn't make reservations or bookings of any kind. A hotel in your plan is not reserved for you, and its availability and rates can change at any time.",
            "Before relying on a stay, check availability and the total price (including taxes and fees) with the property, on its website or by phone, or on a booking site, and book it yourself. Any booking is between you and the property or booking site, under their terms.",
        ]),
        TermsSection(title: "Costs are estimates", paragraphs: [
            "Fuel, lodging and toll costs shown in Waystage are estimates based on data from Google Maps, Expedia and the U.S. Energy Information Administration, and on the fuel economy you enter. What you actually pay can be different, including taxes, resort and other fees, and price changes.",
        ]),
        TermsSection(title: "Fuel", paragraphs: [
            "Fuel grades and prices are as stations report them to Google Maps. A station that reports no grades is assumed to sell regular, midgrade and premium gasoline. Stations can be closed, out of a grade, or keep different hours than shown. Keep a reserve, refuel early in remote areas, and confirm a station before relying on it.",
        ]),
        TermsSection(title: "Driving safely", paragraphs: [
            "You are responsible for driving safely and lawfully. Set up your trip before you drive, and don't use the app while the vehicle is moving: let a passenger operate it, or stop in a safe place first.",
            "Planned breaks don't replace your judgment. Rest whenever you feel tired, stop only where it is legal and safe, and don't follow a route or instruction that seems unsafe, illegal or impossible.",
        ]),
        TermsSection(title: "Vehicles", paragraphs: [
            "Waystage is designed for passenger cars. Its routes and plans don't consider the size, weight, height or cargo limits of trucks, RVs, buses or vehicles towing a trailer, and its breaks are not a substitute for the hours-of-service rules that apply to commercial drivers.",
        ]),
        TermsSection(title: "Your location", paragraphs: [
            "Waystage uses your device's location to plan from where you are and to guide you. The Privacy Policy explains how location is handled.",
        ]),
        TermsSection(title: "Other websites", paragraphs: [
            "Links to Google Maps, Expedia, hotels and other sites take you to services we don't control. Their own terms and privacy policies apply.",
        ]),
        TermsSection(title: "No warranty", paragraphs: [
            "Waystage is provided \"as is\" and \"as available\", without warranties of any kind, express or implied, including warranties of accuracy, fitness for a particular purpose and non-infringement, to the fullest extent permitted by law.",
        ]),
        TermsSection(title: "Limitation of liability", paragraphs: [
            "To the fullest extent permitted by law, the developer of Waystage is not liable for any indirect, incidental, special or consequential damages, or for any loss, injury, damage, cost or delay arising from your use of the app or your reliance on its information, including unavailable lodging, price differences, closures and road conditions.",
            "Some places don't allow these limits, so they may not apply to you. Nothing in these terms limits rights you have under the law where you live.",
        ]),
        TermsSection(title: "Changes to these terms", paragraphs: [
            "We may update these terms. When we do, Waystage asks you to agree again before you continue.",
        ]),
    ]
}

/// Whether someone needs to agree to the terms (first use, or the terms changed).
public enum TermsAgreement {
    public static func isNeeded(_ preferences: UserPreferences) -> Bool {
        (preferences.acceptedTermsVersion ?? 0) < Disclosures.termsVersion
    }

    public static func accept(_ preferences: inout UserPreferences) {
        preferences.acceptedTermsVersion = Disclosures.termsVersion
    }
}
