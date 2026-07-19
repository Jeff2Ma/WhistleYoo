import XCTest
@testable import whistleYooCore

final class ModelAndSettingsTests: XCTestCase {
    func testMobileRootCertificateURLUsesProxyPortAndWhistleEndpoint() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = EngineConfiguration(
            proxyPort: 10_080,
            baseDirectory: root.appendingPathComponent("data"),
            runtimeDirectory: root.appendingPathComponent("runtime")
        )

        XCTAssertEqual(
            configuration.mobileRootCertificateURL(host: " 192.0.2.10 ")?.absoluteString,
            "http://192.0.2.10:10080/cgi-bin/rootca?type=crt"
        )
        XCTAssertNil(configuration.mobileRootCertificateURL(host: "  \n "))
    }

    func testDockVisibilityDefaultsToVisibleAndPersistsChanges() throws {
        let suiteName = "DockVisibilityPreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)
        let preference = DockVisibilityPreference(defaults: defaults)

        XCTAssertTrue(preference.isVisible)
        preference.setVisible(false)
        XCTAssertFalse(preference.isVisible)
        preference.setVisible(true)
        XCTAssertTrue(preference.isVisible)
    }

    func testPartialProxyStatusPreservesAppProxyIntent() {
        XCTAssertTrue(SystemProxyStatus.enabledByThisApp.indicatesAppProxyIntent)
        XCTAssertTrue(SystemProxyStatus.partiallyEnabled.indicatesAppProxyIntent)
        XCTAssertFalse(SystemProxyStatus.disabled.indicatesAppProxyIntent)
        XCTAssertFalse(SystemProxyStatus.configuredByOther.indicatesAppProxyIntent)
        XCTAssertFalse(SystemProxyStatus.unavailable("error").indicatesAppProxyIntent)
        XCTAssertTrue(
            SystemProxyStatus.unavailable("networksetup failed")
                .requiresSafetyEngine(afterCleanupFailed: true)
        )
        XCTAssertFalse(SystemProxyStatus.disabled.requiresSafetyEngine(afterCleanupFailed: false))
    }

    func testSemanticVersions() {
        XCTAssertEqual(SemanticVersion("v22.12.1"), SemanticVersion(22, 12, 1))
        XCTAssertEqual(SemanticVersion("Whistle 2.10"), SemanticVersion(2, 10, 0))
        XCTAssertTrue(SemanticVersion(2, 10, 0) > SemanticVersion(2, 9, 9))
        XCTAssertNil(SemanticVersion("unknown"))
    }

    func testSettingsRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json")
        let store = SettingsStore(fileURL: url)
        var settings = PersistedSettings()
        settings.engine.proxyPort = 10080
        settings.selectedNetworkServices = ["Wi-Fi"]
        settings.softwareDomainWhitelistDomains = ["*.example.com", "api.example.com"]

        try store.save(settings)

        XCTAssertEqual(try store.load(), settings)
    }

    func testPortableConfigurationRoundTripIncludesSettingsAndRules() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Cloud/WhistleYoo.json")
        let store = WhistleYooConfigurationStore(defaultFileURL: url)
        var settings = PersistedSettings()
        settings.engine.proxyPort = 10_080
        settings.selectedNetworkServices = ["Wi-Fi"]
        let rules = WhistleRulesSnapshot(
            documents: [
                WhistleRuleDocument(
                    name: "Default",
                    value: "default.example host://127.0.0.1",
                    isEnabled: true,
                    isDefault: true
                ),
                WhistleRuleDocument(
                    name: "API mocks",
                    value: "api.example file://mock.json",
                    isEnabled: false
                )
            ],
            allowMultipleChoice: true,
            backRulesFirst: true
        )
        let configuration = WhistleYooConfigurationFile(settings: settings, rules: rules)

        try store.save(configuration, to: url)

        XCTAssertEqual(try store.load(from: url), configuration)
    }

    func testPortableConfigurationRejectsUnsupportedFormatWithoutChangingExistingFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("WhistleYoo.json")
        let validConfiguration = WhistleYooConfigurationFile(
            settings: PersistedSettings(),
            rules: WhistleRulesSnapshot(documents: [
                WhistleRuleDocument(
                    name: "Default",
                    value: "",
                    isEnabled: true,
                    isDefault: true
                )
            ])
        )
        let encoded = try JSONEncoder().encode(validConfiguration)
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["formatVersion"] = 99
        let original = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try original.write(to: url)

        XCTAssertThrowsError(try WhistleYooConfigurationStore(defaultFileURL: url).load(from: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testPortableConfigurationRejectsInvalidPortsBeforeWriting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("WhistleYoo.json")
        var settings = PersistedSettings()
        settings.engine.uiPort = settings.engine.proxyPort
        let configuration = WhistleYooConfigurationFile(
            settings: settings,
            rules: WhistleRulesSnapshot(documents: [
                WhistleRuleDocument(
                    name: "Default",
                    value: "",
                    isEnabled: true,
                    isDefault: true
                )
            ])
        )

        XCTAssertThrowsError(
            try WhistleYooConfigurationStore(defaultFileURL: url).save(configuration, to: url)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testPortableConfigurationDefaultsToJSONFilename() {
        XCTAssertEqual(
            WhistleYooConfigurationStore().defaultFileURL.lastPathComponent,
            "WhistleYoo.json"
        )
    }

    func testLegacyPortableConfigurationMigratesToJSONFilename() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appendingPathComponent("WhistleYoo.whistleyoo")
        let jsonURL = root.appendingPathComponent("WhistleYoo.json")
        let store = WhistleYooConfigurationStore(
            defaultFileURL: jsonURL,
            legacyDefaultFileURL: legacyURL
        )
        let configuration = WhistleYooConfigurationFile(
            settings: PersistedSettings(),
            rules: WhistleRulesSnapshot(documents: [
                WhistleRuleDocument(
                    name: "Default",
                    value: "",
                    isEnabled: true,
                    isDefault: true
                )
            ])
        )
        try store.save(configuration, to: legacyURL)

        XCTAssertTrue(try store.migrateLegacyDefaultFileIfNeeded())
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertEqual(try store.load(from: jsonURL), configuration)
        XCTAssertFalse(try store.migrateLegacyDefaultFileIfNeeded())
    }

    func testLegacyPortableConfigurationMigratesInsideCustomCloudFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appendingPathComponent("Cloud/WhistleYoo.whistleyoo")
        let jsonURL = root.appendingPathComponent("Cloud/WhistleYoo.json")
        let store = WhistleYooConfigurationStore(defaultFileURL: root.appendingPathComponent("Default.json"))
        let configuration = WhistleYooConfigurationFile(
            settings: PersistedSettings(),
            rules: WhistleRulesSnapshot(documents: [
                WhistleRuleDocument(
                    name: "Default",
                    value: "",
                    isEnabled: true,
                    isDefault: true
                )
            ])
        )
        try store.save(configuration, to: legacyURL)

        XCTAssertTrue(try store.migrateLegacyFileIfNeeded(from: legacyURL, to: jsonURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertEqual(try store.load(from: jsonURL), configuration)
    }

    func testPortInUseDescriptionNeverGroupsDigits() {
        XCTAssertEqual(WhistleYooError.portInUse(8_899).errorDescription, "端口 8899 已被占用")
    }

    func testVersionOneSettingsMigrateToCurrentVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("settings.json")
        let encoded = try JSONEncoder().encode(PersistedSettings())
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["schemaVersion"] = 1
        object.removeValue(forKey: "completedOnboardingVersion")
        object.removeValue(forKey: "certificateStepSkipped")
        object.removeValue(forKey: "softwareDomainWhitelistEnabled")
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let migrated = try SettingsStore(fileURL: url).load()

        XCTAssertEqual(migrated.schemaVersion, 4)
        XCTAssertNil(migrated.completedOnboardingVersion)
        XCTAssertFalse(migrated.certificateStepSkipped)
        XCTAssertTrue(migrated.softwareDomainWhitelistEnabled)
        XCTAssertEqual(migrated.softwareDomainWhitelistDomains, SoftwareDomainWhitelistManager.domains)
    }

    func testSoftwareWhitelistManagedRulesPreserveUserDefaultRules() {
        let userRules = "example.com file://{body}"
        let enabled = SoftwareDomainWhitelistManager.mergingManagedRules(
            into: userRules,
            enabled: true
        )

        XCTAssertTrue(enabled.hasPrefix(SoftwareDomainWhitelistManager.managedRules))
        XCTAssertTrue(enabled.contains(userRules))
        XCTAssertEqual(
            SoftwareDomainWhitelistManager.mergingManagedRules(into: enabled, enabled: true),
            enabled
        )
        XCTAssertEqual(
            SoftwareDomainWhitelistManager.mergingManagedRules(into: enabled, enabled: false),
            userRules
        )
    }

    func testSoftwareWhitelistManagedRulesUseEditedDomains() {
        let domains = ["*.example.com", " api.example.com ", "*.example.com"]
        let rules = SoftwareDomainWhitelistManager.mergingManagedRules(
            into: "",
            enabled: true,
            domains: domains
        )

        XCTAssertTrue(rules.contains("disable://intercept *.example.com api.example.com"))
        XCTAssertFalse(rules.contains("apple.com"))
        XCTAssertEqual(
            SoftwareDomainWhitelistManager.normalizedDomains(domains),
            ["*.example.com", "api.example.com"]
        )
    }

    func testApplicationStatusDistinguishesListeningAndSystemProxy() {
        XCTAssertEqual(
            ApplicationStatus.resolve(engineState: .running(version: "2.10.1"), systemProxyStatus: .disabled),
            .listeningOnly
        )
        XCTAssertEqual(
            ApplicationStatus.resolve(
                engineState: .running(version: "2.10.1"),
                systemProxyStatus: .enabledByThisApp
            ),
            .systemProxyEnabled
        )
        XCTAssertEqual(
            ApplicationStatus.resolve(
                engineState: .running(version: "2.10.1"),
                systemProxyStatus: .partiallyEnabled
            ),
            .attention
        )
    }

    func testAllApplicationStatusIconsShareGlobeAndUseDistinctBadges() {
        let statuses: [ApplicationStatus] = [
            .systemProxyEnabled,
            .listeningOnly,
            .transitioning,
            .stopped,
            .attention,
            .unavailable
        ]
        let icons = statuses.map(\.statusBarIcon)

        XCTAssertTrue(icons.allSatisfy { $0.baseSymbolName == "globe" })
        XCTAssertEqual(Set(icons.map(\.badgeSymbolName)).count, statuses.count)
        XCTAssertEqual(statuses[0].statusBarIcon.badgeSymbolName, "bolt.fill")
        XCTAssertEqual(statuses[1].statusBarIcon.badgeSymbolName, "waveform")
        XCTAssertEqual(statuses[2].statusBarIcon.badgeSymbolName, "ellipsis.circle.fill")
        XCTAssertEqual(statuses[3].statusBarIcon.badgeSymbolName, "pause.circle.fill")
        XCTAssertEqual(statuses[4].statusBarIcon.badgeSymbolName, "exclamationmark.circle.fill")
        XCTAssertEqual(statuses[5].statusBarIcon.badgeSymbolName, "xmark.circle.fill")
    }

    func testApplicationStatusAnimationBehaviorOnlyRepeatsDuringTransitions() {
        XCTAssertEqual(ApplicationStatus.listeningOnly.statusBarAnimationBehavior, .entryPulse)
        XCTAssertEqual(ApplicationStatus.systemProxyEnabled.statusBarAnimationBehavior, .entryPulse)
        XCTAssertEqual(ApplicationStatus.transitioning.statusBarAnimationBehavior, .continuousPulse)
        XCTAssertEqual(ApplicationStatus.stopped.statusBarAnimationBehavior, .none)
        XCTAssertEqual(ApplicationStatus.attention.statusBarAnimationBehavior, .none)
        XCTAssertEqual(ApplicationStatus.unavailable.statusBarAnimationBehavior, .none)
    }

    func testMissingMigrationIsReported() throws {
        let object: [String: Any] = ["schemaVersion": 0]
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try MigrationManager().migrate(data, from: 0, to: 1))
    }

    func testRegisteredMigrationRuns() throws {
        struct Migration: SettingsMigrating {
            let fromVersion = 0
            let toVersion = 1
            func migrate(_ data: Data) throws -> Data {
                var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                object["schemaVersion"] = 1
                object["migrated"] = true
                return try JSONSerialization.data(withJSONObject: object)
            }
        }
        let source = try JSONSerialization.data(withJSONObject: ["schemaVersion": 0])
        let result = try MigrationManager(migrations: [Migration()]).migrate(source, from: 0, to: 1)
        let object = try JSONSerialization.jsonObject(with: result) as! [String: Any]
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["migrated"] as? Bool, true)
    }

    func testFoundationRunnerCapturesOutput() throws {
        let result = try FoundationProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello"], environment: nil, timeout: 2
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }
}
