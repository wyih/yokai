import XCTest
@testable import SyncCore

private final class DAVMock: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var responses: [(Int, [String: String], Data)] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request)
        let response = Self.responses.removeFirst(); Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: response.0, httpVersion: nil, headerFields: response.1)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.2)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class DAVClientTests: XCTestCase {
    private func client(_ responses: [(Int, [String: String], Data)]) -> DAVClient {
        DAVMock.requests = []; DAVMock.responses = responses
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DAVMock.self]
        return DAVClient(configuration: DAVConfiguration(url: "https://dav.example.test/", username: "test", directory: "personal/漫画"), password: "example", session: URLSession(configuration: configuration))
    }
    func testFirstSyncCreatesDirectoriesAndUsesCreateOnlyWrite() async throws {
        let client = client([(207, [:], Data()), (201, [:], Data()), (405, [:], Data()), (201, [:], Data()), (201, [:], Data()), (404, [:], Data()), (201, [:], Data())])
        let url = try await client.prepare()
        let (state, etag) = try await client.read(url)
        XCTAssertNil(etag)
        let written = try await client.write(state, to: url, etag: etag)
        XCTAssertTrue(written)
        XCTAssertEqual(DAVMock.requests.map(\.httpMethod), ["PROPFIND", "MKCOL", "MKCOL", "MKCOL", "MKCOL", "GET", "PUT"])
        XCTAssertEqual(DAVMock.requests.first?.value(forHTTPHeaderField: "Depth"), "0")
        XCTAssertEqual(DAVMock.requests.last?.value(forHTTPHeaderField: "If-None-Match"), "*")
        XCTAssertEqual(url.path, "/personal/漫画/Yokai/sync/library.json")
    }
    func testConcurrentWriteReturnsRetryWithoutOverwriting() async throws {
        let client = client([(200, ["ETag": "\"revision-1\""], try JSONEncoder().encode(ShelfState())), (412, [:], Data())])
        let url = URL(string: "https://dav.example.test/library.json")!
        let (state, etag) = try await client.read(url)
        let written = try await client.write(state, to: url, etag: etag)
        XCTAssertFalse(written)
        XCTAssertEqual(DAVMock.requests.last?.value(forHTTPHeaderField: "If-Match"), "\"revision-1\"")
    }
    func testWeakETagIsRejectedBeforeWriting() async throws {
        let client = client([(200, ["ETag": "W/\"revision\""], try JSONEncoder().encode(ShelfState()))])
        do { _ = try await client.read(URL(string: "https://dav.example.test/library.json")!); XCTFail("Weak ETag accepted") }
        catch SyncError.weakETag {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(DAVMock.requests.count, 1)
    }
}
