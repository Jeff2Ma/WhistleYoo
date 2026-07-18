import AppKit
import Combine
#if canImport(whistleYooCore)
import whistleYooCore
#endif

enum AppEnvironmentStatus: Equatable {
    case checking
    case ready(EnvironmentInfo)
    case unavailable(String)
}

@MainActor
final class AppStateController: ObservableObject {
    @Published private(set) var settings = PersistedSettings() {
        didSet { onStatusChange?() }
    }
    @Published private(set) var environmentStatus: AppEnvironmentStatus = .checking {
        didSet { onStatusChange?() }
    }
    @Published private(set) var engineState: EngineState = .stopped {
        didSet { onStatusChange?() }
    }
    @Published private(set) var systemProxyStatus: SystemProxyStatus = .disabled {
        didSet { onStatusChange?() }
    }
    @Published private(set) var certificateHealth = CertificateHealth()
    @Published private(set) var networkServices: [NetworkService] = []
    @Published private(set) var localNetworkEndpoints: [LocalNetworkEndpoint] = []
    @Published private(set) var selectedLocalEndpointID: String?
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var showDockIcon: Bool
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var rulesSnapshot = WhistleRulesSnapshot()
    @Published private(set) var isLoadingRules = false
    @Published private(set) var isSavingRules = false
    @Published private(set) var isChangingSystemProxy = false
    @Published private(set) var isPerformingEngineOperation = false
    @Published private(set) var isImportingConfiguration = false
    @Published private(set) var configurationFileURL: URL

    var onStatusChange: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onMessage: ((String) -> Void)?
    var onEngineReady: ((URL) -> Void)?
    var onDockVisibilityChange: ((Bool) -> Bool)?

    private let settingsStore: SettingsStore
    private let proxyManager: SystemProxyManager
    private let certificateManager: CertificateManager
    private let softwareWhitelistManager: SoftwareDomainWhitelistManager
    private let rulesManager: WhistleRulesManager
    private let interfaceManager: NetworkInterfaceManager
    private let portChecker: PortAvailabilityChecking
    private let configurationStore: WhistleYooConfigurationStore
    private let configurationLocationDefaults: UserDefaults
    private let dockVisibilityPreference: DockVisibilityPreference
    private var environment: EnvironmentInfo?
    private var engine: WhistleEngineController?
    private var monitorTask: Task<Void, Never>?
    private var configurationSyncTask: Task<Void, Never>?
    private var pendingStartupRules: WhistleRulesSnapshot?
    private static let configurationLocationKey = "WhistleYooConfigurationFilePath"

    init(
        settingsStore: SettingsStore = SettingsStore(),
        proxyManager: SystemProxyManager = SystemProxyManager(),
        certificateManager: CertificateManager = CertificateManager(),
        softwareWhitelistManager: SoftwareDomainWhitelistManager = SoftwareDomainWhitelistManager(),
        rulesManager: WhistleRulesManager = WhistleRulesManager(),
        interfaceManager: NetworkInterfaceManager = NetworkInterfaceManager(),
        portChecker: PortAvailabilityChecking = PortChecker(),
        configurationStore: WhistleYooConfigurationStore = WhistleYooConfigurationStore(),
        configurationLocationDefaults: UserDefaults = .standard,
        dockVisibilityPreference: DockVisibilityPreference = DockVisibilityPreference()
    ) {
        self.settingsStore = settingsStore
        self.proxyManager = proxyManager
        self.certificateManager = certificateManager
        self.softwareWhitelistManager = softwareWhitelistManager
        self.rulesManager = rulesManager
        self.interfaceManager = interfaceManager
        self.portChecker = portChecker
        self.configurationStore = configurationStore
        self.configurationLocationDefaults = configurationLocationDefaults
        self.dockVisibilityPreference = dockVisibilityPreference
        showDockIcon = dockVisibilityPreference.isVisible
        if let path = configurationLocationDefaults.string(forKey: Self.configurationLocationKey),
           !path.isEmpty {
            configurationFileURL = URL(fileURLWithPath: path).standardizedFileURL
        } else {
            configurationFileURL = configurationStore.defaultFileURL.standardizedFileURL
        }
    }

    var needsOnboarding: Bool {
        settings.completedOnboardingVersion != PersistedSettings.currentOnboardingVersion
    }

    var applicationStatus: ApplicationStatus {
        if case .unavailable = environmentStatus, engineState == .stopped {
            return .unavailable
        }
        return ApplicationStatus.resolve(
            engineState: engineState,
            systemProxyStatus: systemProxyStatus
        )
    }

    var isEngineRunning: Bool {
        if case .running = engineState { return true }
        return false
    }

    var isSystemProxyEnabled: Bool {
        systemProxyStatus == .enabledByThisApp
    }

    var certificateInstalled: Bool {
        certificateHealth.isReady
    }

    var usesCustomConfigurationFileLocation: Bool {
        configurationFileURL.standardizedFileURL
            != configurationStore.defaultFileURL.standardizedFileURL
    }

