import Foundation

public enum WhistleYooError: LocalizedError, Equatable {
    case environmentUnavailable(String)
    case unsupportedVersion(String)
    case portInUse(Int)
    case commandFailed(String)
    case engineDidNotBecomeReady
    case engineDidNotStop
    case invalidResponse(String)
    case settingsCorrupted(String)
    case certificateNotFound
    case userCancelled

    public var errorDescription: String? {
        switch self {
        case .environmentUnavailable(let message), .unsupportedVersion(let message),
             .commandFailed(let message), .invalidResponse(let message),
             .settingsCorrupted(let message):
            return message
        case .portInUse(let port): return Localization.format(.corePortValueIsAlreadyInUse, String(port))
        case .engineDidNotBecomeReady: return Localization.string(.coreWhistleDidNotPassItsHealthCheckAfterStarting)
        case .engineDidNotStop: return Localization.string(.coreWhistleDidNotStopBeforeTheTimeout)
        case .certificateNotFound: return Localization.string(.coreUnableToObtainTheWhistleRootCertificate)
        case .userCancelled: return Localization.string(.coreTheOperationWasCancelled)
        }
    }
}

public struct SemanticVersion: Comparable, Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(_ value: String) {
        let expression = try! NSRegularExpression(pattern: #"(?:v)?(\d+)\.(\d+)(?:\.(\d+))?"#)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = expression.firstMatch(in: value, range: range),
              let majorRange = Range(match.range(at: 1), in: value),
              let minorRange = Range(match.range(at: 2), in: value) else { return nil }
        major = Int(value[majorRange]) ?? 0
        minor = Int(value[minorRange]) ?? 0
        if match.range(at: 3).location != NSNotFound,
           let patchRange = Range(match.range(at: 3), in: value) {
            patch = Int(value[patchRange]) ?? 0
        } else {
            patch = 0
        }
    }

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

public struct EnvironmentInfo: Equatable, Sendable {
    public let nodeURL: URL
    public let npmURL: URL?
    public let whistleURL: URL
    public let nodeVersion: SemanticVersion
    public let whistleVersion: SemanticVersion

    public init(
        nodeURL: URL,
        npmURL: URL?,
        whistleURL: URL,
        nodeVersion: SemanticVersion,
        whistleVersion: SemanticVersion
    ) {
        self.nodeURL = nodeURL
        self.npmURL = npmURL
        self.whistleURL = whistleURL
        self.nodeVersion = nodeVersion
        self.whistleVersion = whistleVersion
    }
}

public struct EngineConfiguration: Codable, Equatable, Sendable {
    public var proxyPort: Int
    public var uiPort: Int
    public var socksPort: Int?
    public var storageName: String
    public var listenHost: String
    public var uiHost: String
    public var baseDirectory: URL
    public var runtimeDirectory: URL
    public var pluginPaths: [String]
    public var mode: String?

    public init(
        proxyPort: Int = 8899,
        uiPort: Int = 8900,
        socksPort: Int? = nil,
        storageName: String = "whistle-yoo",
        listenHost: String = "0.0.0.0",
        uiHost: String = "127.0.0.1",
        baseDirectory: URL,
        runtimeDirectory: URL,
        pluginPaths: [String] = [],
        mode: String? = nil
    ) {
        self.proxyPort = proxyPort
        self.uiPort = uiPort
        self.socksPort = socksPort
        self.storageName = storageName
        self.listenHost = listenHost
        self.uiHost = uiHost
        self.baseDirectory = baseDirectory
        self.runtimeDirectory = runtimeDirectory
        self.pluginPaths = pluginPaths
        self.mode = mode
    }

    public var uiURL: URL {
        URL(string: "http://\(uiHost):\(uiPort)/")!
    }

    public func mobileRootCertificateURL(host: String) -> URL? {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = proxyPort
        components.path = "/cgi-bin/rootca"
        components.queryItems = [URLQueryItem(name: "type", value: "crt")]
        return components.url
    }

    public var customCertificateDirectory: URL {
        baseDirectory.deletingLastPathComponent()
            .appendingPathComponent("whistle-certs", isDirectory: true)
    }

    public static func applicationDefault(fileManager: FileManager = .default) -> EngineConfiguration {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.devework.whistleyoo", isDirectory: true)
        return EngineConfiguration(
            baseDirectory: support.appendingPathComponent("whistle-data", isDirectory: true),
            runtimeDirectory: support.appendingPathComponent("runtime", isDirectory: true)
        )
    }
}

public struct PersistedSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 4
    public static let currentOnboardingVersion = 1

