import XCTest
@testable import whistleYooCore

final class NetworkAndProxyTests: XCTestCase {
    func testPortableNetworkServiceSelectionUsesMatchingServicesOnCurrentMac() {
        let services = [
            NetworkService(name: "Wi-Fi", device: "en0", hardwarePort: "Wi-Fi", disabled: false),
            NetworkService(name: "USB LAN", device: "en5", hardwarePort: "USB LAN", disabled: false)
        ]

        XCTAssertEqual(
            NetworkServiceSelection.resolve(
                selectedNames: ["Wi-Fi", "Thunderbolt Ethernet"],
                availableServices: services
            ),
            ["Wi-Fi"]
        )
    }

    func testPortableNetworkServiceSelectionFallsBackWhenNoSavedServiceExists() {
        let services = [
            NetworkService(name: "Wi-Fi", device: "en0", hardwarePort: "Wi-Fi", disabled: false),
            NetworkService(name: "USB LAN", device: "en5", hardwarePort: "USB LAN", disabled: false)
        ]

        XCTAssertEqual(
            NetworkServiceSelection.resolve(
                selectedNames: ["Other Mac VPN"],
                availableServices: services
            ),
            ["Wi-Fi", "USB LAN"]
        )
    }

    func testEmptyNetworkServiceSelectionStillMeansAllAvailableServices() {
        let services = [
            NetworkService(name: "Wi-Fi", device: "en0", hardwarePort: "Wi-Fi", disabled: false)
        ]

        XCTAssertEqual(
            NetworkServiceSelection.resolve(selectedNames: [], availableServices: services),
            ["Wi-Fi"]
        )
    }