    var isTransitioning: Bool {
        engineState == .starting || engineState == .stopping
            || isPerformingEngineOperation || isChangingSystemProxy
            || isImportingConfiguration
    }

    var preferredLocalEndpoint: LocalNetworkEndpoint? {
        localNetworkEndpoints.first { $0.id == selectedLocalEndpointID } ?? localNetworkEndpoints.first
    }

    var selectedNetworkServiceNames: [String] {
        NetworkServiceSelection.resolve(
            selectedNames: settings.selectedNetworkServices,
            availableServices: networkServices
        )
    }

    var engineStatusTitle: String {
        switch engineState {
        case .running: return appLocalized("运行中")
        case .starting: return appLocalized("正在启动")
        case .stopping: return appLocalized("正在停止")
        case .stopped: return appLocalized("已停止")
        case .failed: return appLocalized("启动失败")
        }
    }

    var systemProxyTitle: String {
        switch systemProxyStatus {
        case .disabled: return appLocalized("未开启")
        case .enabledByThisApp: return appLocalized("已接入")
        case .partiallyEnabled: return appLocalized("部分接入")
        case .configuredByOther: return appLocalized("检测到其他代理")
        case .unavailable: return appLocalized("状态不可用")
        }
    }

    var statusTitle: String {
        switch applicationStatus {
        case .systemProxyEnabled: return appLocalized("系统代理已开启")
        case .listeningOnly: return appLocalized("仅监听代理")
        case .transitioning:
            return appLocalized(engineState == .starting ? "代理引擎启动中" : "代理引擎停止中")
        case .stopped: return appLocalized("代理引擎已停止")
        case .attention: return appLocalized("代理状态需要检查")
        case .unavailable: return appLocalized("环境未就绪")
        }
    }

    var engineDescription: String {
        switch engineState {
        case .running(let version):
            return appLocalizedFormat(
                "Whistle %@ · 127.0.0.1:%@",
                version,
                String(settings.engine.proxyPort)
            )
        case .failed(let message): return message
        case .starting: return appLocalized("正在启动 Whistle…")
        case .stopping: return appLocalized("正在停止 Whistle…")
        case .stopped:
            switch environmentStatus {
            case .unavailable(let message): return message
            case .checking: return appLocalized("正在检测 Node.js 与 Whistle…")
            case .ready: return appLocalized("Node.js 与 Whistle 已就绪")
            }
        }
    }

    var proxyDescription: String {
        guard isEngineRunning else { return appLocalized("启动代理引擎后可用") }
        switch systemProxyStatus {
        case .disabled: return appLocalized("Mac 流量尚未接入，手机和手动代理仍可使用")
        case .enabledByThisApp: return appLocalized("所选网络服务已指向本机代理")
        case .partiallyEnabled: return appLocalized("只有部分网络服务使用当前代理")
        case .configuredByOther: return appLocalized("系统中存在其他代理配置，WhistleYoo 未接管")
        case .unavailable(let message): return appLocalizedFormat("无法读取系统代理：%@", message)
        }
    }

    var environmentDescription: String {
        switch environmentStatus {
        case .checking: return appLocalized("正在检测…")
        case .unavailable(let message): return message
        case .ready(let info):
            return "Node \(versionString(info.nodeVersion)) · Whistle \(versionString(info.whistleVersion))"
        }
    }

    var uiURL: URL? { engine?.uiURL }

    func launch() async -> Bool {
        do {
            if configurationFileURL.pathExtension.caseInsensitiveCompare("whistleyoo") == .orderedSame {
                let legacyURL = configurationFileURL
                let jsonURL = legacyURL.deletingPathExtension().appendingPathExtension("json")
                try configurationStore.migrateLegacyFileIfNeeded(from: legacyURL, to: jsonURL)
                configurationFileURL = jsonURL.standardizedFileURL
                configurationLocationDefaults.set(
                    configurationFileURL.path,
                    forKey: Self.configurationLocationKey
                )
            }
            if configurationFileURL.standardizedFileURL
                == configurationStore.defaultFileURL.standardizedFileURL {
                try configurationStore.migrateLegacyDefaultFileIfNeeded()
            }
            if FileManager.default.fileExists(atPath: configurationFileURL.path) {
                let configuration = try configurationStore.load(from: configurationFileURL)
                settings = configuration.settings
                pendingStartupRules = configuration.rules
                try settingsStore.save(settings)
            } else {
                settings = try settingsStore.load()
            }
        } catch {
            report(error)
            do {
                settings = try settingsStore.load()
            } catch {
                report(error)
            }
        }
        launchAtLoginEnabled = AutoLaunchManager().isEnabled

        await refreshEnvironment()
        await refreshNetworkServices()
        var proxyCleanupFailed = false
        do {
            let services = proxyCleanupServices
            let proxyPort = settings.engine.proxyPort
            let socksPort = settings.engine.socksPort
            try await Task.detached { [proxyManager] in
                try proxyManager.deactivate(
                    services: services,
                    proxyPort: proxyPort,
                    socksPort: socksPort
                )
            }.value
        } catch {
            proxyCleanupFailed = true
            report(error)
        }
        await refreshCertificateStatus()
        await refreshSystemProxyStatus()

        let shouldShowOnboarding = needsOnboarding
        // If a stale app-owned proxy could not be cleared, bring Whistle back up
        // even during onboarding so macOS is never left pointing at a dead port.
        let needsSafetyEngine = systemProxyStatus.requiresSafetyEngine(
            afterCleanupFailed: proxyCleanupFailed
        )
        // Keep every normal launch idle. The user explicitly starts Whistle
        // when it is needed; only a failed stale-proxy cleanup may start the
        // engine so macOS is not left pointing at a dead local endpoint.
        if environment != nil, needsSafetyEngine {
            _ = await startEngine()
        }
        return shouldShowOnboarding
    }