    public var schemaVersion: Int
    public var engine: EngineConfiguration
    public var selectedNetworkServices: [String]
    public var launchAtLogin: Bool
    public var completedOnboardingVersion: Int?
    public var certificateStepSkipped: Bool
    public var softwareDomainWhitelistEnabled: Bool
    public var softwareDomainWhitelistDomains: [String]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        engine: EngineConfiguration = .applicationDefault(),
        selectedNetworkServices: [String] = [],
        launchAtLogin: Bool = false,
        completedOnboardingVersion: Int? = nil,
        certificateStepSkipped: Bool = false,
        softwareDomainWhitelistEnabled: Bool = true,
        softwareDomainWhitelistDomains: [String] = SoftwareDomainWhitelistManager.domains
    ) {
        self.schemaVersion = schemaVersion
        self.engine = engine
        self.selectedNetworkServices = selectedNetworkServices
        self.launchAtLogin = launchAtLogin
        self.completedOnboardingVersion = completedOnboardingVersion
        self.certificateStepSkipped = certificateStepSkipped
        self.softwareDomainWhitelistEnabled = softwareDomainWhitelistEnabled
        self.softwareDomainWhitelistDomains = softwareDomainWhitelistDomains
    }
}

public enum EngineState: Equatable, Sendable {
    case stopped
    case starting
    case running(version: String)
    case stopping
    case failed(String)
}

public enum SystemProxyStatus: Equatable, Sendable {
    case disabled
    case enabledByThisApp
    case partiallyEnabled
    case configuredByOther
    case unavailable(String)

    public var indicatesAppProxyIntent: Bool {
        switch self {
        case .enabledByThisApp, .partiallyEnabled: return true
        case .disabled, .configuredByOther, .unavailable: return false
        }
    }

    public func requiresSafetyEngine(afterCleanupFailed cleanupFailed: Bool) -> Bool {
        cleanupFailed || indicatesAppProxyIntent
    }
}

public enum ApplicationStatus: Equatable, Sendable {
    case unavailable
    case transitioning
    case stopped
    case listeningOnly
    case systemProxyEnabled
    case attention

    public static func resolve(
        engineState: EngineState,
        systemProxyStatus: SystemProxyStatus
    ) -> ApplicationStatus {
        switch engineState {
        case .failed:
            return .unavailable
        case .starting, .stopping:
            return .transitioning
        case .stopped:
            return .stopped
        case .running:
            switch systemProxyStatus {
            case .enabledByThisApp:
                return .systemProxyEnabled
            case .partiallyEnabled, .unavailable:
                return .attention
            case .disabled, .configuredByOther:
                return .listeningOnly
            }
        }
    }

    /// A platform-neutral description of the status-bar icon composition.
    /// The app target overlays the brand W and the state badge on this base symbol.
    public var statusBarIcon: StatusBarIconDescriptor {
        let badgeSymbolName: String
        switch self {
        case .systemProxyEnabled:
            badgeSymbolName = "bolt.fill"
        case .listeningOnly:
            badgeSymbolName = "waveform"
        case .transitioning:
            badgeSymbolName = "ellipsis.circle.fill"
        case .stopped:
            badgeSymbolName = "pause.circle.fill"
        case .attention:
            badgeSymbolName = "exclamationmark.circle.fill"
        case .unavailable:
            badgeSymbolName = "xmark.circle.fill"
        }
        return StatusBarIconDescriptor(
            baseSymbolName: "circle",
            badgeSymbolName: badgeSymbolName
        )
    }

    /// Platform-neutral animation lifetime for the status-bar presentation.
    /// Rendering details such as opacity, scale and timing stay in the app target.
    public var statusBarAnimationBehavior: StatusBarAnimationBehavior {
        switch self {
        case .listeningOnly, .systemProxyEnabled: return .entryPulse
        case .transitioning: return .continuousPulse
        case .stopped, .attention, .unavailable: return .none
        }
    }
}

public enum StatusBarAnimationBehavior: Equatable, Sendable {
    case none
    case entryPulse
    case continuousPulse
}

public struct StatusBarIconDescriptor: Equatable, Sendable {
    public let baseSymbolName: String
    public let badgeSymbolName: String

    public init(baseSymbolName: String, badgeSymbolName: String) {
        self.baseSymbolName = baseSymbolName
        self.badgeSymbolName = badgeSymbolName
    }
}

public struct EngineHealth: Equatable, Sendable {
    public let version: String
    public let port: Int?

    public init(version: String, port: Int?) {
        self.version = version
        self.port = port
    }
}
