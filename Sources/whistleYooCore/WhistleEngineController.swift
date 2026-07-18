import Foundation

@MainActor
public final class WhistleEngineController {
    public private(set) var state: EngineState = .stopped {
        didSet { onStateChange?(state) }
    }
    public var onStateChange: ((EngineState) -> Void)?

    private let environment: EnvironmentInfo
    private var configuration: EngineConfiguration
    private let runner: ProcessRunning
    private let healthChecker: EngineHealthChecking
    private let portChecker: PortAvailabilityChecking
    private let processCleaner: ManagedProcessCleaning
    private let rootCertificatePreparer: RootCertificatePreparing
    private let fileManager: FileManager
    private var intentionalStop = false
    private var restartAttempts = 0

    public init(
        environment: EnvironmentInfo,
        configuration: EngineConfiguration,
        runner: ProcessRunning = FoundationProcessRunner(),
        healthChecker: EngineHealthChecking = EngineHealthChecker(),
        portChecker: PortAvailabilityChecking = PortChecker(),
        processCleaner: ManagedProcessCleaning = ManagedProcessCleaner(),
        rootCertificatePreparer: RootCertificatePreparing = CertificateManager(),
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.configuration = configuration
        self.runner = runner
        self.healthChecker = healthChecker
        self.portChecker = portChecker
        self.processCleaner = processCleaner
        self.rootCertificatePreparer = rootCertificatePreparer
        self.fileManager = fileManager
    }

    public var uiURL: URL { configuration.uiURL }

    public func update(configuration: EngineConfiguration) {
        precondition(state == .stopped || isFailed, "运行期间不能修改引擎配置")
        self.configuration = configuration
    }