    func refreshEnvironment() async {
        environmentStatus = .checking
        let result = await Task.detached { () -> (EnvironmentInfo?, String?) in
            do {
                return (try EnvironmentDetector().detect(), nil)
            } catch {
                return (nil, error.localizedDescription)
            }
        }.value

        guard let detected = result.0 else {
            environment = nil
            environmentStatus = .unavailable(result.1 ?? appLocalized("环境检测失败"))
            if !isEngineRunning {
                engine = nil
                engineState = .stopped
            }
            return
        }

        environment = detected
        environmentStatus = .ready(detected)
        if engine == nil || engineState == .stopped || isEngineFailed {
            configureEngine(environment: detected)
        }
    }

    func refreshNetworkServices() async {
        let result = await Task.detached { [interfaceManager] in
            let services = (try? interfaceManager.listServices().filter { !$0.disabled }) ?? []
            return (services, interfaceManager.localIPv4Endpoints(services: services))
        }.value
        networkServices = result.0
        localNetworkEndpoints = result.1
        if !localNetworkEndpoints.contains(where: { $0.id == selectedLocalEndpointID }) {
            selectedLocalEndpointID = localNetworkEndpoints.first?.id
        }
    }

    func selectLocalNetworkEndpoint(id: String) {
        guard localNetworkEndpoints.contains(where: { $0.id == id }) else { return }
        selectedLocalEndpointID = id
    }

    func refreshCertificateStatus() async {
        let currentCertificate: Data?
        if isEngineRunning, let url = uiURL {
            currentCertificate = try? await certificateManager.fetchRootCertificate(baseURL: url)
        } else {
            currentCertificate = nil
        }
        certificateHealth = await Task.detached { [certificateManager] in
            certificateManager.health(certificateData: currentCertificate)
        }.value
    }

    func refreshSystemProxyStatus() async {
        let services = selectedNetworkServiceNames
        let port = settings.engine.proxyPort
        systemProxyStatus = await Task.detached { [proxyManager] in
            proxyManager.status(services: services, proxyPort: port)
        }.value
    }

    @discardableResult
    func startEngine() async -> Bool {
        guard !isPerformingEngineOperation else { return false }
        isPerformingEngineOperation = true
        defer { isPerformingEngineOperation = false }
        do {
            try await startEngineThrowing()
            return true
        } catch {
            report(error)
            return false
        }
    }

    func stopEngine() async {
        guard !isPerformingEngineOperation, !isChangingSystemProxy else { return }
        isPerformingEngineOperation = true
        defer { isPerformingEngineOperation = false }
        do {
            try await stopEngineThrowing()
        } catch {
            report(error)
        }
    }

    @discardableResult
    func setSystemProxyEnabled(
        _ enabled: Bool,
        allowDuringEngineOperation: Bool = false
    ) async -> Bool {
        guard !isChangingSystemProxy,
              allowDuringEngineOperation || !isPerformingEngineOperation else { return false }
        isChangingSystemProxy = true
        defer { isChangingSystemProxy = false }
        do {
            if enabled {
                guard isEngineRunning else {
                    throw WhistleYooError.commandFailed(appLocalized("请先启动代理引擎"))
                }
                let services = selectedNetworkServiceNames
                guard !services.isEmpty else {
                    throw WhistleYooError.commandFailed(appLocalized("没有可用的网络服务"))
                }
                let proxyPort = settings.engine.proxyPort
                let socksPort = settings.engine.socksPort
                try await Task.detached { [proxyManager] in
                    try proxyManager.activate(
                        services: services,
                        proxyPort: proxyPort,
                        socksPort: socksPort
                    )
                }.value
            } else {
                let services = proxyCleanupServices
                let proxyPort = settings.engine.proxyPort
                let socksPort = settings.engine.socksPort
                try await Task.detached { [proxyManager] in
                    try proxyManager.deactivate(
                        services: services,
                        proxyPort: proxyPort,
                        socksPort: socksPort
                    )
                }.value
            }
            await refreshSystemProxyStatus()
            return enabled ? isSystemProxyEnabled : true
        } catch {
            report(error)
            await refreshSystemProxyStatus()
            return false
        }
    }

