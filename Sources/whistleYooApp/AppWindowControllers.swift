import AppKit
import SwiftUI
#if canImport(whistleYooCore)
import whistleYooCore
#endif

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private static let defaultContentSize = NSSize(width: 1280, height: 800)
    private static let minimumWindowSize = NSSize(width: 900, height: 640)
    // `.fullSizeContentView` lets the SwiftUI sidebar paint behind the title bar so
    // the window buttons sit inside the sidebar, the way OrbStack and Finder do it.
    private static let windowStyleMask: NSWindow.StyleMask = [
        .titled, .closable, .miniaturizable, .resizable, .fullSizeContentView
    ]
    private static let contentWidthDefaultsKey = "MainWorkspaceWindowContentWidth"
    private static let contentHeightDefaultsKey = "MainWorkspaceWindowContentHeight"

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
        let workspaceSelection = MainWorkspaceSelection(
            selected: initialTab,
            hasUnsavedChanges: { rulesDraft.isDirty },
            hasOperationInProgress: {
                state.isLoadingRules || state.isSavingRules
                    || state.isLoadingValues || state.isSavingValues
                    || state.isImportingConfiguration
            },
            discardUnsavedChanges: { rulesDraft.discardChanges() }
        )
        selection = workspaceSelection
        mobileModel = MobileSetupViewModel(state: state)
        self.rulesDraft = rulesDraft
        let rootView = MainWorkspaceView(
            state: state,
            consoleSession: consoleSession,
            selection: workspaceSelection,
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
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = Self.minimumWindowSize
        window.isReleasedWhenClosed = false
        // The sidebar toggle must live in the real title bar: with a transparent
        // full-size content view the title bar still sits above the SwiftUI layer
        // and would swallow clicks on any button drawn underneath it.
        window.addTitlebarAccessoryViewController(
            SidebarToggleTitlebarAccessory { workspaceSelection.toggleSidebar() }
        )
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
        selection.request(tab)
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
        // With `.fullSizeContentView` the content rect matches the frame rect, so the
        // frame size is the value that `setContentSize(_:)` expects on the next launch.
        let size = window.frame.size
        guard size.width.isFinite, size.height.isFinite,
              size.width >= Self.minimumWindowSize.width,
              size.height >= Self.minimumWindowSize.height else { return }
        UserDefaults.standard.set(size.width, forKey: Self.contentWidthDefaultsKey)
        UserDefaults.standard.set(size.height, forKey: Self.contentHeightDefaultsKey)
    }

    private static func restoredContentSize(defaults: UserDefaults = .standard) -> NSSize {
        let width = defaults.double(forKey: contentWidthDefaultsKey)
        let height = defaults.double(forKey: contentHeightDefaultsKey)
        // Values written by earlier builds excluded the title bar height, so anything
        // below the minimum window size is discarded in favour of the default size.
        guard width.isFinite, height.isFinite,
              width >= minimumWindowSize.width,
              height >= minimumWindowSize.height else {
            return defaultContentSize
        }
        return NSSize(width: width, height: height)
    }
}

/// Hosts the sidebar toggle inside the window's title bar, right after the window
/// buttons, so it stays reachable whether or not the sidebar is currently visible.
@MainActor
final class SidebarToggleTitlebarAccessory: NSTitlebarAccessoryViewController {
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .leading

        let title = Localization.string(.sidebarToggleSidebar)
        let button = NSButton(frame: NSRect(x: 20, y: 5, width: 26, height: 22))
        button.isBordered = false
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: title)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.target = self
        button.action = #selector(toggle)
        button.autoresizingMask = [.minYMargin, .maxYMargin]

        // AppKit stretches the accessory to the title bar height and takes its width
        // from the view's frame. An Auto Layout width constraint on the controller's
        // own view collapses to zero here, so lay the container out with frames.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 66, height: 32))
        container.addSubview(button)
        view = container
    }

    required init?(coder: NSCoder) { nil }

    @objc private func toggle() {
        handler()
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