    func testFormatsRootCertificateNameWithReadableDateTime() throws {
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 11, hour: 9, minute: 8, second: 7
        )))

        XCTAssertEqual(
            CertificateManager.rootCertificateName(
                for: date,
                computerName: "Example-Mac",
                timeZone: timeZone
            ),
            "WhistleYoo.Example-Mac.20260711090807"
        )
    }

    func testPreparesAndReusesCustomRootCertificate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let certificateDirectory = root.appendingPathComponent("certificates")
        try FileManager.default.createDirectory(
            at: certificateDirectory,
            withIntermediateDirectories: true
        )
        try Data("legacy-key".utf8).write(
            to: certificateDirectory.appendingPathComponent("root.key")
        )
        try Data("legacy-certificate".utf8).write(
            to: certificateDirectory.appendingPathComponent("root.crt")
        )
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 11, hour: 9, minute: 8, second: 7
        )))
        let runner = RecordingProcessRunner { _, arguments, _ in
            let keyIndex = try XCTUnwrap(arguments.firstIndex(of: "-keyout"))
            let certificateIndex = try XCTUnwrap(arguments.firstIndex(of: "-out"))
            try Data("private-key".utf8).write(
                to: URL(fileURLWithPath: arguments[keyIndex + 1])
            )
            try Data("certificate".utf8).write(
                to: URL(fileURLWithPath: arguments[certificateIndex + 1])
            )
            return CommandResult(exitCode: 0, standardOutput: "", standardError: "")
        }
        let manager = CertificateManager(
            runner: runner,
            supportDirectory: root.appendingPathComponent("support"),
            computerName: { "Test-Mac" },
            now: { date },
            timeZone: timeZone
        )

        try manager.prepareRootCertificate(in: certificateDirectory)
        try manager.prepareRootCertificate(in: certificateDirectory)

        XCTAssertEqual(runner.invocations.count, 1)
        let arguments = try XCTUnwrap(runner.invocations.first?.arguments)
        XCTAssertTrue(arguments.contains(
            "/CN=WhistleYoo.Test-Mac.20260711090807/O=whistleYoo/OU=whistleYoo"
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: certificateDirectory.appendingPathComponent("root.key").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: certificateDirectory.appendingPathComponent("root.crt").path
        ))
    }

    func testParsesNetworkServicesIncludingDisabledService() {
        let output = """
        An asterisk (*) denotes that a network service is disabled.
        (1) Wi-Fi
        (Hardware Port: Wi-Fi, Device: en0)
        (2) *USB 10/100/1000 LAN
        (Hardware Port: USB 10/100/1000 LAN, Device: en5)
        """
        XCTAssertEqual(NetworkInterfaceManager.parseServiceOrder(output), [
            NetworkService(name: "Wi-Fi", device: "en0", hardwarePort: "Wi-Fi", disabled: false),
            NetworkService(name: "USB 10/100/1000 LAN", device: "en5", hardwarePort: "USB 10/100/1000 LAN", disabled: true)
        ])
    }

    func testParsesDefaultRouteInterface() {
        XCTAssertEqual(
            NetworkInterfaceManager.parseDefaultInterface("""
               route to: default
              interface: en0
            """),
            "en0"
        )
    }

    func testRanksDefaultWiFiAheadOfVirtualInterfaces() {
        let services = [
            NetworkService(name: "Wi-Fi", device: "en0", hardwarePort: "Wi-Fi", disabled: false)
        ]
        let endpoints = NetworkInterfaceManager.rankedEndpoints(
            addresses: [
                (interfaceName: "bridge100", address: "198.51.100.20"),
                (interfaceName: "en0", address: "192.0.2.10")
            ],
            services: services,
            defaultInterface: "en0"
        )

        XCTAssertEqual(endpoints.map(\.address), ["192.0.2.10", "198.51.100.20"])
        XCTAssertEqual(endpoints.first?.displayName, "Wi-Fi")
        XCTAssertEqual(endpoints.first?.kind, .wifi)
        XCTAssertEqual(endpoints.last?.kind, .virtual)
        XCTAssertTrue(endpoints.first?.isDefaultRoute == true)
    }

    func testRanksPhysicalWiFiAheadOfVirtualInterfaceWithoutDefaultRoute() {
        let services = [
            NetworkService(name: "Wi-Fi", device: "en0", hardwarePort: "Wi-Fi", disabled: false)
        ]
        let endpoints = NetworkInterfaceManager.rankedEndpoints(
            addresses: [
                (interfaceName: "bridge100", address: "198.51.100.20"),
                (interfaceName: "en0", address: "192.0.2.10")
            ],
            services: services,
            defaultInterface: nil
        )

        XCTAssertEqual(endpoints.map(\.interfaceName), ["en0", "bridge100"])
    }

    func testParsesProxySettings() {
        let endpoint = SystemProxyManager.parseEndpoint("""
        Enabled: Yes
        Server: 127.0.0.1
        Port: 8899
        Authenticated Proxy Enabled: 0
        """)
        XCTAssertEqual(endpoint, ProxyEndpoint(enabled: true, server: "127.0.0.1", port: 8899))
        XCTAssertEqual(
            SystemProxyManager.parseAutomatic("URL: http://example/p.pac\nEnabled: No\n"),
            AutoProxySettings(enabled: false, url: "http://example/p.pac")
        )
    }

    func testActivationSnapshotsAndSetsHTTPAndHTTPS() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProxySnapshotStore(fileURL: root.appendingPathComponent("proxy.json"))
        let runner = StatefulNetworkSetupRunner()
        let manager = SystemProxyManager(runner: runner, snapshotStore: store)

        try manager.activate(services: ["Wi-Fi"], proxyPort: 8899)

        XCTAssertEqual(
            runner.settings.web,
            ProxyEndpoint(enabled: true, server: "127.0.0.1", port: 8899)
        )
        XCTAssertEqual(
            runner.settings.secureWeb,
            ProxyEndpoint(enabled: true, server: "127.0.0.1", port: 8899)
        )
        XCTAssertFalse(runner.settings.automatic.enabled)
        XCTAssertNotNil(try store.load())
    }

    func testCertificatePEMDecodingAndFingerprint() {
        let pem = Data("""
        -----BEGIN CERTIFICATE-----
        AQID
        -----END CERTIFICATE-----
        """.utf8)
        XCTAssertEqual(CertificateManager.certificateDER(from: pem), Data([1, 2, 3]))
        XCTAssertEqual(CertificateManager.sha256(Data()), "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855")
    }

    func testCertificateHealthRequiresInstallTrustAndCurrentInstanceMatch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let certificate = Data([1, 2, 3])
        let fingerprint = CertificateManager.sha256(certificate)
        var trusted = false
        let runner = RecordingProcessRunner { _, arguments, _ in
            switch arguments.first {
            case "add-trusted-cert":
                return CommandResult(exitCode: 0, standardOutput: "", standardError: "")
            case "find-certificate":
                return CommandResult(
                    exitCode: 0,
                    standardOutput: "SHA-256 hash: \(fingerprint)\n",
                    standardError: ""
                )
            case "verify-cert":
                return CommandResult(exitCode: trusted ? 0 : 1, standardOutput: "", standardError: "")
            default:
                return CommandResult(exitCode: 0, standardOutput: "", standardError: "")
            }
        }
        let manager = CertificateManager(
            runner: runner,
            supportDirectory: root.appendingPathComponent("support"),
            homeDirectory: root
        )
        try manager.install(certificateData: certificate)

        XCTAssertEqual(
            manager.health(certificateData: certificate),
            CertificateHealth(isInstalled: true, isTrusted: false, matchesCurrentInstance: true)
        )

        trusted = true
        XCTAssertTrue(manager.health(certificateData: certificate).isReady)
        XCTAssertEqual(
            manager.health(certificateData: Data([4, 5, 6])).matchesCurrentInstance,
            false
        )
    }

    func testManagedProcessCleanerOnlyMatchesOwnedPforkProcesses() {
        let base = URL(fileURLWithPath: "/tmp/iProxy Test/data")
        let encoded = "%2Ftmp%2FiProxy%20Test%2Fdata"
        let output = """
          101 node /packages/whistle/node_modules/pfork/lib/main options=\(encoded)%2F.whistle
          102 node /packages/whistle/index.js \(encoded)
          103 node /packages/whistle/node_modules/pfork/lib/main options=%2Ftmp%2Fother
        """
        XCTAssertEqual(ManagedProcessCleaner.matchingPIDs(output: output, baseDirectory: base), [101])
    }

    func testRestoreReturnsOwnedSettingsToOriginalValues() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProxySnapshotStore(fileURL: root.appendingPathComponent("proxy.json"))
        let runner = StatefulNetworkSetupRunner()
        let manager = SystemProxyManager(runner: runner, snapshotStore: store)
        let original = runner.settings

        try manager.activate(services: ["Wi-Fi"], proxyPort: 8899)
        XCTAssertEqual(runner.settings.web, ProxyEndpoint(enabled: true, server: "127.0.0.1", port: 8899))
        XCTAssertEqual(runner.settings.secureWeb, ProxyEndpoint(enabled: true, server: "127.0.0.1", port: 8899))
        XCTAssertFalse(runner.settings.automatic.enabled)

        try manager.restoreIfOwned()
        XCTAssertEqual(runner.settings, original)
        XCTAssertNil(try store.load())
    }

    func testRestoreAcceptsDisabledResidualAddressWhenOriginalEndpointWasEmpty() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProxySnapshotStore(fileURL: root.appendingPathComponent("proxy.json"))
        let runner = StatefulNetworkSetupRunner()
        runner.settings = ServiceProxySettings()
        let manager = SystemProxyManager(runner: runner, snapshotStore: store)

        try manager.activate(services: ["Ethernet"], proxyPort: 8899)
        try manager.restoreIfOwned()

        XCTAssertEqual(
            runner.settings.web,
            ProxyEndpoint(enabled: false, server: "127.0.0.1", port: 8899)
        )
        XCTAssertEqual(
            runner.settings.secureWeb,
            ProxyEndpoint(enabled: false, server: "127.0.0.1", port: 8899)
        )
        XCTAssertNil(try store.load())
    }

    func testProxyStatusUsesPersistedOwnershipAndLiveSettings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProxySnapshotStore(fileURL: root.appendingPathComponent("proxy.json"))
        let runner = StatefulNetworkSetupRunner()
        let manager = SystemProxyManager(runner: runner, snapshotStore: store)

        XCTAssertEqual(manager.status(services: ["Wi-Fi"], proxyPort: 8899), .configuredByOther)
        try manager.activate(services: ["Wi-Fi"], proxyPort: 8899)
        XCTAssertEqual(manager.status(services: ["Wi-Fi"], proxyPort: 8899), .enabledByThisApp)
        try manager.restoreIfOwned()
        XCTAssertEqual(manager.status(services: ["Wi-Fi"], proxyPort: 8899), .configuredByOther)
    }

    func testRestoreRetriesWhenNetworkSetupReportsSuccessBeforeStateChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProxySnapshotStore(fileURL: root.appendingPathComponent("proxy.json"))
        let runner = StatefulNetworkSetupRunner()
        let manager = SystemProxyManager(runner: runner, snapshotStore: store)
        let original = runner.settings

        try manager.activate(services: ["Wi-Fi"], proxyPort: 8899)
        runner.ignoredWebDisableAttempts = 1
        try manager.restoreIfOwned()

        XCTAssertEqual(runner.settings, original)
        XCTAssertNil(try store.load())
        XCTAssertGreaterThanOrEqual(runner.webDisableCommandCount, 2)
    }

    func testRestoreKeepsSnapshotWhenProxyCannotBeDisabled() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProxySnapshotStore(fileURL: root.appendingPathComponent("proxy.json"))
        let runner = StatefulNetworkSetupRunner()
        let manager = SystemProxyManager(runner: runner, snapshotStore: store)

        try manager.activate(services: ["Wi-Fi"], proxyPort: 8899)
        runner.ignoredWebDisableAttempts = 10
        XCTAssertThrowsError(try manager.restoreIfOwned())

        XCTAssertTrue(runner.settings.web.enabled)
        XCTAssertNotNil(try store.load(), "failed restoration must remain retryable")
    }

    func testDeactivateCleansOrphanedEndpointsAcrossEveryProvidedService() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProxySnapshotStore(fileURL: root.appendingPathComponent("proxy.json"))
        let appProxy = ServiceProxySettings(
            web: ProxyEndpoint(enabled: true, server: "127.0.0.1", port: 8899),
            secureWeb: ProxyEndpoint(enabled: true, server: "127.0.0.1", port: 8899)
        )
        let runner = MultiServiceNetworkSetupRunner(settings: [
            "Wi-Fi": appProxy,
            "USB LAN": appProxy
        ])
        let manager = SystemProxyManager(runner: runner, snapshotStore: store)

        try manager.deactivate(
            services: ["Wi-Fi", "USB LAN"],
            proxyPort: 8899
        )

        XCTAssertFalse(try XCTUnwrap(runner.settings["Wi-Fi"]).web.enabled)
        XCTAssertFalse(try XCTUnwrap(runner.settings["USB LAN"]).web.enabled)
        XCTAssertFalse(try XCTUnwrap(runner.settings["Wi-Fi"]).secureWeb.enabled)
        XCTAssertFalse(try XCTUnwrap(runner.settings["USB LAN"]).secureWeb.enabled)
    }

    func testSingleProtocolAppEndpointIsReportedAsPartial() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let appEndpoint = ProxyEndpoint(enabled: true, server: "127.0.0.1", port: 8899)
        for (index, settings) in [
            ServiceProxySettings(web: appEndpoint),
            ServiceProxySettings(secureWeb: appEndpoint)
        ].enumerated() {
            let runner = MultiServiceNetworkSetupRunner(settings: ["Wi-Fi": settings])
            let manager = SystemProxyManager(
                runner: runner,
                snapshotStore: ProxySnapshotStore(
                    fileURL: root.appendingPathComponent("proxy-\(index).json")
                )
            )

            XCTAssertEqual(
                manager.status(services: ["Wi-Fi"], proxyPort: 8899),
                .partiallyEnabled
            )
        }
    }

    func testFullOrphanedAppEndpointWithoutSnapshotIsReportedAsPartial() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = MultiServiceNetworkSetupRunner(settings: [
            "Wi-Fi": ServiceProxySettings(
                web: ProxyEndpoint(enabled: true, server: "127.0.0.1", port: 8899),
                secureWeb: ProxyEndpoint(enabled: true, server: "127.0.0.1", port: 8899)
            )
        ])
        let manager = SystemProxyManager(
            runner: runner,
            snapshotStore: ProxySnapshotStore(fileURL: root.appendingPathComponent("proxy.json"))
        )

        XCTAssertEqual(manager.status(services: ["Wi-Fi"], proxyPort: 8899), .partiallyEnabled)
    }

    func testDeactivateRestoresSnapshotAndCleansOrphanOutsideSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProxySnapshotStore(fileURL: root.appendingPathComponent("proxy.json"))
        let original = ServiceProxySettings(
            web: ProxyEndpoint(enabled: false, server: "old.http", port: 8080),
            secureWeb: ProxyEndpoint(enabled: false, server: "old.https", port: 8443)
        )
        let appProxy = ServiceProxySettings(
            web: ProxyEndpoint(enabled: true, server: "127.0.0.1", port: 8899),
            secureWeb: ProxyEndpoint(enabled: true, server: "127.0.0.1", port: 8899)
        )
        try store.save(ProxyActivationRecord(
            original: ["Wi-Fi": original],
            applied: ["Wi-Fi": appProxy]
        ))
        let runner = MultiServiceNetworkSetupRunner(settings: [
            "Wi-Fi": appProxy,
            "USB LAN": appProxy
        ])
        let manager = SystemProxyManager(runner: runner, snapshotStore: store)

        try manager.deactivate(
            services: ["Wi-Fi", "USB LAN"],
            proxyPort: 8899
        )

        XCTAssertEqual(runner.settings["Wi-Fi"], original)
        XCTAssertFalse(try XCTUnwrap(runner.settings["USB LAN"]).web.enabled)
        XCTAssertFalse(try XCTUnwrap(runner.settings["USB LAN"]).secureWeb.enabled)
        XCTAssertNil(try store.load())
    }
}