    func toggleSystemProxy() async {
        _ = await setSystemProxyEnabled(!isSystemProxyActiveOrPartial)
    }

    @discardableResult
    func updatePorts(proxyPort: Int, uiPort: Int) async -> Bool {
        guard !isPerformingEngineOperation, !isChangingSystemProxy else {
            report(WhistleYooError.commandFailed(appLocalized("请等待当前代理操作完成后再试")))
            return false
        }
        guard (1...65535).contains(proxyPort), (1...65535).contains(uiPort), proxyPort != uiPort else {
            report(WhistleYooError.commandFailed(appLocalized("端口必须位于 1–65535，且代理端口和 Web UI 端口不能相同")))
            return false
        }
        guard proxyPort != settings.engine.proxyPort || uiPort != settings.engine.uiPort else {
            return true
        }

        let oldConfiguration = settings.engine
        let wasRunning = isEngineRunning
        let shouldRestoreProxy = isSystemProxyActiveOrPartial
        isPerformingEngineOperation = true
        defer { isPerformingEngineOperation = false }

        do {
            if wasRunning {
                try await stopEngineThrowing()
            }
            guard portChecker.isAvailable(port: proxyPort, host: oldConfiguration.listenHost) else {
                throw WhistleYooError.portInUse(proxyPort)
            }
            guard portChecker.isAvailable(port: uiPort, host: oldConfiguration.uiHost) else {
                throw WhistleYooError.portInUse(uiPort)
            }

            settings.engine.proxyPort = proxyPort
            settings.engine.uiPort = uiPort
            try persistSettings()
            engine?.update(configuration: settings.engine)

            if wasRunning {
                try await startEngineThrowing()
                if shouldRestoreProxy {
                    guard await setSystemProxyEnabled(
                        true,
                        allowDuringEngineOperation: true
                    ) else {
                        throw WhistleYooError.commandFailed(
                            appLocalized("端口已更新，但系统代理未能重新启用")
                        )
                    }
                }
            }
            return true
        } catch {
            let updateError = error
            if isEngineRunning {
                do {
                    try await stopEngineThrowing()
                } catch {
                    report(WhistleYooError.commandFailed(appLocalizedFormat(
                        "端口更新失败：%@；停止新配置失败：%@",
                        updateError.localizedDescription,
                        error.localizedDescription
                    )))
                    return false
                }
            }
            settings.engine = oldConfiguration
            try? persistSettings()
            engine?.update(configuration: oldConfiguration)
            if wasRunning, !isEngineRunning {
                do {
                    try await startEngineThrowing()
                    if shouldRestoreProxy,
                       !(await setSystemProxyEnabled(
                            true,
                            allowDuringEngineOperation: true
                       )) {
                        throw WhistleYooError.commandFailed(
                            appLocalized("旧端口已恢复，但系统代理未能重新启用")
                        )
                    }
                } catch {
                    report(WhistleYooError.commandFailed(appLocalizedFormat(
                        "端口更新失败：%@；恢复旧配置失败：%@",
                        updateError.localizedDescription,
                        error.localizedDescription
                    )))
                    return false
                }
            }
            report(updateError)
            return false
        }
    }

    func portConflicts() -> [Int] {
        guard !isEngineRunning else { return [] }
        var conflicts: [Int] = []
        if !portChecker.isAvailable(
            port: settings.engine.proxyPort,
            host: settings.engine.listenHost
        ) {
            conflicts.append(settings.engine.proxyPort)
        }
        if !portChecker.isAvailable(
            port: settings.engine.uiPort,
            host: settings.engine.uiHost
        ) {
            conflicts.append(settings.engine.uiPort)
        }
        return conflicts
    }

    @discardableResult
    func installCertificate() async -> Bool {
        do {
            guard await startEngine() else { return false }
            guard let url = uiURL else {
                throw WhistleYooError.certificateNotFound
            }
            let certificate = try await certificateManager.fetchRootCertificate(baseURL: url)
            let record = try certificateManager.install(certificateData: certificate)
            settings.certificateStepSkipped = false
            try persistSettings()
            await refreshCertificateStatus()
            onMessage?(appLocalizedFormat("根证书已安装到当前用户钥匙串。\nSHA-256：%@", record.sha256))
            return true
        } catch {
            report(error)
            await refreshCertificateStatus()
            return false
        }
    }

    func certificateData() async throws -> Data {
        guard await startEngine(), let url = uiURL else {
            throw WhistleYooError.certificateNotFound
        }
        return try await certificateManager.fetchRootCertificate(baseURL: url)
    }

    @discardableResult
    func exportConfiguration(to url: URL) async -> Bool {
        do {
            if !hasCompleteRulesSnapshot {
                guard await loadRules() else { return false }
            }
            let configuration = WhistleYooConfigurationFile(
                settings: settings,
                rules: rulesSnapshot
            )
            try configurationStore.save(configuration, to: url.standardizedFileURL)
            return true
        } catch {
            report(error)
            return false
        }
    }

