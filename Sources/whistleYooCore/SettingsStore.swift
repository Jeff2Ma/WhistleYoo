import Foundation

public protocol SettingsMigrating: Sendable {
    var fromVersion: Int { get }
    var toVersion: Int { get }
    func migrate(_ data: Data) throws -> Data
}

public struct MigrationManager: Sendable {
    private let migrations: [SettingsMigrating]

    public init(migrations: [SettingsMigrating] = []) {
        self.migrations = migrations.sorted { $0.fromVersion < $1.fromVersion }
    }

    public func migrate(_ data: Data, from sourceVersion: Int, to targetVersion: Int) throws -> Data {
        var currentVersion = sourceVersion
        var currentData = data
        while currentVersion < targetVersion {
            guard let migration = migrations.first(where: { $0.fromVersion == currentVersion }) else {
                throw WhistleYooError.settingsCorrupted(Localization.format(.coreMissingSettingsMigrationVValueVValue, currentVersion, targetVersion))
            }
            currentData = try migration.migrate(currentData)
            currentVersion = migration.toVersion
        }
        return currentData
    }
}

public struct SettingsV1ToV2Migration: SettingsMigrating {
    public let fromVersion = 1
    public let toVersion = 2

    public init() {}

    public func migrate(_ data: Data) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WhistleYooError.settingsCorrupted(Localization.string(.coreTheV1SettingsFileFormatIsInvalid))
        }
        object["schemaVersion"] = toVersion
        object["certificateStepSkipped"] = false
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}

public struct SettingsV2ToV3Migration: SettingsMigrating {
    public let fromVersion = 2
    public let toVersion = 3

    public init() {}

    public func migrate(_ data: Data) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WhistleYooError.settingsCorrupted(Localization.string(.coreTheV2SettingsFileFormatIsInvalid))
        }
        object["schemaVersion"] = toVersion
        object["softwareDomainWhitelistEnabled"] = true
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}

public struct SettingsV3ToV4Migration: SettingsMigrating {
    public let fromVersion = 3
    public let toVersion = 4

    public init() {}

    public func migrate(_ data: Data) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WhistleYooError.settingsCorrupted(Localization.string(.coreTheV3SettingsFileFormatIsInvalid))
        }
        object["schemaVersion"] = toVersion
        object["softwareDomainWhitelistDomains"] = SoftwareDomainWhitelistManager.domains
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}

public extension MigrationManager {
    static var applicationDefault: MigrationManager {
        MigrationManager(migrations: [
            SettingsV1ToV2Migration(),
            SettingsV2ToV3Migration(),
            SettingsV3ToV4Migration()
        ])
    }
}

public final class SettingsStore: @unchecked Sendable {
    public let fileURL: URL
    private let fileManager: FileManager
    private let migrationManager: MigrationManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default,
        migrationManager: MigrationManager = .applicationDefault
    ) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.devework.whistleyoo", isDirectory: true)
        self.fileURL = fileURL ?? support.appendingPathComponent("settings.json")
        self.fileManager = fileManager
        self.migrationManager = migrationManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    public func load() throws -> PersistedSettings {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            let settings = PersistedSettings()
            try save(settings)
            return settings
        }
        let original = try Data(contentsOf: fileURL)
        guard let object = try JSONSerialization.jsonObject(with: original) as? [String: Any],
              let version = object["schemaVersion"] as? Int else {
            throw WhistleYooError.settingsCorrupted(Localization.string(.coreTheSettingsFileIsMissingSchemaversion))
        }
        guard version <= PersistedSettings.currentSchemaVersion else {
            throw WhistleYooError.settingsCorrupted(Localization.string(.coreTheSettingsFileWasCreatedByANewerVersionOfWhistleyoo))
        }
        let data = version == PersistedSettings.currentSchemaVersion
            ? original
            : try migrationManager.migrate(original, from: version, to: PersistedSettings.currentSchemaVersion)
        do {
            let settings = try decoder.decode(PersistedSettings.self, from: data)
            if data != original { try save(settings) }
            return settings
        } catch {
            throw WhistleYooError.settingsCorrupted(Localization.format(.coreUnableToReadSettingsValue, error.localizedDescription))
        }
    }

    public func save(_ settings: PersistedSettings) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try encoder.encode(settings).write(to: fileURL, options: .atomic)
    }
}

/// Portable WhistleYoo configuration containing both native preferences and
/// the complete Whistle Rules snapshot.
public struct WhistleYooConfigurationFile: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let settings: PersistedSettings
    public let rules: WhistleRulesSnapshot

    public init(
        formatVersion: Int = currentFormatVersion,
        settings: PersistedSettings,
        rules: WhistleRulesSnapshot
    ) {
        self.formatVersion = formatVersion
        self.settings = settings
        self.rules = rules
    }
}

