import Foundation

public struct ProxyEndpoint: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var server: String
    public var port: Int

    public init(enabled: Bool = false, server: String = "", port: Int = 0) {
        self.enabled = enabled
        self.server = server
        self.port = port
    }
}

public struct AutoProxySettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var url: String

    public init(enabled: Bool = false, url: String = "") {
        self.enabled = enabled
        self.url = url
    }
}

public struct ServiceProxySettings: Codable, Equatable, Sendable {
    public var web: ProxyEndpoint
    public var secureWeb: ProxyEndpoint
    public var socks: ProxyEndpoint
    public var automatic: AutoProxySettings

    public init(
        web: ProxyEndpoint = .init(),
        secureWeb: ProxyEndpoint = .init(),
        socks: ProxyEndpoint = .init(),
        automatic: AutoProxySettings = .init()
    ) {
        self.web = web
        self.secureWeb = secureWeb
        self.socks = socks
        self.automatic = automatic
    }
}

public struct ProxyActivationRecord: Codable, Equatable, Sendable {
    public var original: [String: ServiceProxySettings]
    public var applied: [String: ServiceProxySettings]

    public init(original: [String: ServiceProxySettings], applied: [String: ServiceProxySettings]) {
        self.original = original
        self.applied = applied
    }
}

public final class ProxySnapshotStore: @unchecked Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.devework.whistleyoo", isDirectory: true)
        self.fileURL = fileURL ?? support.appendingPathComponent("proxy-activation.json")
    }

    public func save(_ record: ProxyActivationRecord) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: fileURL, options: .atomic)
    }

    public func load() throws -> ProxyActivationRecord? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(ProxyActivationRecord.self, from: Data(contentsOf: fileURL))
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}

public final class SystemProxyManager: @unchecked Sendable {
    private let runner: ProcessRunning
    private let networkSetupURL: URL
    private let snapshotStore: ProxySnapshotStore
    private let operationLock = NSRecursiveLock()
    private let maximumAttempts = 3

    public init(
        runner: ProcessRunning = FoundationProcessRunner(),
        networkSetupURL: URL = URL(fileURLWithPath: "/usr/sbin/networksetup"),
        snapshotStore: ProxySnapshotStore = ProxySnapshotStore()
    ) {
        self.runner = runner
        self.networkSetupURL = networkSetupURL
        self.snapshotStore = snapshotStore
    }

    public func activate(services: [String], proxyPort: Int, socksPort: Int? = nil) throws {
        try synchronized {
            try activateLocked(services: services, proxyPort: proxyPort, socksPort: socksPort)
        }
    }

    /// Restores a saved proxy configuration. If a previous app version lost its snapshot,
    /// exact loopback endpoints for the supplied ports are disabled as a conservative fallback.
    public func deactivate(services: [String], proxyPort: Int, socksPort: Int? = nil) throws {
        try synchronized {
            if let record = try snapshotStore.load() {
                let snapshotServices = Set(record.original.keys)
                try restoreIfOwnedLocked()
                try disableOrphanedAppEndpointsLocked(
                    services: services.filter { !snapshotServices.contains($0) },
                    proxyPort: proxyPort,
                    socksPort: socksPort
                )
            } else {
                try disableOrphanedAppEndpointsLocked(
                    services: services,
                    proxyPort: proxyPort,
                    socksPort: socksPort
                )
            }
        }
    }

