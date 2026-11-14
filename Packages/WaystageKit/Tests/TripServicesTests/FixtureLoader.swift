import Foundation

enum FixtureLoader {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw FixtureError.missing(name)
        }
        return try Data(contentsOf: url)
    }

    enum FixtureError: Error { case missing(String) }
}

extension Data {
    /// Decodes the body of an HTTP request as a JSON dictionary.
    func jsonObject() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: self) as? [String: Any] ?? [:]
    }
}
