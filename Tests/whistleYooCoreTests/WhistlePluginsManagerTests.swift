import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import whistleYooCore

final class WhistlePluginsManagerTests: XCTestCase {
    override func tearDown() {
        PluginsURLProtocol.handler = nil
        super.tearDown()
    }

    func testLoadReturnsGlobalAndPerPluginPreferences() async throws {
        PluginsURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/cgi-bin/plugins/status")
            return (200, #"""
            {
              "disabled": true,
              "list": [
                {"name":"inspect","moduleName":"whistle.inspect","selected":false},
                {"name":"proxy","moduleName":"@scope/whistle.proxy","selected":true}
              ]
            }
            """#.data(using: .utf8)!)
        }

        let snapshot = try await makeManager().load(baseURL: baseURL)

        XCTAssertTrue(snapshot.areAllPluginsDisabled)
        XCTAssertEqual(snapshot.plugins, [
            WhistlePluginState(name: "inspect", isEnabled: false),
            WhistlePluginState(name: "proxy", isEnabled: true)
        ])
    }

    func testApplyChangesSkipsPluginsMissingFromThisMac() async throws {
        var captured = [(String, [String: String])]()
        PluginsURLProtocol.handler = { request in
            captured.append((request.url!.path, Self.formFields(request)))
            return (200, #"{"ec":0,"exists":true}"#.data(using: .utf8)!)
        }
        let installed = WhistlePluginsSnapshot(
            plugins: [
                WhistlePluginState(name: "inspect", isEnabled: true),
                WhistlePluginState(name: "local-only", isEnabled: false)
            ]
        )
        let desired = WhistlePluginsSnapshot(
            areAllPluginsDisabled: true,
            plugins: [
                WhistlePluginState(name: "inspect", isEnabled: false),
                WhistlePluginState(name: "missing", isEnabled: false)
            ]
        )

        try await makeManager().applyChanges(from: installed, to: desired, baseURL: baseURL)

        XCTAssertEqual(captured.map(\.0), [
            "/cgi-bin/plugins/disable-plugin",
            "/cgi-bin/plugins/disable-all-plugins"
        ])
        XCTAssertEqual(captured[0].1["name"], "inspect")
        XCTAssertEqual(captured[0].1["disabled"], "1")
        XCTAssertEqual(captured[1].1["disabledAllPlugins"], "1")
        XCTAssertFalse(captured.contains { $0.1["name"] == "missing" })
        XCTAssertTrue(captured.allSatisfy {
            $0.1["clientId"] == "whistleyoo-plugin-sync"
        })
    }

    func testMergingInstalledPreservesUnavailablePluginPreferences() {
        let portable = WhistlePluginsSnapshot(
            plugins: [
                WhistlePluginState(name: "missing", isEnabled: false),
                WhistlePluginState(name: "shared", isEnabled: false)
            ]
        )
        let installed = WhistlePluginsSnapshot(
            areAllPluginsDisabled: true,
            plugins: [
                WhistlePluginState(name: "local-only", isEnabled: true),
                WhistlePluginState(name: "shared", isEnabled: true)
            ]
        )

        let merged = portable.mergingInstalled(installed)

        XCTAssertTrue(merged.areAllPluginsDisabled)
        XCTAssertEqual(merged.plugins, [
            WhistlePluginState(name: "local-only", isEnabled: true),
            WhistlePluginState(name: "missing", isEnabled: false),
            WhistlePluginState(name: "shared", isEnabled: true)
        ])
    }

    func testRetainedPreferenceIsAppliedWhenMissingPluginIsLaterInstalled() {
        let portable = WhistlePluginsSnapshot(plugins: [
            WhistlePluginState(name: "installed-before", isEnabled: false),
            WhistlePluginState(name: "installed-later", isEnabled: false)
        ])
        let live = WhistlePluginsSnapshot(plugins: [
            WhistlePluginState(name: "installed-before", isEnabled: true),
            WhistlePluginState(name: "installed-later", isEnabled: true),
            WhistlePluginState(name: "new-without-preference", isEnabled: true)
        ])

        let desired = portable.applyingRetainedPreferences(
            to: live,
            previouslyInstalledNames: ["installed-before"]
        )

        XCTAssertEqual(desired.plugins, [
            WhistlePluginState(name: "installed-before", isEnabled: true),
            WhistlePluginState(name: "installed-later", isEnabled: false),
            WhistlePluginState(name: "new-without-preference", isEnabled: true)
        ])
    }

    func testPortableConfigurationKeepsOlderFilesPluginNeutral() throws {
        let rules = WhistleRulesSnapshot(documents: [
            WhistleRuleDocument(
                name: "Default",
                value: "",
                isEnabled: true,
                isDefault: true
            )
        ])
        let configuration = WhistleYooConfigurationFile(
            settings: PersistedSettings(),
            rules: rules,
            plugins: WhistlePluginsSnapshot(plugins: [
                WhistlePluginState(name: "inspect", isEnabled: false)
            ])
        )
        let encoded = try JSONEncoder().encode(configuration)
        XCTAssertEqual(
            try JSONDecoder().decode(WhistleYooConfigurationFile.self, from: encoded).plugins,
            configuration.plugins
        )

        var legacyObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "plugins")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)

        XCTAssertNil(
            try JSONDecoder().decode(WhistleYooConfigurationFile.self, from: legacyData).plugins
        )
    }

    private var baseURL: URL {
        URL(string: "http://127.0.0.1:8900/")!
    }

    private func makeManager() -> WhistlePluginsManager {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PluginsURLProtocol.self]
        return WhistlePluginsManager(session: URLSession(configuration: configuration))
    }

    private static func formFields(_ request: URLRequest) -> [String: String] {
        guard let data = request.httpBody ?? readBodyStream(request.httpBodyStream),
              let query = String(data: data, encoding: .utf8) else { return [:] }
        var components = URLComponents()
        components.percentEncodedQuery = query
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })
    }

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class PluginsURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw WhistleYooError.commandFailed("Missing test handler")
            }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