    private func activateLocked(services: [String], proxyPort: Int, socksPort: Int?) throws {
        // 避免重复开启时覆盖真正的原始代理快照。
        if try snapshotStore.load() != nil {
            try restoreIfOwnedLocked()
        }
        var original: [String: ServiceProxySettings] = [:]
        var applied: [String: ServiceProxySettings] = [:]
        for service in services {
            let current = try readSettingsLocked(service: service)
            var recoverableOriginal = current
            // Older releases could clear the snapshot before all `off` commands took effect.
            // Treat an exact Whistle loopback endpoint as that orphan instead of preserving it.
            if Self.matches(current.web, port: proxyPort) { recoverableOriginal.web.enabled = false }
            if Self.matches(current.secureWeb, port: proxyPort) { recoverableOriginal.secureWeb.enabled = false }
            if let socksPort, Self.matches(current.socks, port: socksPort) {
                recoverableOriginal.socks.enabled = false
            }
            original[service] = recoverableOriginal
            var target = current
            target.web = ProxyEndpoint(enabled: true, server: "127.0.0.1", port: proxyPort)
            target.secureWeb = ProxyEndpoint(enabled: true, server: "127.0.0.1", port: proxyPort)
            target.automatic.enabled = false
            if let socksPort {
                target.socks = ProxyEndpoint(enabled: true, server: "127.0.0.1", port: socksPort)
            }
            applied[service] = target
        }
        try snapshotStore.save(ProxyActivationRecord(original: original, applied: applied))

        do {
            var lastVerificationError: Error?
            for attempt in 0..<maximumAttempts {
                do {
                    for service in services {
                        guard let target = applied[service] else { continue }
                        try setEndpoint(service: service, kind: .web, value: target.web)
                        try setEndpoint(service: service, kind: .secureWeb, value: target.secureWeb)
                        if socksPort != nil {
                            try setEndpoint(service: service, kind: .socks, value: target.socks)
                        }
                        if original[service]?.automatic.enabled == true {
                            try command(["-setautoproxystate", service, "off"])
                        }
                    }
                    try verifyApplied(record: ProxyActivationRecord(original: original, applied: applied))
                    return
                } catch {
                    lastVerificationError = error
                    if attempt + 1 < maximumAttempts { Thread.sleep(forTimeInterval: 0.1) }
                }
            }
            throw lastVerificationError ?? WhistleYooError.commandFailed(
                coreLocalized("未能确认系统代理已生效")
            )
        } catch {
            let activationError = error
            do {
                try restoreIfOwnedLocked()
            } catch {
                throw WhistleYooError.commandFailed(
                    coreLocalizedFormat(
                        "系统代理启用失败，且自动恢复未完成：%@；%@",
                        activationError.localizedDescription,
                        error.localizedDescription
                    )
                )
            }
            throw activationError
        }
    }

    public func restoreIfOwned() throws {
        try synchronized { try restoreIfOwnedLocked() }
    }

    private func restoreIfOwnedLocked() throws {
        guard let record = try snapshotStore.load() else { return }
        var lastError: Error?
        var attemptedRestores: [String: Set<ProxyComponent>] = [:]
        for attempt in 0..<maximumAttempts {
            for (service, original) in record.original {
                guard let applied = record.applied[service] else { continue }
                do {
                    let current = try readSettingsLocked(service: service)
                    if original.web != applied.web,
                       endpointStillManaged(current.web, applied: applied.web)
                        || attemptedRestores[service, default: []].contains(.web) {
                        attemptedRestores[service, default: []].insert(.web)
                        try setEndpoint(service: service, kind: .web, value: original.web)
                    }
                    if original.secureWeb != applied.secureWeb,
                       endpointStillManaged(current.secureWeb, applied: applied.secureWeb)
                        || attemptedRestores[service, default: []].contains(.secureWeb) {
                        attemptedRestores[service, default: []].insert(.secureWeb)
                        try setEndpoint(service: service, kind: .secureWeb, value: original.secureWeb)
                    }
                    if original.socks != applied.socks,
                       endpointStillManaged(current.socks, applied: applied.socks)
                        || attemptedRestores[service, default: []].contains(.socks) {
                        attemptedRestores[service, default: []].insert(.socks)
                        try setEndpoint(service: service, kind: .socks, value: original.socks)
                    }
                    if original.automatic != applied.automatic,
                       current.automatic == applied.automatic
                        || attemptedRestores[service, default: []].contains(.automatic) {
                        attemptedRestores[service, default: []].insert(.automatic)
                        try setAutomatic(service: service, value: original.automatic)
                    }
                } catch {
                    // Continue restoring the remaining services; verification below decides
                    // whether the durable snapshot may safely be removed.
                    lastError = error
                }
            }

            do {
                try verifyRestored(
                    record: record,
                    attemptedRestores: attemptedRestores
                )
                try snapshotStore.clear()
                return
            } catch {
                lastError = error
                if attempt + 1 < maximumAttempts { Thread.sleep(forTimeInterval: 0.1) }
            }
        }
        // Keep the snapshot so launch/shutdown or the next user action can retry safely.
        throw lastError ?? WhistleYooError.commandFailed(coreLocalized("系统代理恢复未完成"))
    }

