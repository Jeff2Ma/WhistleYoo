import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import whistleYooCore

final class WhistleAPIClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocolStub.handler = nil
    }

    func testOfficialNetworkNamesMapToWhistleEndpoints() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/cgi-bin/status":
                return Self.response(for: request, json: #"{"version":"2.10.7"}"#)
            case "/cgi-bin/sessions":
                XCTAssertEqual(request.httpMethod, "POST")
                let body = try Self.bodyData(for: request)
                let object = try JSONDecoder().decode(JSONValue.self, from: body)
                XCTAssertEqual(object.objectValue?["latest"], .bool(true))
                return Self.response(for: request, json: #"[]"#)
            default:
                XCTFail("Unexpected endpoint \(request.url?.path ?? "")")
                return Self.response(for: request, status: 404, json: "{}")
            }
        }

        let status = try await client.networkGetStatus()
        XCTAssertEqual(status.objectValue?["version"], .string("2.10.7"))
        let sessions = try await client.networkGetSessions(.object(["latest": .bool(true)]))
        XCTAssertEqual(sessions, .array([]))
    }

    func testRulesAddUsesOfficialAddAndSelectEndpoints() async throws {
        let requests = RequestRecorder()
        let client = makeClient { request in
            let body = try Self.bodyData(for: request)
            requests.append(
                path: request.url?.path ?? "",
                body: String(decoding: body, as: UTF8.self)
            )
            return Self.response(for: request, json: #"{"ec":0}"#)
        }

        try await client.rulesAdd(name: "Agent Rule", value: "example.test host://127.0.0.1", selected: true)
        let recorded = requests.snapshot()
        XCTAssertEqual(recorded.map(\.path), ["/cgi-bin/rules/add", "/cgi-bin/rules/select"])
        let form = URLComponents(string: "?\(recorded[0].body)")?.queryItems ?? []
        XCTAssertEqual(form.first(where: { $0.name == "name" })?.value, "Agent Rule")
        XCTAssertEqual(
            form.first(where: { $0.name == "value" })?.value,
            "example.test host://127.0.0.1"
        )
    }

    func testWhistleErrorCodeBecomesInvalidResponse() async {
        let client = makeClient { request in
            Self.response(for: request, json: #"{"ec":2,"em":"denied"}"#)
        }

        do {
            try await client.rulesTurnOn()
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "denied")
        }
    }

    private func makeClient(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> WhistleAPIClient {
        URLProtocolStub.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return WhistleAPIClient(
            baseURL: URL(string: "http://127.0.0.1:8900/")!,
            session: URLSession(configuration: configuration)
        )
    }

    private static func response(
        for request: URLRequest,
        status: Int = 200,
        json: String
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!,
            Data(json.utf8)
        )
    }

    private static func bodyData(for request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            throw WhistleYooError.invalidResponse("The test request has no body.")
        }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else {
                throw stream.streamError ?? WhistleYooError.invalidResponse("Unable to read request body.")
            }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
}

private final class RequestRecorder: @unchecked Sendable {
    struct Entry {
        let path: String
        let body: String
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func append(path: String, body: String) {
        lock.lock()
        entries.append(Entry(path: path, body: body))
        lock.unlock()
    }

    func snapshot() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
