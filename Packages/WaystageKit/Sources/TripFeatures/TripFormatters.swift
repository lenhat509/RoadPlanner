import Foundation
import TripModels

/// Locale-aware formatting for durations, distances, money and local times.
public struct TripFormatters: Sendable {
    public var locale: Locale

    public init(locale: Locale = .current) {
        self.locale = locale
    }

    /// "45 min", "5 h 20 min", "3 d 4 h".
    public func duration(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(0, Int((seconds / 60).rounded()))
        let days = totalMinutes / 1_440, hours = (totalMinutes % 1_440) / 60, minutes = totalMinutes % 60
        if days > 0 { return hours > 0 ? "\(days) d \(hours) h" : "\(days) d" }
        if hours > 0 { return minutes > 0 ? "\(hours) h \(minutes) min" : "\(hours) h" }
        return "\(minutes) min"
    }

    /// "2,631 mi", "12.4 mi", "850 ft".
    public func distance(_ meters: Double) -> String {
        let miles = Units.miles(fromMeters: max(0, meters))
        if miles >= 100 { return "\(number(miles, fractionDigits: 0)) mi" }
        if miles >= 0.1 { return "\(number(miles, fractionDigits: 1)) mi" }
        return "\(Int((max(0, meters) / Units.metersPerFoot / 10).rounded()) * 10) ft"
    }

    /// "$1,234" or, when `precise`, "$3.09".
    public func currency(_ value: Double, precise: Bool = false) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = precise ? 2 : 0
        formatter.maximumFractionDigits = precise ? 2 : 0
        let rounded = precise ? (value * 100).rounded() / 100 : value.rounded()
        return formatter.string(from: NSNumber(value: rounded)) ?? String(format: "$%.2f", rounded)
    }

    /// Local clock time at the place, e.g. "8:05 PM".
    public func clockTime(_ date: Date, utcOffsetSeconds: Int) -> String {
        formatted(date, utcOffsetSeconds: utcOffsetSeconds, template: "jmm")
    }

    /// "Mon, May 3".
    public func dayTitle(_ date: Date, utcOffsetSeconds: Int) -> String {
        formatted(date, utcOffsetSeconds: utcOffsetSeconds, template: "EEEMMMd")
    }

    /// "Mon, May 3, 8:05 PM".
    public func dateTime(_ date: Date, utcOffsetSeconds: Int) -> String {
        formatted(date, utcOffsetSeconds: utcOffsetSeconds, template: "EEEMMMdjmm")
    }

    public func gallons(_ value: Double) -> String { "\(number(value, fractionDigits: 1)) gal" }

    private func number(_ value: Double, fractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        // Round explicitly: some Foundation implementations ignore maximumFractionDigits.
        let scale = pow(10, Double(fractionDigits))
        return formatter.string(from: NSNumber(value: (value * scale).rounded() / scale)) ?? "\(value)"
    }

    private func formatted(_ date: Date, utcOffsetSeconds: Int, template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone(secondsFromGMT: utcOffsetSeconds)
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}