    public func status(services: [String], proxyPort: Int) -> SystemProxyStatus {
        synchronized { statusLocked(services: services, proxyPort: proxyPort) }
    }

    private func statusLocked(services: [String], proxyPort: Int) -> SystemProxyStatus {
        guard !services.isEmpty else { return .disabled }
        let record: ProxyActivationRecord?
        do {
            record = try snapshotStore.load()
        } catch {
            return .unavailable(error.localizedDescription)
        }

        var ownedCount = 0
        var appEndpointCount = 0
        var partiallyAppEndpointCount = 0
        var externallyConfiguredCount = 0

        for service in services {
            let current: ServiceProxySettings
            do {
                current = try readSettingsLocked(service: service)
            } catch {
                return .unavailable(error.localizedDescription)
            }

            let webPointsToApp = Self.matches(current.web, port: proxyPort)
            let secureWebPointsToApp = Self.matches(current.secureWeb, port: proxyPort)
            let pointsToApp = webPointsToApp && secureWebPointsToApp
            if pointsToApp {
                appEndpointCount += 1
            } else if webPointsToApp || secureWebPointsToApp {
                partiallyAppEndpointCount += 1
            }

            if let original = record?.original[service],
               let applied = record?.applied[service],
               settingsStillOwned(current: current, original: original, applied: applied) {
                ownedCount += 1
            } else if current.web.enabled || current.secureWeb.enabled
                        || current.socks.enabled || current.automatic.enabled {
                externallyConfiguredCount += 1
            }
        }

        if ownedCount == services.count {
            return .enabledByThisApp
        }
        // Any exact WhistleYoo loopback endpoint without complete snapshot
        // ownership is attention-worthy partial state, including a full orphan
        // left by an older version. This keeps the UI switch actionable for cleanup.
        if ownedCount > 0 || partiallyAppEndpointCount > 0 || appEndpointCount > 0 {
            return .partiallyEnabled
        }
        if externallyConfiguredCount > 0 {
            return .configuredByOther
        }
        return .disabled
    }

    public func readSettings(service: String) throws -> ServiceProxySettings {
        try synchronized { try readSettingsLocked(service: service) }
    }

    private func readSettingsLocked(service: String) throws -> ServiceProxySettings {
        ServiceProxySettings(
            web: try readEndpoint(service: service, argument: "-getwebproxy"),
            secureWeb: try readEndpoint(service: service, argument: "-getsecurewebproxy"),
            socks: try readEndpoint(service: service, argument: "-getsocksfirewallproxy"),
            automatic: try readAutomatic(service: service)
        )
    }

    public static func parseEndpoint(_ output: String) -> ProxyEndpoint {
        let fields = parseFields(output)
        return ProxyEndpoint(
            enabled: fields["Enabled"]?.lowercased() == "yes",
            server: fields["Server"] ?? "",
            port: Int(fields["Port"] ?? "") ?? 0
        )
    }

    public static func parseAutomatic(_ output: String) -> AutoProxySettings {
        let fields = parseFields(output)
        return AutoProxySettings(
            enabled: fields["Enabled"]?.lowercased() == "yes",
            url: fields["URL"] ?? ""
        )
    }

    private enum EndpointKind { case web, secureWeb, socks }
    private enum ProxyComponent: Hashable { case web, secureWeb, socks, automatic }

