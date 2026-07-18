import AppKit
import Sparkle

/// Owns Sparkle's standard updater for the lifetime of the application.
///
/// Views should call `UpdateController.shared.checkForUpdates()` instead of
/// constructing their own updater. The application delegate starts this
/// controller after launch so Sparkle can schedule background update checks.
@MainActor
final class UpdateController {
    static let shared = UpdateController()

    private let controller: SPUStandardUpdaterController
    private var hasStarted = false

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Whether Sparkle is currently able to begin a user-initiated check.
    var canCheckForUpdates: Bool {
        hasStarted && controller.updater.canCheckForUpdates
    }

    /// Starts Sparkle once. Calling this method repeatedly is safe.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        controller.startUpdater()
    }

    /// Presents Sparkle's standard update-checking UI.
    func checkForUpdates() {
        start()
        controller.checkForUpdates(nil)
    }
}
