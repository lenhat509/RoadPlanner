import Foundation
import TripServices

/// Records requests and replies with canned responses matched by URL substring.
public final class StubHTTPTransport: HTTPTransport, @unchecked Sendable {
    public struct Route: Sendable {
        public var urlContains: String
        public var response: HTTPResponse
    }

    private let lock = NSLock()
    private var routes: [Route] = []
    private var queued: [HTTPResponse] = []
    private var recorded: [HTTPRequest] = []
    private var error: (any Error & Sendable)?

    public init() {}

    /// Responds to any request whose URL contains `urlContains`.
    public func stub(_ urlContains: String, status: Int = 200, body: Data) {
        lock.withLock { routes.append(Route(urlContains: urlContains, response: HTTPResponse(statusCode: status, body: body))) }
    }

    /// Responses returned in order before falling back to URL stubs.
    public func enqueue(status: Int, body: Data = Data()) {
        lock.withLock { queued.append(HTTPResponse(statusCode: status, body: body)) }
    }

    public func fail(with error: any Error & Sendable) {
        lock.withLock { self.error = error }
    }

    public var requests: [HTTPRequest] { lock.withLock { recorded } }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try lock.withLock {
            recorded.append(request)
            if let error { throw error }
            if !queued.isEmpty { return queued.removeFirst() }
            if let route = routes.last(where: { request.url.absoluteString.contains($0.urlContains) }) {
                return route.response
            }
            return HTTPResponse(statusCode: 404, body: Data("{\"error\":{\"message\":\"No stub\"}}".utf8))
        }
    }
}
