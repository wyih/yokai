import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct DAVConfiguration: Codable, Equatable {
    var url = ""
    var username = ""
    var directory = ""
    var automatic = true

    func baseURL() throws -> URL {
        guard let base = URL(string: url), base.scheme == "https", base.host != nil,
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
              !directory.hasPrefix("/"), !directory.contains("\\"),
              !directory.contains("%"), !directory.contains("?"), !directory.contains("#"),
              !directory.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              directory.isEmpty || directory.components(separatedBy: "/").allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw SyncError.invalidURL }
        return base
    }

    var identity: String { url + "\n" + username + "\n" + directory }
}

private final class NoDAVRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor DAVClient {
    private let configuration: DAVConfiguration
    private let password: String
    private let session: URLSession

    init(configuration: DAVConfiguration, password: String, session: URLSession? = nil) {
        self.configuration = configuration; self.password = password
        self.session = session ?? URLSession(configuration: .ephemeral, delegate: NoDAVRedirect(), delegateQueue: nil)
    }

    private func request(_ url: URL, method: String, body: Data? = nil, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue("Yokai/0.1", forHTTPHeaderField: "User-Agent")
        if !configuration.username.isEmpty {
            request.setValue("Basic " + Data((configuration.username + ":" + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        }
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw SyncError.server(0) }
        return (data, response)
    }

    func prepare() async throws -> URL {
        var current = try configuration.baseURL()
        let body = Data("<d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/></d:prop></d:propfind>".utf8)
        let (_, response) = try await request(current, method: "PROPFIND", body: body,
            headers: ["Depth": "0", "Content-Type": "application/xml"])
        guard response.statusCode == 207 else { throw SyncError.server(response.statusCode) }
        for part in configuration.directory.split(separator: "/").map(String.init) + ["Yokai", "sync"] {
            current = current.appendingPathComponent(part, isDirectory: true)
            let (_, response) = try await request(current, method: "MKCOL")
            guard [201, 405].contains(response.statusCode) else { throw SyncError.server(response.statusCode) }
        }
        return current.appendingPathComponent("library.json")
    }

    func read(_ url: URL) async throws -> (ShelfState, String?) {
        let (data, response) = try await request(url, method: "GET")
        if response.statusCode == 404 { return (ShelfState(), nil) }
        guard response.statusCode == 200 else { throw SyncError.server(response.statusCode) }
        guard let etag = response.value(forHTTPHeaderField: "ETag"), etag.hasPrefix("\""), etag.hasSuffix("\"") else { throw SyncError.weakETag }
        let state = try JSONDecoder().decode(ShelfState.self, from: data)
        try ShelfMerge.validate(state)
        return (state, etag)
    }

    func write(_ state: ShelfState, to url: URL, etag: String?) async throws -> Bool {
        let (_, response) = try await request(url, method: "PUT", body: JSONEncoder().encode(state),
            headers: ["Content-Type": "application/json", etag == nil ? "If-None-Match" : "If-Match": etag ?? "*"])
        if response.statusCode == 412 { return false }
        guard (200..<300).contains(response.statusCode) else { throw SyncError.server(response.statusCode) }
        return true
    }
}
