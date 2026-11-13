import Foundation

/// Google's Encoded Polyline Algorithm Format (precision 1e-5).
///
/// See https://developers.google.com/maps/documentation/utilities/polylinealgorithm
public enum PolylineCodec {
    public enum DecodingError: Error, Equatable {
        case truncated
        case invalidCharacter
    }

    private static let precision = 1e5

    /// Encodes coordinates into a polyline string.
    public static func encode(_ coordinates: [GeoCoordinate]) -> String {
        var output = ""
        output.reserveCapacity(coordinates.count * 8)
        var previousLat = 0, previousLon = 0
        for coordinate in coordinates {
            let lat = Int((coordinate.latitude * precision).rounded())
            let lon = Int((coordinate.longitude * precision).rounded())
            encodeValue(lat - previousLat, into: &output)
            encodeValue(lon - previousLon, into: &output)
            previousLat = lat
            previousLon = lon
        }
        return output
    }

    /// Decodes a polyline string into coordinates.
    public static func decode(_ encoded: String) throws -> [GeoCoordinate] {
        let bytes = Array(encoded.utf8)
        var index = 0
        var lat = 0, lon = 0
        var coordinates: [GeoCoordinate] = []
        coordinates.reserveCapacity(bytes.count / 4)
        while index < bytes.count {
            lat += try decodeValue(bytes, &index)
            lon += try decodeValue(bytes, &index)
            coordinates.append(GeoCoordinate(latitude: Double(lat) / precision, longitude: Double(lon) / precision))
        }
        return coordinates
    }

    private static func encodeValue(_ value: Int, into output: inout String) {
        var shifted = value < 0 ? ~(value << 1) : (value << 1)
        while shifted >= 0x20 {
            output.unicodeScalars.append(UnicodeScalar(UInt8((0x20 | (shifted & 0x1F)) + 63)))
            shifted >>= 5
        }
        output.unicodeScalars.append(UnicodeScalar(UInt8(shifted + 63)))
    }

    private static func decodeValue(_ bytes: [UInt8], _ index: inout Int) throws -> Int {
        var result = 0
        var shift = 0
        while true {
            guard index < bytes.count else { throw DecodingError.truncated }
            let raw = Int(bytes[index])
            guard raw >= 63, raw <= 126 else { throw DecodingError.invalidCharacter }
            let chunk = raw - 63
            index += 1
            result |= (chunk & 0x1F) << shift
            shift += 5
            if chunk < 0x20 { break }
        }
        return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
    }
}
