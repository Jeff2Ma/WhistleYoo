import Foundation
import MCP
#if canImport(whistleYooCore)
import whistleYooCore
#endif

@MainActor
final class MCPToolBackend {
    private let state: AppStateController
    private var managedFiles = Set<String>()

    init(state: AppStateController) {
        self.state = state
    }

    func makeServer() async -> Server {
        let server = Server(
            name: "whistleyoo",
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            capabilities: .init(
                resources: .init(subscribe: false, listChanged: false),
                tools: .init(listChanged: false)
            )
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: Self.toolSpecs.map(\.tool))
        }
        await server.withMethodHandler(CallTool.self) { [weak self] parameters in
            guard let self else {
                return Self.errorResult("WhistleYoo is no longer available.")
            }
            let startedAt = Date()
            do {
                let result = try await self.call(
                    name: parameters.name,
                    arguments: parameters.arguments ?? [:]
                )
                let accessMode = await MainActor.run { self.state.settings.mcp.accessMode }
                let sanitized = Self.sanitize(
                    result,
                    includeSensitive: accessMode == .fullAccess
                        && parameters.arguments?["includeSensitive"]?.boolValue == true,
                    maximumStringBytes: min(
                        max(parameters.arguments?["maxBodyBytes"]?.intValue ?? 32_768, 1_024),
                        262_144
                    )
                )
                let data = try JSONEncoder.pretty.encode(sanitized)
                let text = String(decoding: data, as: UTF8.self)
                await self.state.recordMCPAudit(
                    tool: parameters.name,
                    succeeded: true,
                    startedAt: startedAt
                )
                return try .init(
                    content: [.text(text: text, annotations: nil, _meta: nil)],
                    structuredContent: try Value(sanitized),
                    isError: false
                )
            } catch {
                await self.state.recordMCPAudit(
                    tool: parameters.name,
                    succeeded: false,
                    startedAt: startedAt,
                    message: error.localizedDescription
                )
                return Self.errorResult(error.localizedDescription)
            }
        }
        await server.withMethodHandler(ListResources.self) { _ in
            .init(resources: [
                Resource(
                    name: "Whistle network status",
                    uri: "whistle://network/status",
                    mimeType: "application/json"
                ),
                Resource(
                    name: "Whistle root certificate",
                    uri: "whistle://root-ca",
                    mimeType: "application/x-x509-ca-cert"
                )
            ])
        }
        await server.withMethodHandler(ListResourceTemplates.self) { _ in
            .init(templates: [
                Resource.Template(
                    uriTemplate: "whistle://network/sessions/{id}",
                    name: "Whistle captured session",
                    mimeType: "application/json"
                ),
                Resource.Template(
                    uriTemplate: "whistle://rules/{name}",
                    name: "Whistle rule",
                    mimeType: "application/json"
                ),
                Resource.Template(
                    uriTemplate: "whistle://values/{name}",
                    name: "Whistle value",
                    mimeType: "application/json"
                )
            ])
        }
        await server.withMethodHandler(ReadResource.self) { [weak self] parameters in
            guard let self else { throw MCPError.internalError("WhistleYoo is unavailable.") }
            return try await self.readResource(parameters.uri)
        }
        return server
    }

    private func call(name: String, arguments: [String: Value]) async throws -> JSONValue {
        guard let spec = Self.toolSpecs.first(where: { $0.name == name }) else {
            throw MCPError.methodNotFound(name)
        }
        if spec.requiresFullAccess, state.settings.mcp.accessMode != .fullAccess {
            throw MCPError.invalidRequest(
                "\(name) requires Full Access in WhistleYoo Settings > MCP."
            )
        }

        switch name {
        case "app_get_status":
            return appStatus()
        case "app_start_engine":
            guard await state.startEngine() else { throw backendError() }
            return appStatus()
        case "app_stop_engine":
            await state.stopEngine()
            return appStatus()
        case "app_restart_engine":
            await state.stopEngine()
            guard await state.startEngine() else { throw backendError() }
            return appStatus()
        case "app_get_system_proxy_status":
            await state.refreshSystemProxyStatus()
            return .object(["status": .string(systemProxyStatusString)])
        case "app_set_system_proxy":
            guard await state.setSystemProxyEnabled(try bool("enabled", arguments)) else {
                throw backendError()
            }
            return .object(["status": .string(systemProxyStatusString)])
        default:
            break
        }

        let client = try await client()
        switch name {
        case "is_enabled_https":
            return .object(["enabled": .bool(try await client.isEnabledHTTPS())])
        case "set_enable_https":
            try await client.setEnableHTTPS(try bool("enable", arguments))
            return success()
        case "get_root_ca":
            let data = try await client.getRootCA()
            return .object([
                "mimeType": .string("application/x-x509-ca-cert"),
                "base64": .string(data.base64EncodedString())
            ])
        case "create_file":
            let result = try await client.createFile(try string("data", arguments))
            if let filepath = result.objectValue?["filepath"]?.stringValue {
                managedFiles.insert(filepath)
            }
            return result
        case "get_file":
            let filepath = try string("filepath", arguments)
            guard managedFiles.contains(filepath) else {
                throw MCPError.invalidRequest("Only files created by this MCP session can be read.")
            }
            return try await client.getFile(filepath)
        case "network_get_status":
            return try await client.networkGetStatus()
        case "network_get_sessions":
            return try await client.networkGetSessions(jsonArguments(arguments, droppingControlFields: true))
        case "network_save_sessions":
            return try await client.networkSaveSessions(
                try json("sessions", arguments),
                name: arguments["name"]?.stringValue
            )
        case "network_get_saved_sessions":
            let data = try await client.networkGetSavedSessions(try string("filename", arguments))
            return .object(["gzipBase64": .string(data.base64EncodedString())])
        case "network_get_frames":
            return try await client.networkGetFrames(jsonArguments(arguments, droppingControlFields: true))
        case "network_request":
            return try await client.networkRequest(jsonArguments(arguments, droppingControlFields: true))
        case "network_abort":
            try await client.networkAbort(try string("reqId", arguments))
            return success()
        case "rules_get_status":
            return try await client.rulesGetStatus()
        case "rules_turn_off":
            try await client.rulesTurnOff()
            return success()
        case "rules_turn_on":
            try await client.rulesTurnOn()
            return success()
        case "rules_is_multi_select":
            return .object(["multiSelect": .bool(try await client.rulesIsMultiSelect())])
        case "rules_set_multi_select":
            try await client.rulesSetMultiSelect(try bool("multiSelect", arguments))
            return success()
        case "rules_set_later_first":
            try await client.rulesSetLaterFirst(try bool("laterRulesFirst", arguments))
            return success()
        case "rules_get_list":
            return try await client.rulesGetList()
        case "rules_get":
            return try await client.rulesGet(try string("name", arguments))
        case "rules_add":
            guard await state.saveRule(
                name: try string("name", arguments),
                value: try string("value", arguments),
                isEnabled: arguments["selected"]?.boolValue ?? false
            ) else { throw backendError() }
            return success()
        case "rules_select", "rules_unselect":
            guard await state.setRuleEnabled(
                name == "rules_select",
                name: try string("name", arguments)
            ) else { throw backendError() }
            return success()
        case "rules_move_to_top":
            try await client.rulesMoveToTop(try string("name", arguments))
            _ = await state.loadRules()
            return success()
        case "values_get_list":
            return try await client.valuesGetList()
        case "values_get":
            return try await client.valuesGet(try string("name", arguments))
        case "values_add":
            let valueName = try string("name", arguments)
            let value = try string("value", arguments)
            _ = await state.loadValues()
            var documents = state.valuesSnapshot.documents.filter { $0.name != valueName }
            documents.append(WhistleValueDocument(name: valueName, value: value))
            guard await state.saveValuesSnapshot(WhistleValuesSnapshot(documents: documents)) else {
                throw backendError()
            }
            return success()
        case "plugins_get_status":
            return try await client.pluginsGetStatus()
        case "plugins_turn_off":
            try await client.pluginsTurnOff()
            return success()
        case "plugins_turn_on":
            try await client.pluginsTurnOn()
            return success()
        case "plugins_get_list":
            return try await client.pluginsGetList()
        case "plugins_get":
            return try await client.pluginsGet(try string("name", arguments))
        case "plugins_select":
            try await client.pluginsSelect(try string("name", arguments))
            return success()
        case "plugins_unselect":
            try await client.pluginsUnselect(try string("name", arguments))
            return success()
        default:
            throw MCPError.methodNotFound(name)
        }
    }

    private func readResource(_ uri: String) async throws -> ReadResource.Result {
        let client = try await client()
        if uri == "whistle://network/status" {
            return try jsonResource(uri: uri, value: await client.networkGetStatus())
        }
        if uri == "whistle://root-ca" {
            return .init(contents: [
                .binary(
                    try await client.getRootCA(),
                    uri: uri,
                    mimeType: "application/x-x509-ca-cert"
                )
            ])
        }
        if let name = resourceSuffix(uri, prefix: "whistle://rules/") {
            return try jsonResource(uri: uri, value: await client.rulesGet(name))
        }
        if let name = resourceSuffix(uri, prefix: "whistle://values/") {
            return try jsonResource(uri: uri, value: await client.valuesGet(name))
        }
        if let id = resourceSuffix(uri, prefix: "whistle://network/sessions/") {
            let sessions = try await client.networkGetSessions(.object([
                "startId": .string(id),
                "count": .number(1)
            ]))
            return try jsonResource(uri: uri, value: sessions)
        }
        throw MCPError.invalidParams("Unknown Whistle resource URI.")
    }

    private func client() async throws -> WhistleAPIClient {
        var environment: EnvironmentInfo?
        if case .ready(let detected) = state.environmentStatus {
            environment = detected
        }
        let needsRefresh = environment.map {
            $0.whistleVersion < WhistleAPIClient.minimumAgentAPIVersion
        } ?? true
        if needsRefresh {
            await state.refreshEnvironment()
            if case .ready(let refreshed) = state.environmentStatus {
                environment = refreshed
            }
        }
        guard let environment else {
            throw MCPError.invalidRequest(
                "Whistle is not installed or the environment is unavailable. "
                    + "Open More Settings > Runtime Environment to inspect the detected executable."
            )
        }
        guard environment.whistleVersion >= WhistleAPIClient.minimumAgentAPIVersion else {
            throw MCPError.invalidRequest(Self.unsupportedWhistleVersionMessage(environment))
        }
        guard await state.startEngine(), let url = state.uiURL else {
            throw backendError()
        }
        return WhistleAPIClient(baseURL: url)
    }

    private func jsonResource(uri: String, value: JSONValue) throws -> ReadResource.Result {
        let sanitized = Self.sanitize(
            value,
            includeSensitive: false,
            maximumStringBytes: 32_768
        )
        return .init(contents: [
            .text(
                String(decoding: try JSONEncoder.pretty.encode(sanitized), as: UTF8.self),
                uri: uri,
                mimeType: "application/json"
            )
        ])
    }

    private func resourceSuffix(_ uri: String, prefix: String) -> String? {
        guard uri.hasPrefix(prefix) else { return nil }
        return String(uri.dropFirst(prefix.count)).removingPercentEncoding
    }

    private func backendError() -> MCPError {
        .internalError(state.lastErrorMessage ?? "WhistleYoo could not complete the operation.")
    }

    private func appStatus() -> JSONValue {
        var details: [String: JSONValue] = [
            "engine": .string(engineStatusString),
            "systemProxy": .string(systemProxyStatusString),
            "proxyPort": .number(Double(state.settings.engine.proxyPort)),
            "uiPort": .number(Double(state.settings.engine.uiPort)),
            "mcpPort": .number(Double(state.settings.mcp.port)),
            "mcpAuthenticationEnabled": .bool(state.settings.mcp.authenticationEnabled),
            "mcpAccessMode": .string(state.settings.mcp.accessMode.rawValue),
            "mcpMinimumWhistleVersion": .string(
                Self.versionString(WhistleAPIClient.minimumAgentAPIVersion)
            )
        ]
        details.merge(
            Self.environmentDetails(state.environmentStatus),
            uniquingKeysWith: { _, new in new }
        )
        return .object(details)
    }

    nonisolated static func environmentDetails(
        _ status: AppEnvironmentStatus
    ) -> [String: JSONValue] {
        switch status {
        case .checking:
            return ["environment": .string("checking")]
        case .unavailable(let message):
            return [
                "environment": .string("unavailable"),
                "environmentMessage": .string(message)
            ]
        case .ready(let environment):
            return [
                "environment": .string("ready"),
                "nodeExecutable": .string(environment.nodeURL.path),
                "nodeVersion": .string(versionString(environment.nodeVersion)),
                "whistleExecutable": .string(environment.whistleURL.path),
                "whistleVersion": .string(versionString(environment.whistleVersion))
            ]
        }
    }

    nonisolated static func unsupportedWhistleVersionMessage(
        _ environment: EnvironmentInfo
    ) -> String {
        let detected = versionString(environment.whistleVersion)
        let required = versionString(WhistleAPIClient.minimumAgentAPIVersion)
        return "Detected Whistle \(detected) at \(environment.whistleURL.path). "
            + "Whistle \(required) or later is required for MCP. "
            + "After updating, open More Settings > Runtime Environment and check again."
    }

    nonisolated private static func versionString(_ version: SemanticVersion) -> String {
        "\(version.major).\(version.minor).\(version.patch)"
    }

    private var engineStatusString: String {
        switch state.engineState {
        case .stopped: "stopped"
        case .starting: "starting"
        case .running(let version): "running \(version)"
        case .stopping: "stopping"
        case .failed(let message): "failed: \(message)"
        }
    }

    private var systemProxyStatusString: String {
        switch state.systemProxyStatus {
        case .disabled: "disabled"
        case .enabledByThisApp: "enabledByThisApp"
        case .partiallyEnabled: "partiallyEnabled"
        case .configuredByOther: "configuredByOther"
        case .unavailable(let message): "unavailable: \(message)"
        }
    }

    private func string(_ key: String, _ arguments: [String: Value]) throws -> String {
        guard let value = arguments[key]?.stringValue, !value.isEmpty else {
            throw MCPError.invalidParams("\(key) is required.")
        }
        return value
    }

    private func bool(_ key: String, _ arguments: [String: Value]) throws -> Bool {
        guard let value = arguments[key]?.boolValue else {
            throw MCPError.invalidParams("\(key) is required and must be a boolean.")
        }
        return value
    }

    private func json(_ key: String, _ arguments: [String: Value]) throws -> JSONValue {
        guard let value = arguments[key] else {
            throw MCPError.invalidParams("\(key) is required.")
        }
        return try JSONValue(value)
    }

    private func jsonArguments(
        _ arguments: [String: Value],
        droppingControlFields: Bool
    ) -> JSONValue {
        var arguments = arguments
        if droppingControlFields {
            arguments.removeValue(forKey: "includeSensitive")
            arguments.removeValue(forKey: "maxBodyBytes")
        }
        return (try? JSONValue(Value.object(arguments))) ?? .object([:])
    }

    private func success() -> JSONValue {
        .object(["ec": .number(0)])
    }

    nonisolated private static func errorResult(_ message: String) -> CallTool.Result {
        .init(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            isError: true
        )
    }

    nonisolated private static func sanitize(
        _ value: JSONValue,
        includeSensitive: Bool,
        maximumStringBytes: Int
    ) -> JSONValue {
        switch value {
        case .array(let values):
            return .array(values.map {
                sanitize($0, includeSensitive: includeSensitive, maximumStringBytes: maximumStringBytes)
            })
        case .object(let object):
            return .object(Dictionary(uniqueKeysWithValues: object.map { key, value in
                let normalized = key.lowercased().replacingOccurrences(of: "_", with: "-")
                let sensitive = [
                    "authorization", "proxy-authorization", "cookie", "set-cookie",
                    "x-api-key", "x-auth-token", "access-token", "refresh-token"
                ].contains(normalized)
                return (
                    key,
                    sensitive && !includeSensitive
                        ? .string("***REDACTED***")
                        : sanitize(
                            value,
                            includeSensitive: includeSensitive,
                            maximumStringBytes: maximumStringBytes
                        )
                )
            }))
        case .string(let string):
            guard string.utf8.count > maximumStringBytes else { return value }
            let prefix = String(decoding: string.utf8.prefix(maximumStringBytes), as: UTF8.self)
            return .string(prefix + "\n…[truncated, originalBytes=\(string.utf8.count)]")
        case .null, .bool, .number:
            return value
        }
    }

    private struct ToolSpec {
        let name: String
        let description: String
        let schema: Value
        let requiresFullAccess: Bool
        let destructive: Bool
        let openWorld: Bool

        var tool: Tool {
            Tool(
                name: name,
                description: description,
                inputSchema: schema,
                annotations: .init(
                    readOnlyHint: !requiresFullAccess,
                    destructiveHint: destructive,
                    idempotentHint: !destructive,
                    openWorldHint: openWorld
                )
            )
        }
    }

    nonisolated private static let emptySchema: Value = [
        "type": "object",
        "properties": [:],
        "additionalProperties": false
    ]

    nonisolated private static func fields(
        _ properties: [String: Value],
        required: [String] = [],
        allowControlFields: Bool = false
    ) -> Value {
        var properties = properties
        if allowControlFields {
            properties["includeSensitive"] = ["type": "boolean", "default": false]
            properties["maxBodyBytes"] = [
                "type": "integer", "minimum": 1_024, "maximum": 262_144, "default": 32_768
            ]
        }
        var schema: [String: Value] = [
            "type": "object",
            "properties": .object(properties),
            "additionalProperties": false
        ]
        if !required.isEmpty { schema["required"] = .array(required.map(Value.string)) }
        return .object(schema)
    }

    nonisolated private static let nameSchema = fields(
        ["name": ["type": "string"]],
        required: ["name"]
    )
    nonisolated private static let toolSpecs: [ToolSpec] = [
        .init(name: "is_enabled_https", description: "Official API: api.isEnabledHTTPS().", schema: emptySchema, requiresFullAccess: false, destructive: false, openWorld: false),
        .init(name: "set_enable_https", description: "Official API: api.setEnableHTTPS(enable).", schema: fields(["enable": ["type": "boolean"]], required: ["enable"]), requiresFullAccess: true, destructive: false, openWorld: false),
        .init(name: "get_root_ca", description: "Official API: api.getRootCA().", schema: emptySchema, requiresFullAccess: false, destructive: false, openWorld: false),
        .init(name: "create_file", description: "Official API: api.createFile(data). Creates a Whistle-managed temporary file.", schema: fields(["data": ["type": "string"]], required: ["data"]), requiresFullAccess: true, destructive: false, openWorld: false),
        .init(name: "get_file", description: "Official API: api.getFile(filepath). Reads only temporary files created in this MCP session.", schema: fields(["filepath": ["type": "string"]], required: ["filepath"]), requiresFullAccess: false, destructive: false, openWorld: false),

        .init(name: "network_get_status", description: "Official API: api.network.getStatus().", schema: emptySchema, requiresFullAccess: false, destructive: false, openWorld: false),
        .init(name: "network_get_sessions", description: "Official API: api.network.getSessions(options).", schema: fields([
            "latest": ["type": "boolean"], "startId": ["type": ["string", "integer"]],
            "startTime": ["type": "integer"], "type": ["type": "string"],
            "subUrl": ["type": "string"], "method": [:], "statusCode": [:],
            "reqHeader": ["type": "object"], "resHeader": ["type": "object"],
            "count": ["type": "integer", "minimum": 1, "maximum": 3_600]
        ], allowControlFields: true), requiresFullAccess: false, destructive: false, openWorld: false),
        .init(name: "network_save_sessions", description: "Official API: api.network.saveSessions(sessions, name).", schema: fields(["sessions": ["type": "array"], "name": ["type": "string"]], required: ["sessions"]), requiresFullAccess: true, destructive: false, openWorld: false),
        .init(name: "network_get_saved_sessions", description: "Official API: api.network.getSavedSessions(filename).", schema: fields(["filename": ["type": "string"]], required: ["filename"]), requiresFullAccess: false, destructive: false, openWorld: false),
        .init(name: "network_get_frames", description: "Official API: api.network.getFrames(options).", schema: fields([
            "reqId": ["type": "string"], "count": ["type": "integer", "minimum": 1, "maximum": 3_600],
            "latest": ["type": "boolean"], "startId": ["type": ["string", "integer"]],
            "startTime": ["type": "integer"], "from": ["type": "string", "enum": ["client", "server"]]
        ], required: ["reqId"], allowControlFields: true), requiresFullAccess: false, destructive: false, openWorld: false),
        .init(name: "network_request", description: "Official API: api.network.request(options). Sends or replays an HTTP request.", schema: fields([
            "url": ["type": "string"], "method": ["type": "string"], "headers": ["type": "object"],
            "body": ["type": "string"], "base64": ["type": "string"], "rules": ["type": "string"],
            "enableHTTP2": ["type": "boolean"], "times": ["type": "integer"],
            "disabledGlobalRules": ["type": "boolean"]
        ], required: ["url"], allowControlFields: true), requiresFullAccess: true, destructive: true, openWorld: true),
        .init(name: "network_abort", description: "Official API: api.network.abort(reqId).", schema: fields(["reqId": ["type": "string"]], required: ["reqId"]), requiresFullAccess: true, destructive: true, openWorld: false),

        .init(name: "rules_get_status", description: "Official API: api.rules.getStatus().", schema: emptySchema, requiresFullAccess: false, destructive: false, openWorld: false),
        .init(name: "rules_turn_off", description: "Official API: api.rules.turnOff().", schema: emptySchema, requiresFullAccess: true, destructive: true, openWorld: false),
        .init(name: "rules_turn_on", description: "Official API: api.rules.turnOn().", schema: emptySchema, requiresFullAccess: true, destructive: false, openWorld: false),
        .init(name: "rules_is_multi_select", description: "Official API: api.rules.isMultiSelect().", schema: emptySchema, requiresFullAccess: false, destructive: false, openWorld: false),
        .init(name: "rules_set_multi_select", description: "Official API: api.rules.setMultiSelect(multiSelect).", schema: fields(["multiSelect": ["type": "boolean"]], required: ["multiSelect"]), requiresFullAccess: true, destructive: false, openWorld: false),
        .init(name: "rules_set_later_first", description: "Official API: api.rules.setLaterFirst(laterRulesFirst).", schema: fields(["laterRulesFirst": ["type": "boolean"]], required: ["laterRulesFirst"]), requiresFullAccess: true, destructive: false, openWorld: false),
        .init(name: "rules_get_list", description: "Official API: api.rules.getList().", schema: emptySchema, requiresFullAccess: false, destructive: false, openWorld: false),
        .init(name: "rules_get", description: "Official API: api.rules.get(name).", schema: nameSchema, requiresFullAccess: false, destructive: false, openWorld: false),
        .init(name: "rules_add", description: "Official API: api.rules.add(name, value, selected).", schema: fields(["name": ["type": "string"], "value": ["type": "string"], "selected": ["type": "boolean"]], required: ["name", "value"]), requiresFullAccess: true, destructive: false, openWorld: false),
        .init(name: "rules_select", description: "Official API: api.rules.select(name).", schema: nameSchema, requiresFullAccess: true, destructive: false, openWorld: false),
        .init(name: "rules_unselect", description: "Official API: api.rules.unselect(name).", schema: nameSchema, requiresFullAccess: true, destructive: true, openWorld: false),
        .init(name: "rules_move_to_top", description: "Official API: api.rules.moveToTop(name).", schema: nameSchema, requiresFullAccess: true, destructive: false, openWorld: false),

        .init(name: "values_get_list", description: "Official API: api.values.getList().", schema: emptySchema, requiresFullAccess: false, destructive: false, openWorld: false),
        .init(name: "values_get", description: "Official API: api.values.get(name).", schema: nameSchema, requiresFullAccess: false, destructive: false, openWorld: false),
        .init(name: "values_add", description: "Official API: api.values.add(name, value).", schema: fields(["name": ["type": "string"], "value": ["type": "string"]], required: ["name", "value"]), requiresFullAccess: true, destructive: false, openWorld: false),

        .init(name: "plugins_get_status", description: "Official API: api.plugins.getStatus().", schema: emptySchema, requiresFullAccess: false, destructive: false, openWorld: false),
        .init(name: "plugins_turn_off", description: "Official API: api.plugins.turnOff().", schema: emptySchema, requiresFullAccess: true, destructive: true, openWorld: false),
        .init(name: "plugins_turn_on", description: "Official API: api.plugins.turnOn().", schema: emptySchema, requiresFullAccess: true, destructive: false, openWorld: false),
        .init(name: "plugins_get_list", description: "Official API: api.plugins.getList().", schema: emptySchema, requiresFullAccess: false, destructive: false, openWorld: false),
        .init(name: "plugins_get", description: "Official API: api.plugins.get(name).", schema: nameSchema, requiresFullAccess: false, destructive: false, openWorld: false),
        .init(name: "plugins_select", description: "Official API: api.plugins.select(name).", schema: nameSchema, requiresFullAccess: true, destructive: false, openWorld: false),
        .init(name: "plugins_unselect", description: "Official API: api.plugins.unselect(name).", schema: nameSchema, requiresFullAccess: true, destructive: true, openWorld: false),

        .init(name: "app_get_status", description: "WhistleYoo extension: get app, engine, system proxy, and detected Node/Whistle environment status.", schema: emptySchema, requiresFullAccess: false, destructive: false, openWorld: false),
        .init(name: "app_start_engine", description: "WhistleYoo extension: start the managed Whistle engine.", schema: emptySchema, requiresFullAccess: false, destructive: false, openWorld: false),
        .init(name: "app_stop_engine", description: "WhistleYoo extension: stop the managed Whistle engine.", schema: emptySchema, requiresFullAccess: true, destructive: true, openWorld: false),
        .init(name: "app_restart_engine", description: "WhistleYoo extension: restart the managed Whistle engine.", schema: emptySchema, requiresFullAccess: true, destructive: true, openWorld: false),
        .init(name: "app_get_system_proxy_status", description: "WhistleYoo extension: get macOS system proxy status.", schema: emptySchema, requiresFullAccess: false, destructive: false, openWorld: false),
        .init(name: "app_set_system_proxy", description: "WhistleYoo extension: enable or disable the macOS system proxy.", schema: fields(["enabled": ["type": "boolean"]], required: ["enabled"]), requiresFullAccess: true, destructive: true, openWorld: false)
    ]
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private extension JSONValue {
    init(_ value: Value) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
