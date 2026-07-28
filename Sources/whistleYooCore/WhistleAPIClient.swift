import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

/// Type-safe transport for Whistle's official Local Agent API surface.
///
/// Methods deliberately mirror `bin/api.js`. Requests are sent to the UI URL
/// of the exact Whistle instance managed by WhistleYoo instead of asking the
/// global `w2` command to resolve an instance implicitly.
public actor WhistleAPIClient {
    public static let minimumAgentAPIVersion = SemanticVersion(2, 10, 7)

    private let baseURL: URL
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func getRootCA() async throws -> Data {
        try await data(path: "cgi-bin/rootca")
    }

    public func isEnabledHTTPS() async throws -> Bool {
        let result = try await json(path: "cgi-bin/is-enabled-https")
        return result.objectValue?["enabled"] == .bool(true)
    }

    public func setEnableHTTPS(_ enabled: Bool) async throws {
        _ = try await form(
            path: "cgi-bin/intercept-https-connects",
            fields: ["interceptHttpsConnects": enabled ? "1" : "0"]
        )
    }

    public func createFile(_ value: String) async throws -> JSONValue {
        try await json(path: "cgi-bin/temp/create", method: "POST", body: .object(["value": .string(value)]))
    }

    public func getFile(_ filepath: String) async throws -> JSONValue {
        try await json(path: "cgi-bin/temp/get", query: ["filename": filepath])
    }

    public func networkGetStatus() async throws -> JSONValue {
        try await json(path: "cgi-bin/status")
    }

    public func networkGetSessions(_ options: JSONValue = .object([:])) async throws -> JSONValue {
        try await json(path: "cgi-bin/sessions", method: "POST", body: options)
    }

    public func networkSaveSessions(_ sessions: JSONValue, name: String?) async throws -> JSONValue {
        var body: [String: JSONValue] = ["sessions": sessions]
        if let name { body["filename"] = .string(name) }
        return try await json(path: "cgi-bin/saved/save", method: "POST", body: .object(body))
    }

    public func networkGetSavedSessions(_ filename: String) async throws -> Data {
        try await data(path: "cgi-bin/saved/sessions", query: ["filename": filename])
    }

    public func networkGetFrames(_ options: JSONValue) async throws -> JSONValue {
        try await json(path: "cgi-bin/frames", method: "POST", body: options)
    }

    public func networkRequest(_ options: JSONValue) async throws -> JSONValue {
        try await json(path: "cgi-bin/composer", method: "POST", body: options)
    }

    public func networkAbort(_ reqID: String) async throws {
        _ = try await form(path: "cgi-bin/abort", fields: ["list": reqID])
    }

    public func rulesGetStatus() async throws -> JSONValue {
        try await json(path: "cgi-bin/rules/status")
    }

    public func rulesTurnOff() async throws {
        _ = try await form(path: "cgi-bin/rules/disable-all-rules", fields: ["disabledAllRules": "1"])
    }

    public func rulesTurnOn() async throws {
        _ = try await form(path: "cgi-bin/rules/disable-all-rules", fields: ["disabledAllRules": "0"])
    }

    public func rulesIsMultiSelect() async throws -> Bool {
        let result = try await json(path: "cgi-bin/rules/is-multi-select")
        return result.objectValue?["multiSelect"] == .bool(true)
    }

    public func rulesSetMultiSelect(_ enabled: Bool) async throws {
        _ = try await form(
            path: "cgi-bin/rules/allow-multiple-choice",
            fields: ["allowMultipleChoice": enabled ? "1" : "0"]
        )
    }

    public func rulesSetLaterFirst(_ enabled: Bool) async throws {
        _ = try await form(
            path: "cgi-bin/rules/enable-back-rules-first",
            fields: ["backRulesFirst": enabled ? "1" : "0"]
        )
    }

    public func rulesGetList() async throws -> JSONValue {
        try await json(path: "cgi-bin/rules/list")
    }

    public func rulesGet(_ name: String) async throws -> JSONValue {
        try await json(path: "cgi-bin/rules/value", query: ["name": name])
    }

    public func rulesAdd(name: String, value: String, selected: Bool) async throws {
        _ = try await form(path: "cgi-bin/rules/add", fields: ["name": name, "value": value])
        try await (selected ? rulesSelect(name) : rulesUnselect(name))
    }

    public func rulesSelect(_ name: String) async throws {
        _ = try await form(path: "cgi-bin/rules/select", fields: ["name": name])
    }

    public func rulesUnselect(_ name: String) async throws {
        _ = try await form(path: "cgi-bin/rules/unselect", fields: ["name": name])
    }

    public func rulesMoveToTop(_ name: String) async throws {
        _ = try await form(path: "cgi-bin/rules/move-top", fields: ["name": name])
    }

    public func valuesGetList() async throws -> JSONValue {
        try await json(path: "cgi-bin/values/list")
    }

    public func valuesGet(_ name: String) async throws -> JSONValue {
        try await json(path: "cgi-bin/values/value", query: ["name": name])
    }

    public func valuesAdd(name: String, value: String) async throws {
        _ = try await form(path: "cgi-bin/values/add", fields: ["name": name, "value": value])
    }

    public func pluginsGetStatus() async throws -> JSONValue {
        try await json(path: "cgi-bin/plugins/status")
    }

    public func pluginsTurnOff() async throws {
        _ = try await form(path: "cgi-bin/plugins/disable-all-plugins", fields: ["disabledAllPlugins": "1"])
    }

    public func pluginsTurnOn() async throws {
        _ = try await form(path: "cgi-bin/plugins/disable-all-plugins", fields: ["disabledAllPlugins": "0"])
    }

    public func pluginsGetList() async throws -> JSONValue {
        try await json(path: "cgi-bin/plugins/list")
    }

    public func pluginsGet(_ name: String) async throws -> JSONValue {
        try await json(path: "cgi-bin/plugins/plugin", query: ["name": name])
    }

    public func pluginsSelect(_ name: String) async throws {
        _ = try await form(path: "cgi-bin/plugins/disable-plugin", fields: ["name": name, "disabled": "0"])
    }

    public func pluginsUnselect(_ name: String) async throws {
        _ = try await form(path: "cgi-bin/plugins/disable-plugin", fields: ["name": name, "disabled": "1"])
    }

    private func form(path: String, fields: [String: String]) async throws -> JSONValue {
        var components = URLComponents()
        components.queryItems = fields.keys.sorted().map {
            URLQueryItem(name: $0, value: fields[$0])
        }
        var request = request(path: path)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        return try await executeJSON(request)
    }

    private func json(
        path: String,
        method: String = "GET",
        query: [String: String] = [:],
        body: JSONValue? = nil
    ) async throws -> JSONValue {
        var request = request(path: path, query: query)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }
        return try await executeJSON(request)
    }

    private func data(path: String, query: [String: String] = [:]) async throws -> Data {
        try await execute(request(path: path, query: query))
    }

    private func request(path: String, query: [String: String] = [:]) -> URLRequest {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty {
            components.queryItems = query.keys.sorted().map {
                URLQueryItem(name: $0, value: query[$0])
            }
        }
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.setValue("WhistleYoo-MCP/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func executeJSON(_ request: URLRequest) async throws -> JSONValue {
        let responseData = try await execute(request)
        guard !responseData.isEmpty else { return .object(["ec": .number(0)]) }
        do {
            return try decoder.decode(JSONValue.self, from: responseData)
        } catch {
            throw WhistleYooError.invalidResponse(
                String(data: responseData, encoding: .utf8) ?? error.localizedDescription
            )
        }
    }

    private func execute(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw WhistleYooError.invalidResponse(
                String(data: data, encoding: .utf8) ?? "Whistle API returned an invalid response."
            )
        }
        if let result = try? decoder.decode(JSONValue.self, from: data),
           case .object(let object) = result,
           case .number(let code)? = object["ec"],
           code != 0 {
            let message = object["em"]?.stringValue ?? "Whistle API operation failed."
            throw WhistleYooError.invalidResponse(message)
        }
        return data
    }
}
