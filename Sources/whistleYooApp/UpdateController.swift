import AppKit
import Sparkle
#if canImport(whistleYooCore)
import whistleYooCore
#endif

/// Owns Sparkle's standard updater for the lifetime of the application.
///
/// Views should call `UpdateController.shared.checkForUpdates()` instead of
/// constructing their own updater. The application delegate starts this
/// controller after launch so release builds can schedule background update checks.
@MainActor
final class UpdateController {
    static let shared = UpdateController()
    static let localTestingVersion = "0.0.0"

    private let controller: SPUStandardUpdaterController
    private var hasStarted = false

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Whether the user-facing update action should be enabled.
    var canCheckForUpdates: Bool {
        if isLocalTestingBuild { return true }
        return hasStarted && controller.updater.canCheckForUpdates
    }

    /// Starts Sparkle once. Calling this method repeatedly is safe.
    func start() {
        guard !isLocalTestingBuild, !hasStarted else { return }
        hasStarted = true
        controller.startUpdater()
    }

    /// Presents Sparkle's standard update-checking UI.
    func checkForUpdates() {
        guard !isLocalTestingBuild else {
            presentLocalTestingVersionAlert()
            return
        }
        start()
        controller.checkForUpdates(nil)
    }

    static func isLocalTestingVersion(_ version: String?) -> Bool {
        version == localTestingVersion
    }

    private var isLocalTestingBuild: Bool {
        Self.isLocalTestingVersion(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        )
    }

    private func presentLocalTestingVersionAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = Localization.string(
            .aboutLocalTestVersionDoesNotSupportCheckingForUpdates
        )
        alert.addButton(withTitle: Localization.string(.menuOk))
        alert.runModal()
    }
}
