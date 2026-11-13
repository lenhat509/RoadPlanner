import Foundation
import TripModels

/// Stores the active trip (auto-saved progress) and saved itineraries.
public protocol TripRepository: Sendable {
    func loadActiveTrip() async throws -> ActiveTrip?
    func saveActiveTrip(_ trip: ActiveTrip) async throws
    func clearActiveTrip() async throws
    /// Saved itineraries, newest first.
    func savedItineraries() async throws -> [Itinerary]
    func saveItinerary(_ itinerary: Itinerary) async throws
    func deleteItinerary(id: UUID) async throws
}

/// Versioned on-disk envelope so future releases can migrate old files.
struct StoredDocument<Payload: Codable>: Codable {
    static var currentVersion: Int { 1 }
    var schemaVersion: Int
    var payload: Payload
}

public enum RepositoryError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
}

/// JSON files in Application Support, written atomically (crash-safe) and excluded from
/// iCloud backups only when the caller chooses so. All access is serialized by the actor.
public actor FileTripRepository: TripRepository {
    private let directory: URL
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    public init(directory: URL) {
        self.directory = directory
    }

    /// `Application Support/Cadence` (created on first write).
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Cadence", isDirectory: true)
    }

    private var activeTripURL: URL { directory.appendingPathComponent("active-trip.json") }
    private var itinerariesDirectory: URL { directory.appendingPathComponent("itineraries", isDirectory: true) }

    public func loadActiveTrip() async throws -> ActiveTrip? {
        try read(ActiveTrip.self, from: activeTripURL)
    }

    public func saveActiveTrip(_ trip: ActiveTrip) async throws {
        try write(trip, to: activeTripURL)
    }

    public func clearActiveTrip() async throws {
        if fileManager.fileExists(atPath: activeTripURL.path) {
            try fileManager.removeItem(at: activeTripURL)
        }
    }

    public func savedItineraries() async throws -> [Itinerary] {
        guard fileManager.fileExists(atPath: itinerariesDirectory.path) else { return [] }
        let files = try fileManager.contentsOfDirectory(at: itinerariesDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        // Skip unreadable files rather than failing the whole list.
        return files.compactMap { try? read(Itinerary.self, from: $0) }.sorted { $0.createdAt > $1.createdAt }
    }

    public func saveItinerary(_ itinerary: Itinerary) async throws {
        try write(itinerary, to: itinerariesDirectory.appendingPathComponent("\(itinerary.id.uuidString).json"))
    }

    public func deleteItinerary(id: UUID) async throws {
        let url = itinerariesDirectory.appendingPathComponent("\(id.uuidString).json")
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    private func read<T: Codable>(_ type: T.Type, from url: URL) throws -> T? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let document = try decoder.decode(StoredDocument<T>.self, from: data)
        guard document.schemaVersion <= StoredDocument<T>.currentVersion else {
            throw RepositoryError.unsupportedSchemaVersion(document.schemaVersion)
        }
        return document.payload
    }

    private func write<T: Codable>(_ value: T, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(StoredDocument(schemaVersion: StoredDocument<T>.currentVersion, payload: value))
        try data.write(to: url, options: [.atomic])
    }
}

/// Volatile repository for previews, tests and UI-test sandbox mode.
public actor InMemoryTripRepository: TripRepository {
    private var active: ActiveTrip?
    private var itineraries: [UUID: Itinerary] = [:]
    /// Number of times the active trip was saved (lets tests assert auto-save).
    public private(set) var activeSaveCount = 0

    public init(active: ActiveTrip? = nil, itineraries: [Itinerary] = []) {
        self.active = active
        self.itineraries = Dictionary(uniqueKeysWithValues: itineraries.map { ($0.id, $0) })
    }

    public func loadActiveTrip() async throws -> ActiveTrip? { active }

    public func saveActiveTrip(_ trip: ActiveTrip) async throws {
        active = trip
        activeSaveCount += 1
    }

    public func clearActiveTrip() async throws { active = nil }

    public func savedItineraries() async throws -> [Itinerary] {
        itineraries.values.sorted { $0.createdAt > $1.createdAt }
    }

    public func saveItinerary(_ itinerary: Itinerary) async throws { itineraries[itinerary.id] = itinerary }

    public func deleteItinerary(id: UUID) async throws { itineraries[id] = nil }
}
