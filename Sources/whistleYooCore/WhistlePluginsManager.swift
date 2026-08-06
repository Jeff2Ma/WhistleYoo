import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct WhistlePluginState: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let isEnabled: Bool

    public var id: String { name }

    public init(name: String, isEnabled: Bool) {
        self.name = name
        self.isEnabled = isEnabled
    }
}

/// Portable plugin preferences. Plugin packages themselves remain managed by
/// npm on each Mac; only Whistle's global and per-plugin enabled state is saved.
public struct WhistlePluginsSnapshot: Codable, Equatable, Sendable {
    public let areAllPluginsDisabled: Bool
    public let plugins: [WhistlePluginState]

    public init(
        areAllPluginsDisabled: Bool = false,
        plugins: [WhistlePluginState] = []
    ) {
        self.areAllPluginsDisabled = areAllPluginsDisabled
        self.plugins = plugins
    }

    /// Replaces states for plugins installed on this Mac while retaining
    /// preferences for unavailable plugins. The retained entries make a shared
    /// configuration safe to round-trip through a Mac with fewer plugins.
    public func mergingInstalled(_ installed: WhistlePluginsSnapshot) -> Self {
        var states = Dictionary(
            plugins.map { ($0.name, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        for plugin in installed.plugins {
            states[plugin.name] = plugin
        }
        return Self(
            areAllPluginsDisabled: installed.areAllPluginsDisabled,
            plugins: states.values.sorted { $0.name < $1.name }
        )
    }

    /// Builds the state to apply when plugins appear after this snapshot was
    /// loaded. Existing plugins keep their live state; newly available plugins
    /// recover any preference retained while they were unavailable.
    public func applyingRetainedPreferences(
        to installed: WhistlePluginsSnapshot,
        previouslyInstalledNames: Set<String>
    ) -> Self {
        let newlyAvailableNames = Set(installed.plugins.map(\.name))
            .subtracting(previouslyInstalledNames)
        guard !newlyAvailableNames.isEmpty else { return installed }
        let retainedByName = Dictionary(
            plugins.map { ($0.name, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        return Self(
            areAllPluginsDisabled: installed.areAllPluginsDisabled,
            plugins: installed.plugins.map { plugin in
                guard newlyAvailableNames.contains(plugin.name) else { return plugin }
                return retainedByName[plugin.name] ?? plugin
            }
        )
    }
}

/// Reads and applies Whistle plugin preferences through its official Local
/// Agent API. Missing plugins are intentionally ignored during application.
public struct WhistlePluginsManager: Sendable {
    private static let clientID = "whistleyoo-plugin-sync"
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func load(baseURL: URL) async throws -> WhistlePluginsSnapshot {
        var request = URLRequest(
            url: endpoint("cgi-bin/plugins/status", baseURL: baseURL),
            timeoutInterval: 8
        )
        request.setValue("WhistleYoo/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        let result = try JSONDecoder().decode(StatusResponse.self, from: data)
        return WhistlePluginsSnapshot(
            areAllPluginsDisabled: result.disabled ?? false,
            plugins: (result.list ?? [])
                .map { WhistlePluginState(name: $0.name, isEnabled: $0.selected ?? true) }
                .sorted { $0.name < $1.name }
        )
    }

    /// Applies preferences only to plugins present in `installed`. Preferences
    /// for missing plugins never reach Whistle's mutation endpoint.
    public func applyChanges(
        from installed: WhistlePluginsSnapshot,
        to desired: WhistlePluginsSnapshot,
        baseURL: URL
    ) async throws {
        let desiredByName = Dictionary(
            desired.plugins.map { ($0.name, $0) },
            uniquingKeysWith: { _, latest in latest }
        )

        for plugin in installed.plugins {
            guard let desiredPlugin = desiredByName[plugin.name],
                  desiredPlugin.isEnabled != plugin.isEnabled else { continue }
            _ = try await post(
                "cgi-bin/plugins/disable-plugin",
                form: [
                    "name": plugin.name,
                    "disabled": desiredPlugin.isEnabled ? "0" : "1"
                ],
                baseURL: baseURL
            )
        }

        if installed.areAllPluginsDisabled != desired.areAllPluginsDisabled {
            _ = try await post(
                "cgi-bin/plugins/disable-all-plugins",
                form: [
                    "disabledAllPlugins": desired.areAllPluginsDisabled ? "1" : "0"
                ],
                baseURL: baseURL
            )
        }
    }

    private func post(
        _ path: String,
        form: [String: String],
        baseURL: URL
    ) async throws -> ActionResponse {
        var request = URLRequest(url: endpoint(path, baseURL: baseURL), timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("WhistleYoo/1.0", forHTTPHeaderField: "User-Agent")
        var fields = form
        fields["clientId"] = Self.clientID
        var components = URLComponents()
        components.queryItems = fields.keys.sorted().map {
            URLQueryItem(name: $0, value: fields[$0])
        }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        let result = try JSONDecoder().decode(ActionResponse.self, from: data)
        guard result.ec == 0 else {
            throw WhistleYooError.invalidResponse(
                result.em ?? Localization.string(.pluginsFailedToLoadWhistlePlugins)
            )
        }
        return result
    }

    private func endpoint(_ path: String, baseURL: URL) -> URL {
        baseURL.appendingPathComponent(path)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw WhistleYooError.invalidResponse(
                String(data: data, encoding: .utf8)
                    ?? Localization.string(.pluginsFailedToLoadWhistlePlugins)
            )
        }
    }
}

private extension WhistlePluginsManager {
    struct StatusResponse: Decodable {
        let disabled: Bool?
        let list: [Plugin]?
    }

    struct Plugin: Decodable {
        let name: String
        let selected: Bool?
    }

    struct ActionResponse: Decodable {
        let ec: Int
        let em: String?
    }
}