private final class StatefulNetworkSetupRunner: ProcessRunning, @unchecked Sendable {
    var ignoredWebDisableAttempts = 0
    private(set) var webDisableCommandCount = 0
    var settings = ServiceProxySettings(
        web: ProxyEndpoint(enabled: false, server: "old.http", port: 8080),
        secureWeb: ProxyEndpoint(enabled: false, server: "old.https", port: 8443),
        socks: ProxyEndpoint(enabled: false, server: "old.socks", port: 1080),
        automatic: AutoProxySettings(enabled: true, url: "http://old/proxy.pac")
    )

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String : String]?,
        timeout: TimeInterval
    ) throws -> CommandResult {
        let command = arguments[0]
        switch command {
        case "-getwebproxy": return endpoint(settings.web)
        case "-getsecurewebproxy": return endpoint(settings.secureWeb)
        case "-getsocksfirewallproxy": return endpoint(settings.socks)
        case "-getautoproxyurl":
            return success("URL: \(settings.automatic.url)\nEnabled: \(settings.automatic.enabled ? "Yes" : "No")\n")
        case "-setwebproxy":
            settings.web.server = arguments[2]
            settings.web.port = Int(arguments[3])!
            settings.web.enabled = true
        case "-setsecurewebproxy":
            settings.secureWeb.server = arguments[2]
            settings.secureWeb.port = Int(arguments[3])!
            settings.secureWeb.enabled = true
        case "-setsocksfirewallproxy":
            settings.socks.server = arguments[2]
            settings.socks.port = Int(arguments[3])!
            settings.socks.enabled = true
        case "-setwebproxystate":
            if arguments[2] == "off" {
                webDisableCommandCount += 1
                if ignoredWebDisableAttempts > 0 {
                    ignoredWebDisableAttempts -= 1
                } else {
                    settings.web.enabled = false
                }
            } else {
                settings.web.enabled = true
            }
        case "-setsecurewebproxystate": settings.secureWeb.enabled = arguments[2] == "on"
        case "-setsocksfirewallproxystate": settings.socks.enabled = arguments[2] == "on"
        case "-setautoproxyurl": settings.automatic.url = arguments[2]
        case "-setautoproxystate": settings.automatic.enabled = arguments[2] == "on"
        default: break
        }
        return success()
    }

    private func endpoint(_ value: ProxyEndpoint) -> CommandResult {
        success("Enabled: \(value.enabled ? "Yes" : "No")\nServer: \(value.server)\nPort: \(value.port)\n")
    }

    private func success(_ output: String = "") -> CommandResult {
        CommandResult(exitCode: 0, standardOutput: output, standardError: "")
    }
}

