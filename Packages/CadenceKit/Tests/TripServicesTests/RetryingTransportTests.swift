import Foundation
import Testing
import TripSandbox
@testable import TripServices

@Suite("RetryingTransport")
struct RetryingTransportTests {
    private let request = HTTPRequest(method: .get, url: URL(string: "https://example.com")!)

    actor SleepLog {
        var delays: [TimeInterval] = []
        func append(_ delay: TimeInterval) { delays.append(delay) }
    }

    @Test("Retries 429 and 5xx with exponential backoff, then succeeds")
    func retriesTransientFailures() async throws {
        let stub = StubHTTPTransport()
        stub.enqueue(status: 503)
        stub.enqueue(status: 429)
        stub.enqueue(status: 200, body: Data("ok".utf8))
        let log = SleepLog()
        let transport = RetryingTransport(stub, maxRetries: 2, initialDelay: 0.5) { await log.append($0) }
        let response = try await transport.send(request)
        #expect(response.statusCode == 200)
        #expect(stub.requests.count == 3)
        #expect(await log.delays == [0.5, 1.0])
    }

    @Test("Gives up after the retry budget and returns the last response")
    func givesUp() async throws {
        let stub = StubHTTPTransport()
        for _ in 0..<5 { stub.enqueue(status: 500) }
        let transport = RetryingTransport(stub, maxRetries: 2) { _ in }
        #expect(try await transport.send(request).statusCode == 500)
        #expect(stub.requests.count == 3)
    }

    @Test("Does not retry client errors")
    func noRetryOnClientError() async throws {
        let stub = StubHTTPTransport()
        stub.enqueue(status: 400)
        stub.enqueue(status: 200)
        let transport = RetryingTransport(stub) { _ in }
        #expect(try await transport.send(request).statusCode == 400)
        #expect(stub.requests.count == 1)
    }

    @Test("Retries transport errors")
    func retriesTransportErrors() async {
        let stub = StubHTTPTransport()
        stub.fail(with: ServiceError.transport("offline"))
        let transport = RetryingTransport(stub, maxRetries: 1) { _ in }
        await #expect(throws: ServiceError.transport("offline")) { _ = try await transport.send(request) }
        #expect(stub.requests.count == 2)
    }
}