    private func verifyApplied(record: ProxyActivationRecord) throws {
        for (service, applied) in record.applied {
            guard let original = record.original[service] else { continue }
            let current = try readSettingsLocked(service: service)
            guard settingsStillOwned(current: current, original: original, applied: applied) else {
                throw WhistleYooError.commandFailed(
                    coreLocalizedFormat("未能确认网络服务“%@”的系统代理已生效", service)
                )
            }
        }
    }

    private func verifyRestored(
        record: ProxyActivationRecord,
        attemptedRestores: [String: Set<ProxyComponent>]
    ) throws {
        for (service, original) in record.original {
            guard let applied = record.applied[service] else { continue }
            let current = try readSettingsLocked(service: service)
            let attempted = attemptedRestores[service, default: []]
            let webRestored = original.web == applied.web
                || (attempted.contains(.web)
                    ? endpointMatchesRestoredState(current.web, original: original.web)
                    : !endpointStillManaged(current.web, applied: applied.web))
            let secureWebRestored = original.secureWeb == applied.secureWeb
                || (attempted.contains(.secureWeb)
                    ? endpointMatchesRestoredState(current.secureWeb, original: original.secureWeb)
                    : !endpointStillManaged(current.secureWeb, applied: applied.secureWeb))
            let socksRestored = original.socks == applied.socks
                || (attempted.contains(.socks)
                    ? endpointMatchesRestoredState(current.socks, original: original.socks)
                    : !endpointStillManaged(current.socks, applied: applied.socks))
            let automaticRestored = original.automatic == applied.automatic
                || (attempted.contains(.automatic)
                    ? current.automatic == original.automatic
                    : current.automatic != applied.automatic)
            guard webRestored, secureWebRestored, socksRestored, automaticRestored else {
                throw WhistleYooError.commandFailed(
                    coreLocalizedFormat("网络服务“%@”仍有 WhistleYoo 代理配置未恢复", service)
                )
            }
        }
    }

    private func disableOrphanedAppEndpointsLocked(
        services: [String],
        proxyPort: Int,
        socksPort: Int?
    ) throws {
        var lastError: Error?
        for attempt in 0..<maximumAttempts {
            do {
                for service in services {
                    let current = try readSettingsLocked(service: service)
                    if Self.matches(current.web, port: proxyPort) {
                        try setEndpointState(service: service, kind: .web, enabled: false)
                    }
                    if Self.matches(current.secureWeb, port: proxyPort) {
                        try setEndpointState(service: service, kind: .secureWeb, enabled: false)
                    }
                    if let socksPort, Self.matches(current.socks, port: socksPort) {
                        try setEndpointState(service: service, kind: .socks, enabled: false)
                    }
                }
                for service in services {
                    let current = try readSettingsLocked(service: service)
                    guard !Self.matches(current.web, port: proxyPort),
                          !Self.matches(current.secureWeb, port: proxyPort),
                          socksPort.map({ !Self.matches(current.socks, port: $0) }) ?? true else {
                        throw WhistleYooError.commandFailed(
                            coreLocalizedFormat("网络服务“%@”仍在使用 WhistleYoo 代理", service)
                        )
                    }
                }
                return
            } catch {
                lastError = error
                if attempt + 1 < maximumAttempts { Thread.sleep(forTimeInterval: 0.1) }
            }
        }
        throw lastError ?? WhistleYooError.commandFailed(coreLocalized("系统代理关闭未完成"))
    }

    private func settingsStillOwned(
        current: ServiceProxySettings,
        original: ServiceProxySettings,
        applied: ServiceProxySettings
    ) -> Bool {
        guard current.web == applied.web, current.secureWeb == applied.secureWeb else { return false }
        if original.socks != applied.socks, current.socks != applied.socks { return false }
        if original.automatic != applied.automatic, current.automatic != applied.automatic { return false }
        return true
    }

    private func endpointStillManaged(_ current: ProxyEndpoint, applied: ProxyEndpoint) -> Bool {
        current == applied
            || (!current.enabled
                && current.server == applied.server
                && current.port == applied.port)
    }

