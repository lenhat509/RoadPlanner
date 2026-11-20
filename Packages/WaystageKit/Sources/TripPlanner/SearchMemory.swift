import Foundation
import TripModels

/// Along-route searches made earlier in this app session, so planning again (an edited plan, the
/// rest of a trip) doesn't pay again for road already searched. Kept in memory only, for a short
/// time, and never written to disk (see docs/COMPLIANCE.md).
actor SearchMemory {
    struct Entry: Sendable {
        var search: AlongRouteSearch
        var places: [FoundPlace]
        var madeAt: Date
    }

    private let lifetime: TimeInterval
    private let capacity: Int
    private var entries: [Entry] = []

    init(lifetime: TimeInterval, capacity: Int) {
        self.lifetime = lifetime
        self.capacity = capacity
    }

    /// The searches still fresh at `now`, oldest first.
    func recent(now: Date) -> [Entry] {
        entries.removeAll { now.timeIntervalSince($0.madeAt) > lifetime }
        return entries
    }

    /// Remembers successful searches; the oldest go first when full.
    func remember(_ new: [Entry]) {
        guard lifetime > 0, capacity > 0 else { return }
        entries += new
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }
}
