import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A transport-agnostic HTTP request.
public struct HTTPRequest: Hashable, Sendable {
    public enum Method: String, Sendable { case get = "GET", post = "POST" }

    public var method: Method
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: Method, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Hashable, Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

/// Sends HTTP requests. Implemented by `URLSessionTransport` in production and by fakes in tests.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// Errors surfaced by service adapters.
public enum ServiceError: Error, Equatable, Sendable {
    case missingAPIKey
    case invalidRequest(String)
    case unauthorized(String)
    case rateLimited
    case server(status: Int, message: String)
    case decoding(String)
    case transport(String)

    /// Transient failures worth retrying.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .transport: true
        case let .server(status, _): status >= 500
        default: false
        }
    }
}

/// Production transport backed by `URLSession`.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    private let timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = 20) {
        self.session = session
        self.timeout = timeout
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: timeout)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        do {
            let (data, response) = try await data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw ServiceError.transport("Not an HTTP response") }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let key = key as? String, let value = value as? String { headers[key] = value }
            }
            return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
        } catch let error as ServiceError {
            throw error
        } catch {
            throw ServiceError.transport(error.localizedDescription)
        }
    }

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let response {
                    continuation.resume(returning: (data ?? Data(), response))
                } else {
                    continuation.resume(throwing: ServiceError.transport("Empty response"))
                }
            }
            task.resume()
        }
    }
}

/// Retries transient failures (429, 5xx, network) with exponential backoff.
public struct RetryingTransport: HTTPTransport {
    private let base: any HTTPTransport
    private let maxRetries: Int
    private let initialDelay: TimeInterval
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        _ base: any HTTPTransport,
        maxRetries: Int = 2,
        initialDelay: TimeInterval = 0.5,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }
    ) {
        self.base = base
        self.maxRetries = maxRetries
        self.initialDelay = initialDelay
        self.sleep = sleep
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var attempt = 0
        while true {
            do {
                let response = try await base.send(request)
                let retryable = response.statusCode == 429 || response.statusCode >= 500
                if retryable && attempt < maxRetries {
                    try await sleep(initialDelay * pow(2, Double(attempt)))
                    attempt += 1
                    continue
                }
                return response
            } catch let error as ServiceError where error.isRetryable && attempt < maxRetries {
                try await sleep(initialDelay * pow(2, Double(attempt)))
                attempt += 1
            }
        }
    }
}

extension HTTPResponse {
    /// Throws a `ServiceError` for non-2xx responses, extracting Google-style error messages.
    func validated() throws -> HTTPResponse {
        guard !(200..<300).contains(statusCode) else { return self }
        let message = GoogleErrorEnvelope.message(from: body) ?? String(decoding: body.prefix(300), as: UTF8.self)
        switch statusCode {
        case 400: throw ServiceError.invalidRequest(message)
        case 401, 403: throw ServiceError.unauthorized(message)
        case 429: throw ServiceError.rateLimited
        default: throw ServiceError.server(status: statusCode, message: message)
        }
    }
}

/// `{"error": {"code": 400, "message": "...", "status": "INVALID_ARGUMENT"}}`
struct GoogleErrorEnvelope: Decodable {
    struct Body: Decodable {
        var message: String?
        var status: String?
    }

    var error: Body

    static func message(from data: Data) -> String? {
        guard let envelope = try? JSONDecoder().decode(GoogleErrorEnvelope.self, from: data) else { return nil }
        return [envelope.error.status, envelope.error.message].compactMap { $0 }.joined(separator: ": ")
    }
}

enum JSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ServiceError.decoding(String(describing: error))
        }
    }
}