    private func endpointMatchesRestoredState(
        _ current: ProxyEndpoint,
        original: ProxyEndpoint
    ) -> Bool {
        if original.enabled {
            return current == original
        }
        guard !current.enabled else { return false }
        // `networksetup -set*proxystate off` disables an endpoint but macOS
        // retains its most recently configured server and port. There is no
        // reliable networksetup representation for an empty endpoint, so an
        // off switch is the complete restoration when the saved endpoint had
        // no address. Dormant user-configured addresses remain exact-matched.
        guard !original.server.isEmpty, original.port > 0 else { return true }
        return current.server == original.server && current.port == original.port
    }

    private static func matches(_ endpoint: ProxyEndpoint, port: Int) -> Bool {
        endpoint.enabled && endpoint.server == "127.0.0.1" && endpoint.port == port
    }

    private func readEndpoint(service: String, argument: String) throws -> ProxyEndpoint {
        let result = try command([argument, service])
        return Self.parseEndpoint(result.standardOutput)
    }

    private func readAutomatic(service: String) throws -> AutoProxySettings {
        let result = try command(["-getautoproxyurl", service])
        return Self.parseAutomatic(result.standardOutput)
    }

    private func setEndpoint(service: String, kind: EndpointKind, value: ProxyEndpoint) throws {
        let setCommand: String
        let stateCommand: String
        switch kind {
        case .web: (setCommand, stateCommand) = ("-setwebproxy", "-setwebproxystate")
        case .secureWeb: (setCommand, stateCommand) = ("-setsecurewebproxy", "-setsecurewebproxystate")
        case .socks: (setCommand, stateCommand) = ("-setsocksfirewallproxy", "-setsocksfirewallproxystate")
        }
        if value.enabled {
            if !value.server.isEmpty, value.port > 0 {
                try command([setCommand, service, value.server, String(value.port)])
            }
            try command([stateCommand, service, "on"])
        } else {
            // Disable first. If the following address restoration fails, traffic is still safe.
            try command([stateCommand, service, "off"])
            if !value.server.isEmpty, value.port > 0 {
                try command([setCommand, service, value.server, String(value.port)])
            }
            // `-set*proxy` may enable the endpoint on some macOS releases.
            // Always force it off again after restoring the saved address.
            try command([stateCommand, service, "off"])
            let current: ProxyEndpoint
            switch kind {
            case .web: current = try readEndpoint(service: service, argument: "-getwebproxy")
            case .secureWeb:
                current = try readEndpoint(service: service, argument: "-getsecurewebproxy")
            case .socks:
                current = try readEndpoint(service: service, argument: "-getsocksfirewallproxy")
            }
            guard !current.enabled else {
                throw WhistleYooError.commandFailed(
                    coreLocalizedFormat("网络服务“%@”的代理开关未能关闭", service)
                )
            }
        }
    }

    private func setEndpointState(service: String, kind: EndpointKind, enabled: Bool) throws {
        let commandName: String
        switch kind {
        case .web: commandName = "-setwebproxystate"
        case .secureWeb: commandName = "-setsecurewebproxystate"
        case .socks: commandName = "-setsocksfirewallproxystate"
        }
        try command([commandName, service, enabled ? "on" : "off"])
    }

    private func setAutomatic(service: String, value: AutoProxySettings) throws {
        if !value.url.isEmpty {
            try command(["-setautoproxyurl", service, value.url])
        }
        try command(["-setautoproxystate", service, value.enabled ? "on" : "off"])
    }

    @discardableResult
    private func command(_ arguments: [String]) throws -> CommandResult {
        let result = try runner.run(
            executableURL: networkSetupURL, arguments: arguments, environment: nil, timeout: 15
        )
        guard result.exitCode == 0 else {
            let message = (result.standardError + result.standardOutput)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw WhistleYooError.commandFailed(message.isEmpty ? coreLocalized("networksetup 执行失败") : message)
        }
        return result
    }

    private static func parseFields(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                result[parts[0].trimmingCharacters(in: .whitespaces)] =
                    parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return result
    }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        operationLock.lock()
        defer { operationLock.unlock() }
        return try body()
    }
}