    @discardableResult
    func useConfigurationFile(at url: URL) async -> Bool {
        let targetURL = url.standardizedFileURL
        guard await exportConfiguration(to: targetURL) else { return false }
        configurationFileURL = targetURL
        configurationLocationDefaults.set(
            targetURL.path,
            forKey: Self.configurationLocationKey
        )
        return true
    }

    @discardableResult
    func restoreDefaultConfigurationFileLocation() async -> Bool {
        let targetURL = configurationStore.defaultFileURL.standardizedFileURL
        guard await exportConfiguration(to: targetURL) else { return false }
        configurationFileURL = targetURL
        configurationLocationDefaults.removeObject(forKey: Self.configurationLocationKey)
        return true
    }

    @discardableResult
    func importConfiguration(from url: URL) async -> Bool {
        guard !isImportingConfiguration, !isTransitioning,
              !isLoadingRules, !isSavingRules else {
            report(WhistleYooError.commandFailed(appLocalized("请等待当前操作完成后再导入配置")))
            return false
        }

        let imported: WhistleYooConfigurationFile
        do {
            imported = try configurationStore.load(from: url.standardizedFileURL)
        } catch {
            report(error)
            return false
        }

        let engineWasRunning = isEngineRunning
        let shouldRestoreProxy = isSystemProxyActiveOrPartial
        let originalSettings = settings
        let originalLaunchAtLogin = launchAtLoginEnabled
        let originalPendingStartupRules = pendingStartupRules
        var originalRules: WhistleRulesSnapshot?
        pendingStartupRules = nil
        isImportingConfiguration = true

        do {
            if !hasCompleteRulesSnapshot {
                guard await loadRules() else {
                    throw WhistleYooError.commandFailed(appLocalized("无法读取当前规则，配置未导入"))
                }
            }
            originalRules = rulesSnapshot

            if isEngineRunning {
                try await stopEngineThrowing()
            }
            settings = imported.settings
            if let environment {
                configureEngine(environment: environment)
            }
            try await startEngineThrowing()
            try await applyImportedRulesThrowing(imported.rules)

            try settingsStore.save(settings)
            try AutoLaunchManager().setEnabled(settings.launchAtLogin)
            launchAtLoginEnabled = AutoLaunchManager().isEnabled

            if shouldRestoreProxy {
                guard await setSystemProxyEnabled(true) else {
                    throw WhistleYooError.commandFailed(appLocalized("配置已导入，但系统代理未能重新启用"))
                }
            }
            if !engineWasRunning, !shouldRestoreProxy {
                try await stopEngineThrowing()
            }
            isImportingConfiguration = false
            await synchronizeConfigurationFile()
            return true
        } catch {
            let importError = error
            if isEngineRunning {
                try? await stopEngineThrowing()
            }
            settings = originalSettings
            try? settingsStore.save(originalSettings)
            try? AutoLaunchManager().setEnabled(originalLaunchAtLogin)
            launchAtLoginEnabled = AutoLaunchManager().isEnabled
            if let environment {
                configureEngine(environment: environment)
            }
            if engineWasRunning || shouldRestoreProxy || originalRules != nil {
                do {
                    try await startEngineThrowing()
                    if let originalRules {
                        try await applyImportedRulesThrowing(originalRules)
                    }
                    if shouldRestoreProxy {
                        _ = await setSystemProxyEnabled(true)
                    }
                    if !engineWasRunning, !shouldRestoreProxy {
                        try await stopEngineThrowing()
                    }
                } catch {
                    pendingStartupRules = originalPendingStartupRules
                    isImportingConfiguration = false
                    report(WhistleYooError.commandFailed(appLocalizedFormat(
                        "配置导入失败：%@；恢复原配置失败：%@",
                        importError.localizedDescription,
                        error.localizedDescription
                    )))
                    return false
                }
            }
            pendingStartupRules = originalPendingStartupRules
            isImportingConfiguration = false
            report(importError)
            return false
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try AutoLaunchManager().setEnabled(enabled)
            launchAtLoginEnabled = AutoLaunchManager().isEnabled
            settings.launchAtLogin = launchAtLoginEnabled
            try persistSettings()
        } catch {
            launchAtLoginEnabled = AutoLaunchManager().isEnabled
            report(error)
        }
    }

    func setShowDockIcon(_ isVisible: Bool) {
        guard showDockIcon != isVisible else { return }

        // Publish the requested state before changing AppKit's activation policy.
        // setActivationPolicy may synchronously activate/deactivate the app, so any
        // delegate callback must observe the new value instead of the stale one.
        let previousValue = showDockIcon
        showDockIcon = isVisible
        guard onDockVisibilityChange?(isVisible) == true else {
            showDockIcon = previousValue
            report(WhistleYooError.commandFailed(appLocalized("无法更新程序坞显示状态")))
            return
        }
        dockVisibilityPreference.setVisible(isVisible)
    }

