import Foundation
import ServiceManagement

/// Machine-local UI preference. It intentionally stays out of the portable
/// proxy configuration so importing rules cannot unexpectedly hide the app.
public struct DockVisibilityPreference {
    public static let defaultsKey = "WhistleYooShowDockIcon"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isVisible: Bool {
        guard defaults.object(forKey: Self.defaultsKey) != nil else { return true }
        return defaults.bool(forKey: Self.defaultsKey)
    }

    public func setVisible(_ isVisible: Bool) {
        defaults.set(isVisible, forKey: Self.defaultsKey)
    }
}

@available(macOS 13.0, *)
public struct AutoLaunchManager {
    public init() {}

    public var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}