/// Reads and atomically writes the portable JSON configuration.
public final class WhistleYooConfigurationStore: @unchecked Sendable {
    public let defaultFileURL: URL
    public let legacyDefaultFileURL: URL?

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        defaultFileURL: URL? = nil,
        legacyDefaultFileURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.devework.whistleyoo", isDirectory: true)
        if let defaultFileURL {
            self.defaultFileURL = defaultFileURL
            self.legacyDefaultFileURL = legacyDefaultFileURL
        } else {
            self.defaultFileURL = support.appendingPathComponent("WhistleYoo.json")
            self.legacyDefaultFileURL = legacyDefaultFileURL
                ?? support.appendingPathComponent("WhistleYoo.whistleyoo")
        }
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    /// Moves the previous default `.whistleyoo` file to the JSON filename once.
    /// Existing JSON files always win, and explicitly selected legacy files can
    /// still be loaded directly through `load(from:)`.
    @discardableResult
    public func migrateLegacyDefaultFileIfNeeded() throws -> Bool {
        guard let legacyDefaultFileURL else { return false }
        return try migrateLegacyFileIfNeeded(from: legacyDefaultFileURL, to: defaultFileURL)
    }

    /// Renames a legacy portable configuration in place, including files in a
    /// user-selected cloud-drive folder. An existing JSON file always wins.
    @discardableResult
    public func migrateLegacyFileIfNeeded(from legacyURL: URL, to jsonURL: URL) throws -> Bool {
        guard !fileManager.fileExists(atPath: jsonURL.path),
              fileManager.fileExists(atPath: legacyURL.path) else { return false }
        try fileManager.createDirectory(
            at: jsonURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: legacyURL, to: jsonURL)
        return true
    }

    public func load(from url: URL) throws -> WhistleYooConfigurationFile {
        let data = try Data(contentsOf: url)
        let configuration: WhistleYooConfigurationFile
        do {
            configuration = try decoder.decode(WhistleYooConfigurationFile.self, from: data)
        } catch {
            throw WhistleYooError.settingsCorrupted(
                Localization.format(.coreUnableToReadTheWhistleyooConfigurationFileValue, error.localizedDescription)
            )
        }
        guard configuration.formatVersion == WhistleYooConfigurationFile.currentFormatVersion else {
            throw WhistleYooError.settingsCorrupted(Localization.format(
                .coreUnsupportedWhistleyooConfigurationFileVersionVValue,
                configuration.formatVersion
            ))
        }
        guard configuration.settings.schemaVersion == PersistedSettings.currentSchemaVersion else {
            throw WhistleYooError.settingsCorrupted(Localization.format(
                .coreTheSettingsVersionInTheConfigurationFileIsIncompatibleVValue,
                configuration.settings.schemaVersion
            ))
        }
        try validate(configuration)
        return configuration
    }

    public func save(_ configuration: WhistleYooConfigurationFile, to url: URL) throws {
        guard configuration.formatVersion == WhistleYooConfigurationFile.currentFormatVersion,
              configuration.settings.schemaVersion == PersistedSettings.currentSchemaVersion else {
            throw WhistleYooError.settingsCorrupted(Localization.string(.coreAnIncompatibleWhistleyooConfigurationFileCannotBeWritten))
        }
        try validate(configuration)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(configuration).write(to: url, options: .atomic)
    }

    private func validate(_ configuration: WhistleYooConfigurationFile) throws {
        let engine = configuration.settings.engine
        guard (1...65_535).contains(engine.proxyPort),
              (1...65_535).contains(engine.uiPort),
              engine.proxyPort != engine.uiPort else {
            throw WhistleYooError.settingsCorrupted(Localization.string(.coreTheConfigurationFileContainsInvalidOrConflictingPorts))
        }
        let defaults = configuration.rules.documents.filter(\.isDefault)
        guard defaults.count == 1,
              defaults[0].name == "Default",
              defaults[0].isEnabled else {
            throw WhistleYooError.settingsCorrupted(Localization.string(.coreTheConfigurationFileMustContainAnEnabledDefaultRule))
        }
        let names = configuration.rules.documents.map(\.name)
        guard Set(names).count == names.count,
              names.allSatisfy({ !$0.isEmpty && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) }) else {
            throw WhistleYooError.settingsCorrupted(Localization.string(.coreTheConfigurationFileContainsInvalidOrDuplicateRuleNames))
        }
    }
}