    func setSoftwareDomainWhitelistEnabled(_ enabled: Bool) async {
        guard settings.softwareDomainWhitelistEnabled != enabled else { return }
        settings.softwareDomainWhitelistEnabled = enabled
        do {
            try persistSettings()
            if isEngineRunning, let url = uiURL {
                try await softwareWhitelistManager.sync(
                    baseURL: url,
                    enabled: enabled,
                    domains: settings.softwareDomainWhitelistDomains
                )
            }
        } catch {
            report(error)
        }
    }

    func updateSoftwareDomainWhitelistDomains(_ domains: [String]) async -> Bool {
        let normalized = SoftwareDomainWhitelistManager.normalizedDomains(domains)
        guard !normalized.isEmpty else {
            report(WhistleYooError.commandFailed(appLocalized("请至少保留一个白名单域名")))
            return false
        }
        guard settings.softwareDomainWhitelistDomains != normalized else { return true }

        settings.softwareDomainWhitelistDomains = normalized
        do {
            try persistSettings()
            if isEngineRunning, let url = uiURL, settings.softwareDomainWhitelistEnabled {
                try await softwareWhitelistManager.sync(
                    baseURL: url,
                    enabled: true,
                    domains: normalized
                )
            }
            return true
        } catch {
            report(error)
            return false
        }
    }

    @discardableResult
    func loadRules() async -> Bool {
        guard !isLoadingRules else { return false }
        isLoadingRules = true
        defer { isLoadingRules = false }
        guard await startEngine(), let baseURL = uiURL else { return false }
        do {
            let loaded = try await rulesManager.load(baseURL: baseURL)
            rulesSnapshot = snapshotForEditing(loaded)
            return true
        } catch {
            report(error)
            return false
        }
    }

    @discardableResult
    func saveRule(name: String, value: String, isEnabled: Bool) async -> Bool {
        guard !isSavingRules else { return false }
        isSavingRules = true
        defer { isSavingRules = false }
        guard await startEngine(), let baseURL = uiURL else { return false }
        do {
            let persistedValue = name == "Default"
                ? SoftwareDomainWhitelistManager.mergingManagedRules(
                    into: value,
                    enabled: settings.softwareDomainWhitelistEnabled,
                    domains: settings.softwareDomainWhitelistDomains
                )
                : value
            try await rulesManager.save(
                name: name,
                value: persistedValue,
                isEnabled: isEnabled,
                baseURL: baseURL
            )
            try await reloadRules(baseURL: baseURL)
            await synchronizeConfigurationFile()
            return true
        } catch {
            report(error)
            return false
        }
    }

    @discardableResult
    func saveRulesSnapshot(_ updated: WhistleRulesSnapshot) async -> Bool {
        guard !isSavingRules else { return false }
        isSavingRules = true
        defer { isSavingRules = false }
        guard await startEngine(), let baseURL = uiURL else { return false }
        do {
            try await rulesManager.applyChanges(
                from: rulesSnapshot,
                to: updated,
                baseURL: baseURL
            )
            try await reloadRules(baseURL: baseURL)
            await synchronizeConfigurationFile()
            return true
        } catch {
            report(error)
            return false
        }
    }

    @discardableResult
    func createRule(name: String) async -> Bool {
        guard !rulesSnapshot.documents.contains(where: { $0.name == name }) else {
            report(WhistleYooError.commandFailed(appLocalized("已存在同名规则")))
            return false
        }
        return await saveRule(name: name, value: "", isEnabled: true)
    }

    @discardableResult
    func deleteRule(name: String) async -> Bool {
        guard !isSavingRules else { return false }
        isSavingRules = true
        defer { isSavingRules = false }
        guard await startEngine(), let baseURL = uiURL else { return false }
        do {
            try await rulesManager.delete(name: name, baseURL: baseURL)
            try await reloadRules(baseURL: baseURL)
            await synchronizeConfigurationFile()
            return true
        } catch {
            report(error)
            return false
        }
    }

    @discardableResult
    func renameRule(name: String, to newName: String) async -> Bool {
        guard !rulesSnapshot.documents.contains(where: { $0.name == newName }) else {
            report(WhistleYooError.commandFailed(appLocalized("已存在同名规则")))
            return false
        }
        guard !isSavingRules else { return false }
        isSavingRules = true
        defer { isSavingRules = false }
        guard await startEngine(), let baseURL = uiURL else { return false }
        do {
            try await rulesManager.rename(name: name, to: newName, baseURL: baseURL)
            try await reloadRules(baseURL: baseURL)
            await synchronizeConfigurationFile()
            return true
        } catch {
            report(error)
            return false
        }
    }

