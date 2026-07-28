import Foundation
import XCTest
@testable import whistleYooApp
@testable import whistleYooCore

final class MCPHTTPServerTests: XCTestCase {
    func testMCPEnvironmentDetailsIncludeDetectedVersionsAndExecutablePaths() throws {
        let environment = EnvironmentInfo(
            nodeURL: URL(fileURLWithPath: "/opt/example/bin/node"),
            npmURL: URL(fileURLWithPath: "/opt/example/bin/npm"),
            whistleURL: URL(fileURLWithPath: "/opt/example/bin/w2"),
            nodeVersion: SemanticVersion(22, 4, 1),
            whistleVersion: SemanticVersion(2, 10, 7)
        )

        let details = MCPToolBackend.environmentDetails(.ready(environment))

        XCTAssertEqual(details["environment"], .string("ready"))
        XCTAssertEqual(details["nodeExecutable"], .string("/opt/example/bin/node"))
        XCTAssertEqual(details["nodeVersion"], .string("22.4.1"))
        XCTAssertEqual(details["whistleExecutable"], .string("/opt/example/bin/w2"))
        XCTAssertEqual(details["whistleVersion"], .string("2.10.7"))
    }

    func testUnsupportedWhistleVersionMessageIncludesDetectedVersionAndPath() {
        let environment = EnvironmentInfo(
            nodeURL: URL(fileURLWithPath: "/opt/example/bin/node"),
            npmURL: nil,
            whistleURL: URL(fileURLWithPath: "/old/node/bin/w2"),
            nodeVersion: SemanticVersion(20, 0, 0),
            whistleVersion: SemanticVersion(2, 10, 6)
        )

        let message = MCPToolBackend.unsupportedWhistleVersionMessage(environment)

        XCTAssertTrue(message.contains("Detected Whistle 2.10.6"))
        XCTAssertTrue(message.contains("/old/node/bin/w2"))
        XCTAssertTrue(message.contains("Whistle 2.10.7 or later is required"))
    }

    @MainActor
    func testLocalHTTPTransportRequiresTokenAndListsOfficialTools() async throws {
        let port = 18_901
        guard PortChecker().isAvailable(port: port, host: "127.0.0.1") else {
            throw XCTSkip("Port \(port) is in use.")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let tokenStore = MCPTokenStore(fileURL: directory.appendingPathComponent("token"))
        let token = try tokenStore.loadOrCreate()
        let state = AppStateController(
            settingsStore: SettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
        )
        let coordinator = MCPHTTPServerCoordinator(state: state, tokenStore: tokenStore)
        await coordinator.apply(MCPSettings(enabled: true, port: port))

        do {
            let initialize = try request(
                port: port,
                token: nil,
                id: 1,
                method: "initialize",
                params: [
                    "protocolVersion": "2025-06-18",
                    "capabilities": [:],
                    "clientInfo": ["name": "test", "version": "1"]
                ]
            )
            let (_, unauthorizedResponse) = try await URLSession.shared.data(for: initialize)
            XCTAssertEqual((unauthorizedResponse as? HTTPURLResponse)?.statusCode, 401)

            let (initializeData, initializeResponse) = try await URLSession.shared.data(
                for: request(
                    port: port,
                    token: token,
                    id: 1,
                    method: "initialize",
                    params: [
                        "protocolVersion": "2025-06-18",
                        "capabilities": [:],
                        "clientInfo": ["name": "test", "version": "1"]
                    ]
                )
            )
            XCTAssertEqual((initializeResponse as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertNotNil(try JSONSerialization.jsonObject(with: initializeData))

            let (toolsData, toolsResponse) = try await URLSession.shared.data(
                for: request(port: port, token: token, id: 2, method: "tools/list", params: [:])
            )
            XCTAssertEqual((toolsResponse as? HTTPURLResponse)?.statusCode, 200)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: toolsData) as? [String: Any]
            )
            let result = try XCTUnwrap(object["result"] as? [String: Any])
            let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
            let names = Set(tools.compactMap { $0["name"] as? String })
            XCTAssertTrue(names.contains("network_get_sessions"))
            XCTAssertTrue(names.contains("app_get_status"))

            let (callData, callResponse) = try await URLSession.shared.data(
                for: request(
                    port: port,
                    token: token,
                    id: 3,
                    method: "tools/call",
                    params: ["name": "app_get_status", "arguments": [:]]
                )
            )
            XCTAssertEqual((callResponse as? HTTPURLResponse)?.statusCode, 200)
            let callObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: callData) as? [String: Any]
            )
            let callResult = try XCTUnwrap(callObject["result"] as? [String: Any])
            XCTAssertEqual(callResult["isError"] as? Bool, false)
        } catch {
            await coordinator.stop()
            throw error
        }
        await coordinator.stop()
    }

    @MainActor
    func testLocalHTTPTransportSkipsAuthorizationWhenAuthenticationIsDisabled() async throws {
        let port = 18_902
        guard PortChecker().isAvailable(port: port, host: "127.0.0.1") else {
            throw XCTSkip("Port \(port) is in use.")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let state = AppStateController(
            settingsStore: SettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
        )
        let coordinator = MCPHTTPServerCoordinator(
            state: state,
            tokenStore: MCPTokenStore(fileURL: directory.appendingPathComponent("token"))
        )
        await coordinator.apply(MCPSettings(
            enabled: true,
            authenticationEnabled: false,
            port: port
        ))

        do {
            let (withoutHeaderData, withoutHeaderResponse) = try await URLSession.shared.data(
                for: request(
                    port: port,
                    token: nil,
                    id: 1,
                    method: "initialize",
                    params: [
                        "protocolVersion": "2025-06-18",
                        "capabilities": [:],
                        "clientInfo": ["name": "test", "version": "1"]
                    ]
                )
            )
            XCTAssertEqual((withoutHeaderResponse as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertNotNil(try JSONSerialization.jsonObject(with: withoutHeaderData))

            var arbitraryHeaderRequest = try request(
                port: port,
                token: nil,
                id: 2,
                method: "tools/list",
                params: [:]
            )
            arbitraryHeaderRequest.setValue(
                "any authentication string",
                forHTTPHeaderField: "Authorization"
            )
            let (arbitraryHeaderData, arbitraryHeaderResponse) = try await URLSession.shared.data(
                for: arbitraryHeaderRequest
            )
            XCTAssertEqual((arbitraryHeaderResponse as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertNotNil(try JSONSerialization.jsonObject(with: arbitraryHeaderData))

            let (_, wrongBearerResponse) = try await URLSession.shared.data(
                for: request(
                    port: port,
                    token: "wrong-token",
                    id: 3,
                    method: "tools/list",
                    params: [:]
                )
            )
            XCTAssertEqual((wrongBearerResponse as? HTTPURLResponse)?.statusCode, 200)
        } catch {
            await coordinator.stop()
            throw error
        }
        await coordinator.stop()
    }

    private func request(
        port: Int,
        token: String?,
        id: Int,
        method: String,
        params: [String: Any]
    ) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ])
        return request
    }
}
