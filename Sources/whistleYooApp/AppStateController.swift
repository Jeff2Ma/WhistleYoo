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
    @Published private(set) var valuesSnapshot = WhistleValuesSnapshot()
    @Published private(set) var isLoadingValues = false
    @Published private(set) var isSavingValues = false
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
    private let valuesManager: WhistleValuesManager
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
    private var pendingStartupValues: WhistleValuesSnapshot?
    private var hasLoadedValuesSnapshot = false
    private static let configurationLocationKey = "WhistleYooConfigurationFilePath"

    init(
        settingsStore: SettingsStore = SettingsStore(),
        proxyManager: SystemProxyManager = SystemProxyManager(),
        certificateManager: CertificateManager = CertificateManager(),
        softwareWhitelistManager: SoftwareDomainWhitelistManager = SoftwareDomainWhitelistManager(),
        rulesManager: WhistleRulesManager = WhistleRulesManager(),
        valuesManager: WhistleValuesManager = WhistleValuesManager(),
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
        self.valuesManager = valuesManager
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
        case .running: return Localization.string(.settingsRunning)
        case .starting: return Localization.string(.statusStarting)
        case .stopping: return Localization.string(.statusStopping)
        case .stopped: return Localization.string(.statusStopped)
        case .failed: return Localization.string(.mobileFailedToStart)
        }
    }

    var systemProxyTitle: String {
        switch systemProxyStatus {
        case .disabled: return Localization.string(.statusNotEnabled)
        case .enabledByThisApp: return Localization.string(.statusConnected)
        case .partiallyEnabled: return Localization.string(.statusPartiallyConnected)
        case .configuredByOther: return Localization.string(.statusAnotherProxyDetected)
        case .unavailable: return Localization.string(.statusStatusUnavailable)
        }
    }

    var statusTitle: String {
        switch applicationStatus {
        case .systemProxyEnabled: return Localization.string(.statusSystemProxyEnabled)
        case .listeningOnly: return Localization.string(.statusProxyListeningOnly)
        case .transitioning:
            return Localization.string(
                engineState == .starting ? .statusStartingProxyEngine : .statusStoppingProxyEngine
            )
        case .stopped: return Localization.string(.statusProxyEngineStopped)
        case .attention: return Localization.string(.statusProxyStatusNeedsAttention)
        case .unavailable: return Localization.string(.statusEnvironmentNotReady)
        }
    }

    var engineDescription: String {
        switch engineState {
        case .running(let version):
            return Localization.format(
                .statusWhistleValue127001Value,
                version,
                String(settings.engine.proxyPort)
            )
        case .failed(let message): return message
        case .starting: return Localization.string(.statusStartingWhistle)
        case .stopping: return Localization.string(.statusStoppingWhistle)
        case .stopped:
            switch environmentStatus {
            case .unavailable(let message): return message
            case .checking: return Localization.string(.statusCheckingNodeJsAndWhistle)
            case .ready: return Localization.string(.statusNodeJsAndWhistleAreReady)
            }
        }
    }

    var proxyDescription: String {
        guard isEngineRunning else { return Localization.string(.statusAvailableAfterStartingTheProxyEngine) }
        switch systemProxyStatus {
        case .disabled: return Localization.string(.statusMacTrafficIsNotConnectedMobileAndManualProxiesAreStillAvailab)
        case .enabledByThisApp: return Localization.string(.statusSelectedNetworkServicesAreUsingTheLocalProxy)
        case .partiallyEnabled: return Localization.string(.statusOnlySomeNetworkServicesAreUsingThisProxy)
        case .configuredByOther: return Localization.string(.statusAnotherProxyConfigurationExistsWhistleyooHasNotTakenControl)
        case .unavailable(let message): return Localization.format(.statusUnableToReadSystemProxySettingsValue, message)
        }
    }

    var environmentDescription: String {
        switch environmentStatus {
        case .checking: return Localization.string(.statusChecking)
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
                pendingStartupValues = configuration.values
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
            environmentStatus = .unavailable(result.1 ?? Localization.string(.statusEnvironmentCheckFailed))
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
                    throw WhistleYooError.commandFailed(Localization.string(.statusStartTheProxyEngineFirst))
                }
                let services = selectedNetworkServiceNames
                guard !services.isEmpty else {
                    throw WhistleYooError.commandFailed(Localization.string(.statusNoNetworkServicesAreAvailable))
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
            report(WhistleYooError.commandFailed(Localization.string(.statusWaitForTheCurrentProxyOperationToFinishThenTryAgain)))
            return false
        }
        guard (1...65535).contains(proxyPort), (1...65535).contains(uiPort), proxyPort != uiPort else {
            report(WhistleYooError.commandFailed(Localization.string(.statusPortsMustBeBetween1And65535AndTheProxyAndWebUiPortsMustDi)))
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
                            Localization.string(.statusThePortsWereUpdatedButTheSystemProxyCouldNotBeReEnabled)
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
                    report(WhistleYooError.commandFailed(Localization.format(
                        .statusPortUpdateFailedValueStoppingTheNewConfigurationAlsoFailedValu,
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
                            Localization.string(.statusThePreviousPortsWereRestoredButTheSystemProxyCouldNotBeReEn)
                        )
                    }
                } catch {
                    report(WhistleYooError.commandFailed(Localization.format(
                        .statusPortUpdateFailedValueRestoringThePreviousConfigurationAlsoFaile,
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
            onMessage?(Localization.format(.coreTheRootCertificateWasInstalledInTheCurrentUserSKeychainSha25, record.sha256))
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
            if !hasLoadedValuesSnapshot {
                guard await loadValues() else { return false }
            }
            let configuration = WhistleYooConfigurationFile(
                settings: settings,
                rules: rulesSnapshot,
                values: valuesSnapshot
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
            report(WhistleYooError.commandFailed(Localization.string(.statusWaitForTheCurrentOperationToFinishBeforeImportingAConfiguratio)))
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
        let originalPendingStartupValues = pendingStartupValues
        var originalRules: WhistleRulesSnapshot?
        var originalValues: WhistleValuesSnapshot?
        pendingStartupRules = nil
        pendingStartupValues = nil
        isImportingConfiguration = true

        do {
            if !hasCompleteRulesSnapshot {
                guard await loadRules() else {
                    throw WhistleYooError.commandFailed(Localization.string(.statusTheCurrentRulesCouldNotBeReadSoTheConfigurationWasNotImporte))
                }
            }
            originalRules = rulesSnapshot
            if !hasLoadedValuesSnapshot {
                guard await loadValues() else {
                    throw WhistleYooError.commandFailed(Localization.string(.statusTheCurrentRulesCouldNotBeReadSoTheConfigurationWasNotImporte))
                }
            }
            originalValues = valuesSnapshot

            if isEngineRunning {
                try await stopEngineThrowing()
            }
            settings = imported.settings
            if let environment {
                configureEngine(environment: environment)
            }
            try await startEngineThrowing()
            try await applyImportedRulesThrowing(imported.rules)
            try await applyImportedValuesThrowing(imported.values)

            try settingsStore.save(settings)
            try AutoLaunchManager().setEnabled(settings.launchAtLogin)
            launchAtLoginEnabled = AutoLaunchManager().isEnabled

            if shouldRestoreProxy {
                guard await setSystemProxyEnabled(true) else {
                    throw WhistleYooError.commandFailed(Localization.string(.statusTheConfigurationWasImportedButTheSystemProxyCouldNotBeReEnab))
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
                    if let originalValues {
                        try await applyImportedValuesThrowing(originalValues)
                    }
                    if shouldRestoreProxy {
                        _ = await setSystemProxyEnabled(true)
                    }
                    if !engineWasRunning, !shouldRestoreProxy {
                        try await stopEngineThrowing()
                    }
                } catch {
                    pendingStartupRules = originalPendingStartupRules
                    pendingStartupValues = originalPendingStartupValues
                    isImportingConfiguration = false
                    report(WhistleYooError.commandFailed(Localization.format(
                        .statusConfigurationImportFailedValueRestoringThePreviousConfigurationA,
                        importError.localizedDescription,
                        error.localizedDescription
                    )))
                    return false
                }
            }
            pendingStartupRules = originalPendingStartupRules
            pendingStartupValues = originalPendingStartupValues
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
            report(WhistleYooError.commandFailed(Localization.string(.statusUnableToUpdateDockVisibility)))
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
            report(WhistleYooError.commandFailed(Localization.string(.statusKeepAtLeastOneAllowlistedDomain)))
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
    func loadValues() async -> Bool {
        guard !isLoadingValues else { return false }
        isLoadingValues = true
        defer { isLoadingValues = false }
        guard await startEngine(), let baseURL = uiURL else { return false }
        do {
            valuesSnapshot = try await valuesManager.load(baseURL: baseURL)
            hasLoadedValuesSnapshot = true
            return true
        } catch {
            report(error)
            return false
        }
    }

    @discardableResult
    func saveValuesSnapshot(_ updated: WhistleValuesSnapshot) async -> Bool {
        guard !isSavingValues else { return false }
        isSavingValues = true
        defer { isSavingValues = false }
        guard await startEngine(), let baseURL = uiURL else { return false }
        do {
            try await valuesManager.applyChanges(
                from: valuesSnapshot,
                to: updated,
                baseURL: baseURL
            )
            valuesSnapshot = try await valuesManager.load(baseURL: baseURL)
            hasLoadedValuesSnapshot = true
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
            report(WhistleYooError.commandFailed(Localization.string(.statusARuleWithThisNameAlreadyExists)))
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
            report(WhistleYooError.commandFailed(Localization.string(.statusARuleWithThisNameAlreadyExists)))
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
                throw WhistleYooError.commandFailed(Localization.string(.statusTheRuleToUpdateCouldNotBeFound))
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
            report(WhistleYooError.commandFailed(Localization.string(.statusWaitForTheCurrentProxyOperationToFinishThenTryAgain)))
            return
        }
        guard !names.isEmpty else {
            report(WhistleYooError.commandFailed(Localization.string(.statusSelectAtLeastOneNetworkService)))
            return
        }
        guard systemProxyStatus != .enabledByThisApp,
              systemProxyStatus != .partiallyEnabled else {
            report(WhistleYooError.commandFailed(Localization.string(.settingsDisableTheSystemProxyBeforeChangingNetworkServices)))
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
            throw WhistleYooError.commandFailed(Localization.string(.statusWaitForTheCurrentProxyOperationToFinishBeforeQuitting))
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
            throw WhistleYooError.environmentUnavailable(Localization.string(.statusTheNodeJsOrWhistleEnvironmentIsNotReady))
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
        if let pendingStartupValues,
           await applyImportedValues(pendingStartupValues) {
            self.pendingStartupValues = nil
        }
        if pendingStartupRules == nil, pendingStartupValues == nil {
            if !hasCompleteRulesSnapshot {
                do {
                    try await reloadRules(baseURL: engine.uiURL)
                } catch {
                    report(error)
                }
            }
            if !hasLoadedValuesSnapshot {
                _ = await loadValues()
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
            report(WhistleYooError.commandFailed(Localization.string(.statusTheProxyEngineIsNotReadySoTheRuleConfigurationCannotBeApplie)))
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
            throw WhistleYooError.commandFailed(Localization.string(.statusTheProxyEngineIsNotReadySoTheRuleConfigurationCannotBeApplie))
        }
        let current = snapshotForEditing(try await rulesManager.load(baseURL: baseURL))
        guard let currentDefault = current.documents.first(where: \.isDefault) else {
            throw WhistleYooError.commandFailed(Localization.string(.statusTheCurrentRulesAreMissingDefaultSoTheConfigurationCannotBeImp))
        }
        let target = WhistleRulesSnapshot(
            documents: [currentDefault] + imported.documents.filter { !$0.isDefault },
            allowMultipleChoice: true,
            backRulesFirst: imported.backRulesFirst
        )
        try await rulesManager.applyChanges(from: current, to: target, baseURL: baseURL)
        try await reloadRules(baseURL: baseURL)
    }

    private func applyImportedValues(_ imported: WhistleValuesSnapshot) async -> Bool {
        guard let baseURL = uiURL else { return false }
        do {
            let original = try await valuesManager.load(baseURL: baseURL)
            try await valuesManager.applyChanges(from: original, to: imported, baseURL: baseURL)
            valuesSnapshot = try await valuesManager.load(baseURL: baseURL)
            hasLoadedValuesSnapshot = true
            return true
        } catch {
            report(error)
            return false
        }
    }

    private func applyImportedValuesThrowing(_ imported: WhistleValuesSnapshot) async throws {
        guard let baseURL = uiURL else {
            throw WhistleYooError.commandFailed(Localization.string(.statusTheProxyEngineIsNotReadySoTheRuleConfigurationCannotBeApplie))
        }
        let current = try await valuesManager.load(baseURL: baseURL)
        try await valuesManager.applyChanges(from: current, to: imported, baseURL: baseURL)
        valuesSnapshot = try await valuesManager.load(baseURL: baseURL)
        hasLoadedValuesSnapshot = true
    }

    private func persistSettings() throws {
        try settingsStore.save(settings)
        scheduleConfigurationSynchronization()
    }

    private func scheduleConfigurationSynchronization() {
        // Do not overwrite a cloud-synced startup snapshot before its rules
        // have been applied. On first launch, onboarding delays engine startup
        // until after `launch()` has returned.
        guard !isImportingConfiguration,
              pendingStartupRules == nil,
              pendingStartupValues == nil else { return }
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
        let values: WhistleValuesSnapshot
        if hasLoadedValuesSnapshot {
            values = valuesSnapshot
        } else if let existing = try? configurationStore.load(from: configurationFileURL) {
            values = existing.values
        } else {
            return
        }
        do {
            try configurationStore.save(
                WhistleYooConfigurationFile(settings: settings, rules: rules, values: values),
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