    @discardableResult
    func setRuleEnabled(_ enabled: Bool, name: String) async -> Bool {
        guard !isSavingRules else { return false }
        isSavingRules = true
        defer { isSavingRules = false }
        guard await startEngine(), let baseURL = uiURL else { return false }
        do {
            guard let document = rulesSnapshot.documents.first(where: { $0.name == name }) else {
                throw WhistleYooError.commandFailed(appLocalized("未找到要更新的规则"))
            }
            let persistedValue = document.isDefault
                ? SoftwareDomainWhitelistManager.mergingManagedRules(
                    into: document.value,
                    enabled: settings.softwareDomainWhitelistEnabled,
                    domains: settings.softwareDomainWhitelistDomains
                )
                : document.value
            try await rulesManager.setEnabled(
                enabled,
                name: name,
                value: persistedValue,
                baseURL: baseURL
            )
            try await reloadRules(baseURL: baseURL)
            await synchronizeConfigurationFile()
            return true
        } catch {
            report(error)
            return false
        }
    }

    func updateSelectedNetworkServices(_ names: Set<String>) {
        guard !isChangingSystemProxy, !isPerformingEngineOperation else {
            report(WhistleYooError.commandFailed(appLocalized("请等待当前代理操作完成后再试")))
            return
        }
        guard !names.isEmpty else {
            report(WhistleYooError.commandFailed(appLocalized("请至少选择一个网络服务")))
            return
        }
        guard systemProxyStatus != .enabledByThisApp,
              systemProxyStatus != .partiallyEnabled else {
            report(WhistleYooError.commandFailed(appLocalized("请先关闭系统代理，再修改网络服务")))
            return
        }
        settings.selectedNetworkServices = networkServices
            .map(\.name)
            .filter { names.contains($0) }
        do {
            try persistSettings()
        } catch {
            report(error)
        }
    }

    func completeOnboarding(enableSystemProxy: Bool, skippedCertificate: Bool) async {
        settings.completedOnboardingVersion = PersistedSettings.currentOnboardingVersion
        settings.certificateStepSkipped = skippedCertificate
        do {
            try persistSettings()
        } catch {
            report(error)
        }
        if enableSystemProxy {
            _ = await setSystemProxyEnabled(true)
        }
        if isEngineRunning, !hasCompleteRulesSnapshot, let baseURL = uiURL {
            try? await reloadRules(baseURL: baseURL)
            await synchronizeConfigurationFile()
        }
    }

    func resetOnboarding() {
        settings.completedOnboardingVersion = nil
        do {
            try persistSettings()
        } catch {
            report(error)
        }
    }

    func clearError() {
        lastErrorMessage = nil
    }

    func shutdown() async throws {
        guard !isPerformingEngineOperation, !isChangingSystemProxy else {
            throw WhistleYooError.commandFailed(appLocalized("请等待当前代理操作完成后再退出"))
        }
        isPerformingEngineOperation = true
        defer { isPerformingEngineOperation = false }
        configurationSyncTask?.cancel()
        configurationSyncTask = nil
        await synchronizeConfigurationFile()
        let services = proxyCleanupServices
        let proxyPort = settings.engine.proxyPort
        let socksPort = settings.engine.socksPort
        try await Task.detached { [proxyManager] in
            try proxyManager.deactivate(
                services: services,
                proxyPort: proxyPort,
                socksPort: socksPort
            )
        }.value
        monitorTask?.cancel()
        monitorTask = nil
        if let engine {
            try await engine.stop()
        }
        await refreshSystemProxyStatus()
    }

    private var isEngineFailed: Bool {
        if case .failed = engineState { return true }
        return false
    }

    private func configureEngine(environment: EnvironmentInfo) {
        let controller = WhistleEngineController(
            environment: environment,
            configuration: settings.engine,
            rootCertificatePreparer: certificateManager
        )
        controller.onStateChange = { [weak self] state in
            guard let self else { return }
            self.engineState = state
            if case .running = state, let uiURL = self.uiURL {
                self.onEngineReady?(uiURL)
            }
        }
        engine = controller
        engineState = controller.state
    }

    private func startEngineThrowing() async throws {
        if engine == nil, let environment {
            configureEngine(environment: environment)
        }
        guard let engine else {
            throw WhistleYooError.environmentUnavailable(appLocalized("Node.js 或 Whistle 环境未就绪"))
        }
        try await engine.start()
        await refreshCertificateStatus()
        do {
            try await softwareWhitelistManager.sync(
                baseURL: engine.uiURL,
                enabled: settings.softwareDomainWhitelistEnabled,
                domains: settings.softwareDomainWhitelistDomains
            )
        } catch {
            report(error)
        }
        if let pendingStartupRules,
           await applyImportedRules(pendingStartupRules) {
            self.pendingStartupRules = nil
        }
        if pendingStartupRules == nil {
            if !hasCompleteRulesSnapshot {
                do {
                    try await reloadRules(baseURL: engine.uiURL)
                } catch {
                    report(error)
                }
            }
            await synchronizeConfigurationFile()
        }
        startMonitoring()
        await refreshSystemProxyStatus()
    }

