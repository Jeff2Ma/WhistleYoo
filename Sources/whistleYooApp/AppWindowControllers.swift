import AppKit
import SwiftUI
#if canImport(whistleYooCore)
import whistleYooCore
#endif

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private static let defaultContentSize = NSSize(width: 1280, height: 800)
    private static let minimumWindowSize = NSSize(width: 900, height: 640)
    private static let windowStyleMask: NSWindow.StyleMask = [
        .titled, .closable, .miniaturizable, .resizable
    ]
    private static let contentWidthDefaultsKey = "MainWorkspaceWindowContentWidth"
    private static let contentHeightDefaultsKey = "MainWorkspaceWindowContentHeight"
    private static let hostingSizeMigrationDefaultsKey = "MainWorkspaceWindowHostingSizeMigrationV1"

    private static var minimumContentSize: NSSize {
        NSWindow.contentRect(
            forFrameRect: NSRect(origin: .zero, size: minimumWindowSize),
            styleMask: windowStyleMask
        ).size
    }

    private let selection: MainWorkspaceSelection
    private let mobileModel: MobileSetupViewModel
    private let rulesDraft: RuleConfigurationDraft

    init(
        state: AppStateController,
        consoleSession: WhistleConsoleSession,
        initialTab: MainWorkspaceTab,
        exportCertificate: @escaping () -> Void,
        runOnboarding: @escaping () -> Void
    ) {
        let rulesDraft = RuleConfigurationDraft()
        selection = MainWorkspaceSelection(selected: initialTab)
        mobileModel = MobileSetupViewModel(state: state)
        self.rulesDraft = rulesDraft
        let rootView = MainWorkspaceView(
            state: state,
            consoleSession: consoleSession,
            selection: selection,
            mobileModel: mobileModel,
            rulesDraft: rulesDraft,
            exportCertificate: exportCertificate,
            runOnboarding: runOnboarding
        )
        let restoredContentSize = Self.restoredContentSize()
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: restoredContentSize),
            styleMask: Self.windowStyleMask,
            backing: .buffered,
            defer: false
        )
        window.title = "WhistleYoo"
        window.minSize = Self.minimumWindowSize
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: rootView)
        // Attaching an NSHostingController resizes a new NSWindow to the SwiftUI
        // root view's fitting size (currently the 900 x 640 minimum). Reapply the
        // restored content size before installing the delegate so that this
        // framework-driven resize cannot replace the user's saved dimensions.
        window.setContentSize(restoredContentSize)
        super.init(window: window)
        shouldCascadeWindows = false
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    var hasUnsavedRules: Bool {
        rulesDraft.isDirty
    }

    func discardUnsavedRules() {
        rulesDraft.discardChanges()
    }

    func show(tab: MainWorkspaceTab, centeredOn preferredScreen: NSScreen?) {
        selection.selected = tab
        centerWindow(centeredOn: preferredScreen)
        window?.makeKeyAndOrderFront(nil)
        reassertWindowPosition(centeredOn: preferredScreen)
    }

    func reopen(centeredOn preferredScreen: NSScreen?) {
        show(tab: selection.selected, centeredOn: preferredScreen)
    }

    private func reassertWindowPosition(centeredOn preferredScreen: NSScreen?) {
        // Avoid NSWindowController.showWindow(_:): its automatic placement can
        // cascade from the status-item popover. Reassert once on the next run-loop
        // turn as well, after AppKit has finished making the window key.
        DispatchQueue.main.async { [weak self] in
            self?.centerWindow(centeredOn: preferredScreen)
        }
    }

    private func centerWindow(centeredOn preferredScreen: NSScreen?) {
        guard let window else { return }
        guard let screen = preferredScreen ?? window.screen ?? NSScreen.main else { return }
        let screenFrame = screen.frame
        var frame = window.frame
        frame.origin = NSPoint(
            x: screenFrame.midX - frame.width / 2,
            y: screenFrame.midY - frame.height / 2
        )
        window.setFrame(frame.integral, display: window.isVisible)
    }

    func windowDidResize(_ notification: Notification) {
        guard let resizedWindow = notification.object as? NSWindow,
              resizedWindow === window else { return }
        persistContentSize(of: resizedWindow)
    }

    func windowWillClose(_ notification: Notification) {
        if let closingWindow = notification.object as? NSWindow,
           closingWindow === window {
            persistContentSize(of: closingWindow)
        }
        mobileModel.stop()
    }

    private func persistContentSize(of window: NSWindow) {
        let size = window.contentLayoutRect.size
        guard size.width.isFinite, size.height.isFinite,
              size.width >= Self.minimumContentSize.width,
              size.height >= Self.minimumContentSize.height else { return }
        UserDefaults.standard.set(size.width, forKey: Self.contentWidthDefaultsKey)
        UserDefaults.standard.set(size.height, forKey: Self.contentHeightDefaultsKey)
    }

    private static func restoredContentSize(defaults: UserDefaults = .standard) -> NSSize {
        let width = defaults.double(forKey: contentWidthDefaultsKey)
        let height = defaults.double(forKey: contentHeightDefaultsKey)

        // Earlier builds let NSHostingController collapse every restored window
        // to the minimum frame size and then persisted that value. Recover that
        // exact poisoned value once; future intentional minimum-size windows are
        // preserved because the migration marker has already been written.
        if !defaults.bool(forKey: hostingSizeMigrationDefaultsKey) {
            defaults.set(true, forKey: hostingSizeMigrationDefaultsKey)
            let minimumContentSize = Self.minimumContentSize
            if abs(width - Double(minimumContentSize.width)) < 0.5,
               abs(height - Double(minimumContentSize.height)) < 0.5 {
                defaults.set(defaultContentSize.width, forKey: contentWidthDefaultsKey)
                defaults.set(defaultContentSize.height, forKey: contentHeightDefaultsKey)
                return defaultContentSize
            }
        }

        guard width.isFinite, height.isFinite,
              width >= minimumContentSize.width,
              height >= minimumContentSize.height else {
            return defaultContentSize
        }
        return NSSize(width: width, height: height)
    }
}

@MainActor
final class OnboardingWindowController: NSWindowController {
    init(state: AppStateController, completion: @escaping () -> Void) {
        let rootView = OnboardingView(state: state, completion: completion)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = Localization.string(.onboardingWhistleyooSetupAssistant)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: rootView)
        super.init(window: window)
        // NSWindowController defaults to cascading newly shown windows from the
        // app's most recent window. For a menu-bar app that window is usually
        // the status-item popover, which would override our centered frame.
        shouldCascadeWindows = false
    }

    required init?(coder: NSCoder) { nil }

    func showCentered(on preferredScreen: NSScreen?) {
        centerWindow(on: preferredScreen)
        window?.makeKeyAndOrderFront(nil)
        // NSWindowController.showWindow(_:) may cascade a new window from the
        // status-item popover. Ordering the already-positioned NSWindow directly
        // bypasses that placement path; the next-run-loop assertion wins over any
        // final key-window adjustment performed by AppKit.
        DispatchQueue.main.async { [weak self] in
            self?.centerWindow(on: preferredScreen)
        }
    }

    private func centerWindow(on preferredScreen: NSScreen?) {
        guard let window,
              let screen = preferredScreen ?? window.screen ?? NSScreen.main else { return }
        let screenFrame = screen.frame
        var frame = window.frame
        frame.origin = NSPoint(
            x: screenFrame.midX - frame.width / 2,
            y: screenFrame.midY - frame.height / 2
        )
        window.setFrame(frame.integral, display: window.isVisible)
    }
}