private final class MultiServiceNetworkSetupRunner: ProcessRunning, @unchecked Sendable {
    var settings: [String: ServiceProxySettings]

    init(settings: [String: ServiceProxySettings]) {
        self.settings = settings
    }

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String : String]?,
        timeout: TimeInterval
    ) throws -> CommandResult {
        let command = arguments[0]
        let service = arguments[1]
        guard var value = settings[service] else {
            return CommandResult(exitCode: 1, standardOutput: "", standardError: "unknown service")
        }
        switch command {
        case "-getwebproxy": return endpoint(value.web)
        case "-getsecurewebproxy": return endpoint(value.secureWeb)
        case "-getsocksfirewallproxy": return endpoint(value.socks)
        case "-getautoproxyurl":
            return success("URL: \(value.automatic.url)\nEnabled: \(value.automatic.enabled ? "Yes" : "No")\n")
        case "-setwebproxy":
            value.web.server = arguments[2]
            value.web.port = Int(arguments[3])!
            value.web.enabled = true
        case "-setsecurewebproxy":
            value.secureWeb.server = arguments[2]
            value.secureWeb.port = Int(arguments[3])!
            value.secureWeb.enabled = true
        case "-setsocksfirewallproxy":
            value.socks.server = arguments[2]
            value.socks.port = Int(arguments[3])!
            value.socks.enabled = true
        case "-setwebproxystate": value.web.enabled = arguments[2] == "on"
        case "-setsecurewebproxystate": value.secureWeb.enabled = arguments[2] == "on"
        case "-setsocksfirewallproxystate": value.socks.enabled = arguments[2] == "on"
        case "-setautoproxyurl": value.automatic.url = arguments[2]
        case "-setautoproxystate": value.automatic.enabled = arguments[2] == "on"
        default: break
        }
        settings[service] = value
        return success()
    }

    private func endpoint(_ value: ProxyEndpoint) -> CommandResult {
        success("Enabled: \(value.enabled ? "Yes" : "No")\nServer: \(value.server)\nPort: \(value.port)\n")
    }

    private func success(_ output: String = "") -> CommandResult {
        CommandResult(exitCode: 0, standardOutput: output, standardError: "")
    }
}