    public func start() async throws {
        guard state == .stopped || isFailed else { return }
        intentionalStop = false
        state = .starting
        do {
            try await prepareDirectoriesAndCertificate()

            if let health = await healthChecker.check(baseURL: uiURL),
               await managedStatusIsRunning() {
                state = .running(version: health.version)
                restartAttempts = 0
                return
            }
            _ = try? await cleanupManagedProcesses()
            let portsAvailable = await checkConfiguredPorts()
            guard portsAvailable.proxy else {
                throw WhistleYooError.portInUse(configuration.proxyPort)
            }
            guard portsAvailable.ui else {
                throw WhistleYooError.portInUse(configuration.uiPort)
            }

            let result = try await executeWhistle(arguments: startArguments(), timeout: 20)
            guard result.exitCode == 0 else {
                throw WhistleYooError.commandFailed(commandMessage(result))
            }
            guard let health = await healthChecker.waitUntilReady(baseURL: uiURL, timeout: 15) else {
                _ = try? await executeWhistle(
                    arguments: ["stop", "-S", configuration.storageName], timeout: 10
                )
                throw WhistleYooError.engineDidNotBecomeReady
            }
            guard let version = SemanticVersion(health.version),
                  version >= EnvironmentDetector.minimumWhistleVersion else {
                throw WhistleYooError.unsupportedVersion(coreLocalizedFormat("运行中的 Whistle 版本不受支持：%@", health.version))
            }
            restartAttempts = 0
            state = .running(version: health.version)
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    public func stop() async throws {
        guard state != .stopped, state != .stopping else { return }
        intentionalStop = true
        state = .stopping
        let result = try await executeWhistle(
            arguments: ["stop", "-S", configuration.storageName], timeout: 15
        )
        guard result.exitCode == 0 else {
            state = .failed(commandMessage(result))
            throw WhistleYooError.commandFailed(commandMessage(result))
        }
        guard await healthChecker.waitUntilStopped(baseURL: uiURL, timeout: 10) else {
            state = .failed(WhistleYooError.engineDidNotStop.localizedDescription)
            throw WhistleYooError.engineDidNotStop
        }
        _ = try? await cleanupManagedProcesses()
        restartAttempts = 0
        state = .stopped
    }

    public func checkAndRecover(maximumAttempts: Int = 3) async {
        guard case .running = state, !intentionalStop else { return }
        guard await healthChecker.check(baseURL: uiURL) == nil else {
            restartAttempts = 0
            return
        }
        guard restartAttempts < maximumAttempts else {
            state = .failed(coreLocalized("Whistle 连续异常退出，已停止自动重启"))
            return
        }
        restartAttempts += 1
        _ = try? await executeWhistle(
            arguments: ["stop", "-S", configuration.storageName], timeout: 8
        )
        state = .stopped
        try? await Task.sleep(for: .seconds(2))
        try? await start()
    }

    public func isHealthy() async -> Bool {
        await healthChecker.check(baseURL: uiURL) != nil
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func prepareDirectoriesAndCertificate() async throws {
        let configuration = configuration
        let fileManager = fileManager
        let rootCertificatePreparer = rootCertificatePreparer
        try await Task.detached {
            try fileManager.createDirectory(
                at: configuration.baseDirectory,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: configuration.runtimeDirectory,
                withIntermediateDirectories: true
            )
            try rootCertificatePreparer.prepareRootCertificate(
                in: configuration.customCertificateDirectory
            )
        }.value
    }

    private func startArguments() -> [String] {
        var arguments = [
            "start",
            "-D", configuration.baseDirectory.path,
            "-z", configuration.customCertificateDirectory.path,
            "-S", configuration.storageName,
            "-H", configuration.listenHost,
            "-p", String(configuration.proxyPort),
            "-P", "\(configuration.uiHost):\(configuration.uiPort)"
        ]
        if let socksPort = configuration.socksPort {
            arguments += ["--socksPort", String(socksPort)]
        }
        if !configuration.pluginPaths.isEmpty {
            arguments += ["-A", configuration.pluginPaths.joined(separator: ",")]
        }
        if let mode = configuration.mode, !mode.isEmpty {
            arguments += ["-M", mode]
        }
        return arguments
    }

    private func managedStatusIsRunning() async -> Bool {
        guard let result = try? await executeWhistle(
            arguments: ["status", "-S", configuration.storageName], timeout: 8
        ) else { return false }
        return (result.standardOutput + result.standardError).contains(" is running")
    }

    private func checkConfiguredPorts() async -> (proxy: Bool, ui: Bool) {
        let configuration = configuration
        let portChecker = portChecker
        return await Task.detached {
            (
                proxy: portChecker.isAvailable(
                    port: configuration.proxyPort,
                    host: configuration.listenHost
                ),
                ui: portChecker.isAvailable(
                    port: configuration.uiPort,
                    host: configuration.uiHost
                )
            )
        }.value
    }

    private func cleanupManagedProcesses() async throws -> [Int32] {
        let processCleaner = processCleaner
        let baseDirectory = configuration.baseDirectory
        return try await Task.detached {
            try processCleaner.cleanup(baseDirectory: baseDirectory)
        }.value
    }

    private func executeWhistle(
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> CommandResult {
        let environment = environment
        let configuration = configuration
        let runner = runner
        let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let executionPath = [
            environment.whistleURL.deletingLastPathComponent().path,
            environment.nodeURL.deletingLastPathComponent().path,
            inheritedPath
        ].joined(separator: ":")
        return try await Task.detached {
            try runner.run(
                executableURL: environment.whistleURL,
                arguments: arguments,
                environment: [
                    "STARTING_DATA_DIR": configuration.runtimeDirectory.path,
                    "WHISTLE_PATH": configuration.baseDirectory.deletingLastPathComponent().path,
                    "PATH": executionPath
                ],
                timeout: timeout
            )
        }.value
    }

    private func commandMessage(_ result: CommandResult) -> String {
        let message = (result.standardError + "\n" + result.standardOutput)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? coreLocalizedFormat("Whistle 命令执行失败（%lld）", result.exitCode) : message
    }
}
