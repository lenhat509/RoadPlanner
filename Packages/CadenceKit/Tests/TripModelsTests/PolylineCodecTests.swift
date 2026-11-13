import Foundation
import Testing
@testable import TripModels

@Suite("PolylineCodec")
struct PolylineCodecTests {
    /// Reference example from Google's "Encoded Polyline Algorithm Format" documentation.
    private let referenceEncoded = "_p~iF~ps|U_ulLnnqC_mqNvxq`@"
    private let referencePoints = [
        GeoCoordinate(latitude: 38.5, longitude: -120.2),
        GeoCoordinate(latitude: 40.7, longitude: -120.95),
        GeoCoordinate(latitude: 43.252, longitude: -126.453),
    ]

    @Test("Decodes Google's reference polyline")
    func decodeReference() throws {
        let decoded = try PolylineCodec.decode(referenceEncoded)
        #expect(decoded.count == 3)
        for (actual, expected) in zip(decoded, referencePoints) {
            #expect(abs(actual.latitude - expected.latitude) < 1e-5)
            #expect(abs(actual.longitude - expected.longitude) < 1e-5)
        }
    }

    @Test("Encodes Google's reference points")
    func encodeReference() {
        #expect(PolylineCodec.encode(referencePoints) == referenceEncoded)
    }

    @Test("Round-trips arbitrary coordinates at 1e-5 precision")
    func roundTrip() throws {
        let points = (0..<200).map { index in
            GeoCoordinate(
                latitude: 25 + Double(index) * 0.0731,
                longitude: -124 + Double(index) * 0.2917
            )
        }
        let decoded = try PolylineCodec.decode(PolylineCodec.encode(points))
        #expect(decoded.count == points.count)
        for (actual, expected) in zip(decoded, points) {
            #expect(abs(actual.latitude - expected.latitude) < 1e-5)
            #expect(abs(actual.longitude - expected.longitude) < 1e-5)
        }
    }

    @Test("Empty input decodes to an empty path")
    func emptyInput() throws {
        #expect(try PolylineCodec.decode("").isEmpty)
        #expect(PolylineCodec.encode([]).isEmpty)
    }

    @Test("Truncated input is rejected")
    func truncatedInput() {
        #expect(throws: PolylineCodec.DecodingError.self) {
            _ = try PolylineCodec.decode("_p~iF~ps|U_")
        }
    }
}