    private func stopEngineThrowing() async throws {
        let services = proxyCleanupServices
        let proxyPort = settings.engine.proxyPort
        let socksPort = settings.engine.socksPort
        try await Task.detached { [proxyManager] in
            try proxyManager.deactivate(
                services: services,
                proxyPort: proxyPort,
                socksPort: socksPort
            )
        }.value
        monitorTask?.cancel()
        monitorTask = nil
        await refreshSystemProxyStatus()
        try await engine?.stop()
    }

    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                await self.engine?.checkAndRecover()
                await self.refreshSystemProxyStatus()
                if !self.isEngineRunning,
                   (self.systemProxyStatus == .enabledByThisApp
                    || self.systemProxyStatus == .partiallyEnabled) {
                    _ = await self.setSystemProxyEnabled(false)
                }
            }
        }
    }

    private func reloadRules(baseURL: URL) async throws {
        rulesSnapshot = snapshotForEditing(try await rulesManager.load(baseURL: baseURL))
    }

    private var hasCompleteRulesSnapshot: Bool {
        rulesSnapshot.documents.filter(\.isDefault).count == 1
    }

    private func applyImportedRules(_ imported: WhistleRulesSnapshot) async -> Bool {
        guard let baseURL = uiURL else {
            report(WhistleYooError.commandFailed(appLocalized("代理引擎未就绪，无法应用规则配置")))
            return false
        }
        var original: WhistleRulesSnapshot?
        do {
            original = snapshotForEditing(try await rulesManager.load(baseURL: baseURL))
            try await applyImportedRulesThrowing(imported)
            return true
        } catch {
            if let original,
               let current = try? await rulesManager.load(baseURL: baseURL) {
                try? await rulesManager.applyChanges(
                    from: snapshotForEditing(current),
                    to: original,
                    baseURL: baseURL
                )
                try? await reloadRules(baseURL: baseURL)
            }
            report(error)
            return false
        }
    }

    private func applyImportedRulesThrowing(_ imported: WhistleRulesSnapshot) async throws {
        guard let baseURL = uiURL else {
            throw WhistleYooError.commandFailed(appLocalized("代理引擎未就绪，无法应用规则配置"))
        }
        let current = snapshotForEditing(try await rulesManager.load(baseURL: baseURL))
        guard let currentDefault = current.documents.first(where: \.isDefault) else {
            throw WhistleYooError.commandFailed(appLocalized("当前规则缺少 Default，无法导入配置"))
        }
        let target = WhistleRulesSnapshot(
            documents: [currentDefault] + imported.documents.filter { !$0.isDefault },
            allowMultipleChoice: true,
            backRulesFirst: imported.backRulesFirst
        )
        try await rulesManager.applyChanges(from: current, to: target, baseURL: baseURL)
        try await reloadRules(baseURL: baseURL)
    }

    private func persistSettings() throws {
        try settingsStore.save(settings)
        scheduleConfigurationSynchronization()
    }

    private func scheduleConfigurationSynchronization() {
        // Do not overwrite a cloud-synced startup snapshot before its rules
        // have been applied. On first launch, onboarding delays engine startup
        // until after `launch()` has returned.
        guard !isImportingConfiguration, pendingStartupRules == nil else { return }
        configurationSyncTask?.cancel()
        configurationSyncTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            await self.synchronizeConfigurationFile()
        }
    }

    private func synchronizeConfigurationFile() async {
        guard !isImportingConfiguration else { return }
        let rules: WhistleRulesSnapshot
        if hasCompleteRulesSnapshot {
            rules = rulesSnapshot
        } else if let existing = try? configurationStore.load(from: configurationFileURL) {
            rules = existing.rules
        } else {
            return
        }
        do {
            try configurationStore.save(
                WhistleYooConfigurationFile(settings: settings, rules: rules),
                to: configurationFileURL
            )
        } catch {
            report(error)
        }
    }

    private func snapshotForEditing(_ snapshot: WhistleRulesSnapshot) -> WhistleRulesSnapshot {
        WhistleRulesSnapshot(
            documents: snapshot.documents.map { document in
                guard document.isDefault else { return document }
                return WhistleRuleDocument(
                    name: document.name,
                    value: SoftwareDomainWhitelistManager.removingManagedRules(from: document.value),
                    isEnabled: document.isEnabled,
                    isDefault: true
                )
            },
            allowMultipleChoice: true,
            backRulesFirst: snapshot.backRulesFirst
        )
    }

    private func report(_ error: Error) {
        lastErrorMessage = error.localizedDescription
        onError?(error)
    }

    private var proxyCleanupServices: [String] {
        // Inspect every service that exists on this Mac so orphaned endpoints
        // can still be cleaned up, but never pass synchronized names from a
        // different Mac to `networksetup`.
        networkServices.map(\.name)
    }

    private var isSystemProxyActiveOrPartial: Bool {
        systemProxyStatus.indicatesAppProxyIntent
    }

    private func versionString(_ version: SemanticVersion) -> String {
        "\(version.major).\(version.minor).\(version.patch)"
    }
}
